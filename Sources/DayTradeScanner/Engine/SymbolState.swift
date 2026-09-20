import Foundation

/// Everything that accumulates within one trading session for one symbol.
///
/// Deliberately a value type with explicit mutation so the engine actor owns
/// it outright and no view can hold a stale reference to live state.
struct SymbolState: Sendable {
    let symbol: String
    private(set) var sessionDay: Date

    // VWAP accumulators. Kept as raw sums so VWAP is exact rather than
    // incrementally drifting, and so dispersion is available for free.
    private(set) var sumVolume: Double = 0
    private(set) var sumPriceVolume: Double = 0
    private(set) var sumPriceSquaredVolume: Double = 0

    private(set) var sessionOpen: Double = 0
    private(set) var dayHigh: Double = 0
    private(set) var dayLow: Double = .greatestFiniteMagnitude
    private(set) var last: Double = 0
    private(set) var lastBarAt: Date?
    private(set) var lastBarVolume: Double = 0
    private(set) var lastTradeCount: Int = 0
    private(set) var barsSeen: Int = 0

    // Rolling window for the detail sparkline. 120 minutes is enough context
    // without holding the whole session in memory for hundreds of symbols.
    private(set) var recentCloses: [Double] = []
    private(set) var recentVWAPs: [Double] = []

    /// Full bars for microstructure work. Twenty is enough for every scalp
    /// signal and small enough to hold for a few hundred symbols at once.
    private(set) var recentBars: [MinuteBar] = []

    /// Pre-market volume, accumulated separately so it never contaminates the
    /// regular-session VWAP or the RVOL numerator.
    private(set) var premarketVolume: Double = 0
    private(set) var premarketHigh: Double = 0
    private(set) var premarketLow: Double = .greatestFiniteMagnitude

    // VWAP event detection
    private(set) var currentSide: TrendState = .atVWAP
    private(set) var pendingSide: TrendState?
    private(set) var pendingSinceBar: Int = 0
    private(set) var lastEvent: VWAPEvent = .none
    private(set) var lastEventAt: Date?

    // News attached to this symbol, newest first, capped.
    private(set) var news: [NewsItem] = []

    init(symbol: String, sessionDay: Date = Date()) {
        self.symbol = symbol
        self.sessionDay = sessionDay
    }

    var vwap: Double {
        guard sumVolume > 0 else { return last }
        return sumPriceVolume / sumVolume
    }

    /// Volume-weighted standard deviation of price around VWAP. This is the
    /// denominator that makes VWAP distance comparable across symbols —
    /// a percentage is not, because a biotech and a mega-cap have completely
    /// different intraday dispersion.
    var vwapSigma: Double {
        guard sumVolume > 0 else { return 0 }
        let mean = sumPriceVolume / sumVolume
        let meanOfSquares = sumPriceSquaredVolume / sumVolume
        let variance = max(meanOfSquares - (mean * mean), 0)
        return sqrt(variance)
    }

    var vwapZ: Double {
        let sigma = vwapSigma
        // Early in the session sigma is near zero and z explodes. Suppress it
        // until there's enough dispersion for the number to mean anything.
        guard sigma > 0.0001, barsSeen >= 5 else { return 0 }
        return (last - vwap) / sigma
    }

    var rangePosition: Double {
        guard dayHigh > dayLow, dayLow < .greatestFiniteMagnitude else { return 0.5 }
        return (last - dayLow) / (dayHigh - dayLow)
    }

    var dollarVolume: Double { sumVolume * vwap }

