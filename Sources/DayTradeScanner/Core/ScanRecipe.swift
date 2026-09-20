import Foundation

/// The kind of setup a candidate represents.
///
/// Serves two purposes. It labels what the scanner found, and it tags every
/// paper trade so outcomes can be sliced by setup rather than only by
/// component. Knowing that gap-and-go works for you and VWAP reclaims don't is
/// a more useful finding than knowing your relative-volume weight is 0.22.
enum SetupType: String, Codable, CaseIterable, Identifiable, Sendable {
    case gapAndGo
    case highOfDayMomentum
    case runningUp
    case runningDown
    case vwapReclaim
    case vwapLoss
    case lowFloatSqueeze
    case newsCatalyst
    case haltResume
    case openingDrive
    case pullbackContinuation
    case rangeBreakout
    case unclassified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gapAndGo: return "Gap and go"
        case .highOfDayMomentum: return "High of day momentum"
        case .runningUp: return "Running up"
        case .runningDown: return "Running down"
        case .vwapReclaim: return "VWAP reclaim"
        case .vwapLoss: return "VWAP loss"
        case .lowFloatSqueeze: return "Low float squeeze"
        case .newsCatalyst: return "News catalyst"
        case .haltResume: return "Halt resume"
        case .openingDrive: return "Opening drive"
        case .pullbackContinuation: return "Pullback continuation"
        case .rangeBreakout: return "Range breakout"
        case .unclassified: return "Unclassified"
        }
    }

    var isShortBias: Bool {
        self == .runningDown || self == .vwapLoss
    }

    /// Classifies a scored candidate. Order matters — the most specific and
    /// most time-sensitive setups are tested first, because a halt resume that
    /// also happens to be above VWAP is a halt resume, not a VWAP reclaim.
    static func classify(_ candidate: Candidate, isFreshResume: Bool = false) -> SetupType {
        let snapshot = candidate.snapshot
        let extended = snapshot.extended

        if isFreshResume { return .haltResume }

        if let category = extended.floatCategory,
           (category == .nano || category == .micro),
           snapshot.rvol >= 3, snapshot.changePercent > 0.08 {
            return .lowFloatSqueeze
        }

        if let age = snapshot.newsAgeMinutes, age <= 15, snapshot.rvol >= 2 {
            return .newsCatalyst
        }

        if snapshot.minuteOfSession < 15, abs(extended.openingDriveATR) >= 0.5 {
            return .openingDrive
        }

        if abs(snapshot.gapPercent) >= 0.04, snapshot.minuteOfSession < 60,
           snapshot.rangePosition > 0.7 {
            return .gapAndGo
        }

        if snapshot.rangePosition >= 0.95, snapshot.rvol >= 2 {
            return .highOfDayMomentum
        }

        if extended.pullbackQuality >= 0.5, extended.consecutiveDirectionalBars != 0 {
            return .pullbackContinuation
        }

        if extended.consecutiveDirectionalBars >= 3, extended.burstScore >= 0.4 {
            return .runningUp
        }
        if extended.consecutiveDirectionalBars <= -3, extended.burstScore >= 0.4 {
            return .runningDown
        }

        if snapshot.vwapEvent == .reclaim, (snapshot.minutesSinceVWAPEvent ?? 99) <= 10 {
            return .vwapReclaim
        }
        if snapshot.vwapEvent == .loss, (snapshot.minutesSinceVWAPEvent ?? 99) <= 10 {
            return .vwapLoss
        }

        if extended.compressionRatio < 0.65, snapshot.rvol >= 2 {
            return .rangeBreakout
        }

        return .unclassified
    }
}

