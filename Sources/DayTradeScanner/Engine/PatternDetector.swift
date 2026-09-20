import Foundation

/// Geometric pivot/trendline detection over a symbol's own recent minute
/// bars — a pattern-recognition signal source distinct from every other
/// component in `ScoringModel`, which all read momentum/volume/float
/// context rather than chart shape. Pure and self-contained: no chart
/// library, no image analysis, just fractal pivot points and a two-point
/// trendline projected forward to the latest bar.
enum PatternDetector {
    struct Result: Sendable {
        /// 0...1, purely a ranking aid like every other normalized component.
        let score: Double
        let note: String
    }

    /// A bar counts as a pivot high/low if it's the extreme point among
    /// `wing` bars on each side — the standard "fractal" pivot definition
    /// used by most manual trendline tools, small enough to still find
    /// pivots in a single trading session's worth of minute bars.
    private static let wing = 3

    static func detect(bars: [MinuteBar]) -> Result? {
        guard bars.count >= wing * 2 + 8 else { return nil }

        let pivotHighs = findPivots(bars, isHigh: true)
        let pivotLows = findPivots(bars, isHigh: false)

        let breakout = detectBreak(bars: bars, pivots: pivotHighs, isResistance: true)
        let breakdown = detectBreak(bars: bars, pivots: pivotLows, isResistance: false)

        // Take whichever break is fresher/stronger; a symbol rarely shows a
        // clean break of both a support and a resistance line at once, and
        // when it does the more recent one is the one actually driving price
        // right now.
        switch (breakout, breakdown) {
        case let (.some(up), .some(down)):
            return up.score >= down.score ? up : down
        case let (.some(up), nil):
            return up
        case let (nil, .some(down)):
            return down
        case (nil, nil):
            return nil
        }
    }

    /// Indices of local extrema, at least `wing` bars from either end so a
    /// full window exists on both sides to compare against.
    private static func findPivots(_ bars: [MinuteBar], isHigh: Bool) -> [(index: Int, value: Double)] {
        var pivots: [(Int, Double)] = []
        guard bars.count > wing * 2 else { return pivots }
        for index in wing..<(bars.count - wing) {
            let value = isHigh ? bars[index].high : bars[index].low
            let window = (index - wing)...(index + wing)
            let isExtreme = window.allSatisfy { other in
                other == index || (isHigh ? bars[other].high <= value : bars[other].low >= value)
            }
            if isExtreme { pivots.append((index, value)) }
        }
        return pivots
    }

    /// Fits a line through the two most recent pivots of the same kind,
    /// projects it to the latest bar, and scores how decisively the latest
    /// close has broken through it. `isResistance` picks the direction: a
    /// break above a declining/flat resistance line is bullish, a break
    /// below a rising/flat support line is bearish.
    private static func detectBreak(bars: [MinuteBar], pivots: [(index: Int, value: Double)], isResistance: Bool) -> Result? {
        guard pivots.count >= 2, let last = bars.last else { return nil }
        let recentPivots = Array(pivots.suffix(2))
        let (x1, y1) = (Double(recentPivots[0].index), recentPivots[0].value)
        let (x2, y2) = (Double(recentPivots[1].index), recentPivots[1].value)
        guard x2 > x1 else { return nil }

        let slope = (y2 - y1) / (x2 - x1)
        let latestIndex = Double(bars.count - 1)
        let projectedLevel = y1 + slope * (latestIndex - x1)
        guard projectedLevel > 0 else { return nil }

        let closeVsLevel = (last.close - projectedLevel) / projectedLevel

        // How many bars since the projected level was last touched — a break
        // that happened 40 bars ago and has since gone quiet is not the same
        // signal as one on the most recent bar.
        let barsSincePivot = Int(latestIndex) - recentPivots[1].index
        let freshnessFactor = max(0, 1 - Double(barsSincePivot) / 20.0)

        if isResistance {
            guard closeVsLevel > 0.002 else { return nil }
            let magnitude = min(closeVsLevel / 0.03, 1.0)
            let score = (0.5 * magnitude + 0.5 * freshnessFactor).clamped(to: 0...1)
            return Result(score: score, note: String(format: "broke resistance trendline, %.1f%% above", closeVsLevel * 100))
        } else {
            guard closeVsLevel < -0.002 else { return nil }
            let magnitude = min(abs(closeVsLevel) / 0.03, 1.0)
            let score = (0.5 * magnitude + 0.5 * freshnessFactor).clamped(to: 0...1)
            return Result(score: score, note: String(format: "broke support trendline, %.1f%% below", abs(closeVsLevel) * 100))
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
