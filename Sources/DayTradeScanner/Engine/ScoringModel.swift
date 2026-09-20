import Foundation

/// Turns a snapshot into a score, and — just as importantly — into a record of
/// how that score was reached.
///
/// Two design rules here:
/// 1. Every component normalizes to 0...1 before weighting, so a weight slider
///    means the same thing regardless of which component it belongs to.
/// 2. The breakdown is kept, not discarded. A number you can't decompose is a
///    number you can't debug, and the paper log stores it so past alerts can
///    be re-examined against outcomes.
struct ScoringModel: Sendable {
    let config: ScoringConfig
    /// Set by the halt-resume profile, which needs halted symbols in the list
    /// so it can watch them for the reopen.
    var allowHalted: Bool = false
    /// Optional recipe overlay, applied after the profile's own gates.
    var recipe: ScanRecipe?
    /// Symbols that have just reopened from a tradeable halt code.
    var freshResumeSymbols: Set<String> = []

    // MARK: - Gates

    enum Rejection: String, Sendable {
        case price = "Outside price range"
        case dollarVolume = "Too illiquid"
        case tradeCount = "Too few prints"
        case relativeVolume = "Volume is normal"
        case flat = "Barely moving"
        case noBaseline = "No volume baseline yet"
        case halted = "Currently halted"
        case recipeMismatch = "Outside recipe"

        var detail: String {
            switch self {
            case .price: return "Price is outside the configured range."
            case .dollarVolume: return "Not enough dollar volume to get filled cleanly."
            case .tradeCount: return "Too few prints in the last bar for the data to be meaningful."
            case .relativeVolume: return "Volume is running near its normal pace."
            case .flat: return "Price hasn't moved enough from the prior close."
            case .noBaseline: return "No volume history built for this symbol yet."
            case .halted: return "Trading is halted. No order will execute anywhere until it resumes."
            case .recipeMismatch: return "Doesn't match the active scan recipe's conditions."
            }
        }
    }

    /// Hard filters run before scoring. A high score on a symbol you can't
    /// trade is worse than no result, because it costs attention during the
    /// exact minutes attention is scarcest.
    func gate(_ snapshot: SignalSnapshot) -> Rejection? {
        // A halted symbol is removed outright rather than merely penalised.
        // Ranking something you provably cannot trade wastes the scarcest
        // resource in the session, which is attention. The halt profile is the
        // one exception, since its entire purpose is the reopen.
        if snapshot.extended.isHalted, !allowHalted { return .halted }
        if snapshot.baselineVolumeAtMinute <= 0 { return .noBaseline }
        if snapshot.last < config.minPrice || snapshot.last > config.maxPrice { return .price }
        if snapshot.dollarVolume < config.minDollarVolume { return .dollarVolume }
        if snapshot.tradeCount < config.minTradeCount { return .tradeCount }
        if snapshot.rvol < config.minRVOL { return .relativeVolume }
        if abs(snapshot.changePercent) < config.minAbsChangePercent { return .flat }
        return nil
    }

    // MARK: - Component normalization

    /// Log-scaled so the difference between 1× and 2× volume matters more than
    /// the difference between 8× and 9×. Linear scaling makes one halted
    /// runaway dominate the entire list.
    internal func normalizeRVOL(_ rvol: Double) -> Double {
        guard rvol > config.rvolFloor else { return 0 }
        let ceiling = max(config.rvolSaturation, config.rvolFloor + 0.1)
        let value = log(rvol / config.rvolFloor) / log(ceiling / config.rvolFloor)
        return clamp(value)
    }

    /// A confirmed cross, decayed linearly. Thirty minutes after a reclaim the
    /// signal is spent — anyone acting on it has already acted.
    internal func normalizeVWAPEvent(_ snapshot: SignalSnapshot) -> Double {
        guard snapshot.vwapEvent != .none,
              let minutes = snapshot.minutesSinceVWAPEvent else { return 0 }
        let decay = max(0, 1 - (Double(minutes) / config.vwapEventDecayMinutes))
        // A loss is a real signal too — it's the short setup — so it scores on
        // magnitude, not direction. Direction lives in the snapshot for the UI.
        return clamp(decay)
    }

