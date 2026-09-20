import Foundation

// MARK: - Market data primitives

/// A single one-minute bar. Free-tier Alpaca builds these from IEX trades only,
/// so `volume` is a fraction of consolidated volume. Never compare it to an
/// absolute threshold — only to this symbol's own history.
struct MinuteBar: Codable, Hashable, Sendable {
    let symbol: String
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    /// Trade count in the bar. Useful as a liquidity sanity check on thin names.
    let tradeCount: Int
    /// Alpaca's own VWAP for the bar interval.
    let barVWAP: Double

    /// Typical price. Used for session VWAP accumulation rather than close,
    /// because a bar's close alone throws away where the volume actually traded.
    var typicalPrice: Double { (high + low + close) / 3.0 }

    enum CodingKeys: String, CodingKey {
        case symbol = "S", timestamp = "t", open = "o", high = "h"
        case low = "l", close = "c", volume = "v", tradeCount = "n", barVWAP = "vw"
    }
}

struct DailyBar: Codable, Hashable, Sendable {
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double

    enum CodingKeys: String, CodingKey {
        case timestamp = "t", open = "o", high = "h", low = "l", close = "c", volume = "v"
    }
}

struct NewsItem: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let headline: String
    let summary: String
    let author: String
    let createdAt: Date
    let updatedAt: Date
    let url: String?
    let symbols: [String]
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id, headline, summary, author, url, symbols, source
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    /// Coarse catalyst classification from the headline. Deliberately crude —
    /// the point is to separate "offering" (usually bearish, dilutive) from
    /// "earnings beat" (usually bullish), not to do real NLP.
    var category: Catalyst { Catalyst.classify(headline) }
}

enum Catalyst: String, Codable, CaseIterable, Sendable {
    case earnings, offering, fda, merger, guidance, analyst, halt, filing, other

    /// Signed lean: offerings and dilution generally kill upside momentum,
    /// so the scorer treats them differently from a clean beat.
    var lean: Double {
        switch self {
        case .earnings, .fda, .merger, .guidance: return 1.0
        case .analyst, .filing: return 0.5
        case .halt: return 0.7
        case .offering: return -0.6
        case .other: return 0.3
        }
    }

    static func classify(_ headline: String) -> Catalyst {
        let h = headline.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { h.contains($0) } }
        if has(["offering", "dilut", "registered direct", "atm program", "shelf"]) { return .offering }
        if has(["earnings", "q1 ", "q2 ", "q3 ", "q4 ", "eps", "beats", "misses", "revenue"]) { return .earnings }
        if has(["fda", "phase 1", "phase 2", "phase 3", "clinical", "trial results", "approval"]) { return .fda }
        if has(["acquire", "merger", "buyout", "takeover", "stake in"]) { return .merger }
        if has(["guidance", "outlook", "forecast", "raises", "lowers"]) { return .guidance }
        if has(["upgrade", "downgrade", "price target", "initiates coverage", "reiterates"]) { return .analyst }
        if has(["halt", "resumption", "circuit breaker"]) { return .halt }
        if has(["8-k", "10-q", "10-k", "s-1", "13d", "13g", "form 4"]) { return .filing }
        return .other
    }
}

/// One row of FINRA's consolidated Reg SHO daily file.
/// Off-exchange (TRF/ADF/ORF) volume only — the ratio runs high by construction,
/// so it is only meaningful as a rank across symbols on the same day.
struct ShortVolumeRecord: Codable, Hashable, Sendable {
    let date: Date
    let symbol: String
    let shortVolume: Double
    let shortExemptVolume: Double
    let totalVolume: Double

    var shortRatio: Double {
        guard totalVolume > 0 else { return 0 }
        return shortVolume / totalVolume
    }
}

// MARK: - Signals

enum VWAPEvent: String, Codable, Hashable, Sendable {
    case reclaim      // crossed from below to above, confirmed
    case loss         // crossed from above to below, confirmed
    case none

    var label: String {
        switch self {
        case .reclaim: return "Reclaimed VWAP"
        case .loss: return "Lost VWAP"
        case .none: return "No VWAP event"
        }
    }
}

