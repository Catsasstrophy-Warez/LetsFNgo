import Foundation
import Observation

/// A short-lookback backtest for the day-trade/scalp horizon, over whatever
/// recent minute-bar history Alpaca's free IEX feed actually retains
/// (typically a handful of trading days — nowhere near the depth
/// `BacktestEngine`'s swing-horizon daily-bar replay gets). This can't be a
/// faithful backtest of the live day-trade `ScoringModel`: most of its
/// components depend on state that simply isn't reconstructable from a raw
/// bar array alone — `BaselineStore`'s multi-week per-minute volume
/// baseline, live halt/news/social/insider feeds, FINRA short data. None of
/// that can be replayed from bars.
///
/// What CAN be replayed faithfully is VWAP, VWAP z-score, and range
/// position — `SymbolState.apply(bar:includePremarket:)` is the exact same
/// mutating accumulator the live engine uses, reused here as-is rather than
/// reimplemented, so those three components carry real fidelity. Relative
/// volume and gap use honestly-labeled approximations (this fetch's own
/// window as its own baseline, rather than `BaselineStore`'s proper
/// multi-week median) since the short lookback has no other data to compare
/// against — that limitation is exactly why this is a "micro" backtest and
/// not presented as equivalent to the swing-horizon one.
@MainActor
@Observable
final class MicroBacktestEngine {
    struct BarResult: Identifiable, Sendable {
        let id = UUID()
        let symbol: String
        let timestamp: Date
        let score: Double
        let forwardReturn: Double?
    }

    struct Summary: Sendable {
        let totalBars: Int
        let signalBars: Int
        let signalWinRate: Double
        let signalAverageReturn: Double
        let baselineAverageReturn: Double
        var edge: Double { signalAverageReturn - baselineAverageReturn }
    }

    private(set) var results: [BarResult] = []
    private(set) var summary: Summary?
    private(set) var isRunning = false
    private(set) var lastError: String?

    private let rest: AlpacaREST
    private let scoringModel = ScoringModel(config: ScanProfile.dayTrade.makeConfig())

    init(rest: AlpacaREST) {
        self.rest = rest
    }

    /// - Parameters:
    ///   - symbols: day-trade/scalp watchlist to walk.
    ///   - lookbackDays: how many calendar days back to fetch — kept small
    ///     since the free feed's minute-bar retention is itself small.
    ///   - forwardMinutes: holding window each bar's signal is measured over.
    ///   - scoreThreshold: score at/above which a bar counts as "would have
    ///     alerted," for the win-rate/edge comparison.
    func run(symbols: [String], lookbackDays: Int = 5, forwardMinutes: Int = 15, scoreThreshold: Double = 0.6) async {
        guard !isRunning, !symbols.isEmpty else { return }
        isRunning = true
        results = []
        summary = nil
        lastError = nil
        defer { isRunning = false }

        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: end) else { return }

        guard let bars = try? await rest.minuteBars(symbols: symbols, start: start, end: end) else {
            lastError = "Could not load recent minute-bar history."
            return
        }

        var allResults: [BarResult] = []
        for symbol in symbols {
            guard let symbolBars = bars[symbol], !symbolBars.isEmpty else { continue }
            allResults.append(contentsOf: walk(symbol: symbol, bars: symbolBars, forwardMinutes: forwardMinutes))
        }

        guard !allResults.isEmpty else {
            lastError = "No usable regular-session bars in the fetched window."
            return
        }

        results = allResults
        summary = Self.summarize(allResults, scoreThreshold: scoreThreshold)
    }

    private func walk(symbol: String, bars: [MinuteBar], forwardMinutes: Int) -> [BarResult] {
        let sorted = bars.sorted { $0.timestamp < $1.timestamp }
        let byDay = Dictionary(grouping: sorted) { MarketClock.startOfTradingDay(on: $0.timestamp) ?? Calendar.current.startOfDay(for: $0.timestamp) }
        let days = byDay.keys.sorted()
        guard days.count >= 2 else { return [] }   // need at least one prior close for gap

        var results: [BarResult] = []
        var priorClose: Double?

        for day in days {
            guard let dayBars = byDay[day]?.sorted(by: { $0.timestamp < $1.timestamp }) else { continue }
            var state = SymbolState(symbol: symbol, sessionDay: day)
            var cumulativeBarCount = 0
            var cumulativeVolumeSum = 0.0

            for (index, bar) in dayBars.enumerated() {
                guard state.apply(bar: bar, includePremarket: false) else { continue }
                cumulativeBarCount += 1
                cumulativeVolumeSum += bar.volume
                guard cumulativeBarCount >= 5 else { continue }   // let vwapZ warm up

                // Relative volume proxy: this session's average bar size so
                // far against the average bar size across the whole fetched
                // window for this symbol — a stand-in for BaselineStore's
                // proper multi-week per-minute median, which a 5-day window
                // has no way to compute.
                let sessionAvgBarVolume = cumulativeVolumeSum / Double(cumulativeBarCount)
                let windowAvgBarVolume = sorted.map(\.volume).reduce(0, +) / Double(max(sorted.count, 1))
                let rvolProxy = windowAvgBarVolume > 0 ? sessionAvgBarVolume / windowAvgBarVolume : 1

                let gap = priorClose.map { (state.sessionOpen / $0) - 1.0 } ?? 0

                let rvolScore = scoringModel.normalizeRVOL(rvolProxy)
                let vwapScore = scoringModel.normalizeVWAPPosition(state.vwapZ)
                let gapScore = scoringModel.normalizeGap(gap)
                let rangeScore = scoringModel.normalizeRangePosition(state.rangePosition)
                // Equal weight across the four replayable components — there's
                // no principled way to reuse the live day-trade weights when
                // ten of fourteen components can't be computed here at all.
                let score = (rvolScore + vwapScore + gapScore + rangeScore) / 4.0

                let forwardIndex = index + forwardMinutes
                let forwardReturn: Double?
                if forwardIndex < dayBars.count, bar.close > 0 {
                    forwardReturn = (dayBars[forwardIndex].close / bar.close) - 1.0
                } else {
                    forwardReturn = nil
                }

                results.append(BarResult(symbol: symbol, timestamp: bar.timestamp, score: score, forwardReturn: forwardReturn))
            }

            if let lastClose = dayBars.last?.close { priorClose = lastClose }
        }

        return results
    }

    private static func summarize(_ results: [BarResult], scoreThreshold: Double) -> Summary? {
        let resolved = results.filter { $0.forwardReturn != nil }
        guard !resolved.isEmpty else { return nil }

        let signals = resolved.filter { $0.score >= scoreThreshold }
        let signalReturns = signals.compactMap(\.forwardReturn)
        let baselineReturns = resolved.compactMap(\.forwardReturn)

        let signalAverage = signalReturns.isEmpty ? 0 : signalReturns.reduce(0, +) / Double(signalReturns.count)
        let baselineAverage = baselineReturns.reduce(0, +) / Double(baselineReturns.count)
        let winRate = signalReturns.isEmpty ? 0 : Double(signalReturns.filter { $0 > 0 }.count) / Double(signalReturns.count)

        return Summary(
            totalBars: resolved.count,
            signalBars: signals.count,
            signalWinRate: winRate,
            signalAverageReturn: signalAverage,
            baselineAverageReturn: baselineAverage
        )
    }
}
