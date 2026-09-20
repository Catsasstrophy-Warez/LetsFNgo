import Foundation

/// Everything the swing engine knows about one symbol, computed from daily
/// bars rather than the minute-bar stream the day-trade engine uses.
///
/// The unit of time here is the session, not the minute. A swing setup that
/// changes meaningfully within an hour isn't a swing setup — it's noise on
/// the way to one.
struct SwingSignalSnapshot: Codable, Hashable, Sendable {
    let symbol: String
    let asOf: Date

    let last: Double
    let priorClose: Double

    // Trend
    /// Simple moving averages. Their relative order (price > 20 > 50 > 200)
    /// is the single most-cited trend filter in technical trading, precisely
    /// because it's crude enough to be robust.
    let sma20: Double
    let sma50: Double
    let sma200: Double
    /// Percent change in the 50-day SMA over the last 10 sessions — a rising
    /// average is a different claim than merely being above one.
    let sma50SlopePercent: Double

    // Relative strength
    /// This symbol's return over the window, minus SPY's return over the same
    /// window. A stock up 8% while the market is up 6% is not the same as one
    /// up 8% while the market is flat — only the second is actually leading.
    let relativeStrength20Day: Double
    let relativeStrength60Day: Double

    // Range and structure
    let high52Week: Double
    let low52Week: Double
    /// 0...1, where 1.0 is sitting at the 52-week high.
    let positionIn52WeekRange: Double
    /// Highest high of the preceding N sessions, used for breakout detection.
    let priorRangeHigh20: Double
    let atrPercent: Double

    // Volume
    /// Today's volume (or most recent session's) against its own 20-day
    /// median. The daily-bar equivalent of RVOL.
    let volumeVsAverage: Double
    /// Median volume over the last 5 sessions against the last 20 — a rising
    /// ratio suggests building interest ahead of a move rather than after one.
    let volumeTrend: Double
    /// Median observed daily dollar volume from the same feed as the bars.
    var averageDollarVolume: Double? = nil

    // Pullback
    /// Distance from the 20-day SMA in ATR units, signed. Positive means
    /// price is above the average.
    let distanceFromSMA20ATR: Double

    // Float and insider context, shared with the day-trade engine's sources
    let floatShares: Double?
    let floatCategory: SECFloatClient.FloatCategory?
    let insiderFilingsRecent: Int
    /// SIC-code industry description from SEC EDGAR — coarse, but genuinely
    /// free, and it rides along in the same fetch already made for insider
    /// filing frequency, so it costs nothing extra.
    let sector: String?

    // Event risk
    /// Estimated days until the next quarterly filing, projected from the
    /// historical filing cadence. This is an estimate, not a confirmed date —
    /// free EDGAR data has no forward-looking earnings-date field, only the
    /// pattern of when filings have landed before.
    let estimatedDaysToNextFiling: Int?

    var changePercent: Double {
        guard priorClose > 0 else { return 0 }
        return (last / priorClose) - 1.0
    }

    var isAboveAllMovingAverages: Bool { last > sma20 && sma20 > sma50 && sma50 > sma200 }
    var isBelowAllMovingAverages: Bool { last < sma20 && sma20 < sma50 && sma50 < sma200 }
}

enum SwingSetupType: String, Codable, CaseIterable, Identifiable, Sendable {
    case trendContinuation
    case pullbackToSupport
    case breakout
    case baseBuilding
    case relativeStrengthLeader
    case reversal
    case unclassified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trendContinuation: return "Trend continuation"
        case .pullbackToSupport: return "Pullback to support"
        case .breakout: return "Breakout"
        case .baseBuilding: return "Base building"
        case .relativeStrengthLeader: return "Relative strength leader"
        case .reversal: return "Reversal"
        case .unclassified: return "Unclassified"
        }
    }

    static func classify(_ snapshot: SwingSignalSnapshot) -> SwingSetupType {
        if snapshot.last >= snapshot.priorRangeHigh20, snapshot.volumeVsAverage >= 1.5 {
            return .breakout
        }
        if snapshot.isAboveAllMovingAverages, snapshot.distanceFromSMA20ATR < 0.8, snapshot.distanceFromSMA20ATR > -0.3 {
            return .pullbackToSupport
        }
        if snapshot.isAboveAllMovingAverages, snapshot.relativeStrength20Day > 0.05 {
            return .relativeStrengthLeader
        }
        if snapshot.isAboveAllMovingAverages {
            return .trendContinuation
        }
        if snapshot.isBelowAllMovingAverages, snapshot.changePercent > 0.03, snapshot.volumeVsAverage >= 1.5 {
            return .reversal
        }
        if abs(snapshot.sma50SlopePercent) < 0.02, snapshot.positionIn52WeekRange > 0.4, snapshot.positionIn52WeekRange < 0.75 {
            return .baseBuilding
        }
        return .unclassified
    }
}

