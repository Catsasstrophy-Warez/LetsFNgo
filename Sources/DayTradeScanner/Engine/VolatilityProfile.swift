import Foundation

/// What a symbol is capable of, independent of what it is doing today.
///
/// This is the honest replacement for float data. Float is the number people
/// actually want — a 4M-share float is why a stock can go up 60% on one
/// headline — but no free feed provides it. Rather than approximate float
/// badly, this measures the thing float is a proxy *for*: how often has this
/// symbol actually made a large intraday move recently, and how far does it
/// travel on an average day.
///
/// An empirical measure of realised behaviour beats a bad estimate of the
/// mechanism behind it.
struct VolatilityProfile: Codable, Sendable {
    let symbol: String
    let builtAt: Date
    let sessionsAnalyzed: Int

    /// ATR(14) as a share of price.
    let atrPercent: Double
    /// Median (high − low) / open across the window.
    let medianRangePercent: Double
    /// 90th-percentile daily range. What a good day looks like, not an average one.
    let upperRangePercent: Double
    /// Share of sessions whose intraday range exceeded the runner threshold.
    let runnerFrequency: Double
    let runnerDayCount: Int
    /// Largest single-session range in the window.
    let maxRangePercent: Double

    /// Last 5 sessions' average range over last 20 sessions' average range.
    /// Below ~0.6 means the symbol has been coiling.
    let compressionRatio: Double

    let medianDailyVolume: Double
    /// Median volume of the last 5 sessions over the median of the last 30.
    /// Rising interest often precedes the move rather than following it.
    let volumeTrend: Double

    let lastClose: Double

    /// 0...1 summary used both for screening and as the `volatilityPotential`
    /// component. Weighted toward realised runner days, because a symbol that
    /// has actually gone 15% three times this quarter is a better candidate
    /// than one with a merely elevated ATR.
    var gainPotential: Double {
        let runnerTerm = min(runnerFrequency / 0.15, 1.0) * 0.5
        let atrTerm = min(atrPercent / 0.10, 1.0) * 0.3
        let upsideTerm = min(upperRangePercent / 0.20, 1.0) * 0.2
        return min(runnerTerm + atrTerm + upsideTerm, 1.0)
    }

    /// Human-readable band, used in the discovery list.
    var potentialBand: String {
        switch gainPotential {
        case 0.75...: return "Very high"
        case 0.5..<0.75: return "High"
        case 0.3..<0.5: return "Moderate"
        default: return "Low"
        }
    }

    var isCoiled: Bool { compressionRatio < 0.65 }

    /// Typical dollars of movement in a five-minute window, derived from ATR.
    /// A scalper needs to know whether the move they're chasing is bigger than
    /// the spread they'll pay to get it.
    var expectedFiveMinuteMovePercent: Double {
        // Intraday volatility scales roughly with the square root of time.
        // 5 minutes of a 390-minute session: sqrt(5/390) ≈ 0.113.
        atrPercent * 0.113
    }

    func passes(_ criteria: DiscoveryCriteria) -> Bool {
        guard atrPercent >= criteria.minATRPercent else { return false }
        guard medianDailyVolume >= criteria.minMedianDailyVolume else { return false }
        guard lastClose >= criteria.minPrice, lastClose <= criteria.maxPrice else { return false }
        if runnerDayCount >= criteria.minRunnerDays { return true }
        if criteria.includeCompressed && compressionRatio <= criteria.compressionCeiling { return true }
        return criteria.minRunnerDays == 0
    }

    // MARK: - Construction

