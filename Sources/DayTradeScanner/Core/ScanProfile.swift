import Foundation

/// A scan profile is a complete scoring personality, not a preset.
///
/// Day trading and scalping ask genuinely different questions of the same
/// data. A scalp cares about the last four bars and treats an overnight gap
/// as ancient history; a day-trade scan cares about the whole session shape
/// and treats a three-bar burst as noise. Bolting both onto one weight vector
/// produces a scan that is mediocre at each.
enum ScanProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case dayTrade
    case scalp
    case premarket
    case runnerHunt
    case haltResume

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dayTrade: return "Day trade"
        case .scalp: return "Scalp"
        case .premarket: return "Pre-market"
        case .runnerHunt: return "Runner hunt"
        case .haltResume: return "Halt resume"
        }
    }

    var shortDescription: String {
        switch self {
        case .dayTrade:
            return "Session-shape setups. Volume, VWAP structure and catalysts over the whole day."
        case .scalp:
            return "Microstructure over the last few minutes. Bursts, pullbacks and acceleration."
        case .premarket:
            return "Gappers before the open, ranked on pre-market volume and catalyst quality."
        case .runnerHunt:
            return "Symbols with the history and the range to make an outsized move today."
        case .haltResume:
            return "Symbols reopening from a volatility pause, where the auction often produces a fast move."
        }
    }

    var systemImage: String {
        switch self {
        case .dayTrade: return "waveform.path.ecg"
        case .scalp: return "bolt"
        case .premarket: return "sunrise"
        case .runnerHunt: return "flame"
        case .haltResume: return "pause.circle"
        }
    }

    /// When this profile is worth running, in minutes from the 9:30 open.
    /// Nil means any time. Used to nudge, never to block.
    var suggestedWindow: ClosedRange<Int>? {
        switch self {
        case .premarket: return -330...0
        case .scalp: return 0...120
        case .runnerHunt: return -60...45
        case .dayTrade, .haltResume: return nil
        }
    }

    var isActiveNow: Bool {
        guard let window = suggestedWindow else { return true }
        guard let minute = MarketClock.minuteOfSession() else { return false }
        return window.contains(minute)
    }

    // MARK: - Weights

    var weights: [SignalComponent: Double] {
        switch self {
        case .dayTrade:
            return [
                .relativeVolume: 0.22, .vwapEvent: 0.15, .vwapPosition: 0.08,
                .gap: 0.09, .news: 0.12, .shortPressure: 0.04, .rangePosition: 0.03,
                .volatilityPotential: 0.08, .rangeExpansion: 0.07, .compression: 0.04,
                .floatTightness: 0.08,
                .socialMomentum: 0.04, .insiderCluster: 0.02,
                .momentumBurst: 0.0, .pullbackQuality: 0.0, .acceleration: 0.0,
                .extensionRisk: 0.03, .haltRisk: 0.02
            ]

        case .scalp:
            // Everything slow is zeroed. A scalp entry lives or dies on what
            // the last four bars did, and VWAP is a level to trade against
            // rather than a thesis.
            return [
                .relativeVolume: 0.12, .vwapEvent: 0.10, .vwapPosition: 0.04,
                .gap: 0.0, .news: 0.04, .shortPressure: 0.0, .rangePosition: 0.04,
                .volatilityPotential: 0.05, .rangeExpansion: 0.04, .compression: 0.0,
                .floatTightness: 0.03,
                .socialMomentum: 0.02, .insiderCluster: 0.0,
                .momentumBurst: 0.22, .pullbackQuality: 0.15, .acceleration: 0.10,
                .extensionRisk: 0.03, .haltRisk: 0.04
            ]

        case .premarket:
            // No session VWAP exists yet and no volume baseline applies, so
            // the scan runs almost entirely on gap size, pre-market volume
            // and whether there is a real catalyst behind it.
            return [
                .relativeVolume: 0.20, .vwapEvent: 0.0, .vwapPosition: 0.0,
                .gap: 0.28, .news: 0.24, .shortPressure: 0.04, .rangePosition: 0.0,
                .volatilityPotential: 0.12, .rangeExpansion: 0.0, .compression: 0.03,
                .floatTightness: 0.11,
                .socialMomentum: 0.08, .insiderCluster: 0.02,
                .momentumBurst: 0.0, .pullbackQuality: 0.0, .acceleration: 0.0,
                .extensionRisk: 0.02, .haltRisk: 0.02
            ]

        case .runnerHunt:
            // Deliberately biased toward capacity rather than confirmation.
            // This profile is answering "what could go 20% today", which means
            // accepting more false positives than the day-trade scan.
            return [
                .relativeVolume: 0.18, .vwapEvent: 0.06, .vwapPosition: 0.04,
                .gap: 0.12, .news: 0.14, .shortPressure: 0.08, .rangePosition: 0.04,
                .volatilityPotential: 0.15, .rangeExpansion: 0.09, .compression: 0.05,
                .floatTightness: 0.15,
                .socialMomentum: 0.06, .insiderCluster: 0.05,
                .momentumBurst: 0.04, .pullbackQuality: 0.0, .acceleration: 0.03,
                .extensionRisk: 0.02, .haltRisk: 0.03
            ]

        case .haltResume:
            // The reopening auction is its own regime. Nothing about the
            // pre-halt session shape survives it, so the weights sit almost
            // entirely on what happens in the first minutes after trading
            // restarts. Halt risk is weighted UP rather than down: a symbol
            // that just halted is materially more likely to halt again.
            return [
                .relativeVolume: 0.22, .vwapEvent: 0.08, .vwapPosition: 0.05,
                .gap: 0.0, .news: 0.10, .shortPressure: 0.02, .rangePosition: 0.06,
                .volatilityPotential: 0.06, .rangeExpansion: 0.03, .compression: 0.0,
                .floatTightness: 0.09,
                .socialMomentum: 0.03, .insiderCluster: 0.0,
                .momentumBurst: 0.17, .pullbackQuality: 0.04, .acceleration: 0.08,
                .extensionRisk: 0.02, .haltRisk: 0.06
            ]
        }
    }

    // MARK: - Gates and time constants

    /// Gate overrides. Scalping needs tighter liquidity gates than day trading
    /// because you're paying the spread far more often, and the spread on a
    /// thin name eats a scalp's entire expected move.
    var gateOverrides: (minRVOL: Double, minChange: Double, minDollarVolume: Double, minPrints: Int, minPrice: Double) {
        switch self {
        case .dayTrade: return (1.5, 0.015, 250_000, 30, 1.50)
        case .scalp: return (2.0, 0.010, 600_000, 80, 3.00)
        case .premarket: return (1.2, 0.030, 60_000, 10, 1.00)
        case .runnerHunt: return (2.5, 0.040, 200_000, 25, 0.75)
        case .haltResume: return (2.0, 0.030, 150_000, 20, 0.75)
        }
    }

    /// How fast event-driven components decay, in minutes.
    var eventDecayMinutes: Double {
        switch self {
        case .dayTrade: return 30
        case .scalp: return 6
        case .premarket: return 90
        case .runnerHunt: return 45
        case .haltResume: return 8
        }
    }

    var newsHalfLifeMinutes: Double {
        switch self {
        case .dayTrade: return 20
        case .scalp: return 8
        case .premarket: return 180
        case .runnerHunt: return 45
        case .haltResume: return 30
        }
    }

    /// Rescoring cadence. A scalp list that refreshes every three seconds is
    /// stale; one that refreshes every second is unreadable.
    var rescoreInterval: Duration {
        switch self {
        case .scalp: return .seconds(2)
        case .premarket: return .seconds(10)
        default: return .seconds(3)
        }
    }

    var defaultAlertThreshold: Double {
        switch self {
        case .dayTrade: return 0.62
        case .scalp: return 0.70
        case .premarket: return 0.58
        case .runnerHunt: return 0.66
        case .haltResume: return 0.55
        }
    }

    var alertCooldownMinutes: Double {
        switch self {
        case .scalp, .haltResume: return 5
        case .premarket: return 45
        default: return 20
        }
    }

    /// Builds a full scoring config from the profile, preserving any
    /// normalization anchors the user has already tuned.
    func makeConfig(preserving existing: ScoringConfig? = nil) -> ScoringConfig {
        var config = ScoringConfig(weights: weights)
        let gates = gateOverrides

        config.minRVOL = gates.minRVOL
        config.minAbsChangePercent = gates.minChange
        config.minDollarVolume = gates.minDollarVolume
        config.minTradeCount = gates.minPrints
        config.minPrice = gates.minPrice
        config.alertThreshold = defaultAlertThreshold
        config.alertCooldownMinutes = alertCooldownMinutes
        config.vwapEventDecayMinutes = eventDecayMinutes
        config.newsHalfLifeMinutes = newsHalfLifeMinutes

        if let existing {
            config.rvolSaturation = existing.rvolSaturation
            config.rvolFloor = existing.rvolFloor
            config.gapSaturation = existing.gapSaturation
            config.vwapZSaturation = existing.vwapZSaturation
            config.maxPrice = existing.maxPrice
        }
        return config
    }
}

