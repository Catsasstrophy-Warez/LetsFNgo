import Foundation
import Observation

/// Fundamentals scanner for a short, curated watchlist held over months to years.
///
/// This is the slowest-moving engine in the app on purpose. Its data source —
/// SEC XBRL filings — updates quarterly; refreshing more than once every few
/// hours would just re-fetch the same numbers and spend the person's own
/// patience for nothing. The universe is deliberately small: fundamentals
/// scoring across hundreds of tickers produces hundreds of shallow opinions,
/// while a good long-term list is usually a dozen or two companies someone
/// actually wants to understand.
@MainActor
@Observable
final class LongTermEngine {
    private(set) var candidates: [LongTermCandidate] = []
    private(set) var isRefreshing = false
    private(set) var refreshProgress: Double = 0
    private(set) var refreshMessage = ""
    private(set) var lastRefreshedAt: Date?
    private(set) var lastError: String?

    private let rest: AlpacaREST
    private let secFloat: SECFloatClient
    private var refreshTask: Task<Void, Never>?

    private var settings: Settings { Settings.shared }

    init(rest: AlpacaREST, secFloat: SECFloatClient) {
        self.rest = rest
        self.secFloat = secFloat
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: TradeHorizon.longTerm.refreshInterval)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshProgress = 0
        defer { isRefreshing = false }

        let universe = settings.longTermUniverse
        guard !universe.isEmpty else { return }

        // Daily bars for the 200-day trend read and 52-week high, one batched
        // call — cheap, and shared across every symbol in the watchlist.
        refreshMessage = "Fetching price history"
        let dailyBars = (try? await rest.dailyBars(symbols: universe, lookbackDays: 400)) ?? [:]
        refreshProgress = 0.2

        var snapshots: [FundamentalSnapshot] = []
        for (index, symbol) in universe.enumerated() {
            refreshMessage = "Fetching fundamentals for \(symbol)"
            guard let fundamentals = await secFloat.fundamentals(for: symbol) else {
                refreshProgress = 0.2 + (Double(index + 1) / Double(universe.count)) * 0.7
                continue
            }

            var floatRecord = await secFloat.record(for: symbol)
            if floatRecord == nil {
                // Same fallback as the swing engine: don't depend on the
                // day-trade engine's market-wide float refresh ever having
                // run. This engine already has its own daily bars in hand.
                let barsForPricing = dailyBars
                try? await secFloat.refreshSymbol(symbol) { sym, date in
                    SwingEngine.closestClose(in: barsForPricing[sym] ?? [], to: date)
                }
                floatRecord = await secFloat.record(for: symbol)
            }
            let submissions = await secFloat.submissionsSummary(for: symbol)
            let insiderCount = submissions?.form4CountLast90Days ?? 0
            let sector = submissions?.sicDescription

            let bars = (dailyBars[symbol] ?? []).sorted { $0.timestamp < $1.timestamp }
            let lastPrice = bars.last?.close ?? 0

            var priceVsSMA200: Double?
            if bars.count >= 200 {
                let sma200 = bars.suffix(200).map(\.close).reduce(0, +) / 200.0
                if sma200 > 0 { priceVsSMA200 = (lastPrice / sma200) - 1.0 }
            }

            var distanceFromHigh: Double?
            if !bars.isEmpty {
                let high52 = bars.suffix(min(252, bars.count)).map(\.high).max() ?? lastPrice
                if high52 > 0 { distanceFromHigh = (lastPrice / high52) - 1.0 }
            }

            var netMarginYearAgo: Double?
            if let incomeAgo = fundamentals.netIncomeTTMYearAgo, let revenueAgo = fundamentals.revenueTTMYearAgo, revenueAgo > 0 {
                netMarginYearAgo = incomeAgo / revenueAgo
            }

            let snapshot = FundamentalSnapshot(
                symbol: symbol,
                entityName: fundamentals.entityName ?? symbol,
                asOf: Date(),
                lastPrice: lastPrice,
                sharesOutstanding: floatRecord?.sharesOutstanding,
                revenueTTM: fundamentals.revenueTTM,
                revenueTTMYearAgo: fundamentals.revenueTTMYearAgo,
                netIncomeTTM: fundamentals.netIncomeTTM,
                netMarginYearAgo: netMarginYearAgo,
                totalAssets: fundamentals.totalAssets,
                totalLiabilities: fundamentals.totalLiabilities,
                priceVsSMA200Percent: priceVsSMA200,
                distanceFrom52WeekHighPercent: distanceFromHigh,
                floatShares: floatRecord?.floatShares,
                floatCategory: floatRecord?.category,
                insiderFilingsRecent: insiderCount,
                insiderFilingWindowDays: 90,
                sector: sector
            )
            snapshots.append(snapshot)

            refreshProgress = 0.2 + (Double(index + 1) / Double(universe.count)) * 0.7
            // Several SEC calls per symbol; this list is short and the
            // refresh is hourly-plus, so a generous pause per symbol costs
            // nothing while staying well clear of the rate limit.
            try? await Task.sleep(for: .milliseconds(400))
        }

        let model = LongTermScoringModel(weights: settings.longTermWeights)
        candidates = model.rank(snapshots)
        lastRefreshedAt = Date()
        lastError = candidates.isEmpty ? "No symbols returned enough fundamentals data to score." : nil
        refreshProgress = 1.0
    }

    func candidate(for symbol: String) -> LongTermCandidate? {
        candidates.first { $0.symbol == symbol }
    }
}