/// A named, single-purpose scan.
///
/// Every established momentum platform ships a library of these rather than one
/// configurable scanner, and the reason becomes obvious once you use one: a
/// scan that answers a single question is legible, and a scan with forty knobs
/// is not. A recipe is a thin overlay on a `ScanProfile` — it narrows the
/// gates and re-weights a few components, then hands off to the same engine.
struct ScanRecipe: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }

    let name: String
    let summary: String
    let baseProfile: ScanProfile
    let setup: SetupType

    // Gate overrides. Nil leaves the profile's own value in place.
    var minPrice: Double?
    var maxPrice: Double?
    var minRVOL: Double?
    var minChangePercent: Double?
    var maxChangePercent: Double?
    var minDollarVolume: Double?
    var maxFloatShares: Double?
    var minFloatShares: Double?
    var requireNews: Bool = false
    var requireAboveVWAP: Bool?
    var minRangePosition: Double?
    var maxExtensionATR: Double?
    var requireFreshResume: Bool = false

    /// Weight multipliers applied on top of the base profile.
    var weightBoosts: [SignalComponent: Double] = [:]

    var alertThreshold: Double?

    /// Whether a snapshot satisfies the recipe's own gates. Applied after the
    /// profile's gates, never instead of them.
    func admits(_ snapshot: SignalSnapshot, isFreshResume: Bool) -> Bool {
        if requireFreshResume && !isFreshResume { return false }
        if let minPrice, snapshot.last < minPrice { return false }
        if let maxPrice, snapshot.last > maxPrice { return false }
        if let minRVOL, snapshot.rvol < minRVOL { return false }
        if let minChangePercent, abs(snapshot.changePercent) < minChangePercent { return false }
        if let maxChangePercent, abs(snapshot.changePercent) > maxChangePercent { return false }
        if let minDollarVolume, snapshot.dollarVolume < minDollarVolume { return false }
        if let minRangePosition, snapshot.rangePosition < minRangePosition { return false }
        if let maxExtensionATR, snapshot.extended.extensionATR > maxExtensionATR { return false }
        if requireNews, (snapshot.newsAgeMinutes ?? .greatestFiniteMagnitude) > 120 { return false }

        if let requireAboveVWAP {
            let isAbove = snapshot.trend == .aboveVWAP
            if isAbove != requireAboveVWAP { return false }
        }

        // Float gates only apply when float is actually known. Treating an
        // unknown float as large would silently exclude exactly the newly
        // listed, thinly filed names these recipes exist to find.
        if let maxFloatShares {
            guard let float = snapshot.extended.floatShares else { return false }
            if float > maxFloatShares { return false }
        }
        if let minFloatShares {
            guard let float = snapshot.extended.floatShares else { return false }
            if float < minFloatShares { return false }
        }

        return true
    }

    func makeConfig(from base: ScoringConfig) -> ScoringConfig {
        var config = base
        for (component, multiplier) in weightBoosts {
            config.weights[component] = (config.weights[component] ?? component.defaultWeight) * multiplier
        }
        if let minRVOL { config.minRVOL = minRVOL }
        if let minChangePercent { config.minAbsChangePercent = minChangePercent }
        if let minPrice { config.minPrice = minPrice }
        if let maxPrice { config.maxPrice = maxPrice }
        if let minDollarVolume { config.minDollarVolume = minDollarVolume }
        if let alertThreshold { config.alertThreshold = alertThreshold }
        return config
    }
}

// MARK: - Library

/// The built-in recipes.
///
/// The small-cap momentum entries follow the criteria most widely published by
/// retail momentum educators: relative volume at least twice normal, already up
/// around 5% from the prior close, a news catalyst, a price range roughly $1
/// to $10, and a float under about 10–20M shares. Those five conditions have
/// been the backbone of the strategy for a decade, and they are simple enough
/// to state in a sentence — which is itself the lesson.
enum RecipeLibrary {

    static let all: [ScanRecipe] = [
        smallCapHighOfDay,
        smallCapRunningUp,
        smallCapRunningDown,
        gapAndGo,
        lowFloatSqueeze,
        nanoFloatRunner,
        newsBreakout,
        offeringFade,
        vwapReclaimContinuation,
        vwapLossBreakdown,
        haltResumeLong,
        openingDrive,
        scalpPullback,
        scalpBurst,
        coiledBreakout,
        largeCapMomentum,
        premarketGapper
    ]

    static func recipe(named name: String) -> ScanRecipe? {
        all.first { $0.name == name }
    }

    // MARK: Small cap momentum

    static let smallCapHighOfDay = ScanRecipe(
        name: "Small cap high of day",
        summary: "Sub-$20 names printing new highs on multiples of normal volume, with a tight float.",
        baseProfile: .dayTrade,
        setup: .highOfDayMomentum,
        minPrice: 1.0,
        maxPrice: 20.0,
        minRVOL: 3.0,
        minChangePercent: 0.05,
        minDollarVolume: 150_000,
        maxFloatShares: 50_000_000,
        minRangePosition: 0.92,
        maxExtensionATR: 5.0,
        weightBoosts: [.relativeVolume: 1.3, .rangePosition: 3.0, .floatTightness: 1.5],
        alertThreshold: 0.64
    )

