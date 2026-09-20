import Foundation

/// The outermost split in the app: what kind of trade this is.
///
/// Day trading, swing trading, and long-term investing are not the same
/// activity performed at different speeds — they use different data
/// (minute bars vs daily bars vs quarterly filings), different hazards
/// (halts and spread vs earnings gaps vs balance-sheet risk), and different
/// definitions of "done" (flat by the bell vs a multi-week target vs a
/// thesis that plays out over quarters). Bolting all three onto one scoring
/// vector is how a scanner ends up mediocre at each — the same mistake a
/// single `ScanProfile` would make trying to cover both day trading and
/// scalping, one level up.
///
/// Each horizon gets its own engine, its own universe, and its own refresh
/// cadence. What they share is the paper log — an outcome is an outcome
/// regardless of how long the position was open, and comparing horizons
/// against each other in one place is itself useful.
enum TradeHorizon: String, Codable, CaseIterable, Identifiable, Sendable {
    case dayTrade
    case swing
    case longTerm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dayTrade: return "Day Trade"
        case .swing: return "Swing"
        case .longTerm: return "Long Term"
        }
    }

    var shortDescription: String {
        switch self {
        case .dayTrade:
            return "Flat by the close. Minute bars, VWAP, volume, halts."
        case .swing:
            return "Days to a few weeks. Daily bars, trend, relative strength, breakouts."
        case .longTerm:
            return "Months to years. Fundamentals, growth, insider conviction."
        }
    }

    var systemImage: String {
        switch self {
        case .dayTrade: return "bolt.fill"
        case .swing: return "chart.line.uptrend.xyaxis"
        case .longTerm: return "building.columns"
        }
    }

    /// What "closed" means for a paper trade opened under this horizon.
    /// Day trades are marked flat at the bell regardless of what price does
    /// afterward, because holding overnight is a different strategy with
    /// different risk than the one being measured. Swing and long-term
    /// positions have no such artificial deadline — they close on their own
    /// schedule or when the person closes them.
    var forcesEndOfDayClose: Bool { self == .dayTrade }

    /// The horizons over which a paper trade gets marked to market. Day
    /// trades care about the next hour; a long-term thesis doesn't resolve
    /// in a day, so marking it hourly would just be noise around a number
    /// that hasn't had time to mean anything yet.
    var markToMarketHorizons: [(label: String, duration: TimeInterval)] {
        switch self {
        case .dayTrade:
            return [("15m", 15 * 60), ("30m", 30 * 60), ("60m", 60 * 60)]
        case .swing:
            return [("1d", 86400), ("3d", 3 * 86400), ("5d", 5 * 86400)]
        case .longTerm:
            return [("1w", 7 * 86400), ("1m", 30 * 86400), ("3m", 91 * 86400)]
        }
    }

    /// How often the engine refreshes its ranked list. Day trading needs
    /// seconds; re-screening fundamentals every few seconds would just
    /// re-fetch the same quarterly numbers and burn through EDGAR's rate
    /// limit for nothing.
    var refreshInterval: Duration {
        switch self {
        case .dayTrade: return .seconds(3)
        case .swing: return .seconds(900)      // 15 minutes
        case .longTerm: return .seconds(21600) // 6 hours
        }
    }

    /// A sane starter universe for each horizon. Day trading wants hundreds
    /// of liquid, volatile names; swing wants a smaller list of names with
    /// clean technical structure; long-term wants a short list of companies
    /// actually worth researching, because fundamentals scoring on five
    /// hundred tickers produces five hundred shallow opinions rather than
    /// a handful of good ones.
    static func starterUniverse(for horizon: TradeHorizon) -> [String] {
        switch horizon {
        case .dayTrade:
            return Settings.starterUniverse
        case .swing:
            return [
                "AAPL", "MSFT", "NVDA", "AMD", "GOOGL", "AMZN", "META", "TSLA",
                "AVGO", "CRM", "ADBE", "NFLX", "COST", "JPM", "V", "MA",
                "UNH", "HD", "LOW", "XOM", "CVX", "CAT", "DE", "BA",
                "LMT", "SPY", "QQQ", "IWM", "SMH", "XLE", "XLF", "XLK"
            ]
        case .longTerm:
            return [
                "AAPL", "MSFT", "GOOGL", "AMZN", "META", "NVDA", "AVGO", "COST",
                "JNJ", "PG", "KO", "V", "MA", "UNH", "HD", "BRK.B"
            ]
        }
    }
}
