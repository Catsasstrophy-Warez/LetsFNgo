import Foundation
import Observation

/// Nightly-ish self-reweighting: recomputes each day-trade recipe's real,
/// live performance from resolved paper trades and turns that into a
/// fitness multiplier that adjusts how hard it is for that recipe's
/// candidates to earn an alert — a recipe that's actually been working
/// gets a lower effective bar, one that's been losing gets a higher one.
///
/// Deliberately built on `PaperTradeLog`'s real recorded outcomes rather
/// than a synthetic historical replay: day-trade scoring needs minute bars,
/// and the free Alpaca IEX tier doesn't carry enough historical minute
/// depth to backtest a day-trade recipe honestly the way `BacktestEngine`
/// backtests swing recipes over daily bars. Live paper-trade results are
/// the data this app actually has for the day-trade horizon.
///
/// "Nightly" here means "recomputed at most once per calendar day" rather
/// than a literal midnight batch job — there's no background task
/// scheduler in this app beyond its own foreground refresh loops, and
/// recomputing more often than daily would just chase noise in what's
/// usually a handful of trades per recipe.
@MainActor
@Observable
final class RecipeFitnessEngine {
    struct Fitness: Sendable {
        let recipeName: String
        let sampleCount: Int
        let winRate: Double
        let averageReturn: Double
        /// The actual multiplier applied to the alert threshold: >1 makes a
        /// recipe's threshold easier to clear (recent winner), <1 makes it
        /// harder (recent loser). Clamped to a modest band — this nudges
        /// prioritization, it doesn't override the underlying score.
        let multiplier: Double
    }

    private(set) var fitnessByRecipe: [String: Fitness] = [:]
    private(set) var lastComputedAt: Date?

    /// Need at least this many resolved trades before trusting a recipe's
    /// win rate enough to act on it — a 2-trade sample swinging the
    /// multiplier around would be reacting to noise, not performance.
    private let minimumSampleSize = 5

    /// Recomputes once per calendar day at most. Cheap enough to call from
    /// every scoring pass — it's a no-op read of already-in-memory trades
    /// most of the time, and only does the actual aggregation once a day.
    func recomputeIfNeeded(using paperLog: PaperTradeLog) {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastComputedAt, Calendar.current.startOfDay(for: lastComputedAt) == today { return }
        recompute(using: paperLog)
    }

    func recompute(using paperLog: PaperTradeLog) {
        let dayTradeTrades = paperLog.trades.filter { $0.horizon == .dayTrade && $0.recipeName != nil }
        let grouped = Dictionary(grouping: dayTradeTrades) { $0.recipeName! }

        var result: [String: Fitness] = [:]
        for (name, trades) in grouped {
            let resolved = trades.compactMap { trade -> Double? in trade.bestAvailableReturn }
            guard resolved.count >= minimumSampleSize else { continue }

            let winRate = Double(resolved.filter { $0 > 0 }.count) / Double(resolved.count)
            let averageReturn = resolved.reduce(0, +) / Double(resolved.count)

            // Win rate carries more weight than average return — a recipe
            // that wins often on small moves is more reliably "working"
            // than one with one huge outlier propping up its average.
            let winRateEdge = winRate - 0.5
            let returnSignal = (averageReturn / 0.02).clamped(to: -1...1)   // ±2% treated as a strong signal
            let rawMultiplier = 1.0 + (winRateEdge * 0.5) + (returnSignal * 0.15)
            let multiplier = rawMultiplier.clamped(to: 0.75...1.25)

            result[name] = Fitness(
                recipeName: name,
                sampleCount: resolved.count,
                winRate: winRate,
                averageReturn: averageReturn,
                multiplier: multiplier
            )
        }

        fitnessByRecipe = result
        lastComputedAt = Date()
    }

    func fitness(for recipeName: String?) -> Fitness? {
        recipeName.flatMap { fitnessByRecipe[$0] }
    }

    /// 1.0 (neutral) when there's no active recipe or not enough sample
    /// yet to have an opinion.
    func multiplier(for recipeName: String?) -> Double {
        fitness(for: recipeName)?.multiplier ?? 1.0
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
