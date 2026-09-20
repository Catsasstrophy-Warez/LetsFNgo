import Foundation
import Observation

/// Daily-bar technical scanner for multi-day to multi-week holds.
///
/// The contrast with `ScannerEngine` is the point: no websocket, no VWAP
/// accumulator, no per-minute rescoring. A swing setup doesn't change in the
/// time it takes to fetch it, so this engine polls REST on a slow timer and
/// is perfectly fine running from the background or being started cold.
@MainActor
@Observable
final class SwingEngine {
    private(set) var candidates: [SwingCandidate] = []
    private(set) var rejected: [(symbol: String, reason: SwingScoringModel.Rejection)] = []
    private(set) var isRunning = false
    private(set) var isRefreshing = false
    private(set) var refreshProgress: Double = 0
    private(set) var refreshMessage = ""
    private(set) var lastRefreshedAt: Date?
    private(set) var lastError: String?

    private let rest: AlpacaREST
    private let secFloat: SECFloatClient
    private var refreshTask: Task<Void, Never>?
    private var floatCache: [String: SECFloatClient.FloatRecord] = [:]
    private var insiderCountCache: [String: Int] = [:]
    private var estimatedFilingCache: [String: Int] = [:]
    private var sectorCache: [String: String] = [:]

    private let settings: Settings

