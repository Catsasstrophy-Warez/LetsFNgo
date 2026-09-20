import Foundation

/// Scores swing candidates from daily-bar technicals.
///
/// The shape mirrors `ScoringModel` deliberately — normalize each component
/// to 0...1, weight, sum, keep the breakdown — but every input is a daily-bar
/// technical rather than a minute-bar microstructure signal, because a swing
/// position is held through dozens of sessions and needs to be right about
/// the trend, not the next five minutes.
struct SwingScoringModel: Sendable {
    var weights: [SwingComponent: Double]

    // Gates
    var minPrice: Double = 5.0
    var maxPrice: Double = 2000.0
    var minDollarVolume: Double = 2_000_000
    var minATRPercent: Double = 0.015
    var alertThreshold: Double = 0.62

    static let `default` = SwingScoringModel(
        weights: Dictionary(uniqueKeysWithValues: SwingComponent.allCases.map { ($0, $0.defaultWeight) })
    )

    private func normalizedWeight(_ component: SwingComponent) -> Double {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return (weights[component] ?? 0) / total
    }

    enum Rejection: String, Sendable {
        case price = "Outside price range"
        case dollarVolume = "Too illiquid"
        case tooQuiet = "Not enough range to swing"
        case insufficientHistory = "Not enough daily history"
    }

    func gate(_ snapshot: SwingSignalSnapshot) -> Rejection? {
        if snapshot.last < minPrice || snapshot.last > maxPrice { return .price }
        guard let dollarVolume = snapshot.averageDollarVolume,
              dollarVolume.isFinite, dollarVolume >= minDollarVolume else { return .dollarVolume }
        if snapshot.atrPercent < minATRPercent { return .tooQuiet }
        return nil
    }

    private func clamp(_ value: Double, min lower: Double = 0, max upper: Double = 1) -> Double {
        Swift.max(lower, Swift.min(value, upper))
    }

    // MARK: - Normalization

    private func normalizeTrendAlignment(_ snapshot: SwingSignalSnapshot) -> Double {
        var score = 0.0
        if snapshot.last > snapshot.sma20 { score += 0.3 }
        if snapshot.sma20 > snapshot.sma50 { score += 0.3 }
        if snapshot.sma50 > snapshot.sma200 { score += 0.2 }
        if snapshot.sma50SlopePercent > 0 { score += 0.2 }
        return clamp(score)
    }

    /// Both windows count, but agreement between them counts more — a stock
    /// leading over 20 sessions but lagging over 60 is a recent development,
    /// not yet a trend.
    private func normalizeRelativeStrength(_ snapshot: SwingSignalSnapshot) -> Double {
        let short = clamp(snapshot.relativeStrength20Day / 0.15 + 0.5)
        let long = clamp(snapshot.relativeStrength60Day / 0.25 + 0.5)
        let agreement = (snapshot.relativeStrength20Day > 0) == (snapshot.relativeStrength60Day > 0) ? 1.1 : 0.85
        return clamp(((short * 0.6) + (long * 0.4)) * agreement)
    }

    private func normalizeBreakout(_ snapshot: SwingSignalSnapshot) -> Double {
        guard snapshot.priorRangeHigh20 > 0 else { return 0 }
        let extension_ = (snapshot.last / snapshot.priorRangeHigh20) - 1.0
        guard extension_ >= -0.01 else { return 0 }   // not yet at the level
        return clamp(0.5 + (extension_ / 0.03) * 0.5)
    }

    private func normalizeVolumeConfirmation(_ snapshot: SwingSignalSnapshot) -> Double {
        let level = clamp(log(max(snapshot.volumeVsAverage, 0.1)) / log(3.0))
        let trend = clamp((snapshot.volumeTrend - 0.8) / 0.8)
        return clamp((level * 0.7) + (trend * 0.3))
    }

    /// Peaks at a shallow, controlled pullback — the same shaped curve as the
    /// day-trade engine's intraday pullback signal, just measured in daily
    /// ATR instead of intraday ATR, because the psychology is identical:
    /// too close to the average isn't a pullback, too far is a broken trend.
    private func normalizePullback(_ snapshot: SwingSignalSnapshot) -> Double {
        guard snapshot.isAboveAllMovingAverages else { return 0 }
        let distance = snapshot.distanceFromSMA20ATR
        guard distance > -0.5 else { return 0 }
        let ideal = 0.3
        let spread = 0.9
        return clamp(1 - (abs(distance - ideal) / spread))
    }

    private func normalizeRangePosition(_ snapshot: SwingSignalSnapshot) -> Double {
        clamp(snapshot.positionIn52WeekRange)
    }

    private func normalizeFloatTightness(_ snapshot: SwingSignalSnapshot) -> Double {
        snapshot.floatCategory?.tightnessScore ?? 0
    }

    private func normalizeInsiderActivity(_ snapshot: SwingSignalSnapshot) -> Double {
        clamp(Double(snapshot.insiderFilingsRecent) / 8.0)
    }

    /// Negative. A swing entry taken two days before an earnings print is a
    /// gap-risk bet, not the trend-following trade the rest of the score
    /// describes — so proximity subtracts rather than simply going to zero.
    private func normalizeEarningsRisk(_ snapshot: SwingSignalSnapshot) -> Double {
        guard let days = snapshot.estimatedDaysToNextFiling, days <= 10 else { return 0 }
        return -clamp((10.0 - Double(days)) / 10.0)
    }

    // MARK: - Scoring

    func score(_ snapshot: SwingSignalSnapshot) -> SwingScoreBreakdown {
        var breakdown = SwingScoreBreakdown()
        let normalized: [SwingComponent: Double] = [
            .trendAlignment: normalizeTrendAlignment(snapshot),
            .relativeStrength: normalizeRelativeStrength(snapshot),
            .breakoutQuality: normalizeBreakout(snapshot),
            .volumeConfirmation: normalizeVolumeConfirmation(snapshot),
            .pullbackQuality: normalizePullback(snapshot),
            .rangePosition: normalizeRangePosition(snapshot),
            .floatTightness: normalizeFloatTightness(snapshot),
            .insiderActivity: normalizeInsiderActivity(snapshot),
            .earningsRisk: normalizeEarningsRisk(snapshot)
        ]

        var total = 0.0
        for (component, value) in normalized {
            let contribution = value * normalizedWeight(component)
            breakdown.normalized[component] = value
            breakdown.contributions[component] = contribution
            total += contribution
        }
        breakdown.total = clamp(total)
        return breakdown
    }

    func rank(_ snapshots: [SwingSignalSnapshot]) -> (candidates: [SwingCandidate], rejected: [(String, Rejection)]) {
        var candidates: [SwingCandidate] = []
        var rejected: [(String, Rejection)] = []
        for snapshot in snapshots {
            if let rejection = gate(snapshot) {
                rejected.append((snapshot.symbol, rejection))
                continue
            }
            candidates.append(SwingCandidate(snapshot: snapshot, breakdown: score(snapshot)))
        }
        candidates.sort { $0.score > $1.score }
        return (candidates, rejected)
    }
}
