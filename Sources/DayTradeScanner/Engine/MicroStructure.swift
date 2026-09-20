import Foundation

/// Scalp signals, computed fresh each minute from the recent bar window.
///
/// Written as pure functions over an array of bars so they can be unit-tested
/// against a fixture without standing up a stream, and so `SymbolState` stays
/// a plain accumulator rather than growing a second brain.
enum MicroStructure {

    /// Everything the scalp profile needs, in one pass over the window.
    /// - Parameters:
    ///   - bars: recent minute bars, oldest first. 20 is plenty.
    ///   - vwap: current session VWAP, used for pullback quality.
    ///   - atr: daily ATR(14) in dollars, used to express depth in ATR units.
    ///   - barVolumeMedian: this symbol's median volume for a bar at this time
    ///     of day, so "high volume" means high for this symbol at this hour.
    static func compute(
        bars: [MinuteBar],
        vwap: Double,
        atr: Double,
        barVolumeMedian: Double
    ) -> (
        consecutive: Int,
        burst: Double,
        pullbackDepthATR: Double,
        pullbackQuality: Double,
        acceleration: Double,
        spreadPercent: Double
    ) {
        guard bars.count >= 4, let last = bars.last, last.close > 0 else {
            return (0, 0, 0, 0, 0, 0)
        }

        let consecutive = consecutiveDirectionalBars(bars, volumeFloor: barVolumeMedian)
        let burst = burstScore(bars, consecutive: consecutive, atr: atr, volumeMedian: barVolumeMedian)
        let (depth, quality) = pullback(bars, vwap: vwap, atr: atr)
        let acceleration = accelerationPercentPerMinute(bars)
        let spread = spreadProxy(last)

        return (consecutive, burst, depth, quality, acceleration, spread)
    }

    // MARK: - Components

    /// Trailing run of bars closing in the same direction. A bar only counts
    /// toward the run if it carried at least 70% of this symbol's normal
    /// volume for that slot — a drift higher on no volume is not a burst.
    static func consecutiveDirectionalBars(_ bars: [MinuteBar], volumeFloor: Double) -> Int {
        guard bars.count >= 2 else { return 0 }
        let threshold = volumeFloor * 0.7

        var run = 0
        var direction = 0

        for index in stride(from: bars.count - 1, through: 1, by: -1) {
            let bar = bars[index]
            let previous = bars[index - 1]
            let sign = bar.close > previous.close ? 1 : (bar.close < previous.close ? -1 : 0)

            if sign == 0 { break }
            if direction == 0 { direction = sign }
            guard sign == direction else { break }
            if volumeFloor > 0 && bar.volume < threshold { break }
            run += 1
        }

        return run * direction   // signed: negative means a downside run
    }

    /// A composite of run length, volume surge and distance covered.
    ///
    /// All three matter and none is sufficient: five bars up on no volume is
    /// drift, one huge-volume bar is often a print rather than a move, and a
    /// long run that covers 0.1 ATR isn't worth a commission.
    static func burstScore(
        _ bars: [MinuteBar],
        consecutive: Int,
        atr: Double,
        volumeMedian: Double
    ) -> Double {
        let runLength = abs(consecutive)
        guard runLength >= 2, let last = bars.last else { return 0 }

        let runBars = Array(bars.suffix(runLength + 1))
        guard let first = runBars.first, first.close > 0 else { return 0 }

        // 1. Run length, saturating at 5 bars. Beyond that it's extension, not entry.
        let runTerm = min(Double(runLength) / 5.0, 1.0)

        // 2. Volume through the run against its own norm.
        let runVolume = runBars.dropFirst().reduce(0.0) { $0 + $1.volume }
        let expectedVolume = volumeMedian * Double(runLength)
        let volumeTerm = expectedVolume > 0
            ? min(log(max(runVolume / expectedVolume, 1.0)) / log(4.0), 1.0)
            : 0

        // 3. Distance covered, in ATR units. A quarter-ATR push in a few
        //    minutes is a real move on almost any symbol.
        let distance = abs(last.close - first.close)
        let distanceTerm = atr > 0 ? min(distance / (atr * 0.25), 1.0) : 0

        return (runTerm * 0.35) + (volumeTerm * 0.35) + (distanceTerm * 0.30)
    }

