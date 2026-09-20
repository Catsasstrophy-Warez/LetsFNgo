import Foundation

/// Scores long-term candidates from fundamentals rather than price action.
///
/// The gate here is deliberately loose compared to the day-trade and swing
/// models — a long-term watchlist is short and curated by the person using
/// the app, not screened out of thousands of tickers, so there's little to
/// filter and much to lose by being clever about it.
struct LongTermScoringModel: Sendable {
    var weights: [LongTermComponent: Double]

    static let `default` = LongTermScoringModel(
        weights: Dictionary(uniqueKeysWithValues: LongTermComponent.allCases.map { ($0, $0.defaultWeight) })
    )

    private func normalizedWeight(_ component: LongTermComponent) -> Double {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return (weights[component] ?? 0) / total
    }

    private func clamp(_ value: Double, min lower: Double = 0, max upper: Double = 1) -> Double {
        Swift.max(lower, Swift.min(value, upper))
    }

    // MARK: - Normalization

    private func normalizeRevenueGrowth(_ snapshot: FundamentalSnapshot) -> Double {
        guard let growth = snapshot.revenueGrowthYoY else { return 0 }
        // 25% YoY growth reaches full marks; negative growth pulls below zero
        // rather than flooring at it, so a shrinking business visibly costs
        // the score instead of just contributing nothing.
        return clamp(growth / 0.25, min: -0.5, max: 1.0)
    }

    private func normalizeProfitability(_ snapshot: FundamentalSnapshot) -> Double {
        guard let margin = snapshot.netMarginTTM else { return 0 }
        return clamp(margin / 0.20, min: -0.5, max: 1.0)
    }

    private func normalizeMarginTrend(_ snapshot: FundamentalSnapshot) -> Double {
        guard let trend = snapshot.marginTrend else { return 0 }
        return clamp(trend / 0.05, min: -1.0, max: 1.0)
    }

    /// The one component that meaningfully subtracts. A price-to-sales
    /// multiple north of 15 is where "growth premium" starts to shade into
    /// "priced for perfection," and the score says so rather than staying
    /// silent about valuation the way a pure momentum scan would.
    private func normalizeValuation(_ snapshot: FundamentalSnapshot) -> Double {
        guard let ps = snapshot.priceToSales, ps > 0 else { return 0 }
        if ps <= 5 { return clamp(1.0 - (ps / 10.0)) }
        return -clamp((ps - 5) / 15.0)
    }

    private func normalizePriceTrend(_ snapshot: FundamentalSnapshot) -> Double {
        var score = 0.0
        if let vsSMA = snapshot.priceVsSMA200Percent {
            score += clamp(vsSMA / 0.20 + 0.5) * 0.6
        }
        if let distanceFromHigh = snapshot.distanceFrom52WeekHighPercent {
            // Closer to the 52-week high scores higher, but this is a trend
            // read, not a "don't buy at highs" rule — long-term theses are
            // routinely right about businesses making new highs for years.
            score += clamp(1.0 + distanceFromHigh / 0.3) * 0.4
        }
        return clamp(score)
    }

    private func normalizeInsiderConviction(_ snapshot: FundamentalSnapshot) -> Double {
        clamp(Double(snapshot.insiderFilingsRecent) / 10.0)
    }

    private func normalizeLeverageRisk(_ snapshot: FundamentalSnapshot) -> Double {
        guard let leverage = snapshot.leverageRatio, leverage > 0.6 else { return 0 }
        return -clamp((leverage - 0.6) / 0.4)
    }

    private func normalizeFloatRisk(_ snapshot: FundamentalSnapshot) -> Double {
        guard snapshot.floatCategory?.carriesElevatedRisk == true else { return 0 }
        return -0.5
    }

    // MARK: - Scoring

    func score(_ snapshot: FundamentalSnapshot) -> LongTermScoreBreakdown {
        var breakdown = LongTermScoreBreakdown()
        let normalized: [LongTermComponent: Double] = [
            .revenueGrowth: normalizeRevenueGrowth(snapshot),
            .profitability: normalizeProfitability(snapshot),
            .marginTrend: normalizeMarginTrend(snapshot),
            .valuation: normalizeValuation(snapshot),
            .priceTrend: normalizePriceTrend(snapshot),
            .insiderConviction: normalizeInsiderConviction(snapshot),
            .leverageRisk: normalizeLeverageRisk(snapshot),
            .floatRisk: normalizeFloatRisk(snapshot)
        ]

        var total = 0.0
        for (component, value) in normalized {
            let contribution = value * normalizedWeight(component)
            breakdown.normalized[component] = value
            breakdown.contributions[component] = contribution
            total += contribution
        }
        // Long-term scores are allowed to go slightly negative (a shrinking,
        // overleveraged, richly-valued business should visibly rank below
        // zero) but are clamped to a floor so the UI's score bar stays sane.
        breakdown.total = Swift.max(-0.3, Swift.min(total, 1.0))
        return breakdown
    }

    func rank(_ snapshots: [FundamentalSnapshot]) -> [LongTermCandidate] {
        snapshots
            .filter(\.hasEnoughDataToScore)
            .map { LongTermCandidate(snapshot: $0, breakdown: score($0)) }
            .sorted { $0.score > $1.score }
    }
}