    static let smallCapRunningUp = ScanRecipe(
        name: "Running up",
        summary: "Fast upside moves that haven't printed a new high yet — fires earlier than a high-of-day scan.",
        baseProfile: .scalp,
        setup: .runningUp,
        minPrice: 1.0,
        maxPrice: 30.0,
        minRVOL: 2.0,
        minChangePercent: 0.03,
        minDollarVolume: 200_000,
        maxFloatShares: 80_000_000,
        requireAboveVWAP: true,
        maxExtensionATR: 4.5,
        weightBoosts: [.momentumBurst: 1.4, .acceleration: 1.5],
        alertThreshold: 0.66
    )

    static let smallCapRunningDown = ScanRecipe(
        name: "Running down",
        summary: "The mirror image. Fast downside moves on volume, for short setups and fade avoidance.",
        baseProfile: .scalp,
        setup: .runningDown,
        minPrice: 2.0,
        maxPrice: 50.0,
        minRVOL: 2.0,
        minChangePercent: 0.03,
        minDollarVolume: 400_000,
        requireAboveVWAP: false,
        weightBoosts: [.momentumBurst: 1.4, .acceleration: 1.5],
        alertThreshold: 0.66
    )

    static let gapAndGo = ScanRecipe(
        name: "Gap and go",
        summary: "Overnight gappers holding their gains through the first hour instead of filling.",
        baseProfile: .dayTrade,
        setup: .gapAndGo,
        minPrice: 1.0,
        maxPrice: 100.0,
        minRVOL: 2.0,
        minChangePercent: 0.04,
        minDollarVolume: 250_000,
        requireAboveVWAP: true,
        minRangePosition: 0.6,
        weightBoosts: [.gap: 2.0, .rangePosition: 2.0, .news: 1.3],
        alertThreshold: 0.62
    )

    // MARK: Float-driven

    static let lowFloatSqueeze = ScanRecipe(
        name: "Low float squeeze",
        summary: "Under 20M shares, heavy volume, and elevated short volume. The classic squeeze shape.",
        baseProfile: .runnerHunt,
        setup: .lowFloatSqueeze,
        minPrice: 0.75,
        maxPrice: 40.0,
        minRVOL: 4.0,
        minChangePercent: 0.08,
        minDollarVolume: 200_000,
        maxFloatShares: 20_000_000,
        weightBoosts: [.floatTightness: 2.2, .shortPressure: 2.0, .relativeVolume: 1.3],
        alertThreshold: 0.68
    )

    static let nanoFloatRunner = ScanRecipe(
        name: "Nano float runner",
        summary: "Under 5M shares. Enormous upside, and the highest halt risk in the app — treat accordingly.",
        baseProfile: .runnerHunt,
        setup: .lowFloatSqueeze,
        minPrice: 0.50,
        maxPrice: 30.0,
        minRVOL: 5.0,
        minChangePercent: 0.12,
        minDollarVolume: 100_000,
        maxFloatShares: 5_000_000,
        weightBoosts: [.floatTightness: 2.5, .volatilityPotential: 1.5, .haltRisk: 1.8],
        alertThreshold: 0.70
    )

    // MARK: News

    static let newsBreakout = ScanRecipe(
        name: "News breakout",
        summary: "A fresh headline with volume actually responding to it, not just a stale wire item.",
        baseProfile: .dayTrade,
        setup: .newsCatalyst,
        minPrice: 1.0,
        minRVOL: 2.5,
        minChangePercent: 0.04,
        minDollarVolume: 200_000,
        requireNews: true,
        weightBoosts: [.news: 2.0, .relativeVolume: 1.2],
        alertThreshold: 0.60
    )

    static let offeringFade = ScanRecipe(
        name: "Offering fade",
        summary: "Dilutive headlines on names that were running. Short bias — the news component scores negative here.",
        baseProfile: .dayTrade,
        setup: .vwapLoss,
        minPrice: 1.0,
        minRVOL: 2.0,
        minChangePercent: 0.03,
        minDollarVolume: 250_000,
        requireNews: true,
        requireAboveVWAP: false,
        weightBoosts: [.news: 1.6, .vwapEvent: 1.4],
        alertThreshold: 0.58
    )

    // MARK: VWAP structure

    static let vwapReclaimContinuation = ScanRecipe(
        name: "VWAP reclaim",
        summary: "A confirmed cross back above VWAP on volume, within the last few minutes.",
        baseProfile: .dayTrade,
        setup: .vwapReclaim,
        minPrice: 1.5,
        minRVOL: 1.8,
        minChangePercent: 0.02,
        minDollarVolume: 300_000,
        requireAboveVWAP: true,
        weightBoosts: [.vwapEvent: 2.0, .vwapPosition: 1.3],
        alertThreshold: 0.60
    )