    /// Builds a profile from daily bars. Returns nil if there isn't enough
    /// history for the numbers to mean anything.
    static func build(
        symbol: String,
        dailyBars: [DailyBar],
        runnerThreshold: Double,
        lookback: Int
    ) -> VolatilityProfile? {
        let sorted = dailyBars.sorted { $0.timestamp < $1.timestamp }
        let window = Array(sorted.suffix(lookback))
        guard window.count >= 20, let last = window.last, last.close > 0 else { return nil }

        // Intraday range as a share of the open, not the close. Using the close
        // on a stock that ran 40% understates the range badly.
        let ranges: [Double] = window.compactMap { bar in
            guard bar.open > 0 else { return nil }
            return (bar.high - bar.low) / bar.open
        }
        guard ranges.count >= 20 else { return nil }

        let sortedRanges = ranges.sorted()
        let medianRange = BaselineStore.median(ranges)
        let upperRange = sortedRanges[Int(Double(sortedRanges.count - 1) * 0.9)]
        let maxRange = sortedRanges.last ?? 0

        let runnerDays = ranges.filter { $0 >= runnerThreshold }.count
        let runnerFrequency = Double(runnerDays) / Double(ranges.count)

        let atr = BaselineStore.averageTrueRange(window, period: 14)
        let atrPercent = last.close > 0 ? atr / last.close : 0

        let recentRanges = Array(ranges.suffix(5))
        let longerRanges = Array(ranges.suffix(20))
        let recentAverage = recentRanges.reduce(0, +) / Double(max(recentRanges.count, 1))
        let longerAverage = longerRanges.reduce(0, +) / Double(max(longerRanges.count, 1))
        let compression = longerAverage > 0 ? recentAverage / longerAverage : 1

        let volumes = window.map(\.volume)
        let medianVolume = BaselineStore.median(volumes)
        let recentVolume = BaselineStore.median(Array(volumes.suffix(5)))
        let baseVolume = BaselineStore.median(Array(volumes.suffix(30)))
        let volumeTrend = baseVolume > 0 ? recentVolume / baseVolume : 1

        return VolatilityProfile(
            symbol: symbol,
            builtAt: Date(),
            sessionsAnalyzed: window.count,
            atrPercent: atrPercent,
            medianRangePercent: medianRange,
            upperRangePercent: upperRange,
            runnerFrequency: runnerFrequency,
            runnerDayCount: runnerDays,
            maxRangePercent: maxRange,
            compressionRatio: compression,
            medianDailyVolume: medianVolume,
            volumeTrend: volumeTrend,
            lastClose: last.close
        )
    }
}

// MARK: - LULD

/// Limit Up-Limit Down band arithmetic.
///
/// A halted position is an untradeable position, and the symbols this scanner
/// is now hunting are exactly the ones that halt. The bands here follow the
/// standard tier structure closely enough to warn on proximity; they are a
/// hazard estimate, not an exchange-accurate reproduction.
enum LULD {
    /// Band width as a share of the reference price.
    /// Tier 1 covers S&P 500, Russell 1000 and select ETPs; Tier 2 is
    /// everything else. Bands double in the closing period and are wider
    /// for low-priced stocks.
    static func bandPercent(price: Double, isTier1: Bool, at date: Date = Date()) -> Double {
        let base: Double
        if price > 3.00 {
            base = isTier1 ? 0.05 : 0.10
        } else if price >= 0.75 {
            base = 0.20
        } else {
            base = min(0.75, 0.15 / max(price, 0.01))
        }

        let minute = MarketClock.minutesSinceMidnightET(date)
        // Bands double in the first and last 15 minutes of the session.
        let isWidened = (minute >= 570 && minute < 585) || (minute >= 945 && minute < 960)
        return isWidened ? base * 2 : base
    }

    /// How close price is to its band, 0...1.
    /// The reference price is the average trade price over the preceding five
    /// minutes; VWAP over the recent window is a reasonable stand-in.
    static func proximity(price: Double, referencePrice: Double, isTier1: Bool, at date: Date = Date()) -> Double {
        guard referencePrice > 0 else { return 0 }
        let band = bandPercent(price: referencePrice, isTier1: isTier1, at: date)
        let distance = abs(price - referencePrice) / referencePrice
        return min(distance / max(band, 0.0001), 1.0)
    }
}
