import Foundation
import Observation

/// Chain data, greeks, and — on top of that — unusual-activity ranking for a
/// small, hand-picked list of underlyings.
///
/// Mirrors the shape of `ScannerEngine`/`SwingEngine`/`LongTermEngine`
/// deliberately: its own state, its own refresh loop, its own candidate list —
/// rather than bolting options onto the equity engines, which score and gate
/// on assumptions (VWAP, minute bars, float) that don't apply to a
/// derivatives contract.
///
/// Refresh cadence sits between the day-trade and swing engines: an option
/// chain moves with the underlying, but re-fetching every strike and
/// expiration for several underlyings every few seconds is neither
/// necessary nor within the free tier's comfortable request budget.
@MainActor
@Observable
final class OptionsEngine {
    private(set) var chains: [String: OptionChain] = [:]
    private(set) var unusualActivity: [UnusualActivityDetector.Signal] = []
    private(set) var isRefreshing = false
    private(set) var refreshProgress: Double = 0
    private(set) var refreshMessage = ""
    private(set) var lastRefreshedAt: Date?
    private(set) var lastError: String?

    private let rest: AlpacaREST
    private let paperLog: OptionsPaperTradeLog
    let ivHistory: IVHistoryStore
    let strategyBot: StrategyBotEngine
    let positionActivities = PositionActivityManager()
    private var refreshTask: Task<Void, Never>?
    /// Volume/OI history per contract, so the unusual-activity detector can
    /// compare today's pace against this contract's own recent average
    /// rather than only its static open interest.
    private var volumeHistory: [String: [(date: Date, volume: Int)]] = [:]

    private var settings: Settings { Settings.shared }

    static let refreshInterval: Duration = .seconds(60)

    init(
        rest: AlpacaREST,
        paperLog: OptionsPaperTradeLog,
        ivHistory: IVHistoryStore = IVHistoryStore(),
        strategyBot: StrategyBotEngine? = nil
    ) {
        self.rest = rest
        self.paperLog = paperLog
        self.ivHistory = ivHistory
        self.strategyBot = strategyBot ?? StrategyBotEngine(paperLog: paperLog)
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        await positionActivities.endAll()
    }

    // MARK: - Refresh

    /// How many nearest expirations to keep per underlying. Starts at 3 for
    /// everyone; `loadMoreExpirations(for:)` raises a single underlying's
    /// window and re-fetches just that chain, rather than widening every
    /// chain in the universe at once.
    private var expirationWindow: [String: Int] = [:]
    private static let defaultExpirationCount = 3
    private static let maxExpirationCount = 12

    func refresh() async {
        guard !isRefreshing, settings.hasCredentials else { return }
        isRefreshing = true
        refreshProgress = 0
        defer { isRefreshing = false }

        let universe = settings.optionsUniverse
        guard !universe.isEmpty else { return }

        var builtChains: [String: OptionChain] = [:]

        for (index, underlying) in universe.enumerated() {
            refreshMessage = "Fetching \(underlying) chain"
            let count = expirationWindow[underlying] ?? Self.defaultExpirationCount
            if let chain = await fetchChain(for: underlying, expirationCount: count) {
                builtChains[underlying] = chain
            }
            refreshProgress = Double(index + 1) / Double(universe.count)
            // A chain fetch is several requests (contracts list + snapshot
            // batches); pace between underlyings to stay well clear of
            // Alpaca's per-minute ceiling.
            try? await Task.sleep(for: .milliseconds(300))
        }

        chains = builtChains
        unusualActivity = UnusualActivityDetector.scan(chains: builtChains, history: volumeHistory)
        lastRefreshedAt = Date()
        lastError = builtChains.isEmpty ? "Could not load any option chains." : nil
        refreshProgress = 1.0

        await markOpenPaperTrades()
        recordIVHistory()
        await strategyBot.evaluate()
    }

    /// Records today's front-month at-the-money IV per underlying, so IV
    /// Rank/Percentile has a growing local history to compare against.
    /// Averages call and put IV at the nearest expiration's ATM strike —
    /// the same pairing `ImpliedMoveCalculator` uses — rather than picking
    /// one side arbitrarily.
    private func recordIVHistory() {
        for (underlying, chain) in chains {
            guard let nearestExpiration = chain.expirations.first,
                  let call = chain.atmContract(for: nearestExpiration, type: .call),
                  let put = chain.atmContract(for: nearestExpiration, type: .put) else { continue }
            let ivs = [call.impliedVolatility, put.impliedVolatility].compactMap { $0 }
            guard !ivs.isEmpty else { continue }
            let atmIV = ivs.reduce(0, +) / Double(ivs.count)
            ivHistory.record(symbol: underlying, atmIV: atmIV)
        }
    }

    /// Whether `underlying`'s chain can still grow — false once it's already
    /// showing every expiration Alpaca lists for it or the app's own cap.
    func hasMoreExpirations(for underlying: String) -> Bool {
        let current = expirationWindow[underlying] ?? Self.defaultExpirationCount
        return current < Self.maxExpirationCount
    }

    /// Widens one underlying's expiration window and re-fetches just that
    /// chain. Kept separate from the periodic `refresh()` sweep so drilling
    /// into one chain's later expirations doesn't cost a full-universe
    /// refetch, and so it's safe to call from a "load more" button while a
    /// background refresh is also in flight.
    func loadMoreExpirations(for underlying: String) async {
        guard settings.hasCredentials, hasMoreExpirations(for: underlying) else { return }
        let nextCount = min((expirationWindow[underlying] ?? Self.defaultExpirationCount) + 3, Self.maxExpirationCount)
        expirationWindow[underlying] = nextCount

        refreshMessage = "Loading more \(underlying) expirations"
        guard let chain = await fetchChain(for: underlying, expirationCount: nextCount) else { return }
        chains[underlying] = chain
        unusualActivity = UnusualActivityDetector.scan(chains: chains, history: volumeHistory)
        await markOpenPaperTrades()
        await strategyBot.evaluate()
    }

