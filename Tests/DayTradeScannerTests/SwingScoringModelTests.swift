import XCTest
import Foundation
@testable import DayTradeScanner

final class SwingScoringModelTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Passes every `SwingScoringModel.default` gate by default: price $20
    /// (5...2000), $5M average dollar volume (min $2M), 3% ATR (min 1.5%).
    private func makeSnapshot(
        symbol: String = "TEST",
        last: Double = 20.0,
        priorClose: Double = 19.5,
        sma20: Double = 19.0,
        sma50: Double = 18.0,
        sma200: Double = 16.0,
        sma50SlopePercent: Double = 0.01,
        relativeStrength20Day: Double = 0.0,
        relativeStrength60Day: Double = 0.0,
        high52Week: Double = 22.0,
        low52Week: Double = 10.0,
        positionIn52WeekRange: Double = 0.6,
        priorRangeHigh20: Double = 20.5,
        atrPercent: Double = 0.03,
        volumeVsAverage: Double = 1.2,
        volumeTrend: Double = 1.0,
        averageDollarVolume: Double? = 5_000_000,
        distanceFromSMA20ATR: Double = 0.3,
        floatShares: Double? = nil,
        floatCategory: SECFloatClient.FloatCategory? = nil,
        insiderFilingsRecent: Int = 0,
        sector: String? = nil,
        estimatedDaysToNextFiling: Int? = nil
    ) -> SwingSignalSnapshot {
        var snapshot = SwingSignalSnapshot(
            symbol: symbol,
            asOf: referenceDate,
            last: last,
            priorClose: priorClose,
            sma20: sma20,
            sma50: sma50,
            sma200: sma200,
            sma50SlopePercent: sma50SlopePercent,
            relativeStrength20Day: relativeStrength20Day,
            relativeStrength60Day: relativeStrength60Day,
            high52Week: high52Week,
            low52Week: low52Week,
            positionIn52WeekRange: positionIn52WeekRange,
            priorRangeHigh20: priorRangeHigh20,
            atrPercent: atrPercent,
            volumeVsAverage: volumeVsAverage,
            volumeTrend: volumeTrend,
            distanceFromSMA20ATR: distanceFromSMA20ATR,
            floatShares: floatShares,
            floatCategory: floatCategory,
            insiderFilingsRecent: insiderFilingsRecent,
            sector: sector,
            estimatedDaysToNextFiling: estimatedDaysToNextFiling
        )
        snapshot.averageDollarVolume = averageDollarVolume
        return snapshot
    }

    private let model = SwingScoringModel.default

    // MARK: - Gate rejections

    func testGateRejectsOutOfRangePrice() {
        let tooLow = makeSnapshot(last: 2.0)
        XCTAssertEqual(model.gate(tooLow), .price)

        let tooHigh = makeSnapshot(last: 3000.0)
        XCTAssertEqual(model.gate(tooHigh), .price)
    }

    func testGateRejectsLowDollarVolume() {
        let snapshot = makeSnapshot(averageDollarVolume: 500_000)
        XCTAssertEqual(model.gate(snapshot), .dollarVolume)
    }

    func testGateRejectsMissingDollarVolume() {
        let snapshot = makeSnapshot(averageDollarVolume: nil)
        XCTAssertEqual(model.gate(snapshot), .dollarVolume)
    }

    func testGateRejectsLowATRPercent() {
        let snapshot = makeSnapshot(atrPercent: 0.005) // below 1.5%
        XCTAssertEqual(model.gate(snapshot), .tooQuiet)
    }

    func testCleanSnapshotPassesGate() {
        XCTAssertNil(model.gate(makeSnapshot()))
    }

    // MARK: - Scoring

    func testStrongTrendAndRelativeStrengthOutscoresWeakSetup() {
        let strong = makeSnapshot(
            last: 25.0,
            sma20: 23.0,
            sma50: 21.0,
            sma200: 18.0,
            sma50SlopePercent: 0.02,
            relativeStrength20Day: 0.10,
            relativeStrength60Day: 0.20,
            positionIn52WeekRange: 0.95,
            priorRangeHigh20: 24.0,
            volumeVsAverage: 2.5,
            volumeTrend: 1.5,
            distanceFromSMA20ATR: 0.3
        )

        let weak = makeSnapshot(
            last: 15.0,
            sma20: 16.0,
            sma50: 17.0,
            sma200: 19.0,
            sma50SlopePercent: -0.02,
            relativeStrength20Day: -0.10,
            relativeStrength60Day: -0.15,
            positionIn52WeekRange: 0.15,
            priorRangeHigh20: 20.0,
            volumeVsAverage: 0.7,
            volumeTrend: 0.6,
            distanceFromSMA20ATR: -0.5
        )

        let strongScore = model.score(strong).total
        let weakScore = model.score(weak).total
        XCTAssertGreaterThan(strongScore, weakScore)
    }

    func testRankSeparatesCandidatesFromRejections() {
        let good = makeSnapshot(symbol: "GOOD")
        let bad = makeSnapshot(symbol: "BAD", atrPercent: 0.005)

        let result = model.rank([good, bad])
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.symbol, "GOOD")
        XCTAssertEqual(result.rejected.count, 1)
        XCTAssertEqual(result.rejected.first?.0, "BAD")
        XCTAssertEqual(result.rejected.first?.1, .tooQuiet)
    }
}