    static let vwapLossBreakdown = ScanRecipe(
        name: "VWAP loss",
        summary: "A confirmed break below VWAP after a failed push. The short-side counterpart.",
        baseProfile: .dayTrade,
        setup: .vwapLoss,
        minPrice: 2.0,
        minRVOL: 1.8,
        minChangePercent: 0.02,
        minDollarVolume: 400_000,
        requireAboveVWAP: false,
        weightBoosts: [.vwapEvent: 2.0],
        alertThreshold: 0.60
    )

    // MARK: Halts

    static let haltResumeLong = ScanRecipe(
        name: "Halt resume",
        summary: "Symbols reopening from a volatility pause. Only tradeable halt codes — never a T12 or an SEC suspension.",
        baseProfile: .scalp,
        setup: .haltResume,
        minPrice: 0.75,
        minRVOL: 2.0,
        minDollarVolume: 150_000,
        requireFreshResume: true,
        weightBoosts: [.momentumBurst: 1.5, .relativeVolume: 1.3, .floatTightness: 1.4],
        alertThreshold: 0.55
    )

    // MARK: Session structure

    static let openingDrive = ScanRecipe(
        name: "Opening drive",
        summary: "The first fifteen minutes, where a decisive move sets the tone for the session.",
        baseProfile: .dayTrade,
        setup: .openingDrive,
        minPrice: 1.0,
        minRVOL: 2.5,
        minChangePercent: 0.03,
        minDollarVolume: 300_000,
        weightBoosts: [.gap: 1.4, .relativeVolume: 1.3, .rangePosition: 1.5],
        alertThreshold: 0.62
    )

    static let coiledBreakout = ScanRecipe(
        name: "Coiled breakout",
        summary: "Symbols that spent weeks compressing and are now expanding on volume.",
        baseProfile: .runnerHunt,
        setup: .rangeBreakout,
        minPrice: 1.0,
        minRVOL: 3.0,
        minChangePercent: 0.04,
        minDollarVolume: 250_000,
        weightBoosts: [.compression: 2.5, .rangeExpansion: 1.8],
        alertThreshold: 0.64
    )

    // MARK: Scalping

    static let scalpPullback = ScanRecipe(
        name: "Scalp pullback",
        summary: "A shallow retrace holding VWAP after a push, on liquid names where the spread won't eat the trade.",
        baseProfile: .scalp,
        setup: .pullbackContinuation,
        minPrice: 3.0,
        minRVOL: 2.0,
        minChangePercent: 0.01,
        minDollarVolume: 800_000,
        minFloatShares: 5_000_000,
        requireAboveVWAP: true,
        maxExtensionATR: 3.0,
        weightBoosts: [.pullbackQuality: 2.0, .vwapPosition: 1.3],
        alertThreshold: 0.68
    )

    static let scalpBurst = ScanRecipe(
        name: "Scalp burst",
        summary: "Consecutive minute bars in one direction with volume behind each of them.",
        baseProfile: .scalp,
        setup: .runningUp,
        minPrice: 3.0,
        minRVOL: 2.5,
        minChangePercent: 0.01,
        minDollarVolume: 800_000,
        maxExtensionATR: 3.5,
        weightBoosts: [.momentumBurst: 2.0, .acceleration: 1.6],
        alertThreshold: 0.70
    )

    // MARK: Large cap and pre-market

    static let largeCapMomentum = ScanRecipe(
        name: "Large cap momentum",
        summary: "Liquid, tight-spread names for size. Lower ceiling, far lower halt risk.",
        baseProfile: .dayTrade,
        setup: .highOfDayMomentum,
        minPrice: 20.0,
        minRVOL: 2.0,
        minChangePercent: 0.02,
        minDollarVolume: 2_000_000,
        minFloatShares: 50_000_000,
        minRangePosition: 0.8,
        weightBoosts: [.relativeVolume: 1.3, .vwapPosition: 1.2],
        alertThreshold: 0.62
    )

    static let premarketGapper = ScanRecipe(
        name: "Pre-market gapper",
        summary: "Before the open: gap size, pre-market volume against this symbol's own norm, and a real catalyst.",
        baseProfile: .premarket,
        setup: .gapAndGo,
        minPrice: 0.75,
        minRVOL: 1.2,
        minChangePercent: 0.04,
        minDollarVolume: 50_000,
        weightBoosts: [.gap: 1.5, .news: 1.4, .floatTightness: 1.5],
        alertThreshold: 0.56
    )
}