    var minutesSinceLastEvent: Int? {
        guard let lastEventAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastEventAt) / 60))
    }

    var latestNews: NewsItem? { news.first }

    var newsAgeMinutes: Double? {
        guard let item = news.first else { return nil }
        return Date().timeIntervalSince(item.createdAt) / 60
    }

    // MARK: - Ingestion

    /// Applies one minute bar. Returns true if the bar was accepted.
    /// - Parameter includePremarket: whether pre-market bars contribute to VWAP.
    ///   Off by default, because a VWAP anchored to thin 5am prints is a VWAP
    ///   no other participant is watching.
    @discardableResult
    mutating func apply(bar: MinuteBar, includePremarket: Bool) -> Bool {
        // Reconnects can repeat bars or deliver stale backfill. Never count
        // the same minute twice or roll the active session backward.
        guard bar.symbol == symbol else { return false }
        if let lastBarAt, bar.timestamp <= lastBarAt { return false }
        guard [bar.open, bar.high, bar.low, bar.close, bar.volume].allSatisfy({ $0.isFinite }),
              bar.volume > 0, bar.close > 0, bar.low > 0,
              bar.high >= bar.low, bar.high >= bar.close, bar.low <= bar.close else { return false }
        // Roll the session over at the first bar of a new trading day.
        if !MarketClock.isSameTradingDay(bar.timestamp, sessionDay) {
            reset(to: bar.timestamp)
        }

        let phase = MarketClock.phase(at: bar.timestamp)
        guard bar.volume > 0, bar.close > 0 else { return false }

        // Pre-market is tracked whether or not it feeds VWAP, because the
        // gapper scan needs it and it costs three additions to keep.
        if phase == .premarket {
            premarketVolume += bar.volume
            premarketHigh = max(premarketHigh, bar.high)
            premarketLow = min(premarketLow, bar.low)
            last = bar.close
            lastBarAt = bar.timestamp
            if !includePremarket { return false }
        }

        guard phase == .regular || (phase == .premarket && includePremarket) else { return false }

        if sessionOpen == 0 { sessionOpen = bar.open }

        let price = bar.typicalPrice
        sumVolume += bar.volume
        sumPriceVolume += price * bar.volume
        sumPriceSquaredVolume += price * price * bar.volume

        dayHigh = max(dayHigh, bar.high)
        dayLow = min(dayLow, bar.low)
        last = bar.close
        lastBarAt = bar.timestamp
        lastBarVolume = bar.volume
        lastTradeCount = bar.tradeCount
        barsSeen += 1

        recentCloses.append(bar.close)
        recentVWAPs.append(vwap)
        if recentCloses.count > 120 {
            recentCloses.removeFirst()
            recentVWAPs.removeFirst()
        }

        recentBars.append(bar)
        if recentBars.count > 20 { recentBars.removeFirst() }

        detectVWAPEvent(bar: bar)
        return true
    }

    /// A cross only counts once price holds the new side for a second bar.
    /// Single-bar wicks through VWAP are the main source of false alerts, and
    /// requiring confirmation costs one minute of latency to remove most of them.
    private mutating func detectVWAPEvent(bar: MinuteBar) {
        guard barsSeen >= 3 else {
            currentSide = bar.close >= vwap ? .aboveVWAP : .belowVWAP
            return
        }

        let side: TrendState = bar.close >= vwap ? .aboveVWAP : .belowVWAP
        guard side != currentSide else {
            pendingSide = nil
            return
        }

        if pendingSide == side {
            // Second consecutive bar on the new side — confirmed.
            currentSide = side
            lastEvent = side == .aboveVWAP ? .reclaim : .loss
            lastEventAt = bar.timestamp
            pendingSide = nil
        } else {
            pendingSide = side
            pendingSinceBar = barsSeen
        }
    }

    mutating func attach(news item: NewsItem) {
        guard !news.contains(where: { $0.id == item.id }) else { return }
        news.insert(item, at: 0)
        if news.count > 10 { news.removeLast() }
    }

    /// Seeds price context from a REST snapshot so the list is populated
    /// before the first streamed bar arrives.
    mutating func seed(open: Double, high: Double, low: Double, last: Double, volume: Double) {
        guard sumVolume == 0 else { return }
        sessionOpen = open
        dayHigh = high
        dayLow = low
        self.last = last
        // Approximate the VWAP accumulators from the daily bar so the first
        // few streamed minutes don't produce a wildly wrong VWAP.
        let typical = (high + low + last) / 3
        if volume > 0 {
            sumVolume = volume
            sumPriceVolume = typical * volume
            sumPriceSquaredVolume = typical * typical * volume
        }
    }

    mutating func reset(to date: Date) {
        sessionDay = date
        sumVolume = 0
        sumPriceVolume = 0
        sumPriceSquaredVolume = 0
        sessionOpen = 0
        dayHigh = 0
        dayLow = .greatestFiniteMagnitude
        last = 0
        lastBarVolume = 0
        lastTradeCount = 0
        barsSeen = 0
        recentCloses.removeAll(keepingCapacity: true)
        recentVWAPs.removeAll(keepingCapacity: true)
        recentBars.removeAll(keepingCapacity: true)
        premarketVolume = 0
        premarketHigh = 0
        premarketLow = .greatestFiniteMagnitude
        currentSide = .atVWAP
        pendingSide = nil
        lastEvent = .none
        lastEventAt = nil
        news.removeAll(keepingCapacity: true)
    }
}