// MARK: - Discovery criteria

/// What the universe builder screens for when it goes looking for symbols
/// worth watching, rather than scanning a hand-typed list.
struct DiscoveryCriteria: Codable, Equatable, Sendable {
    /// Minimum ATR as a share of price. Below this the symbol cannot produce
    /// a day-trade-sized move even on a good day.
    var minATRPercent: Double = 0.035
    var minMedianDailyVolume: Double = 500_000
    var minPrice: Double = 1.00
    var maxPrice: Double = 400.00

    /// An intraday range this large counts as a "runner" day when computing
    /// runner frequency.
    var runnerThreshold: Double = 0.10
    /// Require the symbol to have had at least this many runner days recently.
    var minRunnerDays: Int = 2

    /// Cap on how many symbols the discovered universe holds. Each symbol
    /// costs memory and a slot in the per-minute scoring pass.
    var maxUniverseSize: Int = 250

    /// Include symbols that are merely coiled, even without recent big days.
    var includeCompressed: Bool = true
    var compressionCeiling: Double = 0.65

    /// How many sessions of daily bars to screen over.
    var lookbackSessions: Int = 60

    // Float filters, now that float comes from SEC filings rather than a proxy.
    /// Upper bound on float in shares. Nil means no float ceiling.
    var maxFloatShares: Double? = 150_000_000
    var minFloatShares: Double? = nil
    /// Keep symbols whose float is unknown. Unknown is not the same as large —
    /// recent listings and delinquent filers are exactly the names that run,
    /// so excluding them by default would defeat the purpose.
    var includeUnknownFloat: Bool = true

    static let `default` = DiscoveryCriteria()

    /// Deliberately loose, for finding low-priced high-beta names.
    /// Carries more halt risk, which the hazard components then penalise.
    static let aggressive = DiscoveryCriteria(
        minATRPercent: 0.06,
        minMedianDailyVolume: 250_000,
        minPrice: 0.50,
        maxPrice: 60,
        runnerThreshold: 0.15,
        minRunnerDays: 3,
        maxUniverseSize: 300,
        includeCompressed: false,
        compressionCeiling: 0.65,
        lookbackSessions: 60,
        maxFloatShares: 30_000_000,
        minFloatShares: nil,
        includeUnknownFloat: true
    )

    /// Large, liquid, tighter spreads. The scalping universe.
    static let liquid = DiscoveryCriteria(
        minATRPercent: 0.02,
        minMedianDailyVolume: 5_000_000,
        minPrice: 5,
        maxPrice: 800,
        runnerThreshold: 0.06,
        minRunnerDays: 0,
        maxUniverseSize: 150,
        includeCompressed: true,
        compressionCeiling: 0.7,
        lookbackSessions: 60,
        maxFloatShares: nil,
        minFloatShares: 30_000_000,
        includeUnknownFloat: false
    )
}
