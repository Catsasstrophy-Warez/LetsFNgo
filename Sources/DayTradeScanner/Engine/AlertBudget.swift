import Foundation

/// Rations alerts against attention rather than against each symbol separately.
///
/// The insight is borrowed from the most-used retail momentum scanners, whose
/// high-of-day alerts deliberately do *not* fire every time a stock prints a
/// new high: a scanner built that way could produce thousands of alerts in the
/// first few minutes of the session, washing out the actionable ideas among
/// them.
///
/// The scanner's previous design only had a per-symbol cooldown, which bounds
/// repetition but not volume — forty different symbols can each alert once and
/// still bury you. This adds the missing constraint: a fixed number of slots
/// per rolling window, awarded to the highest scores, with a short holding
/// delay so a marginally better candidate arriving two seconds later isn't
/// locked out by a worse one that happened to be first.
struct AlertBudget: Sendable {

    struct Config: Codable, Equatable, Sendable {
        /// Slots available per window.
        var slotsPerWindow: Int = 4
        var windowMinutes: Double = 15
        /// Slots reserved for the open, when everything happens at once.
        var openingSlotsPerWindow: Int = 6
        /// Minutes from the open that count as the opening period.
        var openingWindowMinutes: Int = 30

        /// How long a candidate is held before its alert fires, so the window
        /// can be filled by the best of a burst rather than the first of one.
        var holdingSeconds: Double = 4

        /// A candidate this much better than one already alerted may preempt
        /// the budget entirely. Reserved for the genuinely exceptional.
        var preemptionMargin: Double = 0.18
        var allowPreemption: Bool = true

        /// Never spend a slot below this, regardless of available budget.
        var absoluteFloor: Double = 0.5

        static let `default` = Config()

        /// Every alert that clears the score threshold fires. Restores the
        /// original behaviour for anyone who wants it.
        static let unlimited = Config(
            slotsPerWindow: 999,
            windowMinutes: 1,
            openingSlotsPerWindow: 999,
            openingWindowMinutes: 30,
            holdingSeconds: 0,
            preemptionMargin: 1,
            allowPreemption: false,
            absoluteFloor: 0
        )
    }

    struct Grant: Sendable {
        let candidate: Candidate
        let wasPreemption: Bool
        let remainingSlots: Int
    }

    struct Suppression: Sendable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let score: Double
        let reason: Reason
        let at: Date

        enum Reason: String, Sendable {
            case budgetExhausted = "Budget full"
            case cooldown = "Recently alerted"
            case belowFloor = "Below floor"
            case outranked = "Outranked in window"
        }
    }
}

/// Stateful budget keeper. Held by the engine on the main actor.
@MainActor
final class AlertBudgetKeeper {
    private(set) var config: AlertBudget.Config
    private var grantTimestamps: [(date: Date, score: Double, symbol: String)] = []
    private var lastAlertBySymbol: [String: Date] = [:]
    private var holding: [String: (candidate: Candidate, since: Date)] = [:]

    private(set) var recentSuppressions: [AlertBudget.Suppression] = []

    private let clock: () -> Date

    init(config: AlertBudget.Config = .default, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.config = config
    }

    func update(config: AlertBudget.Config) {
        self.config = config
    }

    /// Slots available right now, accounting for the wider opening allowance.
    var currentCapacity: Int {
        let minute = MarketClock.minuteOfSession(clock()) ?? 999
        let isOpening = minute >= 0 && minute < config.openingWindowMinutes
        return isOpening ? config.openingSlotsPerWindow : config.slotsPerWindow
    }

    var slotsUsed: Int {
        prune()
        return grantTimestamps.count
    }

    var slotsRemaining: Int { max(0, currentCapacity - slotsUsed) }

