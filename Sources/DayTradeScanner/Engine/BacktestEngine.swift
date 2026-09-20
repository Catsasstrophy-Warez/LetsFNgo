import Foundation
import Observation

/// Walks a symbol's daily-bar history day by day, scoring each day with the
/// same pure `SwingEngine.buildSnapshot`/`SwingScoringModel` the live swing
/// engine uses, then checks what actually happened over the following N
/// sessions. This is the only horizon a free daily-bars endpoint can
/// backtest meaningfully — day-trade scoring needs minute bars, and Alpaca's
/// free IEX tier doesn't offer enough historical minute-bar depth to make a
/// day-trade backtest honest.
///
/// Every day's snapshot is built from only the bars up to and including that
/// day — never later ones — so there is no lookahead bias. Float and insider
/// context are intentionally left out (nil/zero) rather than reconstructed
/// retroactively from data that wasn't actually knowable on that date.
@MainActor
@Observable
final class BacktestEngine {
    struct DayResult: Identifiable, Sendable {
        let id = UUID()
        let symbol: String
        let date: Date
        let score: Double
        /// Forward return over the holding period, nil if not enough future
        /// bars existed in the fetched history to resolve it.
        let forwardReturn: Double?
    }

    struct Summary: Sendable {
        let totalDays: Int
        let signalDays: Int
        let signalWinRate: Double
        let signalAverageReturn: Double
        let baselineAverageReturn: Double
        var edge: Double { signalAverageReturn - baselineAverageReturn }
    }

    private(set) var results: [DayResult] = []
    private(set) var summary: Summary?
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var lastError: String?

    private let rest: AlpacaREST
    private let scoringModel = SwingScoringModel.default

    init(rest: AlpacaREST) {
        self.rest = rest
    }

    /// - Parameters:
    ///   - symbols: underlyings to walk.
    ///   - holdingDays: forward window each signal's return is measured over.
    ///   - scoreThreshold: score at/above which a day counts as "the scanner
    ///     would have alerted here," for the win-rate/edge comparison against
    ///     every other day in the sample.
    func run(symbols: [String], holdingDays: Int = 5, scoreThreshold: Double = 0.6, lookbackDays: Int = 900) async {
        guard !isRunning, !symbols.isEmpty else { return }
        isRunning = true
        progress = 0
        results = []
        summary = nil
        lastError = nil
        defer { isRunning = false }

        var pool = symbols
        if !pool.contains("SPY") { pool.append("SPY") }

        guard let bars = try? await rest.dailyBars(symbols: pool, lookbackDays: lookbackDays),
              let benchmarkBars = bars["SPY"], benchmarkBars.count > 200 else {
            lastError = "Could not load enough daily-bar history to backtest."
            return
        }

        var allResults: [DayResult] = []
        for (index, symbol) in symbols.enumerated() {
            guard let symbolBars = bars[symbol] else { continue }
            let sorted = symbolBars.sorted { $0.timestamp < $1.timestamp }
            guard sorted.count > 200 + holdingDays else { continue }

            for day in 200..<(sorted.count - holdingDays) {
                let truncatedBars = Array(sorted[0...day])
                let truncatedBenchmark = benchmarkBars.filter { $0.timestamp <= sorted[day].timestamp }
                guard let snapshot = SwingEngine.buildSnapshot(
                    symbol: symbol,
                    bars: truncatedBars,
                    benchmark: truncatedBenchmark,
                    floatRecord: nil,
                    insiderCount: 0,
                    estimatedDaysToNextFiling: nil,
                    sector: nil
                ) else { continue }

                let breakdown = scoringModel.score(snapshot)
                let entryClose = sorted[day].close
                let exitClose = sorted[day + holdingDays].close
                let forwardReturn = entryClose > 0 ? (exitClose / entryClose) - 1.0 : nil

                allResults.append(DayResult(symbol: symbol, date: sorted[day].timestamp, score: breakdown.total, forwardReturn: forwardReturn))
            }
            progress = Double(index + 1) / Double(symbols.count)
            // Backtesting is CPU-bound scoring, not network-bound, but a
            // cooperative yield keeps the UI responsive across a large
            // symbol list.
            await Task.yield()
        }

        results = allResults
        summary = Self.summarize(allResults, scoreThreshold: scoreThreshold)
    }

    private static func summarize(_ results: [DayResult], scoreThreshold: Double) -> Summary? {
        let resolved = results.filter { $0.forwardReturn != nil }
        guard !resolved.isEmpty else { return nil }

        let signals = resolved.filter { $0.score >= scoreThreshold }
        let signalReturns = signals.compactMap(\.forwardReturn)
        let baselineReturns = resolved.compactMap(\.forwardReturn)

        let signalAverage = signalReturns.isEmpty ? 0 : signalReturns.reduce(0, +) / Double(signalReturns.count)
        let baselineAverage = baselineReturns.reduce(0, +) / Double(baselineReturns.count)
        let winRate = signalReturns.isEmpty ? 0 : Double(signalReturns.filter { $0 > 0 }.count) / Double(signalReturns.count)

        return Summary(
            totalDays: resolved.count,
            signalDays: signals.count,
            signalWinRate: winRate,
            signalAverageReturn: signalAverage,
            baselineAverageReturn: baselineAverage
        )
    }
}