enum SwingComponent: String, Codable, CaseIterable, Identifiable, Sendable {
    case trendAlignment
    case relativeStrength
    case breakoutQuality
    case volumeConfirmation
    case pullbackQuality
    case rangePosition
    case floatTightness
    case insiderActivity
    case earningsRisk   // negative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trendAlignment: return "Trend alignment"
        case .relativeStrength: return "Relative strength"
        case .breakoutQuality: return "Breakout quality"
        case .volumeConfirmation: return "Volume confirmation"
        case .pullbackQuality: return "Pullback quality"
        case .rangePosition: return "52-week range position"
        case .floatTightness: return "Float tightness"
        case .insiderActivity: return "Insider filing activity"
        case .earningsRisk: return "Earnings proximity"
        }
    }

    var explanation: String {
        switch self {
        case .trendAlignment:
            return "Price above the 20, 50, and 200-day averages in order, with the 50-day actually rising. The most-cited trend filter in technical trading because it's crude enough to be robust."
        case .relativeStrength:
            return "Return over the last 20 and 60 sessions minus SPY's return over the same window. Only a stock beating the index is actually leading rather than just following the tape up."
        case .breakoutQuality:
            return "A close at or above the prior 20-session high, on volume meaningfully above normal. A breakout on light volume is usually a false one."
        case .volumeConfirmation:
            return "Recent volume against its own 20-day baseline, and whether the 5-day trend in volume is rising. Confirms genuine interest rather than a single noisy session."
        case .pullbackQuality:
            return "Distance from the 20-day moving average in ATR units. A shallow pullback in an established uptrend is a better entry than chasing a fresh high."
        case .rangePosition:
            return "Where price sits in its 52-week range. Rewards proximity to highs without penalizing a name that's simply mid-range and building a base."
        case .floatTightness:
            return "Same float data as the day-trade engine, weighted far lower here — a swing position is held through more sessions, which is more exposure to a tight float's larger overnight gaps."
        case .insiderActivity:
            return "Frequency of Form 4 filings at this company in the last 90 days, from SEC EDGAR. A count, not a signed buy/sell signal — free EDGAR data doesn't expose transaction direction without parsing each filing's ownership XML."
        case .earningsRisk:
            return "Estimated proximity to the next quarterly filing, projected from filing history rather than a confirmed date. Scores negative — a swing position held through an earnings gap is a different, riskier trade than the one being scored."
        }
    }

    var defaultWeight: Double {
        switch self {
        case .trendAlignment: return 0.22
        case .relativeStrength: return 0.20
        case .breakoutQuality: return 0.14
        case .volumeConfirmation: return 0.12
        case .pullbackQuality: return 0.14
        case .rangePosition: return 0.08
        case .floatTightness: return 0.03
        case .insiderActivity: return 0.04
        case .earningsRisk: return 0.03
        }
    }
}

struct SwingScoreBreakdown: Codable, Hashable, Sendable {
    var normalized: [SwingComponent: Double] = [:]
    var contributions: [SwingComponent: Double] = [:]
    var total: Double = 0

    var sortedContributions: [(SwingComponent, Double)] {
        contributions.sorted { $0.value > $1.value }
    }

    func topDrivers(limit: Int = 3, floor: Double = 0.03) -> [SwingComponent] {
        sortedContributions.filter { $0.1 >= floor }.prefix(limit).map(\.0)
    }
}

struct SwingCandidate: Identifiable, Hashable, Sendable {
    var id: String { snapshot.symbol }
    let snapshot: SwingSignalSnapshot
    let breakdown: SwingScoreBreakdown

    var symbol: String { snapshot.symbol }
    var score: Double { breakdown.total }
    var setup: SwingSetupType { SwingSetupType.classify(snapshot) }

    var plainReason: String {
        var parts: [String] = []
        for component in breakdown.topDrivers() {
            switch component {
            case .trendAlignment:
                if snapshot.isAboveAllMovingAverages { parts.append("above all key averages") }
            case .relativeStrength:
                parts.append(String(format: "%+.1f%% vs SPY over 20 sessions", snapshot.relativeStrength20Day * 100))
            case .breakoutQuality:
                if snapshot.last >= snapshot.priorRangeHigh20 { parts.append("breaking a 20-day high") }
            case .volumeConfirmation:
                parts.append(String(format: "%.1f× normal volume", snapshot.volumeVsAverage))
            case .pullbackQuality:
                parts.append(String(format: "%.1f ATR off the 20-day average", snapshot.distanceFromSMA20ATR))
            case .rangePosition:
                parts.append(String(format: "%.0f%% of 52-week range", snapshot.positionIn52WeekRange * 100))
            case .floatTightness:
                if let category = snapshot.floatCategory { parts.append(category.displayName.lowercased()) }
            case .insiderActivity:
                if snapshot.insiderFilingsRecent > 0 { parts.append("\(snapshot.insiderFilingsRecent) insider filings, 90d") }
            case .earningsRisk:
                break
            }
        }
        return parts.isEmpty ? "No component above threshold" : parts.joined(separator: ", ")
    }

    var hazardNote: String? {
        var warnings: [String] = []
        if let days = snapshot.estimatedDaysToNextFiling, days <= 7 {
            warnings.append("earnings likely within \(days)d")
        }
        if snapshot.floatCategory?.carriesElevatedRisk == true {
            warnings.append("tight float — larger overnight gaps")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }
}