enum TrendState: String, Codable, Sendable {
    case aboveVWAP, belowVWAP, atVWAP
}

/// Everything the engine knows about one symbol at one instant.
/// This is the unit that gets written to the paper log, so that every
/// alert can be audited later against what actually happened.
struct SignalSnapshot: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(symbol)-\(Int(asOf.timeIntervalSince1970))" }

    let symbol: String
    let asOf: Date

    // Price
    let last: Double
    let priorClose: Double
    let sessionOpen: Double
    let dayHigh: Double
    let dayLow: Double

    // VWAP block
    let vwap: Double
    /// Standard deviations from VWAP, using the running dispersion of
    /// today's own trade prices around VWAP. Percent distance is useless
    /// across symbols; a z-score is comparable.
    let vwapZ: Double
    let vwapEvent: VWAPEvent
    let minutesSinceVWAPEvent: Int?
    let trend: TrendState

    // Volume block
    /// Cumulative session volume / median cumulative volume at this same
    /// minute-of-day over the baseline window. 1.0 = a completely normal day.
    let rvol: Double
    let cumulativeVolume: Double
    let baselineVolumeAtMinute: Double
    let minuteOfSession: Int
    /// Volume in the most recent bar / median volume in that same bar slot.
    let barRVOL: Double

    // Gap and range
    let gapPercent: Double
    let atr14: Double
    /// Where price sits in today's range. 1.0 = at highs.
    let rangePosition: Double

    // News
    let latestNews: NewsItem?
    let newsAgeMinutes: Double?
    let newsCategory: Catalyst?

    // Short data (previous session, FINRA)
    let shortRatio: Double?
    /// 0...1 percentile of this symbol's short ratio across the scanned universe.
    let shortRatioPercentile: Double?

    // Liquidity guard
    let dollarVolume: Double
    let tradeCount: Int

    /// Gain-potential, microstructure and hazard signals.
    var extended: ExtendedSignals = ExtendedSignals()

    var changePercent: Double {
        guard priorClose > 0 else { return 0 }
        return (last / priorClose) - 1.0
    }

    var vwapDistancePercent: Double {
        guard vwap > 0 else { return 0 }
        return (last / vwap) - 1.0
    }
}

// MARK: - Scoring

enum SignalComponent: String, Codable, CaseIterable, Identifiable, Sendable {
    case relativeVolume
    case vwapEvent
    case vwapPosition
    case gap
    case news
    case shortPressure
    case rangePosition
    // Gain-potential block: is this a symbol capable of a big move at all?
    case volatilityPotential
    case rangeExpansion
    case compression
    /// Float tightness. Now sourced from real SEC filings rather than proxied.
    case floatTightness
    // Scalp block: microstructure over the last few minutes.
    case momentumBurst
    case pullbackQuality
    case acceleration
    // Hazard block: scores negative. Kept as components rather than gates so
    // a dangerous setup ranks below a clean one instead of vanishing silently.
    case extensionRisk
    case haltRisk
    /// StockTwits sentiment and message-volume surge.
    case socialMomentum
    /// SEC Form 4 cluster buying, sourced from the live EDGAR filing feed.
    case insiderCluster
    /// Geometric pivot/trendline break, computed purely from this symbol's
    /// own recent bar shape — the only component that reads chart geometry
    /// rather than momentum, volume, or fundamentals-adjacent context.
    case trendlineBreak

    var id: String { rawValue }

    /// Which profiles use this component. A scalp profile scoring an overnight
    /// gap is measuring something that stopped being relevant hours ago.
    var isScalpSignal: Bool {
        switch self {
        case .momentumBurst, .pullbackQuality, .acceleration: return true
        default: return false
        }
    }

    var isHazard: Bool {
        self == .extensionRisk || self == .haltRisk
    }