    init(rest: AlpacaREST, secFloat: SECFloatClient, settings: Settings = .shared) {
        self.rest = rest
        self.secFloat = secFloat
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: TradeHorizon.swing.refreshInterval)
            }
        }
    }

    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshProgress = 0
        defer { isRefreshing = false }

        let universe = settings.swingUniverse
        guard !universe.isEmpty else { return }

        refreshMessage = "Fetching daily bars"
        let lookbackDays = 420   // ~280 trading days, enough for a 200-day SMA plus slope room

        let benchmarkSymbol = "SPY"
        var pool = universe
        if !pool.contains(benchmarkSymbol) { pool.append(benchmarkSymbol) }

        var dailyBars: [String: [DailyBar]] = [:]
        for batch in pool.chunked(into: 25) {
            guard let bars = try? await rest.dailyBars(symbols: batch, lookbackDays: lookbackDays) else { continue }
            dailyBars.merge(bars) { _, new in new }
            refreshProgress = min(refreshProgress + (0.5 / Double(max(pool.count / 25, 1))), 0.5)
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard let benchmarkBars = dailyBars[benchmarkSymbol], benchmarkBars.count > 60 else {
            lastError = "Could not load SPY as a relative-strength benchmark."
            return
        }

        refreshMessage = "Refreshing float and filing context"
        for (index, symbol) in universe.enumerated() {
            if floatCache[symbol] == nil {
                if let record = await secFloat.record(for: symbol) {
                    floatCache[symbol] = record
                } else {
                    // The market-wide Frames refresh may never have run — this
                    // engine has no dependency on the day-trade engine's float
                    // button being pressed, so fall back to the per-symbol
                    // fetch using the daily bars already in hand for pricing.
                    try? await secFloat.refreshSymbol(symbol) { [dailyBars] sym, date in
                        Self.closestClose(in: dailyBars[sym] ?? [], to: date)
                    }
                    floatCache[symbol] = await secFloat.record(for: symbol)
                }
            }
            if let summary = await secFloat.submissionsSummary(for: symbol) {
                insiderCountCache[symbol] = summary.form4CountLast90Days
                estimatedFilingCache[symbol] = Self.estimateDaysToNextFiling(from: summary.recentPeriodicFilingDates)
                sectorCache[symbol] = summary.sicDescription
            }
            refreshProgress = 0.5 + (Double(index + 1) / Double(universe.count)) * 0.4
            // One consolidated SEC call per symbol on a slow cadence stays
            // comfortably under the 10 req/sec ceiling without explicit pacing.
            try? await Task.sleep(for: .milliseconds(150))
        }

        refreshMessage = "Scoring"
        var snapshots: [SwingSignalSnapshot] = []
        for symbol in universe {
            guard let bars = dailyBars[symbol], bars.count > 60 else { continue }
            if let snapshot = Self.buildSnapshot(
                symbol: symbol,
                bars: bars,
                benchmark: benchmarkBars,
                floatRecord: floatCache[symbol],
                insiderCount: insiderCountCache[symbol] ?? 0,
                estimatedDaysToNextFiling: estimatedFilingCache[symbol],
                sector: sectorCache[symbol]
            ) {
                snapshots.append(snapshot)
            }
        }

        let model = SwingScoringModel(weights: settings.swingWeights)
        let result = model.rank(snapshots)
        candidates = result.candidates
        rejected = result.rejected.map { (symbol: $0.0, reason: $0.1) }
        lastRefreshedAt = Date()
        lastError = nil
        refreshProgress = 1.0
    }

    // MARK: - Snapshot construction

    nonisolated static func buildSnapshot(
        symbol: String,
        bars: [DailyBar],
        benchmark: [DailyBar],
        floatRecord: SECFloatClient.FloatRecord?,
        insiderCount: Int,
        estimatedDaysToNextFiling: Int?,
        sector: String?
    ) -> SwingSignalSnapshot? {
        let sorted = bars.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 200, let last = sorted.last else { return nil }
        let closes = sorted.map(\.close)

        func sma(_ period: Int) -> Double {
            guard closes.count >= period else { return closes.last ?? 0 }
            return closes.suffix(period).reduce(0, +) / Double(period)
        }

        let sma20 = sma(20), sma50 = sma(50), sma200 = sma(min(200, closes.count))

        // 50-day SMA ten sessions ago, for the slope.
        let sma50Then: Double
        if closes.count >= 60 {
            let window = closes.dropLast(10).suffix(50)
            sma50Then = window.reduce(0, +) / Double(window.count)
        } else {
            sma50Then = sma50
        }
        let sma50Slope = sma50Then > 0 ? (sma50 / sma50Then) - 1.0 : 0

        let priorClose = sorted.count > 1 ? sorted[sorted.count - 2].close : last.close

        // Relative strength: this symbol's N-session return minus SPY's.
        let benchmarkSorted = benchmark.sorted { $0.timestamp < $1.timestamp }
        func returnOver(_ series: [Double], sessions: Int) -> Double {
            guard series.count > sessions, series[series.count - 1 - sessions] > 0 else { return 0 }
            return (series.last! / series[series.count - 1 - sessions]) - 1.0
        }
        let benchmarkCloses = benchmarkSorted.map(\.close)
        let rs20 = returnOver(closes, sessions: 20) - returnOver(benchmarkCloses, sessions: 20)
        let rs60 = returnOver(closes, sessions: 60) - returnOver(benchmarkCloses, sessions: 60)

        let yearWindow = sorted.suffix(min(252, sorted.count))
        let high52 = yearWindow.map(\.high).max() ?? last.high
        let low52 = yearWindow.map(\.low).min() ?? last.low
        let rangePosition = high52 > low52 ? (last.close - low52) / (high52 - low52) : 0.5

        let priorRangeHigh20 = sorted.dropLast().suffix(20).map(\.high).max() ?? last.high

        let atr = BaselineStore.averageTrueRange(sorted, period: 14)
        let atrPercent = last.close > 0 ? atr / last.close : 0

        let volumes = sorted.map(\.volume)
        let medianVolume20 = BaselineStore.median(Array(volumes.suffix(20)))
        let volumeVsAverage = medianVolume20 > 0 ? last.volume / medianVolume20 : 0
        let recentVolume5 = BaselineStore.median(Array(volumes.suffix(5)))
        let volumeTrend = medianVolume20 > 0 ? recentVolume5 / medianVolume20 : 1

        let distanceFromSMA20ATR = atr > 0 ? (last.close - sma20) / atr : 0

        return SwingSignalSnapshot(
            symbol: symbol,
            asOf: Date(),
            last: last.close,
            priorClose: priorClose,
            sma20: sma20,
            sma50: sma50,
            sma200: sma200,
            sma50SlopePercent: sma50Slope,
            relativeStrength20Day: rs20,
            relativeStrength60Day: rs60,
            high52Week: high52,
            low52Week: low52,
            positionIn52WeekRange: rangePosition,
            priorRangeHigh20: priorRangeHigh20,
            atrPercent: atrPercent,
            volumeVsAverage: volumeVsAverage,
            volumeTrend: volumeTrend,
            averageDollarVolume: BaselineStore.median(sorted.suffix(20).map { $0.close * $0.volume }),
            distanceFromSMA20ATR: distanceFromSMA20ATR,
            floatShares: floatRecord?.floatShares,
            floatCategory: floatRecord?.category,
            insiderFilingsRecent: insiderCount,
            sector: sector,
            estimatedDaysToNextFiling: estimatedDaysToNextFiling
        )
    }

    /// Projects the next filing window from the cadence between the last few
    /// 10-Q/10-K filings. Quarterly filers land roughly 90 days apart; this
    /// takes the average gap and extrapolates forward from the most recent one.
    nonisolated static func estimateDaysToNextFiling(from dates: [Date]) -> Int? {
        guard dates.count >= 2 else { return nil }
        let sorted = dates.sorted(by: >)
        var gaps: [Double] = []
        for index in 0..<(sorted.count - 1) {
            gaps.append(sorted[index].timeIntervalSince(sorted[index + 1]) / 86400)
        }
        guard !gaps.isEmpty else { return nil }
        let averageGap = gaps.reduce(0, +) / Double(gaps.count)
        let nextExpected = sorted[0].addingTimeInterval(averageGap * 86400)
        let daysOut = Int(nextExpected.timeIntervalSince(Date()) / 86400)
        return daysOut
    }

    /// Closest daily-bar close to a target date, for converting a filing's
    /// dollar-denominated public float into a share count. Mirrors the same
    /// nearest-bar matching the day-trade engine uses, since filing
    /// measurement dates are quarter-ends and frequently not trading days.
    nonisolated static func closestClose(in bars: [DailyBar], to date: Date) -> Double? {
        bars.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(date)) < abs(rhs.timestamp.timeIntervalSince(date))
        }?.close
    }

    func candidate(for symbol: String) -> SwingCandidate? {
        candidates.first { $0.symbol == symbol }
    }
}
