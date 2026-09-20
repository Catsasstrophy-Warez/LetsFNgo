import XCTest
import Foundation
@testable import DayTradeScanner

/// `SetupType.classify`, `ScanRecipe.admits`, and `ScanRecipe.makeConfig`
/// decide which candidates get scored and alerted under each recipe, but
/// had no direct tests before this.
final class ScanRecipeTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(
        last: Double = 10.0,
        priorClose: Double = 9.7,
        vwap: Double = 9.9,
        vwapEvent: VWAPEvent = .none,
        minutesSinceVWAPEvent: Int? = nil,
        trend: TrendState = .aboveVWAP,
        rvol: Double = 3.0,
        minuteOfSession: Int = 60,
        gapPercent: Double = 0.0,
        rangePosition: Double = 0.5,
        dollarVolume: Double = 500_000,
        newsAgeMinutes: Double? = nil,
        extended: ExtendedSignals = ExtendedSignals()
    ) -> SignalSnapshot {
        SignalSnapshot(
            symbol: "TEST", asOf: referenceDate, last: last, priorClose: priorClose,
            sessionOpen: priorClose, dayHigh: max(last, priorClose) + 0.5,
            dayLow: min(last, priorClose) - 0.5, vwap: vwap, vwapZ: 1.0,
            vwapEvent: vwapEvent, minutesSinceVWAPEvent: minutesSinceVWAPEvent,
            trend: trend, rvol: rvol, cumulativeVolume: 100_000 * rvol,
            baselineVolumeAtMinute: 100_000, minuteOfSession: minuteOfSession,
            barRVOL: 2.0, gapPercent: gapPercent, atr14: 0.5,
            rangePosition: rangePosition, latestNews: nil,
            newsAgeMinutes: newsAgeMinutes, newsCategory: nil,
            shortRatio: nil, shortRatioPercentile: nil,
            dollarVolume: dollarVolume, tradeCount: 50, extended: extended
        )
    }

    private func makeCandidate(snapshot: SignalSnapshot) -> Candidate {
        Candidate(snapshot: snapshot, breakdown: ScoreBreakdown())
    }

    // MARK: - SetupType.classify

    func testClassifyPrioritizesFreshResumeOverEverythingElse() {
        // Also matches gapAndGo's own criteria, to prove ordering wins.
        let snapshot = makeSnapshot(gapPercent: 0.06, minuteOfSession: 5, rangePosition: 0.9)
        let candidate = makeCandidate(snapshot: snapshot)
        XCTAssertEqual(SetupType.classify(candidate, isFreshResume: true), .haltResume)
    }

    func testClassifyDetectsLowFloatSqueezeBeforeGapAndGo() {
        var extended = ExtendedSignals()
        extended.floatCategory = .nano
        // Also satisfies gapAndGo's own criteria (large gap, early session,
        // near day high) — this proves lowFloatSqueeze wins on ordering.
        let snapshot = makeSnapshot(
            last: 11, priorClose: 10, rvol: 4, gapPercent: 0.1,
            minuteOfSession: 5, rangePosition: 0.9, extended: extended
        )
        let candidate = makeCandidate(snapshot: snapshot)
        XCTAssertEqual(SetupType.classify(candidate), .lowFloatSqueeze)
    }

    func testClassifyFallsBackToUnclassifiedWhenNothingMatches() {
        // Flat, mid-session, no news, no float category, no drift.
        var extended = ExtendedSignals()
        extended.pullbackQuality = 0
        extended.consecutiveDirectionalBars = 0
        extended.burstScore = 0
        extended.compressionRatio = 1.0
        let snapshot = makeSnapshot(
            vwapEvent: .none, rvol: 1.0, minuteOfSession: 200,
            gapPercent: 0.0, rangePosition: 0.5, extended: extended
        )
        let candidate = makeCandidate(snapshot: snapshot)
        XCTAssertEqual(SetupType.classify(candidate), .unclassified)
    }

    func testClassifyDetectsVWAPReclaimWithinTenMinutes() {
        let snapshot = makeSnapshot(
            vwapEvent: .reclaim, minutesSinceVWAPEvent: 3, rvol: 1.0,
            minuteOfSession: 200, gapPercent: 0.0, rangePosition: 0.5
        )
        let candidate = makeCandidate(snapshot: snapshot)
        XCTAssertEqual(SetupType.classify(candidate), .vwapReclaim)
    }

    func testClassifyIgnoresStaleVWAPReclaim() {
        // Same event, but more than 10 minutes old — must not classify as
        // a fresh vwapReclaim.
        let snapshot = makeSnapshot(
            vwapEvent: .reclaim, minutesSinceVWAPEvent: 45, rvol: 1.0,
            minuteOfSession: 200, gapPercent: 0.0, rangePosition: 0.5
        )
        let candidate = makeCandidate(snapshot: snapshot)
        XCTAssertNotEqual(SetupType.classify(candidate), .vwapReclaim)
    }

    // MARK: - ScanRecipe.admits

    private let baseRecipe = ScanRecipe(name: "Test recipe", summary: "", baseProfile: .dayTrade, setup: .unclassified)

    func testAdmitsRejectsBelowMinPrice() {
        var recipe = baseRecipe
        recipe.minPrice = 5
        let snapshot = makeSnapshot(last: 2)
        XCTAssertFalse(recipe.admits(snapshot, isFreshResume: false))
    }

    func testAdmitsRejectsAboveMaxPrice() {
        var recipe = baseRecipe
        recipe.maxPrice = 20
        let snapshot = makeSnapshot(last: 25)
        XCTAssertFalse(recipe.admits(snapshot, isFreshResume: false))
    }

    func testAdmitsRequiresFreshResumeWhenFlagSet() {
        var recipe = baseRecipe
        recipe.requireFreshResume = true
        let snapshot = makeSnapshot()
        XCTAssertFalse(recipe.admits(snapshot, isFreshResume: false))
        XCTAssertTrue(recipe.admits(snapshot, isFreshResume: true))
    }

    func testAdmitsTreatsUnknownFloatAsFailingAMaxFloatGate() {
        // No floatShares set on ExtendedSignals() — the point of this gate
        // is that an unknown float doesn't silently pass a max-float filter.
        var recipe = baseRecipe
        recipe.maxFloatShares = 10_000_000
        let snapshot = makeSnapshot(extended: ExtendedSignals())
        XCTAssertFalse(recipe.admits(snapshot, isFreshResume: false))
    }

    func testAdmitsPassesKnownFloatWithinRange() {
        var recipe = baseRecipe
        recipe.maxFloatShares = 10_000_000
        var extended = ExtendedSignals()
        extended.floatShares = 5_000_000
        let snapshot = makeSnapshot(extended: extended)
        XCTAssertTrue(recipe.admits(snapshot, isFreshResume: false))
    }

    func testAdmitsChecksRequireAboveVWAPAgainstTrend() {
        var recipe = baseRecipe
        recipe.requireAboveVWAP = true
        let above = makeSnapshot(trend: .aboveVWAP)
        let below = makeSnapshot(trend: .belowVWAP)
        XCTAssertTrue(recipe.admits(above, isFreshResume: false))
        XCTAssertFalse(recipe.admits(below, isFreshResume: false))
    }

    func testAdmitsWithNoOverridesAcceptsAnySnapshot() {
        // A recipe with every gate left nil should admit like a no-op.
        let snapshot = makeSnapshot(last: 500, rvol: 0.1, dollarVolume: 1)
        XCTAssertTrue(baseRecipe.admits(snapshot, isFreshResume: false))
    }

    // MARK: - ScanRecipe.makeConfig

    func testMakeConfigOverridesOnlyProvidedGates() {
        var recipe = baseRecipe
        recipe.minRVOL = 4.0
        recipe.alertThreshold = 0.9
        let base = ScoringConfig.default

        let config = recipe.makeConfig(from: base)

        XCTAssertEqual(config.minRVOL, 4.0)
        XCTAssertEqual(config.alertThreshold, 0.9)
        // Untouched fields carry the base profile's values through unchanged.
        XCTAssertEqual(config.minPrice, base.minPrice)
        XCTAssertEqual(config.maxPrice, base.maxPrice)
        XCTAssertEqual(config.minDollarVolume, base.minDollarVolume)
    }

    func testMakeConfigAppliesWeightBoostsMultiplicatively() {
        var recipe = baseRecipe
        recipe.weightBoosts = [.relativeVolume: 2.0]
        let base = ScoringConfig.default
        let baseWeight = base.weights[.relativeVolume] ?? SignalComponent.relativeVolume.defaultWeight

        let config = recipe.makeConfig(from: base)

        XCTAssertEqual(config.weights[.relativeVolume], baseWeight * 2.0, accuracy: 0.0001)
        // Every other weight should be untouched.
        for component in SignalComponent.allCases where component != .relativeVolume {
            XCTAssertEqual(config.weights[component], base.weights[component])
        }
    }
}
