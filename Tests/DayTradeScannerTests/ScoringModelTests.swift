import XCTest
import Foundation
@testable import DayTradeScanner

final class ScoringModelTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a snapshot that clears every `ScanProfile.dayTrade` gate by
    /// default: rvol 3.0 (min 1.5), ~3.1% change (min 1.5%), $500k dollar
    /// volume (min $250k), 50 prints (min 30), price $10 (in 1.50...1000).
    private func makeSnapshot(
        symbol: String = "TEST",
        last: Double = 10.0,
        priorClose: Double = 9.7,
        vwap: Double = 9.9,
        vwapZ: Double = 1.0,
        vwapEvent: VWAPEvent = .none,
        minutesSinceVWAPEvent: Int? = nil,
        trend: TrendState = .aboveVWAP,
        rvol: Double = 3.0,
        baselineVolumeAtMinute: Double = 100_000,
        minuteOfSession: Int = 60,
        barRVOL: Double = 2.0,
        gapPercent: Double = 0.0,
        rangePosition: Double = 0.5,
        dollarVolume: Double = 500_000,
        tradeCount: Int = 50,
        extended: ExtendedSignals = ExtendedSignals()
    ) -> SignalSnapshot {
        SignalSnapshot(
            symbol: symbol,
            asOf: referenceDate,
            last: last,
            priorClose: priorClose,
            sessionOpen: priorClose,
            dayHigh: max(last, priorClose) + 0.5,
            dayLow: min(last, priorClose) - 0.5,
            vwap: vwap,
            vwapZ: vwapZ,
            vwapEvent: vwapEvent,
            minutesSinceVWAPEvent: minutesSinceVWAPEvent,
            trend: trend,
            rvol: rvol,
            cumulativeVolume: baselineVolumeAtMinute * rvol,
            baselineVolumeAtMinute: baselineVolumeAtMinute,
            minuteOfSession: minuteOfSession,
            barRVOL: barRVOL,
            gapPercent: gapPercent,
            atr14: 0.5,
            rangePosition: rangePosition,
            latestNews: nil,
            newsAgeMinutes: nil,
            newsCategory: nil,
            shortRatio: nil,
            shortRatioPercentile: nil,
            dollarVolume: dollarVolume,
            tradeCount: tradeCount,
            extended: extended
        )
    }

    private let config = ScanProfile.dayTrade.makeConfig()
    private var model: ScoringModel { ScoringModel(config: config) }

    // MARK: - Gate rejections

    func testGateRejectsOutOfRangePrice() {
        let snapshot = makeSnapshot(last: 1500) // above config.maxPrice (1000)
        XCTAssertEqual(model.gate(snapshot), .price)
    }

    func testGateRejectsLowDollarVolume() {
        let snapshot = makeSnapshot(dollarVolume: 10_000) // below 250,000
        XCTAssertEqual(model.gate(snapshot), .dollarVolume)
    }

    func testGateRejectsLowTradeCount() {
        let snapshot = makeSnapshot(tradeCount: 5) // below 30
        XCTAssertEqual(model.gate(snapshot), .tradeCount)
    }

    func testGateRejectsLowRVOL() {
        let snapshot = makeSnapshot(rvol: 1.1) // below 1.5
        XCTAssertEqual(model.gate(snapshot), .relativeVolume)
    }

    func testGateRejectsFlatMove() {
        // Same rvol/liquidity, but last is essentially unchanged from prior close.
        let snapshot = makeSnapshot(last: 9.71, priorClose: 9.70)
        XCTAssertEqual(model.gate(snapshot), .flat)
    }

    func testGateRejectsNoBaseline() {
        let snapshot = makeSnapshot(baselineVolumeAtMinute: 0)
        XCTAssertEqual(model.gate(snapshot), .noBaseline)
    }

    func testGateRejectsHaltedSymbolWhenHaltsNotAllowed() {
        var extended = ExtendedSignals()
        extended.isHalted = true
        let snapshot = makeSnapshot(extended: extended)
        var haltedModel = model
        haltedModel.allowHalted = false
        XCTAssertEqual(haltedModel.gate(snapshot), .halted)
    }

    func testGateAllowsHaltedSymbolWhenHaltsAllowed() {
        var extended = ExtendedSignals()
        extended.isHalted = true
        let snapshot = makeSnapshot(extended: extended)
        var haltedModel = model
        haltedModel.allowHalted = true
        XCTAssertNil(haltedModel.gate(snapshot))
    }

    func testCleanSnapshotPassesGate() {
        XCTAssertNil(model.gate(makeSnapshot()))
    }

    // MARK: - Scoring

    func testStrongSetupScoresHigherThanFlatSetup() {
        var strongExtended = ExtendedSignals()
        strongExtended.atrPercent = 0.06
        strongExtended.runnerFrequency = 0.12

        let strong = makeSnapshot(
            last: 12.0,
            priorClose: 10.0,
            vwapZ: 2.0,
            vwapEvent: .reclaim,
            minutesSinceVWAPEvent: 1,
            rvol: 6.0,
            gapPercent: 0.06,
            rangePosition: 0.95,
            extended: strongExtended
        )

        let flat = makeSnapshot(
            last: 10.05,
            priorClose: 10.0,
            vwapZ: 0.1,
            vwapEvent: .none,
            minutesSinceVWAPEvent: nil,
            rvol: 1.6,
            gapPercent: 0.0,
            rangePosition: 0.5
        )

        let strongScore = model.score(strong).total
        let flatScore = model.score(flat).total
        XCTAssertGreaterThan(strongScore, flatScore)
    }

    func testScoreTotalIsClampedToZeroToOne() {
        var extended = ExtendedSignals()
        extended.atrPercent = 0.10
        extended.runnerFrequency = 0.20
        extended.rangeExpansion = 3.0
        extended.compressionRatio = 0.2
        extended.floatCategory = .nano
        extended.floatRotation = 2.0
        extended.socialTrendingRank = 0
        extended.socialMessageSurge = 5
        extended.socialWatchCount = 6000
        extended.insiderClusterFilers = 5
        extended.insiderClusterMinutesAgo = 1
        extended.patternBreakoutScore = 1.0

        let snapshot = makeSnapshot(
            vwapZ: 5.0,
            vwapEvent: .reclaim,
            minutesSinceVWAPEvent: 0,
            rvol: 20.0,
            gapPercent: 0.5,
            rangePosition: 1.0,
            extended: extended
        )

        let breakdown = model.score(snapshot)
        XCTAssertLessThanOrEqual(breakdown.total, 1.0)
        XCTAssertGreaterThanOrEqual(breakdown.total, 0.0)
    }

    /// Normalized RVOL response should be monotonically non-decreasing as
    /// raw rvol increases, verified indirectly through `score(_:)`'s public
    /// breakdown rather than the private `normalizeRVOL` function.
    func testNormalizedRVOLIsMonotonicNonDecreasing() {
        let rvolValues: [Double] = [1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0]
        var previous: Double = -1
        for rvol in rvolValues {
            let snapshot = makeSnapshot(rvol: rvol)
            let value = model.score(snapshot).normalized[.relativeVolume] ?? -1
            XCTAssertGreaterThanOrEqual(value, previous, "rvol \(rvol) should score >= previous")
            previous = value
        }
    }

    func testRankSeparatesCandidatesFromRejections() {
        let good = makeSnapshot(symbol: "GOOD")
        let bad = makeSnapshot(symbol: "BAD", rvol: 1.1) // fails relativeVolume gate

        let result = model.rank([good, bad])
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.symbol, "GOOD")
        XCTAssertEqual(result.rejected.count, 1)
        XCTAssertEqual(result.rejected.first?.0, "BAD")
        XCTAssertEqual(result.rejected.first?.1, .relativeVolume)
    }
}