    /// Marks every open options paper trade against the current chain data.
    /// Fired after any refresh (full sweep or a single-underlying load) so
    /// the journal's marks are never staler than the last successful fetch.
    private func markOpenPaperTrades() async {
        var mids: [String: Double] = [:]
        for contract in chains.values.flatMap(\.contracts) {
            if let mid = contract.mid { mids[contract.symbol] = mid }
        }
        paperLog.markToMarket(midsByContractSymbol: mids)
        await positionActivities.sync(with: paperLog.trades)
    }

    private func fetchChain(for underlying: String, expirationCount: Int) async -> OptionChain? {
        guard let contractsRaw = try? await rest.optionContracts(underlying: underlying),
              !contractsRaw.isEmpty else { return nil }

        // Near-dated, near-the-money contracts are what a chain view and the
        // unusual-activity scan actually care about; the free tier's request
        // budget doesn't stretch to snapshotting every strike out a year by
        // default. `loadMoreExpirations(for:)` raises this on demand.
        let nearest = Self.nearestExpirations(in: contractsRaw, count: expirationCount)
        let scoped = contractsRaw.filter { raw in
            guard let expiry = Self.parseExpiration(raw.expirationDate) else { return false }
            return nearest.contains(expiry)
        }
        guard !scoped.isEmpty else { return nil }

        var quotes: [String: AlpacaREST.OptionQuoteRaw] = [:]
        for batch in scoped.map(\.symbol).chunked(into: 50) {
            guard let page = try? await rest.optionSnapshots(contractSymbols: batch) else { continue }
            quotes.merge(page) { _, new in new }
        }

        guard let spot = await currentPrice(for: underlying) else { return nil }
        let asOf = Date()

        var contracts: [OptionContract] = []
        contracts.reserveCapacity(scoped.count)

        for raw in scoped {
            guard let expiry = Self.parseExpiration(raw.expirationDate),
                  let type = OptionType(rawValue: raw.type.lowercased()) else { continue }

            let quote = quotes[raw.symbol]
            let bid = quote?.latestQuote?.bidPrice
            let ask = quote?.latestQuote?.askPrice
            let last = quote?.latestTrade?.price ?? Double(raw.closePrice ?? "")
            let openInterest = Int(raw.openInterest ?? "")

            var greeks: Greeks?
            var iv = quote?.impliedVolatility

            // The quote-derived mid, falling back to the last trade when the
            // book is one-sided or empty — either is fine as a pricing input
            // for the local IV solve below.
            let pricingMid: Double? = {
                if let bid, let ask, bid > 0, ask > 0 { return (bid + ask) / 2 }
                return last
            }()

            if let g = quote?.greeks {
                greeks = Greeks(
                    delta: g.delta ?? 0, gamma: g.gamma ?? 0,
                    theta: g.theta ?? 0, vega: g.vega ?? 0, rho: g.rho ?? 0
                )
            } else if let mid = pricingMid, mid > 0 {
                // Server didn't return greeks for this contract — recompute
                // locally so the chain never shows a blank delta column.
                let years = max(Double(daysBetween(asOf, expiry)), 0.5) / 365.0
                let solvedIV = iv ?? GreeksEngine.impliedVolatility(
                    marketPrice: mid, spot: spot, strike: raw.strikePrice,
                    timeToExpiryYears: years, type: type
                )
                if let solvedIV {
                    iv = iv ?? solvedIV
                    greeks = GreeksEngine.greeks(.init(
                        spot: spot, strike: raw.strikePrice, timeToExpiryYears: years,
                        impliedVolatility: solvedIV, type: type
                    ))
                }
            }

            let volume = quote?.latestTrade?.size

            contracts.append(OptionContract(
                symbol: raw.symbol,
                underlying: underlying,
                expiration: expiry,
                strike: raw.strikePrice,
                type: type,
                bid: bid, ask: ask, lastPrice: last,
                volume: volume, openInterest: openInterest,
                impliedVolatility: iv, greeks: greeks
            ))

            if let volume {
                var history = volumeHistory[raw.symbol] ?? []
                history.append((date: asOf, volume: volume))
                if history.count > 10 { history.removeFirst() }
                volumeHistory[raw.symbol] = history
            }
        }

        return OptionChain(underlying: underlying, spotPrice: spot, asOf: asOf, contracts: contracts)
    }

    private func currentPrice(for symbol: String) async -> Double? {
        guard let snapshots = try? await rest.snapshots(symbols: [symbol]),
              let snapshot = snapshots[symbol] else { return nil }
        return snapshot.minuteBar?.close ?? snapshot.dailyBar?.close
    }

    private func daysBetween(_ a: Date, _ b: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    private static func nearestExpirations(in raw: [AlpacaREST.OptionContractRaw], count: Int) -> Set<Date> {
        let dates = Set(raw.compactMap { parseExpiration($0.expirationDate) }).sorted()
        return Set(dates.prefix(count))
    }

    private static let expirationFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseExpiration(_ string: String) -> Date? {
        expirationFormatter.date(from: string)
    }

    // MARK: - Lookups

    func chain(for underlying: String) -> OptionChain? { chains[underlying] }

    func contract(symbol: String) -> OptionContract? {
        chains.values.flatMap(\.contracts).first { $0.symbol == symbol }
    }
}
