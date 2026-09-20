import Foundation
import Observation
import UserNotifications

/// The one object both interfaces read from.
///
/// Simple mode and advanced mode are not two engines — they are two
/// projections of this state. Nothing is computed for one and withheld from
/// the other; advanced mode simply renders more of what already exists.
@MainActor
@Observable
final class ScannerEngine {
    // Published state
    private(set) var candidates: [Candidate] = []
    private(set) var rejected: [(symbol: String, reason: ScoringModel.Rejection)] = []
    private(set) var diagnostics = EngineDiagnostics()
    private(set) var phase: MarketClock.Phase = .closed
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var preparationMessage = ""
    private(set) var preparationProgress: Double = 0
    private(set) var recentAlerts: [Candidate] = []

    // Collaborators
    private let rest = AlpacaREST()
    private let barStream = AlpacaStream(kind: .bars)
    private let newsStream = AlpacaStream(kind: .news)
    private let finra = FINRAShortVolume()
    private let baselines: BaselineStore
    private let universeBuilder: UniverseBuilder
    private let secFloat: SECFloatClient
    private let halts = HaltMonitor()
    private let stockTwits = StockTwitsClient()
    private let edgarStream: EDGARFilingStream
    private let budget = AlertBudgetKeeper()
    private let paperLog: PaperTradeLog
    private let squawk = AudioSquawk()

    // Discovery state
    private(set) var gappers: [UniverseBuilder.Gapper] = []
    private(set) var isScreening = false
    private(set) var screeningMessage = ""
    private(set) var screeningProgress: Double = 0
    private(set) var lastScreenSummary: String?

    // Float
    private(set) var isRefreshingFloat = false
    private(set) var floatProgress: Double = 0
    private(set) var floatMessage = ""
    private(set) var floatRecordCount = 0
    private(set) var floatLastRefreshed: Date?

    // Halts
    private(set) var haltEvents: [HaltMonitor.HaltEvent] = []
    private(set) var activeHalts: Set<String> = []
    private(set) var freshResumes: [HaltMonitor.HaltEvent] = []
    private(set) var haltIntensity: Double = 0

    // Alert budget
    private(set) var slotsRemaining: Int = 0
    private(set) var slotsCapacity: Int = 0
    private(set) var minutesUntilNextSlot: Int?
    private(set) var suppressedAlerts: [AlertBudget.Suppression] = []

    // Social and insider filing feeds
    private(set) var trendingSocial: [StockTwitsClient.TrendingSymbol] = []
    private(set) var insiderClusterList: [EDGARFilingStream.ClusterSignal] = []
    private(set) var recentFiled8Ks: [EDGARFilingStream.FilingEvent] = []
    private(set) var socialLastRefreshed: Date?

    // Internal state
    private var states: [String: SymbolState] = [:]
    private var shortPercentiles: [String: Double] = [:]
    private var shortRatios: [String: Double] = [:]
    /// Mirrored onto the main actor so snapshot building stays synchronous.
    /// Refreshed whenever the universe is screened or the day rolls over.
    private var volatilityProfiles: [String: VolatilityProfile] = [:]
    private var tier1Cache: Set<String> = []
    private var floatCache: [String: SECFloatClient.FloatRecord] = [:]
    private var haltCountToday: [String: Int] = [:]
    private var haltTask: Task<Void, Never>?
    private var filingTask: Task<Void, Never>?
    private var socialTask: Task<Void, Never>?
    private var socialCache: [String: StockTwitsClient.SentimentSnapshot] = [:]
    private var socialTrending: [StockTwitsClient.TrendingSymbol] = []
    private var socialSurge: [String: Double] = [:]
    private var insiderClusters: [String: EDGARFilingStream.ClusterSignal] = [:]
    private var filedReports8K: [String: EDGARFilingStream.FilingEvent] = [:]
    /// Prior closes, kept so SEC public-float dollars can be converted to
    /// shares using the price on the filing's measurement date.
    private var dailyCloseCache: [String: [(date: Date, close: Double)]] = [:]
    private var lastAlertAt: [String: Date] = [:]
    private var barTimestamps: [Date] = []

    private var barTask: Task<Void, Never>?
    private var newsTask: Task<Void, Never>?
    private var scoreTask: Task<Void, Never>?

    private var settings: Settings { Settings.shared }

    /// IEX's approximate share of consolidated US equity volume. Used only to
    /// scale float rotation, never to report a volume figure — every other
    /// volume signal in the app is a ratio and needs no such correction.
    private static let iexVolumeShare = 0.025