    /// Rewards extension from VWAP but rolls off past saturation, because a
    /// symbol 5σ from VWAP is usually late rather than strong.
    internal func normalizeVWAPPosition(_ z: Double) -> Double {
        let magnitude = abs(z)
        let saturation = max(config.vwapZSaturation, 0.1)
        if magnitude <= saturation {
            return clamp(magnitude / saturation)
        }
        // Decay above saturation rather than clipping flat, so an overextended
        // name ranks below one sitting in the sweet spot.
        let overshoot = (magnitude - saturation) / saturation
        return clamp(1.0 - min(overshoot * 0.4, 0.6))
    }

    internal func normalizeGap(_ gap: Double) -> Double {
        clamp(abs(gap) / max(config.gapSaturation, 0.001))
    }

    /// Exponential recency decay, signed by catalyst type. An offering headline
    /// actively subtracts, which is the behaviour that stops the scanner from
    /// screaming about a dilutive collapse as if it were a breakout.
    private func normalizeNews(_ snapshot: SignalSnapshot) -> Double {
        guard let age = snapshot.newsAgeMinutes, age >= 0 else { return 0 }
        let halfLife = max(config.newsHalfLifeMinutes, 1)
        let recency = pow(0.5, age / halfLife)
        let lean = snapshot.newsCategory?.lean ?? 0.3
        // Negative lean pulls the component below zero; the clamp floor is -1
        // so a fresh offering can meaningfully suppress a score.
        return max(-1.0, min(recency * lean, 1.0))
    }

    private func normalizeShortPressure(_ percentile: Double?) -> Double {
        guard let percentile else { return 0 }
        // Only the top of the distribution is interesting. A symbol at the
        // 50th percentile carries no information.
        guard percentile > 0.7 else { return 0 }
        return clamp((percentile - 0.7) / 0.3)
    }

    /// Rewards conviction at either extreme of the day's range. Mid-range is
    /// chop, and chop is where day trades go to die.
    internal func normalizeRangePosition(_ position: Double) -> Double {
        clamp(abs(position - 0.5) * 2)
    }

    // MARK: - Gain potential

    /// Straight through from the volatility profile, which already blends
    /// runner frequency, ATR% and upside range into a 0...1 rating.
    private func normalizeVolatilityPotential(_ extended: ExtendedSignals) -> Double {
        let runnerTerm = min(extended.runnerFrequency / 0.15, 1.0) * 0.6
        let atrTerm = min(extended.atrPercent / 0.10, 1.0) * 0.4
        return clamp(runnerTerm + atrTerm)
    }

    /// Today's range against a normal full day for this symbol, scaled by how
    /// far into the session we are. A full day's range by 10:15 is remarkable;
    /// the same range at 15:45 is ordinary.
    private func normalizeRangeExpansion(_ snapshot: SignalSnapshot) -> Double {
        let expansion = snapshot.extended.rangeExpansion
        guard expansion > 0 else { return 0 }
        let sessionFraction = max(Double(snapshot.minuteOfSession) / 390.0, 0.05)
        // Expected range grows roughly with the square root of elapsed time.
        let expected = sqrt(sessionFraction)
        return clamp((expansion / max(expected, 0.05)) / 2.0)
    }

    /// A coiled symbol scores only once it is actually moving. Compression on
    /// its own is a screening criterion, not a trade signal — plenty of
    /// symbols stay coiled for months.
    private func normalizeCompression(_ snapshot: SignalSnapshot) -> Double {
        let ratio = snapshot.extended.compressionRatio
        guard ratio < 0.8, snapshot.rvol > 1.5 else { return 0 }
        return clamp((0.8 - ratio) / 0.4)
    }

