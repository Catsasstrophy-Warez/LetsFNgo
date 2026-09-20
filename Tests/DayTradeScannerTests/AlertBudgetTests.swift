import XCTest
import Foundation
@testable import DayTradeScanner

@MainActor
final class AlertBudgetTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a candidate with a controllable score. `SignalSnapshot` is
    /// built through the same fields exercised in `ScoringModelTests`; the
    /// only thing this test cares about is `Candidate.score` and `.symbol`.
    private func makeCandidate(symbol: String, score: Double) -> Candidate {
        let snapshot = SignalSnapshot(
            symbol: symbol,
            asOf: referenceDate,
            last: 10.0,
            priorClose: 9.7,
            sessionOpen: 9.7,
            dayHigh: 10.5,
            dayLow: 9.5,
            vwap: 9.9,
            vwapZ: 1.0,
            vwapEvent: .none,
            minutesSinceVWAPEvent: nil,
            trend: .aboveVWAP,
            rvol: 3.0,
            cumulativeVolume: 300_000,
            baselineVolumeAtMinute: 100_000,
            minuteOfSession: 60,
            barRVOL: 2.0,
            gapPercent: 0.0,
            atr14: 0.5,
            rangePosition: 0.5,
            latestNews: nil,
            newsAgeMinutes: nil,
            newsCategory: nil,
            shortRatio: nil,
            shortRatioPercentile: nil,
            dollarVolume: 500_000,
            tradeCount: 50
        )
        var breakdown = ScoreBreakdown()
        breakdown.total = score
        return Candidate(snapshot: snapshot, breakdown: breakdown)
    }

    /// A fake clock lets the tests advance time deterministically instead of
    /// sleeping the thread. `AlertBudgetKeeper.init(clock:)` takes `() -> Date`.
    private final class FakeClock {
        var now: Date
        init(_ start: Date) { self.now = start }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func read() -> Date { now }
    }

    private func makeKeeper(config: AlertBudget.Config, clock: FakeClock) -> AlertBudgetKeeper {
        AlertBudgetKeeper(config: config, clock: clock.read)
    }

    func testSlotsPerWindowCapsGrants() {
        // Use a large opening window so the opening-slots allowance doesn't
        // interfere, and put the clock well past minute 30 so the ordinary
        // (non-opening) slotsPerWindow applies.
        var config = AlertBudget.Config.default
        config.slotsPerWindow = 1
        config.windowMinutes = 15
        config.openingSlotsPerWindow = 1
        config.openingWindowMinutes = 0
        config.holdingSeconds = 0
        config.allowPreemption = false

        let clock = FakeClock(referenceDate)
        let keeper = makeKeeper(config: config, clock: clock)

        let candidates = [
            makeCandidate(symbol: "A", score: 0.9),
            makeCandidate(symbol: "B", score: 0.85),
            makeCandidate(symbol: "C", score: 0.80)
        ]

        let grants = keeper.evaluate(candidates: candidates, threshold: 0.6, cooldownMinutes: 20)
        XCTAssertEqual(grants.count, config.slotsPerWindow)
        // The budget goes to the highest score first.
        XCTAssertEqual(grants.first?.candidate.symbol, "A")
    }

    func testPerSymbolCooldownSuppressesRepeatAlert() {
        var config = AlertBudget.Config.default
        config.slotsPerWindow = 5
        config.windowMinutes = 15
        config.openingSlotsPerWindow = 5
        config.openingWindowMinutes = 0
        config.holdingSeconds = 0
        config.allowPreemption = false

        let clock = FakeClock(referenceDate)
        let keeper = makeKeeper(config: config, clock: clock)

        let candidate = makeCandidate(symbol: "A", score: 0.9)
        let firstGrants = keeper.evaluate(candidates: [candidate], threshold: 0.6, cooldownMinutes: 20)
        XCTAssertEqual(firstGrants.count, 1)

        // Same symbol, shortly after, well inside the 20-minute cooldown.
        clock.advance(60)
        let secondGrants = keeper.evaluate(candidates: [candidate], threshold: 0.6, cooldownMinutes: 20)
        XCTAssertEqual(secondGrants.count, 0)
        XCTAssertTrue(keeper.recentSuppressions.contains { $0.symbol == "A" && $0.reason == .cooldown })
    }

    func testPreemptionTakesSlotWhenMarginIsCleared() {
        var config = AlertBudget.Config.default
        config.slotsPerWindow = 1
        config.windowMinutes = 15
        config.openingSlotsPerWindow = 1
        config.openingWindowMinutes = 0
        config.holdingSeconds = 0
        config.allowPreemption = true
        config.preemptionMargin = 0.18

        let clock = FakeClock(referenceDate)
        let keeper = makeKeeper(config: config, clock: clock)

        // Fill the single slot with a modest score.
        let weak = makeCandidate(symbol: "WEAK", score: 0.65)
        let firstGrants = keeper.evaluate(candidates: [weak], threshold: 0.6, cooldownMinutes: 20)
        XCTAssertEqual(firstGrants.count, 1)
        XCTAssertEqual(keeper.slotsRemaining, 0)

        // A much stronger candidate arrives, clearing the preemption margin
        // (0.65 + 0.18 = 0.83, so 0.90 clears it).
        clock.advance(10)
        let strong = makeCandidate(symbol: "STRONG", score: 0.90)
        let secondGrants = keeper.evaluate(candidates: [strong], threshold: 0.6, cooldownMinutes: 20)

        XCTAssertEqual(secondGrants.count, 1)
        XCTAssertTrue(secondGrants.first?.wasPreemption ?? false)
        XCTAssertEqual(secondGrants.first?.candidate.symbol, "STRONG")
    }

    func testPreemptionDoesNotHappenWhenMarginIsNotMet() {
        var config = AlertBudget.Config.default
        config.slotsPerWindow = 1
        config.windowMinutes = 15
        config.openingSlotsPerWindow = 1
        config.openingWindowMinutes = 0
        config.holdingSeconds = 0
        config.allowPreemption = true
        config.preemptionMargin = 0.18

        let clock = FakeClock(referenceDate)
        let keeper = makeKeeper(config: config, clock: clock)

        let weak = makeCandidate(symbol: "WEAK", score: 0.65)
        let firstGrants = keeper.evaluate(candidates: [weak], threshold: 0.6, cooldownMinutes: 20)
        XCTAssertEqual(firstGrants.count, 1)

        // Only slightly better — 0.65 + 0.10 = 0.75, short of the 0.18 margin.
        clock.advance(10)
        let almost = makeCandidate(symbol: "ALMOST", score: 0.75)
        let secondGrants = keeper.evaluate(candidates: [almost], threshold: 0.6, cooldownMinutes: 20)

        XCTAssertEqual(secondGrants.count, 0)
        XCTAssertTrue(keeper.recentSuppressions.contains { $0.symbol == "ALMOST" && $0.reason == .budgetExhausted })
    }
}