    init(paperLog: PaperTradeLog) {
        self.paperLog = paperLog
        self.secFloat = SECFloatClient(contactEmail: Settings.shared.secContactEmail)
        self.edgarStream = EDGARFilingStream(contactEmail: Settings.shared.secContactEmail)
        self.baselines = BaselineStore(rest: rest)
        self.universeBuilder = UniverseBuilder(rest: rest)
        self.phase = MarketClock.phase()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning, !isPreparing else { return }
        guard settings.hasCredentials else {
            diagnostics.lastError = "Add your Alpaca key and secret in Settings."
            return
        }

        isPreparing = true
        defer { isPreparing = false }

        let universe = settings.universe
        for symbol in universe where states[symbol] == nil {
            states[symbol] = SymbolState(symbol: symbol)
        }

        // 1. Short volume. Cheap, one file, and safe to fail — the component
        // simply scores zero if FINRA is unreachable.
        preparationMessage = "Loading short volume data"
        preparationProgress = 0.05
        do {
            let fileDate = try await finra.load()
            diagnostics.shortVolumeFileDate = fileDate
            var percentiles: [String: Double] = [:]
            var ratios: [String: Double] = [:]
            for symbol in universe {
                if let value = await finra.percentile(for: symbol) { percentiles[symbol] = value }
                if let record = await finra.record(for: symbol) { ratios[symbol] = record.shortRatio }
            }
            shortPercentiles = percentiles
            shortRatios = ratios
        } catch {
            diagnostics.lastError = "Short volume unavailable: \(error.localizedDescription)"
        }

        // 2. Baselines. The slow part — only rebuilt once per trading day.
        let fresh = await baselines.isFresh(for: universe)
        if !fresh {
            preparationMessage = "Building volume baselines"
            do {
                try await baselines.build(
                    universe: universe,
                    sessions: settings.baselineSessions
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.preparationProgress = 0.05 + (progress * 0.8)
                    }
                }
            } catch {
                diagnostics.lastError = "Baseline build failed: \(error.localizedDescription)"
            }
        }
        await syncVolatilityProfiles()
        await syncFloatCache()
        startHaltMonitor()
        startFilingStream()
        startSocialLoop()
        diagnostics.symbolsWithBaseline = await baselines.count
        diagnostics.baselineCoverage = await baselines.coverage(for: universe)

        // 3. Seed today's prices so the list isn't blank before the first bar.
        preparationMessage = "Fetching today's prices"
        preparationProgress = 0.9
        await seedFromSnapshots(universe: universe)

        // 4. Backfill headlines from the last few hours, so a 6am catalyst
        // still shows up when the app opens at 9:25.
        preparationMessage = "Loading recent headlines"
        preparationProgress = 0.95
        await backfillNews(universe: universe)