    /// Float tightness, from filed SEC figures.
    ///
    /// Unknown float scores zero rather than being assumed large or small.
    /// Guessing in either direction is worse than abstaining: assume large and
    /// you drop every recent listing, assume small and you promote every
    /// delinquent filer.
    ///
    /// Float rotation — today's volume divided by the float — is the amplifier.
    /// Once the entire tradeable supply has changed hands in a session, the
    /// remaining supply is whatever holders will part with, which is the
    /// mechanism behind a vertical move.
    private func normalizeFloatTightness(_ extended: ExtendedSignals) -> Double {
        guard let category = extended.floatCategory else { return 0 }
        var score = category.tightnessScore

        if let rotation = extended.floatRotation {
            // Rotation saturates at 1.0× — beyond that the signal is already
            // fully expressed and the extension hazard takes over.
            let rotationBoost = min(rotation, 1.0) * 0.35
            score = min(score + rotationBoost, 1.0)
        }

        // A float figure from two quarters ago on a company that has since
        // been diluting is worse than no figure. Discount rather than discard.
        if extended.floatIsStale { score *= 0.7 }

        return clamp(score)
    }

    // MARK: - Social and insider

    /// Trending rank matters more than raw sentiment score — a symbol at #1
    /// with mixed sentiment is more informative than a symbol at #40 with
    /// perfect sentiment built on three messages. Message-count surge is a
    /// secondary boost for chatter that hasn't cracked the trending list yet.
    private func normalizeSocialMomentum(_ extended: ExtendedSignals) -> Double {
        var score = 0.0
        if let rank = extended.socialTrendingRank {
            // Top of the list saturates fast; trending at all is most of the signal.
            score += clamp(1.0 - (Double(rank) / 30.0)) * 0.55
        }
        if let surge = extended.socialMessageSurge, surge > 1.5 {
            score += clamp((surge - 1.5) / 3.5) * 0.20
        }
        // Watch-count growth is the slower of the two crowd-size signals —
        // it moves with accounts adding a watchlist entry, not posting — so
        // it's weighted below message surge but still counted, since a
        // symbol accumulating watchers ahead of any chatter is an earlier
        // read than either rank or message volume alone.
        if let watchers = extended.socialWatchCount, watchers > 0 {
            // Saturates around 5,000 watchers, which is already a large
            // crowd for anything outside mega-cap names.
            score += clamp(Double(watchers) / 5000.0) * 0.15
        }
        // A sentiment score built on too few tagged messages is noise; only
        // let it nudge the score once there's enough tagged volume to trust.
        if let sentiment = extended.socialSentimentScore, extended.socialTaggedFraction > 0.3 {
            score += clamp(abs(sentiment)) * 0.10
        }
        return clamp(score)
    }

    /// Two filers is worth noting; three or more is the threshold most
    /// cluster-buy research treats as meaningful rather than coincidental.
    /// Recency matters — a cluster from hours ago has already been priced in
    /// by anyone else watching the same free feed.
    private func normalizeInsiderCluster(_ extended: ExtendedSignals) -> Double {
        guard extended.insiderClusterFilers >= 2 else { return 0 }
        let filerTerm = clamp(Double(extended.insiderClusterFilers - 1) / 4.0)
        let recencyTerm: Double
        if let minutes = extended.insiderClusterMinutesAgo {
            recencyTerm = clamp(1.0 - (Double(minutes) / 240.0))
        } else {
            recencyTerm = 0.5
        }
        return clamp((filerTerm * 0.6) + (recencyTerm * 0.4))
    }

    /// Already normalized by `PatternDetector` — clamp defensively rather
    /// than trust it blindly, the same posture every other normalize
    /// function here takes toward its own inputs.
    private func normalizeTrendlineBreak(_ extended: ExtendedSignals) -> Double {
        clamp(extended.patternBreakoutScore)
    }

    // MARK: - Scalp

    private func normalizeMomentumBurst(_ extended: ExtendedSignals) -> Double {
        clamp(extended.burstScore)
    }

    private func normalizePullback(_ extended: ExtendedSignals) -> Double {
        clamp(extended.pullbackQuality)
    }

    /// Acceleration is tiny in absolute terms — a tenth of a percent per
    /// minute is a fast move — so it saturates aggressively.
    private func normalizeAcceleration(_ extended: ExtendedSignals) -> Double {
        clamp(abs(extended.acceleration) / 0.0015)
    }

    // MARK: - Hazards

    /// Returns a negative value. Nothing is deducted below 2.5 ATR from the
    /// open — that is a normal trending day, not overextension.
    private func normalizeExtensionRisk(_ extended: ExtendedSignals) -> Double {
        let distance = extended.extensionATR
        guard distance > 2.5 else { return 0 }
        return -clamp((distance - 2.5) / 3.5)
    }

