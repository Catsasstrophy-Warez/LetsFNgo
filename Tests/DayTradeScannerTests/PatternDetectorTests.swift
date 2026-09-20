import XCTest
import Foundation
@testable import DayTradeScanner

final class PatternDetectorTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a 1-minute bar from a single "price" value: open/high/low/close
    /// are all set from it (with a tiny high/low pad so the bar isn't a
    /// zero-range doji), which is all `PatternDetector` reads.
    private func bar(_ index: Int, _ price: Double, pad: Double = 0.05) -> MinuteBar {
        MinuteBar(
            symbol: "TEST",
            timestamp: referenceDate.addingTimeInterval(Double(index) * 60),
            open: price,
            high: price + pad,
            low: price - pad,
            close: price,
            volume: 1000,
            tradeCount: 50,
            barVWAP: price
        )
    }

    private func makeBars(_ prices: [Double]) -> [MinuteBar] {
        prices.enumerated().map { bar($0.offset, $0.element) }
    }

    /// Two flat pivot highs at 100 (indices 3 and 9, both within the
    /// wing=3 pivot-search window of 3..<(count-3)), followed by a decline
    /// and then a sharp final-bar break back above the projected level.
    func testCleanResistanceBreakIsDetectedWithPositiveScore() throws {
        let prices: [Double] = [
            90, 92, 95, 100, 97, 94, 91, 94, 97, 100,
            97, 94, 91, 88, 85, 82, 79, 76, 73, 110
        ]
        let bars = makeBars(prices)
        let result = try XCTUnwrap(PatternDetector.detect(bars: bars))

        XCTAssertGreaterThan(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 1.0)
        XCTAssertTrue(result.note.contains("resistance"))
    }

    /// The mirror image: two flat pivot lows at 100, then a sharp final-bar
    /// break down through the projected support level.
    func testCleanSupportBreakdownIsDetectedWithPositiveScore() throws {
        let prices: [Double] = [
            110, 108, 105, 100, 103, 106, 109, 106, 103, 100,
            103, 106, 109, 112, 115, 118, 121, 124, 127, 90
        ]
        let bars = makeBars(prices)
        let result = try XCTUnwrap(PatternDetector.detect(bars: bars))

        XCTAssertGreaterThan(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 1.0)
        XCTAssertTrue(result.note.contains("support"))
    }

    /// `PatternDetector.detect` guards on `bars.count >= wing * 2 + 8` (14
    /// with wing == 3). 13 bars must return nil regardless of shape.
    func testTooFewBarsReturnsNil() {
        let prices: [Double] = Array(stride(from: 90.0, to: 90.0 + 13, by: 1))
        XCTAssertEqual(prices.count, 13)
        let bars = makeBars(prices)
        XCTAssertNil(PatternDetector.detect(bars: bars))
    }

    /// A perfectly flat series never crosses the 0.2% break threshold in
    /// either direction, so no break is detected.
    func testFlatSeriesWithNoBreakReturnsNil() {
        let prices = Array(repeating: 100.0, count: 20)
        let bars = makeBars(prices)
        XCTAssertNil(PatternDetector.detect(bars: bars))
    }
}