        // 5. Go live.
        preparationMessage = "Connecting"
        startStreams(universe: universe)
        startScoringLoop()
        isRunning = true
        preparationProgress = 1.0
    }

    func stop() async {
        isRunning = false
        barTask?.cancel()
        newsTask?.cancel()
        scoreTask?.cancel()
        haltTask?.cancel()
        filingTask?.cancel()
        socialTask?.cancel()
        await halts.stop()
        await edgarStream.stop()
        await barStream.stop()
        await newsStream.stop()
        diagnostics.barStreamStatus = .idle
        diagnostics.newsStreamStatus = .idle
    }

    func restart() async {
        await stop()
        await start()
    }

    /// Called when the user edits the universe without a full restart.
    func updateUniverse(_ symbols: [String]) async {
        for symbol in symbols where states[symbol] == nil {
            states[symbol] = SymbolState(symbol: symbol)
        }
        for symbol in states.keys where !symbols.contains(symbol) {
            states.removeValue(forKey: symbol)
        }
        await barStream.updateSymbols(symbols)
        await newsStream.updateSymbols(symbols)
        diagnostics.subscribedSymbols = symbols.count
    }

    // MARK: - Priming

    private func seedFromSnapshots(universe: [String]) async {
        // Chunked because the snapshot endpoint has a practical symbol limit.
        for chunk in universe.chunked(into: 100) {
            guard let snapshots = try? await rest.snapshots(symbols: chunk) else { continue }
            for (symbol, snapshot) in snapshots {
                guard var state = states[symbol] else { continue }
                if let daily = snapshot.dailyBar {
                    state.seed(
                        open: daily.open,
                        high: daily.high,
                        low: daily.low,
                        last: snapshot.minuteBar?.close ?? daily.close,
                        volume: daily.volume
                    )
                }
                states[symbol] = state
            }
        }
    }

    private func backfillNews(universe: [String]) async {
        let since = Calendar.current.date(byAdding: .hour, value: -12, to: Date()) ?? Date()
        for chunk in universe.chunked(into: 50) {
            guard let items = try? await rest.recentNews(symbols: chunk, since: since) else { continue }
            for item in items {
                for symbol in item.symbols {
                    guard var state = states[symbol] else { continue }
                    state.attach(news: item)
                    states[symbol] = state
                }
            }
        }
    }

    // MARK: - Streams

    private func startStreams(universe: [String]) {
        diagnostics.subscribedSymbols = universe.count

        barTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.barStream.events(symbols: universe)
            for await event in stream {
                await self.handle(event)
            }
        }

        newsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.newsStream.events(symbols: universe)
            for await event in stream {
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .bar(let bar):
            guard var state = states[bar.symbol] else {
                diagnostics.droppedBars += 1
                return
            }
            let accepted = state.apply(bar: bar, includePremarket: settings.includePremarketInVWAP)
            states[bar.symbol] = state
            if accepted {
                diagnostics.barsReceived += 1
                diagnostics.lastBarAt = bar.timestamp
                trackBarRate()
            }

        case .news(let item):
            for symbol in item.symbols {
                guard var state = states[symbol] else { continue }
                state.attach(news: item)
                states[symbol] = state
            }

        case .status(let status, let kind):
            switch kind {
            case .bars: diagnostics.barStreamStatus = status
            case .news: diagnostics.newsStreamStatus = status
            }

        case .error(let message):
            diagnostics.lastError = message
        }
    }

    private func trackBarRate() {
        let now = Date()
        barTimestamps.append(now)
        barTimestamps.removeAll { now.timeIntervalSince($0) > 60 }
        diagnostics.barsPerMinute = Double(barTimestamps.count)
    }

    // MARK: - Scoring loop

    /// Rescoring on a timer rather than per-bar. Bars arrive in a burst at the
    /// top of each minute; scoring on every one would rank the list hundreds of
    /// times for the same information.
    private func startScoringLoop() {
        scoreTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.rescore()
                let interval = await self?.settings.activeProfile.rescoreInterval ?? .seconds(3)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func rescore() async {
        phase = MarketClock.phase()
        let started = Date()

        guard let minute = MarketClock.minuteOfSession(), minute >= 0 else {
            // Outside regular hours there is no baseline curve to divide by,
            // so the list is intentionally empty rather than misleading.
            candidates = []
            return
        }

        var snapshots: [SignalSnapshot] = []
        snapshots.reserveCapacity(states.count)

        for (symbol, state) in states {
            guard let baseline = await baselines.baseline(for: symbol), baseline.isUsable else { continue }
            snapshots.append(makeSnapshot(state: state, baseline: baseline, minute: minute))
        }

        var model = ScoringModel(config: settings.scoring)
        model.allowHalted = settings.activeProfile == .haltResume
        model.recipe = activeRecipe
        model.freshResumeSymbols = Set(freshResumes.map(\.symbol))

        let result = await Task.detached(priority: .userInitiated) { [snapshots, model] in
            model.rank(snapshots)
        }.value

        // Hard cap the ranked list.
        //
        // An unbounded list lets the ranking avoid making a hard call. Every
        // scanner that traders actually rely on bounds its output — a fixed
        // number of names forces the score to mean something, and twenty is
        // more than anyone can watch at once anyway.
        candidates = Array(result.candidates.prefix(settings.maxRankedResults))
        rejected = result.rejected.map { (symbol: $0.0, reason: $0.1) }
        diagnostics.lastScoredAt = Date()
        diagnostics.scoringDurationMs = Date().timeIntervalSince(started) * 1000

        // Mark open paper trades against every price we hold, not just the
        // ranked ones — a trade opened an hour ago may have since been gated
        // out of the list, and its outcome still needs recording.
        var prices: [String: Double] = [:]
        for (symbol, state) in states where state.last > 0 { prices[symbol] = state.last }
        paperLog.markToMarket(prices: prices)
        paperLog.markHalted(symbols: activeHalts)

        await fireAlerts(for: result.candidates)
    }

    private func makeSnapshot(state: SymbolState, baseline: VolumeBaseline, minute: Int) -> SignalSnapshot {
        let expectedCumulative = baseline.cumulative(at: minute)
        let expectedBar = baseline.barVolume(at: minute)

        let rvol = expectedCumulative > 0 ? state.sumVolume / expectedCumulative : 0
        let barRVOL = expectedBar > 0 ? state.lastBarVolume / expectedBar : 0

        let gap = baseline.priorClose > 0 && state.sessionOpen > 0
            ? (state.sessionOpen / baseline.priorClose) - 1.0
            : 0

        let latest = state.latestNews
        let extended = makeExtendedSignals(state: state, baseline: baseline, minute: minute)

        return SignalSnapshot(
            symbol: state.symbol,
            asOf: Date(),
            last: state.last,
            priorClose: baseline.priorClose,
            sessionOpen: state.sessionOpen,
            dayHigh: state.dayHigh,
            dayLow: state.dayLow == .greatestFiniteMagnitude ? state.last : state.dayLow,
            vwap: state.vwap,
            vwapZ: state.vwapZ,
            vwapEvent: state.lastEvent,
            minutesSinceVWAPEvent: state.minutesSinceLastEvent,
            trend: state.currentSide,
            rvol: rvol,
            cumulativeVolume: state.sumVolume,
            baselineVolumeAtMinute: expectedCumulative,
            minuteOfSession: minute,
            barRVOL: barRVOL,
            gapPercent: gap,
            atr14: baseline.atr14,
            rangePosition: state.rangePosition,
            latestNews: latest,
            newsAgeMinutes: state.newsAgeMinutes,
            newsCategory: latest?.category,
            shortRatio: shortRatios[state.symbol],
            shortRatioPercentile: shortPercentiles[state.symbol],
            dollarVolume: state.dollarVolume,
            tradeCount: state.lastTradeCount,
            extended: extended
        )
    }

    /// Volatility, microstructure and hazard signals.
    ///
    /// The volatility block is looked up from the cached daily-bar profile and
    /// changes once a day. The microstructure block is recomputed from the
    /// last twenty bars on every scoring pass, which is why the scalp profile
    /// can afford a two-second cadence.
    private func makeExtendedSignals(
        state: SymbolState,
        baseline: VolumeBaseline,
        minute: Int
    ) -> ExtendedSignals {
        var extended = ExtendedSignals()

        // Daily-derived block.
        if let profile = volatilityProfiles[state.symbol] {
            extended.atrPercent = profile.atrPercent
            extended.runnerFrequency = profile.runnerFrequency
            extended.medianDailyRangePercent = profile.medianRangePercent
            extended.compressionRatio = profile.compressionRatio
            extended.averageDailyVolume = profile.medianDailyVolume

            if profile.medianRangePercent > 0, state.sessionOpen > 0 {
                let todayRange = (state.dayHigh - state.dayLow) / state.sessionOpen
                extended.rangeExpansion = todayRange / profile.medianRangePercent
            }
        }

        // Float, from SEC filings.
        if let record = floatCache[state.symbol] {
            extended.floatShares = record.floatShares
            extended.sharesOutstanding = record.sharesOutstanding
            extended.floatCategory = record.category
            extended.floatAgeDays = record.ageInDays
            extended.floatIsStale = record.isPotentiallyStale
            if let float = record.floatShares, float > 0 {
                // Today's volume is IEX-only, so scale it up by the exchange's
                // approximate share of consolidated volume before comparing it
                // to a whole-market float. Rough, but the alternative is a
                // rotation figure understated by roughly fiftyfold.
                let estimatedConsolidated = state.sumVolume / Self.iexVolumeShare
                extended.floatRotation = estimatedConsolidated / float
            }
        }

        // Social, from StockTwits.
        if let snapshot = socialCache[state.symbol] {
            extended.socialSentimentScore = snapshot.sentimentScore
            extended.socialTaggedFraction = snapshot.taggedFraction
        }
        extended.socialTrendingRank = trendingSocial.firstIndex { $0.symbol.uppercased() == state.symbol }
        extended.socialMessageSurge = socialSurge[state.symbol]
        extended.socialWatchCount = trendingSocial.first { $0.symbol.uppercased() == state.symbol }?.watchlistCount

        // Insider clusters and filed 8-Ks, from the live EDGAR filing feed.
        if let cluster = insiderClusters[state.symbol] {
            extended.insiderClusterFilers = cluster.filingCount
            extended.insiderClusterMinutesAgo = Int(Date().timeIntervalSince(cluster.windowEnd) / 60)
        }
        if let report = filedReports8K[state.symbol],
           Date().timeIntervalSince(report.filedAt) < 2 * 3600 {
            extended.filedCatalystMinutesAgo = max(0, Int(Date().timeIntervalSince(report.filedAt) / 60))
            extended.filedCatalystForm = report.form
        }

        // Halts, from the exchange feed.
        extended.isHalted = activeHalts.contains(state.symbol)
        extended.haltsToday = haltCountToday[state.symbol] ?? 0
        if let event = freshResumes.first(where: { $0.symbol == state.symbol }) {
            extended.haltCode = event.code.rawValue
            extended.minutesSinceResume = event.minutesSinceResume
            extended.isFreshTradeableResume = true
        } else if extended.isHalted,
                  let active = haltEvents.first(where: { $0.symbol == state.symbol && !$0.isResumed }) {
            extended.haltCode = active.code.rawValue
        }

        extended.premarketVolumeRatio = extended.averageDailyVolume > 0
            ? state.premarketVolume / (extended.averageDailyVolume * 0.03)
            : 0

        let atr = baseline.atr14
        extended.openingDriveATR = MicroStructure.openingDrive(state.recentBars, atr: atr)

        // Microstructure block.
        let micro = MicroStructure.compute(
            bars: state.recentBars,
            vwap: state.vwap,
            atr: atr,
            barVolumeMedian: baseline.barVolume(at: minute)
        )
        extended.consecutiveDirectionalBars = micro.consecutive
        extended.burstScore = micro.burst
        extended.pullbackDepthATR = micro.pullbackDepthATR
        extended.pullbackQuality = micro.pullbackQuality
        extended.acceleration = micro.acceleration
        extended.barSpreadPercent = micro.spreadPercent

        // Hazard block.
        if atr > 0, state.sessionOpen > 0 {
            extended.extensionATR = abs(state.last - state.sessionOpen) / atr
        }
        // The LULD reference price is the average trade price over the
        // preceding five minutes; the recent bar VWAP is a close stand-in.
        let referenceWindow = state.recentBars.suffix(5)
        if !referenceWindow.isEmpty {
            let referenceVolume = referenceWindow.reduce(0.0) { $0 + $1.volume }
            let referencePrice = referenceVolume > 0
                ? referenceWindow.reduce(0.0) { $0 + ($1.barVWAP * $1.volume) } / referenceVolume
                : state.last
            extended.luldProximity = LULD.proximity(
                price: state.last,
                referencePrice: referencePrice,
                isTier1: tier1Cache.contains(state.symbol)
            )
            extended.isLikelyHaltable = extended.luldProximity > 0.85
        }

        return extended
    }

    // MARK: - Alerts

    /// Alerts now pass through a global attention budget as well as the
    /// per-symbol cooldown.
    ///
    /// A cooldown bounds repetition but not volume: forty different symbols can
    /// each alert once and still bury you, which is precisely what happens in
    /// the first ten minutes of a busy session. The budget rations slots per
    /// rolling window and awards them to the best candidates.
    private func fireAlerts(for candidates: [Candidate]) async {
        budget.update(config: settings.alertBudget)

        let grants = budget.evaluate(
            candidates: candidates,
            threshold: settings.scoring.alertThreshold,
            cooldownMinutes: settings.scoring.alertCooldownMinutes
        )

        slotsCapacity = budget.currentCapacity
        slotsRemaining = budget.slotsRemaining
        minutesUntilNextSlot = budget.minutesUntilNextSlot
        suppressedAlerts = budget.recentSuppressions

        for grant in grants {
            let candidate = grant.candidate
            lastAlertAt[candidate.symbol] = Date()
            recentAlerts.insert(candidate, at: 0)
            if recentAlerts.count > 50 { recentAlerts.removeLast() }

            if settings.notificationsEnabled {
                await Notifier.post(candidate: candidate, wasPreemption: grant.wasPreemption)
            }
            if settings.audioSquawkEnabled, settings.squawkTopSetups {
                squawk.speakTopSetup(candidate)
            }
            if settings.autoPaperTradeOnAlert {
                let setup = SetupType.classify(
                    candidate,
                    isFreshResume: freshResumes.contains { $0.symbol == candidate.symbol }
                )
                paperLog.open(from: candidate, setup: setup, recipeName: settings.activeRecipeName)
            }
        }
    }

    // MARK: - Profiles

    /// Switching profile swaps the entire scoring personality: weights, gates,
    /// decay constants and rescore cadence. Normalization anchors the user has
    /// tuned by hand are carried across, since those describe the symbols
    /// rather than the strategy.
    func switchProfile(to profile: ScanProfile) {
        settings.activeProfile = profile
        settings.scoring = profile.makeConfig(preserving: settings.scoring)

        // Restart the scoring loop so the new cadence takes effect immediately
        // rather than after the current sleep expires.
        scoreTask?.cancel()
        if isRunning { startScoringLoop() }

        Task { await rescore() }
    }

    // MARK: - Discovery

    /// Screens the whole tradable market down to a ranked universe of symbols
    /// with the demonstrated capacity to move.
    ///
    /// Slow and request-heavy — this is a weekly job, not a per-session one.
    /// `refreshDiscovery()` is the daily equivalent.
    func screenMarket(criteria: DiscoveryCriteria) async {
        guard !isScreening, settings.hasCredentials else { return }
        isScreening = true
        screeningProgress = 0
        defer { isScreening = false }

        do {
            // Float first, so the screen can actually filter on it.
            await refreshFloat()
            var floatLookup: [String: Double] = [:]
            for (symbol, record) in await allFloatRecords() {
                if let shares = record.floatShares { floatLookup[symbol] = shares }
            }

            let result = try await universeBuilder.screen(
                criteria: criteria,
                floatLookup: floatLookup
            ) { [weak self] progress, message in
                Task { @MainActor in
                    self?.screeningProgress = progress
                    self?.screeningMessage = message
                }
            }

            guard !result.universe.isEmpty else {
                lastScreenSummary = "Nothing passed the screen. Loosen the criteria."
                return
            }

            lastScreenSummary = "\(result.passed) of \(result.examined) symbols passed; kept the top \(result.universe.count)."
            settings.universe = result.universe
            await syncVolatilityProfiles()
            await restart()
        } catch {
            diagnostics.lastError = "Screen failed: \(error.localizedDescription)"
        }
    }

    /// Refreshes volatility profiles for the current universe without
    /// re-screening the market. Cheap enough to run every morning.
    func refreshDiscovery(criteria: DiscoveryCriteria) async {
        guard settings.hasCredentials else { return }
        isScreening = true
        screeningMessage = "Refreshing volatility profiles"
        defer { isScreening = false }

        try? await universeBuilder.refresh(universe: settings.universe, criteria: criteria)
        await syncVolatilityProfiles()
    }

    private func syncVolatilityProfiles() async {
        var mirrored: [String: VolatilityProfile] = [:]
        var tier1: Set<String> = []
        for profile in await universeBuilder.allProfiles() {
            mirrored[profile.symbol] = profile
            if await universeBuilder.isTier1(profile.symbol) { tier1.insert(profile.symbol) }
        }
        volatilityProfiles = mirrored
        tier1Cache = tier1
    }

    /// Ranks pre-market gappers. Meaningful roughly from 7:00 ET.
    func scanGappers() async {
        guard settings.hasCredentials else { return }
        let newsSymbols = Set(states.values.flatMap { state in
            state.news
                .filter { Date().timeIntervalSince($0.createdAt) < 18 * 3600 }
                .flatMap(\.symbols)
        })

        // Screen a wider pool than the live universe — the point of a gapper
        // scan is to find what you weren't already watching.
        let pool = volatilityProfiles.isEmpty
            ? settings.universe
            : Array(volatilityProfiles.keys.prefix(600))

        gappers = (try? await universeBuilder.scanGappers(
            universe: pool,
            newsSymbols: newsSymbols
        )) ?? []
    }

    /// Adds discovered gappers to the live universe so the scanner starts
    /// streaming them immediately.
    func adoptGappers(_ symbols: [String], limit: Int = 40) async {
        var merged = settings.universe
        for symbol in symbols where !merged.contains(symbol) {
            merged.append(symbol)
            if merged.count >= settings.universe.count + limit { break }
        }
        settings.universe = merged
        await updateUniverse(merged)
    }

    func volatilityProfile(for symbol: String) -> VolatilityProfile? {
        volatilityProfiles[symbol]
    }

    // MARK: - SEC float

    /// Pulls float for the entire market from EDGAR.
    ///
    /// Runs off the Frames endpoint, so this is a handful of requests rather
    /// than one per symbol. Float only changes when a company files, so once a
    /// week is ample — and the cached copy survives relaunches.
    func refreshFloat(force: Bool = false) async {
        guard !isRefreshingFloat else { return }
        if !force, let last = floatLastRefreshed,
           Date().timeIntervalSince(last) < 6 * 24 * 3600 {
            return
        }

        isRefreshingFloat = true
        floatProgress = 0
        defer { isRefreshingFloat = false }

        // Public float is reported in dollars as of a filing date, so turning
        // it into a share count needs the price on that date.
        let lookup: @Sendable (String, Date) async -> Double? = { [weak self] symbol, date in
            await self?.closePrice(for: symbol, near: date)
        }

        do {
            let count = try await secFloat.refreshMarketFloat(priceLookup: lookup) { [weak self] progress, message in
                Task { @MainActor in
                    self?.floatProgress = progress
                    self?.floatMessage = message
                }
            }
            floatRecordCount = count
            floatLastRefreshed = await secFloat.lastRefreshedAt
            await syncFloatCache()
        } catch {
            diagnostics.lastError = "Float refresh failed: \(error.localizedDescription)"
        }
    }

    /// Mirrors float records for the current universe onto the main actor so
    /// snapshot building stays synchronous.
    private func syncFloatCache() async {
        var mirrored: [String: SECFloatClient.FloatRecord] = [:]
        for symbol in settings.universe {
            if let record = await secFloat.record(for: symbol) { mirrored[symbol] = record }
        }
        floatCache = mirrored
        floatRecordCount = await secFloat.recordCount
        floatLastRefreshed = await secFloat.lastRefreshedAt
    }

    /// Closing price on or near a date, from cached daily bars. Falls back to
    /// a REST fetch for a symbol not yet cached.
    private func closePrice(for symbol: String, near date: Date) async -> Double? {
        if let series = dailyCloseCache[symbol], !series.isEmpty {
            return nearest(in: series, to: date)
        }
        guard let bars = try? await rest.dailyBars(symbols: [symbol], lookbackDays: 400),
              let series = bars[symbol]?.map({ (date: $0.timestamp, close: $0.close) }),
              !series.isEmpty else { return nil }
        dailyCloseCache[symbol] = series
        return nearest(in: series, to: date)
    }

    private func nearest(in series: [(date: Date, close: Double)], to date: Date) -> Double? {
        // Filing measurement dates are quarter-ends, which are frequently not
        // trading days, so match the closest bar rather than an exact date.
        series.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }?.close
    }

    func socialSentiment(for symbol: String) -> StockTwitsClient.SentimentSnapshot? {
        socialCache[symbol]
    }

    func insiderCluster(for symbol: String) -> EDGARFilingStream.ClusterSignal? {
        insiderClusters[symbol]
    }

    func filedReport(for symbol: String) -> EDGARFilingStream.FilingEvent? {
        filedReports8K[symbol]
    }

    func floatRecord(for symbol: String) -> SECFloatClient.FloatRecord? {
        floatCache[symbol]
    }

    private func allFloatRecords() async -> [String: SECFloatClient.FloatRecord] {
        var result: [String: SECFloatClient.FloatRecord] = [:]
        for symbol in await secFloat.symbols(in: Set(SECFloatClient.FloatCategory.allCases)) {
            if let record = await secFloat.record(for: symbol) { result[symbol] = record }
        }
        return result
    }

    // MARK: - Halts

    private func startHaltMonitor() {
        haltTask?.cancel()
        haltTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.halts.start()
            for await event in stream {
                await self.handleHalt(event)
            }
        }
    }

    private func handleHalt(_ event: HaltMonitor.HaltEvent) async {
        haltEvents = await halts.events
        activeHalts = await halts.haltedSymbols
        freshResumes = await halts.freshResumes
        haltIntensity = await halts.haltIntensity()

        // Count halts per symbol per session. Two is a warning; three means the
        // symbol cannot be traded with any stop discipline.
        if MarketClock.isSameTradingDay(event.haltedAt, Date()) {
            let key = event.symbol
            let seen = haltEvents.filter {
                $0.symbol == key && MarketClock.isSameTradingDay($0.haltedAt, Date())
            }.count
            haltCountToday[key] = seen
        }

        // Record what price was doing going into the pause. The feed doesn't
        // carry direction, and direction is the first thing worth knowing
        // before considering the reopen.
        if !event.isResumed, let state = states[event.symbol], state.recentBars.count >= 5 {
            let window = state.recentBars.suffix(15)
            if let first = window.first, first.close > 0, let last = window.last {
                let percent = (last.close / first.close) - 1.0
                await halts.annotate(symbol: event.symbol, priceIntoHalt: last.close, percentIntoHalt: percent)
            }
        }

        // A reopening symbol that isn't in the universe is worth streaming,
        // since the halt list is a discovery channel in its own right.
        if event.code.isTradeableResume, settings.autoAdoptHaltedSymbols,
           !settings.universe.contains(event.symbol) {
            await adoptGappers([event.symbol], limit: 1)
        }

        if settings.notificationsEnabled, settings.haltNotifications {
            await Notifier.postHalt(event)
        }
        if settings.audioSquawkEnabled, settings.squawkHalts {
            squawk.speakHalt(event)
        }
    }

    func refreshHalts() async {
        await halts.poll()
        haltEvents = await halts.events
        activeHalts = await halts.haltedSymbols
        freshResumes = await halts.freshResumes
        haltIntensity = await halts.haltIntensity()
    }

    func haltEvent(for symbol: String) async -> HaltMonitor.HaltEvent? {
        await halts.latestEvent(for: symbol)
    }

    // MARK: - Recipes

    /// Applies a named recipe on top of the current profile. Passing nil
    /// returns to the plain profile scan.
    func applyRecipe(_ recipe: ScanRecipe?) {
        settings.activeRecipeName = recipe?.name
        if let recipe {
            settings.activeProfile = recipe.baseProfile
            settings.scoring = recipe.makeConfig(from: recipe.baseProfile.makeConfig(preserving: settings.scoring))
        } else {
            settings.scoring = settings.activeProfile.makeConfig(preserving: settings.scoring)
        }
        scoreTask?.cancel()
        if isRunning { startScoringLoop() }
        Task { await rescore() }
    }

    var activeRecipe: ScanRecipe? {
        settings.activeRecipeName.flatMap { name in
            RecipeLibrary.recipe(named: name) ?? CustomRecipeStore.shared.recipe(named: name)
        }
    }

    // MARK: - EDGAR filing stream (insider clusters + filed catalysts)

    private func startFilingStream() {
        filingTask?.cancel()
        filingTask = Task { [weak self] in
            guard let self else { return }
            // Share the CIK -> ticker table already built for float lookups,
            // so this doesn't fetch the ten-thousand-row mapping a second time.
            let lookup = await self.buildCIKLookup()
            await self.edgarStream.updateTickerLookup(lookup)

            let stream = await self.edgarStream.start()
            for await event in stream {
                await self.handleFiling(event)
            }
        }
    }

    /// Builds the CIK-to-ticker map the filing stream needs to resolve
    /// symbols. Deliberately market-wide rather than scoped to the current
    /// universe — a fresh insider cluster or 8-K on a symbol nobody is
    /// watching yet is exactly the kind of thing worth surfacing, in the same
    /// spirit as the halt feed doubling as a discovery channel.
    private func buildCIKLookup() async -> [Int: String] {
        await secFloat.fullCIKToTickerMap()
    }

    private func handleFiling(_ event: EDGARFilingStream.FilingEvent) async {
        switch event.family {
        case .insiderTransaction:
            let clusters = await edgarStream.clusters()
            insiderClusters = Dictionary(uniqueKeysWithValues: clusters.map { ($0.symbol, $0) })
            insiderClusterList = clusters.filter(\.isSignificant)
        case .currentReport:
            if let symbol = event.symbol {
                filedReports8K[symbol] = event
            }
            recentFiled8Ks = await edgarStream.recentCurrentReports
        }
        if settings.audioSquawkEnabled, settings.squawkFilings {
            squawk.speakFiling(event)
        }
    }

    // MARK: - Social sentiment (StockTwits)

    private func startSocialLoop() {
        socialTask?.cancel()
        socialTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSocial()
                // Keyless public endpoints deserve a slow, polite cadence —
                // this is retail chatter, not a data feed anyone is paying to
                // keep fast, and hammering it risks losing access for everyone.
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    private func refreshSocial() async {
        try? await stockTwits.refreshTrending()
        trendingSocial = await stockTwits.trending()

        // Sentiment is refreshed for the current universe plus anything
        // already trending, so a name trending outside the watchlist still
        // surfaces rather than being invisible until manually added.
        let trendingSymbols = Set(trendingSocial.prefix(30).map(\.symbol))
        let targets = Array(Set(settings.universe).union(trendingSymbols))
        await stockTwits.refreshSentiment(for: targets)

        var sentimentCache: [String: StockTwitsClient.SentimentSnapshot] = [:]
        var surgeCache: [String: Double] = [:]
        for symbol in targets {
            if let snapshot = await stockTwits.sentiment(for: symbol) { sentimentCache[symbol] = snapshot }
            if let surge = await stockTwits.messageCountSurge(for: symbol) { surgeCache[symbol] = surge }
        }
        socialCache = sentimentCache
        socialSurge = surgeCache
        socialLastRefreshed = Date()
    }

    // MARK: - Lookups for detail views

    func state(for symbol: String) -> SymbolState? { states[symbol] }

    func candidate(for symbol: String) -> Candidate? {
        candidates.first { $0.symbol == symbol }
    }

    func baseline(for symbol: String) async -> VolumeBaseline? {
        await baselines.baseline(for: symbol)
    }

    func clearBaselines() async {
        await baselines.clear()
        diagnostics.symbolsWithBaseline = 0
        diagnostics.baselineCoverage = 0
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(candidate: Candidate, wasPreemption: Bool = false) async {
        let content = UNMutableNotificationContent()
        let prefix = wasPreemption ? "★ " : ""
        content.title = "\(prefix)\(candidate.symbol)  \(String(format: "%+.1f%%", candidate.snapshot.changePercent * 100))"
        // Hazards go in the notification body, not just the app. A warning you
        // only see after opening the app is a warning that arrives too late.
        if let hazard = candidate.hazardNote {
            content.body = "\(candidate.plainReason)\n⚠︎ \(hazard)"
        } else {
            content.body = candidate.plainReason
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["symbol": candidate.symbol]

        let request = UNNotificationRequest(
            identifier: "\(candidate.symbol)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Halt and resume notifications are separate from setup alerts and bypass
    /// the score budget — a halt on something you may be holding is not an
    /// opportunity to be rationed.
    static func postHalt(_ event: HaltMonitor.HaltEvent) async {
        let content = UNMutableNotificationContent()
        if event.isResumed {
            content.title = "\(event.symbol) resumed"
            content.body = "\(event.code.displayName) cleared after \(event.minutesHalted)m."
        } else {
            content.title = "\(event.symbol) halted"
            var body = event.code.displayName
            if let expected = event.code.expectedDurationMinutes {
                body += " · usually ~\(expected)m"
            } else {
                body += " · no fixed duration"
            }
            content.body = body
        }
        content.sound = .default
        content.interruptionLevel = event.code.severity >= 4 ? .timeSensitive : .active
        content.userInfo = ["symbol": event.symbol, "halt": true]

        let request = UNNotificationRequest(
            identifier: "halt-\(event.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Utilities

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