    /// Also negative, and now grounded in exchange halt data rather than an
    /// estimated band.
    ///
    /// The severity ladder matters. Being halted right now is absolute: no
    /// order executes anywhere in the US while a symbol is paused, so a
    /// position taken thirty seconds earlier cannot be exited. Having halted
    /// repeatedly today is the next worst thing, because it will very likely
    /// happen again. Estimated band proximity is the weakest of the three and
    /// only applies when the feed has told us nothing.
    private func normalizeHaltRisk(_ extended: ExtendedSignals) -> Double {
        if extended.isHalted { return -1.0 }

        // Each additional halt today compounds. Three halts is a symbol that
        // cannot be traded with any stop discipline at all.
        if extended.haltsToday >= 1 {
            return -clamp(Double(extended.haltsToday) / 3.0, min: 0.25, max: 1.0)
        }

        // A tight float sitting far from its open is the classic pre-halt
        // shape, even before the band is reached.
        if extended.floatCategory?.carriesElevatedRisk == true, extended.extensionATR > 4 {
            return -0.4
        }

        guard extended.luldProximity > 0.5 else { return 0 }
        return -clamp((extended.luldProximity - 0.5) / 0.5)
    }

    private func clamp(_ value: Double, min lower: Double = 0, max upper: Double = 1) -> Double {
        Swift.max(lower, Swift.min(value, upper))
    }

    // MARK: - Scoring

    func score(_ snapshot: SignalSnapshot) -> ScoreBreakdown {
        var breakdown = ScoreBreakdown()

        let normalized: [SignalComponent: Double] = [
            .relativeVolume: normalizeRVOL(snapshot.rvol),
            .vwapEvent: normalizeVWAPEvent(snapshot),
            .vwapPosition: normalizeVWAPPosition(snapshot.vwapZ),
            .gap: normalizeGap(snapshot.gapPercent),
            .news: normalizeNews(snapshot),
            .shortPressure: normalizeShortPressure(snapshot.shortRatioPercentile),
            .rangePosition: normalizeRangePosition(snapshot.rangePosition),
            .volatilityPotential: normalizeVolatilityPotential(snapshot.extended),
            .rangeExpansion: normalizeRangeExpansion(snapshot),
            .compression: normalizeCompression(snapshot),
            .floatTightness: normalizeFloatTightness(snapshot.extended),
            .socialMomentum: normalizeSocialMomentum(snapshot.extended),
            .insiderCluster: normalizeInsiderCluster(snapshot.extended),
            .trendlineBreak: normalizeTrendlineBreak(snapshot.extended),
            .momentumBurst: normalizeMomentumBurst(snapshot.extended),
            .pullbackQuality: normalizePullback(snapshot.extended),
            .acceleration: normalizeAcceleration(snapshot.extended),
            .extensionRisk: normalizeExtensionRisk(snapshot.extended),
            .haltRisk: normalizeHaltRisk(snapshot.extended)
        ]

        var total = 0.0
        for (component, value) in normalized {
            let contribution = value * config.normalizedWeight(component)
            breakdown.normalized[component] = value
            breakdown.contributions[component] = contribution
            total += contribution
        }

        breakdown.total = clamp(total)
        return breakdown
    }

    /// Scores a whole universe and returns the survivors, ranked.
    /// Rejections are returned too — advanced mode shows them, because
    /// "why isn't my symbol on the list" is the question you'll ask most.
    func rank(_ snapshots: [SignalSnapshot]) -> (candidates: [Candidate], rejected: [(String, Rejection)]) {
        var candidates: [Candidate] = []
        var rejected: [(String, Rejection)] = []

        for snapshot in snapshots {
            if let rejection = gate(snapshot) {
                rejected.append((snapshot.symbol, rejection))
                continue
            }
            if let recipe,
               !recipe.admits(snapshot, isFreshResume: freshResumeSymbols.contains(snapshot.symbol)) {
                rejected.append((snapshot.symbol, .recipeMismatch))
                continue
            }
            candidates.append(Candidate(snapshot: snapshot, breakdown: score(snapshot)))
        }

        candidates.sort { $0.score > $1.score }
        return (candidates, rejected)
    }
}
