import XCTest
@testable import DayTradeScanner

/// `BaselineStore`'s pure math (`buildBaseline`, `median`,
/// `averageTrueRange`) drives every RVOL number in the app, but only the
/// disk-serialization wrapper around it had tests before this — the math
/// itself was untested.
final class BaselineStoreMathTests: XCTestCase {
    // MARK: - median

    func testMedianOfEmptyIsZero() {
        XCTAssertEqual(BaselineStore.median([]), 0)
    }

    func testMedianOfOddCount() {
        XCTAssertEqual(BaselineStore.median([5, 1, 3]), 3)
    }

    func testMedianOfEvenCountAveragesTheMiddlePair() {
        XCTAssertEqual(BaselineStore.median([1, 2, 3, 4]), 2.5)
    }

    func testMedianIsRobustToOneOutlier() {
        // One earnings-day 20x spike shouldn't move the median much — the
        // whole reason baselines use median instead of mean.
        let values: [Double] = [100, 105, 98, 102, 101, 2000]
        XCTAssertEqual(BaselineStore.median(values), 101.5)
    }

    // MARK: - averageTrueRange

    private func dailyBar(daysFromEpoch: Int, high: Double, low: Double, close: Double) -> DailyBar {
        DailyBar(
            timestamp: Date(timeIntervalSince1970: Double(daysFromEpoch) * 86400),
            open: (high + low) / 2, high: high, low: low, close: close, volume: 1000
        )
    }

    func testAverageTrueRangeReturnsZeroWithInsufficientBars() {
        let bars = (0..<10).map { dailyBar(daysFromEpoch: $0, high: 12, low: 10, close: 11) }
        XCTAssertEqual(BaselineStore.averageTrueRange(bars, period: 14), 0)
    }

    func testAverageTrueRangeWithConstantRangeConverges() {
        // Every day's high-low is exactly 2, and each day opens where the
        // prior day closed, so every true range is exactly 2 regardless of
        // gap terms — ATR should converge to 2.
        let close = 100.0
        let bars = (0..<20).map { day in
            dailyBar(daysFromEpoch: day, high: close + 1, low: close - 1, close: close)
        }
        let atr = BaselineStore.averageTrueRange(bars, period: 14)
        XCTAssertEqual(atr, 2, accuracy: 0.0001)
    }

    func testAverageTrueRangeReactsToAGapUp() {
        // A single large gap should pull ATR up from a previously-flat
        // range, then Wilder-smooth back down on subsequent flat days.
        var bars = (0..<15).map { dailyBar(daysFromEpoch: $0, high: 101, low: 99, close: 100) }
        // A gap day: prior close 100, this day trades 110-115 — true range
        // is max(5, |115-100|, |110-100|) = 15.
        bars.append(dailyBar(daysFromEpoch: 15, high: 115, low: 110, close: 112))
        let atrAfterGap = BaselineStore.averageTrueRange(bars, period: 14)

        var flatOnly = bars
        flatOnly.removeLast()
        flatOnly.append(dailyBar(daysFromEpoch: 15, high: 101, low: 99, close: 100))
        let atrFlat = BaselineStore.averageTrueRange(flatOnly, period: 14)

        XCTAssertGreaterThan(atrAfterGap, atrFlat)
    }

    // MARK: - buildBaseline

    /// 2024-01-15 is a Monday; five consecutive weekdays give the minimum
    /// session count `buildBaseline` requires.
    private func regularSessionOpen(dayOffset: Int) -> Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 15 + dayOffset
        components.hour = 9
        components.minute = 30
        return MarketClock.calendar.date(from: components)!
    }

    func testBuildBaselineReturnsNilWithFewerThanFiveSessions() {
        let bars = (0..<3).map {
            MinuteBar(symbol: "TEST", timestamp: regularSessionOpen(dayOffset: $0), open: 10, high: 10, low: 10, close: 10, volume: 100, tradeCount: 1, barVWAP: 10)
        }
        let daily = (0..<20).map { dailyBar(daysFromEpoch: $0, high: 11, low: 9, close: 10) }
        XCTAssertNil(BaselineStore.buildBaseline(symbol: "TEST", minuteBars: bars, dailyBars: daily, sessionLimit: 30))
    }

    func testBuildBaselineTakesMedianVolumeAtEachMinuteAcrossSessions() {
        let dayVolumes: [Double] = [100, 200, 300, 400, 500]
        let minuteBars = dayVolumes.enumerated().map { index, volume in
            MinuteBar(symbol: "TEST", timestamp: regularSessionOpen(dayOffset: index), open: 10, high: 10, low: 10, close: 10, volume: volume, tradeCount: 1, barVWAP: 10)
        }
        let daily = (0..<20).map { dailyBar(daysFromEpoch: $0, high: 11, low: 9, close: 10) }

        let baseline = BaselineStore.buildBaseline(symbol: "TEST", minuteBars: minuteBars, dailyBars: daily, sessionLimit: 30)

        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline?.sessionsUsed, 5)
        // Minute 0 (the 9:30 bar) is the only minute with volume in any
        // session, so its median across the five sessions is 300.
        XCTAssertEqual(baseline?.cumulativeMedian.first, 300)
        XCTAssertEqual(baseline?.barMedian.first, 300)
        // Every later minute had zero volume in all five sessions, so the
        // cumulative median stays flat at 300 rather than climbing.
        XCTAssertEqual(baseline?.cumulativeMedian.last, 300)
    }

    func testBuildBaselineIgnoresBarsOutsideRegularHours() {
        // A giant pre-market print must not leak into the median curve.
        var components = DateComponents()
        components.year = 2024; components.month = 1; components.day = 15
        components.hour = 8; components.minute = 0
        let premarketDate = MarketClock.calendar.date(from: components)!

        var minuteBars = (0..<5).map { index in
            MinuteBar(symbol: "TEST", timestamp: regularSessionOpen(dayOffset: index), open: 10, high: 10, low: 10, close: 10, volume: 100, tradeCount: 1, barVWAP: 10)
        }
        minuteBars.append(MinuteBar(symbol: "TEST", timestamp: premarketDate, open: 10, high: 10, low: 10, close: 10, volume: 1_000_000, tradeCount: 1, barVWAP: 10))
        let daily = (0..<20).map { dailyBar(daysFromEpoch: $0, high: 11, low: 9, close: 10) }

        let baseline = BaselineStore.buildBaseline(symbol: "TEST", minuteBars: minuteBars, dailyBars: daily, sessionLimit: 30)

        XCTAssertEqual(baseline?.cumulativeMedian.first, 100, "the 1,000,000-share pre-market bar must not be counted")
    }
}