    var displayName: String {
        switch self {
        case .relativeVolume: return "Relative volume"
        case .vwapEvent: return "VWAP event"
        case .vwapPosition: return "VWAP position"
        case .gap: return "Gap from prior close"
        case .news: return "News catalyst"
        case .shortPressure: return "Short pressure"
        case .rangePosition: return "Range position"
        case .volatilityPotential: return "Move potential"
        case .rangeExpansion: return "Range expansion"
        case .compression: return "Coiled range"
        case .floatTightness: return "Float tightness"
        case .momentumBurst: return "Momentum burst"
        case .pullbackQuality: return "Pullback quality"
        case .acceleration: return "Acceleration"
        case .extensionRisk: return "Overextension"
        case .haltRisk: return "Halt proximity"
        case .socialMomentum: return "Social momentum"
        case .insiderCluster: return "Insider cluster"
        case .trendlineBreak: return "Trendline break"
        }
    }

    /// Shown in the advanced view so the weights aren't a black box.
    var explanation: String {
        switch self {
        case .relativeVolume:
            return "Today's cumulative volume against the median for this minute of the session. The single most reliable filter — a move without volume rarely continues."
        case .vwapEvent:
            return "A confirmed cross of VWAP in the last few minutes. Decays over 30 minutes; a reclaim an hour ago is history, not a signal."
        case .vwapPosition:
            return "Standard deviations from VWAP. Rewards extension without rewarding a runaway that has nothing left."
        case .gap:
            return "Overnight gap from prior close. Sets the day's candidate list before the open."
        case .news:
            return "Recency-decayed headline weight, signed by category. An offering scores negative even on huge volume."
        case .shortPressure:
            return "Yesterday's FINRA off-exchange short volume ratio, ranked across the universe. Not short interest."
        case .rangePosition:
            return "Where price sits in today's range. High means holding gains rather than fading."
        case .volatilityPotential:
            return "How often this symbol has actually made a large intraday move in the last 60 sessions, combined with its ATR as a share of price. A stand-in for float, which no free feed provides."
        case .rangeExpansion:
            return "Today's range so far against this symbol's own median full-day range. Above 1.0 before lunch means the day is already unusual."
        case .compression:
            return "Recent range against the longer-run range. A coiled symbol that starts moving on volume tends to keep moving."
        case .floatTightness:
            return "Shares available to trade, from the company's own SEC cover-page filings. A tight float amplifies every buyer — and every seller. Unknown float scores zero rather than being assumed large."
        case .momentumBurst:
            return "Consecutive one-minute bars in the same direction with volume above their own norm. The core scalp trigger."
        case .pullbackQuality:
            return "A shallow retrace toward VWAP after a push, measured in ATR. Rewards controlled pullbacks and penalises full round-trips."
        case .acceleration:
            return "Rate of change of price over the last few minutes versus the few before. Catches the second leg rather than the first."
        case .extensionRisk:
            return "Distance travelled from the open in ATR units. Scores negative — a symbol six ATRs from its open has already made its move."
        case .haltRisk:
            return "Proximity to the LULD volatility band. Scores negative, because getting halted mid-scalp is how a good entry becomes an untradeable position."
        case .socialMomentum:
            return "StockTwits trending rank and message-volume surge, weighted by tagged sentiment. A leading indicator when it shows up before volume does, a crowding hazard when it shows up after."
        case .insiderCluster:
            return "Multiple company insiders filing Form 4 within the same short window, sourced live from SEC EDGAR's own filing feed rather than a third-party summary. Two or three separate filers close together is a stronger signal than any single filing."
        case .trendlineBreak:
            return "A fresh break of a trendline fit through this symbol's own recent pivot highs or lows, computed geometrically from its minute bars — the one component that reads chart shape rather than volume, momentum, or float."
        }
    }

    /// Defaults are the day-trade profile. `ScanProfile` overrides these
    /// wholesale for scalp and pre-market work.
    var defaultWeight: Double {
        switch self {
        case .relativeVolume: return 0.22
        case .vwapEvent: return 0.15
        case .vwapPosition: return 0.08
        case .gap: return 0.09
        case .news: return 0.12
        case .shortPressure: return 0.04
        case .rangePosition: return 0.03
        case .volatilityPotential: return 0.10
        case .rangeExpansion: return 0.08
        case .compression: return 0.04
        case .floatTightness: return 0.09
        case .socialMomentum: return 0.05
        case .insiderCluster: return 0.03
        case .trendlineBreak: return 0.05
        case .momentumBurst: return 0.0
        case .pullbackQuality: return 0.0
        case .acceleration: return 0.0
        case .extensionRisk: return 0.03
        case .haltRisk: return 0.02
        }
    }
}