    /// Depth of the current retrace from the recent swing extreme, and how
    /// tradeable that retrace looks.
    ///
    /// The quality curve is the opinionated part: a pullback of 0.2–0.9 ATR
    /// that holds the right side of VWAP scores highest. Shallower than that
    /// and there's no entry, deeper and the move is failing rather than resting.
    static func pullback(_ bars: [MinuteBar], vwap: Double, atr: Double) -> (depth: Double, quality: Double) {
        guard bars.count >= 5, let last = bars.last, atr > 0 else { return (0, 0) }

        let window = Array(bars.suffix(15))
        let swingHigh = window.map(\.high).max() ?? last.close
        let swingLow = window.map(\.low).min() ?? last.close

        let isUpMove = last.close >= vwap
        let depthDollars = isUpMove ? (swingHigh - last.close) : (last.close - swingLow)
        let depthATR = depthDollars / atr

        // No pullback at all — price is at the extreme.
        guard depthATR > 0.05 else { return (depthATR, 0) }

        // Quality peaks around 0.45 ATR and falls off in both directions.
        let ideal = 0.45
        let spread = 0.5
        let shape = max(0, 1 - (abs(depthATR - ideal) / spread))

        // A pullback that has broken the level it should hold isn't a pullback.
        let holdsLevel = isUpMove ? (last.close >= vwap) : (last.close <= vwap)
        let sideMultiplier = holdsLevel ? 1.0 : 0.35

        // Volume should dry up into a healthy retrace, not expand.
        let recentVolume = window.suffix(3).reduce(0.0) { $0 + $1.volume } / 3
        let priorVolume = window.dropLast(3).suffix(5).reduce(0.0) { $0 + $1.volume } / 5
        let volumeMultiplier: Double
        if priorVolume > 0 {
            let ratio = recentVolume / priorVolume
            volumeMultiplier = ratio < 0.8 ? 1.0 : max(0.4, 1.0 - (ratio - 0.8))
        } else {
            volumeMultiplier = 0.7
        }

        return (depthATR, min(shape * sideMultiplier * volumeMultiplier, 1.0))
    }

    /// Rate of change of the rate of change. Positive means the last three
    /// minutes moved faster than the three before them.
    ///
    /// This is what separates a second leg from a first one, which matters
    /// because the first leg is usually already gone by the time a scanner
    /// running on one-minute bars can see it.
    static func accelerationPercentPerMinute(_ bars: [MinuteBar]) -> Double {
        guard bars.count >= 7 else { return 0 }
        let window = Array(bars.suffix(7))

        func rate(_ slice: ArraySlice<MinuteBar>) -> Double {
            guard let first = slice.first, let last = slice.last, first.close > 0 else { return 0 }
            let minutes = Double(max(slice.count - 1, 1))
            return ((last.close / first.close) - 1.0) / minutes
        }

        let recent = rate(window.suffix(4))
        let prior = rate(window.prefix(4))
        return recent - prior
    }

    /// High-minus-low of the last bar as a share of price.
    ///
    /// A stand-in for the bid-ask spread, which the free feed doesn't provide
    /// (quotes are one of the 30-channel-capped streams). Wide bars mean the
    /// fill you model is not the fill you get, and on a scalp that difference
    /// is most of the trade.
    static func spreadProxy(_ bar: MinuteBar) -> Double {
        guard bar.close > 0 else { return 0 }
        return (bar.high - bar.low) / bar.close
    }

    /// Signed strength of the opening drive, in ATR units.
    /// The first fifteen minutes set the tone for most day-trade setups.
    static func openingDrive(_ bars: [MinuteBar], atr: Double) -> Double {
        guard atr > 0 else { return 0 }
        let opening = bars.filter { bar in
            guard let minute = MarketClock.minuteOfSession(bar.timestamp) else { return false }
            return minute >= 0 && minute < 15
        }
        guard let first = opening.first, let last = opening.last else { return 0 }
        return (last.close - first.open) / atr
    }
}
