import XCTest
import Foundation
@testable import DayTradeScanner

final class LongTermScoringModelTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(
        symbol: String = "TEST",
        entityName: String = "Test Corp",
        lastPrice: Double = 50.0,
        sharesOutstanding: Double? = 20_000_000,
        revenueTTM: Double? = 100_000_000,
        revenueTTMYearAgo: Double? = 80_000_000,
        netIncomeTTM: Double? = 15_000_000,
        netMarginYearAgo: Double? = 0.10,
        revenueTTMSeries: [Double] = [],
        netIncomeTTMSeries: [Double] = [],
        totalAssets: Double? = 200_000_000,
        totalLiabilities: Double? = 60_000_000,
        priceVsSMA200Percent: Double? = 0.10,
        distanceFrom52WeekHighPercent: Double? = -0.05,
        floatShares: Double? = nil,
        floatCategory: SECFloatClient.FloatCategory? = nil,
        insiderFilingsRecent: Int = 0,
        insiderFilingWindowDays: Int = 90,
        sector: String? = nil
    ) -> FundamentalSnapshot {
        FundamentalSnapshot(
            symbol: symbol,
            entityName: entityName,
            asOf: referenceDate,
            lastPrice: lastPrice,
            sharesOutstanding: sharesOutstanding,
            revenueTTM: revenueTTM,
            revenueTTMYearAgo: revenueTTMYearAgo,
            netIncomeTTM: netIncomeTTM,
            netMarginYearAgo: netMarginYearAgo,
            revenueTTMSeries: revenueTTMSeries,
            netIncomeTTMSeries: netIncomeTTMSeries,
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            priceVsSMA200Percent: priceVsSMA200Percent,
            distanceFrom52WeekHighPercent: distanceFrom52WeekHighPercent,
            floatShares: floatShares,
            floatCategory: floatCategory,
            insiderFilingsRecent: insiderFilingsRecent,
            insiderFilingWindowDays: insiderFilingWindowDays,
            sector: sector
        )
    }

    private let model = LongTermScoringModel.default

    func testProfitableGrowingCheapLowLeverageOutscoresOpposite() {
        // Revenue up 40% YoY, 15% net margin (up from 8%), 3x sales, low
        // leverage (30% liabilities/assets), trading above its 200-day and
        // near its 52-week high.
        let strong = makeSnapshot(
            lastPrice: 50.0,
            sharesOutstanding: 20_000_000, // market cap = $1B
            revenueTTM: 333_333_333,       // price/sales ~3x
            revenueTTMYearAgo: 238_095_238, // +40% YoY
            netIncomeTTM: 50_000_000,       // 15% net margin
            netMarginYearAgo: 0.08,
            totalAssets: 500_000_000,
            totalLiabilities: 150_000_000,  // 30% leverage
            priceVsSMA200Percent: 0.15,
            distanceFrom52WeekHighPercent: -0.02,
            insiderFilingsRecent: 4
        )

        // Revenue down 20% YoY, unprofitable, richly valued (20x sales),
        // high leverage (90% liabilities/assets), below its 200-day and far
        // from its 52-week high.
        let weak = makeSnapshot(
            lastPrice: 50.0,
            sharesOutstanding: 20_000_000,
            revenueTTM: 50_000_000,        // price/sales = 20x
            revenueTTMYearAgo: 62_500_000,  // -20% YoY
            netIncomeTTM: -10_000_000,      // -20% net margin
            netMarginYearAgo: -0.05,
            totalAssets: 200_000_000,
            totalLiabilities: 180_000_000,  // 90% leverage
            priceVsSMA200Percent: -0.20,
            distanceFrom52WeekHighPercent: -0.50,
            insiderFilingsRecent: 0
        )

        let strongScore = model.score(strong).total
        let weakScore = model.score(weak).total
        XCTAssertGreaterThan(strongScore, weakScore)
    }

    /// Ranges verified directly against `LongTermScoringModel`'s normalize
    /// functions rather than assumed:
    /// - revenueGrowth, profitability: clamp(..., min: -0.5, max: 1.0)
    /// - marginTrend: clamp(..., min: -1.0, max: 1.0)
    /// - valuation: either clamp(0...1) (cheap) or -clamp(0...1) (expensive), so -1...1 overall
    /// - leverageRisk: -clamp(0...1), so -1...0
    /// - floatRisk: 0 or exactly -0.5
    func testNormalizedComponentsLandInDocumentedRanges() throws {
        let snapshot = makeSnapshot(
            revenueTTM: 50_000_000,
            revenueTTMYearAgo: 100_000_000,   // steep decline, tests the -0.5 floor
            netIncomeTTM: -20_000_000,        // steep loss, tests the -0.5 floor
            netMarginYearAgo: 0.30,           // steep margin contraction, tests the -1.0 floor
            totalAssets: 100_000_000,
            totalLiabilities: 95_000_000,     // 95% leverage, tests the -1.0 floor
            floatCategory: .nano
        )
        let breakdown = model.score(snapshot)

        let revenueGrowth = try XCTUnwrap(breakdown.normalized[.revenueGrowth])
        XCTAssertGreaterThanOrEqual(revenueGrowth, -0.5)
        XCTAssertLessThanOrEqual(revenueGrowth, 1.0)

        let profitability = try XCTUnwrap(breakdown.normalized[.profitability])
        XCTAssertGreaterThanOrEqual(profitability, -0.5)
        XCTAssertLessThanOrEqual(profitability, 1.0)

        let marginTrend = try XCTUnwrap(breakdown.normalized[.marginTrend])
        XCTAssertGreaterThanOrEqual(marginTrend, -1.0)
        XCTAssertLessThanOrEqual(marginTrend, 1.0)

        let valuation = try XCTUnwrap(breakdown.normalized[.valuation])
        XCTAssertGreaterThanOrEqual(valuation, -1.0)
        XCTAssertLessThanOrEqual(valuation, 1.0)

        let leverageRisk = try XCTUnwrap(breakdown.normalized[.leverageRisk])
        XCTAssertGreaterThanOrEqual(leverageRisk, -1.0)
        XCTAssertLessThanOrEqual(leverageRisk, 0.0)

        let floatRisk = try XCTUnwrap(breakdown.normalized[.floatRisk])
        XCTAssertEqual(floatRisk, -0.5)
    }

    func testTotalIsFlooredAtNegativePointThree() {
        // Stack every hazard to try to push the total below the documented floor.
        let snapshot = makeSnapshot(
            revenueTTM: 10_000_000,
            revenueTTMYearAgo: 100_000_000,
            netIncomeTTM: -50_000_000,
            netMarginYearAgo: 0.50,
            totalAssets: 100_000_000,
            totalLiabilities: 99_000_000,
            priceVsSMA200Percent: -0.9,
            distanceFrom52WeekHighPercent: -0.9,
            floatCategory: .micro
        )
        let breakdown = model.score(snapshot)
        XCTAssertGreaterThanOrEqual(breakdown.total, -0.3)
        XCTAssertLessThanOrEqual(breakdown.total, 1.0)
    }

    func testRankFiltersOutSnapshotsWithoutEnoughData() {
        let scorable = makeSnapshot(symbol: "GOOD", revenueTTM: 100_000_000)
        let unscorable = makeSnapshot(symbol: "BAD", revenueTTM: nil, netIncomeTTM: nil)

        let ranked = model.rank([scorable, unscorable])
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.symbol, "GOOD")
    }
}