// MARK: - Extended signals

/// Signals beyond the original volume/VWAP/news core.
///
/// Split into its own struct rather than flattened into `SignalSnapshot` so
/// the derivation is obvious: the volatility block comes from daily bars and
/// changes once a day, the microstructure block is recomputed every minute.
struct ExtendedSignals: Codable, Hashable, Sendable {
    // Daily-derived. Answers "can this symbol move at all", independent of today.
    var atrPercent: Double = 0
    /// Share of the last 60 sessions where the intraday range exceeded the
    /// runner threshold. The empirical substitute for float data.
    var runnerFrequency: Double = 0
    var medianDailyRangePercent: Double = 0
    /// Last 5 sessions' range over the last 20 sessions' range.
    /// Below ~0.6 means the symbol has been coiling.
    var compressionRatio: Double = 1
    var averageDailyVolume: Double = 0

    // Today
    /// Today's range so far divided by the median full-day range.
    var rangeExpansion: Double = 0
    var premarketVolumeRatio: Double = 0
    /// Signed strength of the first 15 minutes, in ATR units.
    var openingDriveATR: Double = 0

    // Microstructure, recomputed each minute from the recent bar window.
    var consecutiveDirectionalBars: Int = 0
    var burstScore: Double = 0
    var pullbackDepthATR: Double = 0
    var pullbackQuality: Double = 0
    /// Percent move per minute over the last 3 bars minus the 3 before that.
    var acceleration: Double = 0
    /// High-minus-low of the last bar as a share of price. A crude spread and
    /// slippage proxy — wide bars mean the fill you model is not the fill you get.
    var barSpreadPercent: Double = 0

    // Float, from SEC filings rather than estimated.
    var floatShares: Double?
    var sharesOutstanding: Double?
    var floatCategory: SECFloatClient.FloatCategory?
    /// Days since the filing the float figure came from. Quarterly at best,
    /// and blind to any offering priced since.
    var floatAgeDays: Int?
    var floatIsStale: Bool = false
    /// Today's cumulative volume divided by the float. Above 1.0 means the
    /// entire tradeable supply has changed hands today, which is the condition
    /// under which small floats go vertical.
    var floatRotation: Double?

    // Social, from StockTwits' public endpoints.
    var socialSentimentScore: Double?
    var socialTaggedFraction: Double = 0
    var socialTrendingRank: Int?
    var socialMessageSurge: Double?
    /// StockTwits' own `watchlist_count` on the trending endpoint — how many
    /// accounts have this symbol on a watchlist, a slower-moving crowd-size
    /// signal distinct from message volume. A symbol gaining watchers before
    /// its post volume spikes is showing up on more screens before the
    /// crowd starts talking, which is the more useful order for a leading
    /// indicator to arrive in.
    var socialWatchCount: Int?

    /// Geometric pivot/trendline break score from `PatternDetector`, 0...1,
    /// already normalized — computed from this symbol's own recent minute
    /// bars, not derived from any other signal in this struct.
    var patternBreakoutScore: Double = 0
    var patternBreakoutNote: String?

    // Insider activity, from the live EDGAR filing feed.
    var insiderClusterFilers: Int = 0
    var insiderClusterMinutesAgo: Int?

    /// A fresh 8-K on this symbol, distinct from any wire headline about it.
    /// The filing itself is the primary source; a news item covering it is a
    /// republication, sometimes seconds behind and sometimes stale by hours.
    var filedCatalystMinutesAgo: Int?
    var filedCatalystForm: String?

    // Halts, from the exchange feed rather than inferred.
    var isHalted: Bool = false
    var haltCode: String?
    var minutesSinceResume: Int?
    var isFreshTradeableResume: Bool = false
    var haltsToday: Int = 0