    /// Minutes until the oldest grant ages out and a slot frees up.
    var minutesUntilNextSlot: Int? {
        prune()
        guard slotsRemaining == 0, let oldest = grantTimestamps.map(\.date).min() else { return nil }
        let expiry = oldest.addingTimeInterval(config.windowMinutes * 60)
        return max(0, Int(expiry.timeIntervalSince(clock()) / 60) + 1)
    }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-config.windowMinutes * 60)
        grantTimestamps.removeAll { $0.date < cutoff }
        recentSuppressions.removeAll { $0.at < cutoff }
    }

    /// Considers a scored, ranked list and returns which alerts should fire.
    ///
    /// Candidates are held briefly before granting so a burst at the top of the
    /// minute resolves to its best members rather than its earliest.
    func evaluate(
        candidates: [Candidate],
        threshold: Double,
        cooldownMinutes: Double
    ) -> [AlertBudget.Grant] {
        prune()
        let now = clock()
        var grants: [AlertBudget.Grant] = []
        var suppressions: [AlertBudget.Suppression] = []

        let eligible = candidates
            .filter { $0.score >= threshold && $0.score >= config.absoluteFloor }
            .sorted { $0.score > $1.score }

        // 1. Refresh the holding pen. A candidate that stays qualified keeps
        //    its original arrival time, so holding is a delay, not a reset.
        var stillQualified: Set<String> = []
        for candidate in eligible {
            stillQualified.insert(candidate.symbol)
            if let existing = holding[candidate.symbol] {
                holding[candidate.symbol] = (candidate, existing.since)
            } else {
                holding[candidate.symbol] = (candidate, now)
            }
        }
        // Drop anything that stopped qualifying while held — it faded before
        // it ever earned the alert, which is exactly what holding is for.
        holding = holding.filter { stillQualified.contains($0.key) }

        // 2. Anything past its holding period is ready.
        let ready = holding.values
            .filter { now.timeIntervalSince($0.since) >= config.holdingSeconds }
            .map(\.candidate)
            .sorted { $0.score > $1.score }

        for candidate in ready {
            // Per-symbol cooldown still applies on top of the budget.
            if let last = lastAlertBySymbol[candidate.symbol],
               now.timeIntervalSince(last) < cooldownMinutes * 60 {
                suppressions.append(.init(symbol: candidate.symbol, score: candidate.score, reason: .cooldown, at: now))
                continue
            }

            if slotsRemaining > 0 {
                grant(candidate, preemption: false, at: now)
                grants.append(.init(candidate: candidate, wasPreemption: false, remainingSlots: slotsRemaining))
                continue
            }

            // 3. Budget is spent. A candidate clearly better than the weakest
            //    thing that consumed a slot can take it.
            if config.allowPreemption,
               let weakest = grantTimestamps.min(by: { $0.score < $1.score }),
               candidate.score - weakest.score >= config.preemptionMargin {
                grantTimestamps.removeAll { $0.symbol == weakest.symbol && $0.score == weakest.score }
                grant(candidate, preemption: true, at: now)
                grants.append(.init(candidate: candidate, wasPreemption: true, remainingSlots: slotsRemaining))
                continue
            }

            suppressions.append(.init(symbol: candidate.symbol, score: candidate.score, reason: .budgetExhausted, at: now))
        }

        recentSuppressions.append(contentsOf: suppressions)
        if recentSuppressions.count > 60 { recentSuppressions.removeFirst(recentSuppressions.count - 60) }

        return grants
    }

    private func grant(_ candidate: Candidate, preemption: Bool, at date: Date) {
        grantTimestamps.append((date: date, score: candidate.score, symbol: candidate.symbol))
        lastAlertBySymbol[candidate.symbol] = date
        holding.removeValue(forKey: candidate.symbol)
    }

    func reset() {
        grantTimestamps.removeAll()
        lastAlertBySymbol.removeAll()
        holding.removeAll()
        recentSuppressions.removeAll()
    }

    /// What the budget suppressed, for the advanced diagnostics panel.
    /// Suppressed alerts are information — a window that is constantly full
    /// means the threshold is set too low for the budget.
    var suppressionSummary: (count: Int, highestScore: Double?) {
        (recentSuppressions.count, recentSuppressions.map(\.score).max())
    }
}