    // Hazard
    /// Move from the session open in ATR units.
    var extensionATR: Double = 0
    /// 0...1, where 1 means price is sitting on the LULD band.
    var luldProximity: Double = 0
    var isLikelyHaltable: Bool = false
}

struct ScoreBreakdown: Codable, Hashable, Sendable {
    /// Normalized 0...1 value per component before weighting.
    var normalized: [SignalComponent: Double] = [:]
    /// normalized × weight, i.e. the actual points contributed.
    var contributions: [SignalComponent: Double] = [:]
    var total: Double = 0

    var sortedContributions: [(SignalComponent, Double)] {
        contributions.sorted { $0.value > $1.value }
    }

    /// The two or three components doing the real work, for the plain-language line.
    func topDrivers(limit: Int = 3, floor: Double = 0.03) -> [SignalComponent] {
        sortedContributions.filter { $0.1 >= floor }.prefix(limit).map(\.0)
    }
}

enum SetupState: String, Codable, CaseIterable, Sendable {
    case watch = "Watch"
    case triggerForming = "Trigger forming"
    case ready = "Ready"
    case invalidated = "Invalidated"
    case avoid = "Avoid"

    var systemImage: String {
        switch self {
        case .watch: return "eye"
        case .triggerForming: return "scope"
        case .ready: return "bolt.fill"
        case .invalidated: return "xmark.circle"
        case .avoid: return "exclamationmark.triangle.fill"
        }
    }
}

/// A scored, ranked candidate. What both interfaces render.
struct Candidate: Identifiable, Hashable, Sendable {
    var id: String { snapshot.symbol }
    let snapshot: SignalSnapshot
    let breakdown: ScoreBreakdown

    var symbol: String { snapshot.symbol }
    var score: Double { breakdown.total }

    /// Separates ranking from execution readiness. A high score can still be
    /// blocked by a halt, missing data, or a failed trigger.
    var setupState: SetupState {
        if snapshot.extended.isHalted { return .avoid }
        if snapshot.extended.isLikelyHaltable || hasHazard { return .avoid }
        if score < 0.45 { return .watch }
        if snapshot.vwapEvent == .none || snapshot.rvol < 1.5 { return .triggerForming }
        if score >= 0.75 { return .ready }
        return .triggerForming
    }

    /// One sentence a human can act on, built from whatever is actually driving
    /// the score. Deliberately concrete — no "strong setup detected".
    var plainReason: String {
        var parts: [String] = []
        for component in breakdown.topDrivers() {
            switch component {
            case .relativeVolume:
                parts.append(String(format: "%.1f× normal volume", snapshot.rvol))
            case .vwapEvent:
                if snapshot.vwapEvent != .none {
                    let mins = snapshot.minutesSinceVWAPEvent ?? 0
                    let verb = snapshot.vwapEvent == .reclaim ? "reclaimed" : "lost"
                    parts.append(mins <= 1 ? "just \(verb) VWAP" : "\(verb) VWAP \(mins)m ago")
                }
            case .vwapPosition:
                let side = snapshot.vwapZ >= 0 ? "above" : "below"
                parts.append(String(format: "%.1fσ %@ VWAP", abs(snapshot.vwapZ), side))
            case .gap:
                parts.append(String(format: "gapped %+.1f%%", snapshot.gapPercent * 100))
            case .news:
                if let age = snapshot.newsAgeMinutes {
                    let cat = snapshot.newsCategory?.rawValue ?? "news"
                    parts.append("\(cat) headline \(Int(age))m ago")
                }
            case .shortPressure:
                if let pct = snapshot.shortRatioPercentile {
                    parts.append("short volume in top \(Int((1 - pct) * 100))%")
                }
            case .rangePosition:
                if snapshot.rangePosition > 0.8 { parts.append("holding day highs") }
                else if snapshot.rangePosition < 0.2 { parts.append("pinned at day lows") }
            case .volatilityPotential:
                let frequency = Int(snapshot.extended.runnerFrequency * 100)
                if frequency > 0 { parts.append("big move on \(frequency)% of recent days") }
            case .rangeExpansion:
                parts.append(String(format: "range already %.0f%% of a full day", snapshot.extended.rangeExpansion * 100))
            case .compression:
                parts.append("breaking out of a tight range")
            case .floatTightness:
                if let category = snapshot.extended.floatCategory {
                    if let rotation = snapshot.extended.floatRotation, rotation >= 0.5 {
                        parts.append(String(format: "%@ (%@), %.1f× float traded",
                                            category.displayName.lowercased(),
                                            category.shortLabel, rotation))
                    } else {
                        parts.append("\(category.displayName.lowercased()) (\(category.shortLabel))")
                    }
                }
            case .momentumBurst:
                let bars = snapshot.extended.consecutiveDirectionalBars
                if bars > 0 { parts.append("\(bars) bars running on volume") }
            case .pullbackQuality:
                parts.append(String(format: "%.1f ATR pullback holding", snapshot.extended.pullbackDepthATR))
            case .acceleration:
                parts.append("move is speeding up")
            case .socialMomentum:
                if let rank = snapshot.extended.socialTrendingRank {
                    parts.append("#\(rank + 1) trending on StockTwits")
                } else if let surge = snapshot.extended.socialMessageSurge, surge >= 2 {
                    parts.append(String(format: "%.1f× normal StockTwits chatter", surge))
                }
            case .insiderCluster:
                if snapshot.extended.insiderClusterFilers >= 2 {
                    parts.append("\(snapshot.extended.insiderClusterFilers) insiders filed today")
                }
            case .trendlineBreak:
                if let note = snapshot.extended.patternBreakoutNote {
                    parts.append(note)
                }
            case .extensionRisk, .haltRisk:
                break   // Hazards are surfaced separately, not buried in the reason.
            }
        }
        if parts.isEmpty { return "No component above threshold" }
        return parts.joined(separator: ", ")
    }

    /// Hazards get their own line and their own colour. Burying "this is six
    /// ATRs from the open and near a halt band" inside a list of positives is
    /// how a scanner talks someone into a bad entry.
    var hazardNote: String? {
        var warnings: [String] = []
        let extended = snapshot.extended
        if extended.extensionATR >= 3.5 {
            warnings.append(String(format: "%.1f ATR from the open", extended.extensionATR))
        }
        if extended.luldProximity >= 0.6 {
            warnings.append("near the halt band")
        }
        if extended.barSpreadPercent >= 0.015 {
            warnings.append(String(format: "wide bars (%.1f%%)", extended.barSpreadPercent * 100))
        }
        if snapshot.newsCategory == .offering {
            warnings.append("offering headline")
        }
        if extended.isHalted {
            warnings.append("HALTED — \(extended.haltCode ?? "no code")")
        }
        if extended.floatCategory?.carriesElevatedRisk == true {
            warnings.append("tight float, halts easily")
        }
        if extended.floatIsStale, extended.floatShares != nil {
            warnings.append("float figure \(extended.floatAgeDays ?? 0)d old")
        }
        if extended.haltsToday >= 2 {
            warnings.append("halted \(extended.haltsToday)× today")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    var hasHazard: Bool { hazardNote != nil }
}

// MARK: - Engine status

enum StreamStatus: String, Sendable {
    case idle, connecting, authenticating, subscribed, reconnecting, failed

    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating"
        case .subscribed: return "Live"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Connection failed"
        }
    }
}

struct EngineDiagnostics: Sendable {
    var barStreamStatus: StreamStatus = .idle
    var newsStreamStatus: StreamStatus = .idle
    var subscribedSymbols: Int = 0
    var barsReceived: Int = 0
    var barsPerMinute: Double = 0
    var lastBarAt: Date?
    var symbolsWithBaseline: Int = 0
    var baselineCoverage: Double = 0
    var shortVolumeFileDate: Date?
    var lastScoredAt: Date?
    var scoringDurationMs: Double = 0
    var droppedBars: Int = 0
    var lastError: String?
}
