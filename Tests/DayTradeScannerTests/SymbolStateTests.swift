import XCTest
@testable import DayTradeScanner

/// `SymbolState.apply(bar:)` is the per-symbol state machine every score in
/// the app is built on top of (VWAP, RVOL accumulation, VWAP-event
/// detection) — this was previously untested, since ScoringModelTests etc.
/// construct `SignalSnapshot` directly and bypass it entirely.
final class SymbolStateTests: XCTestCase {
    /// 2024-01-16 is a Tuesday; 9:30 ET is the regular-session open.
    private func regularSessionDate(minutesAfterOpen: Int) -> Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 16
        components.hour = 9
        components.minute = 30
        let open = MarketClock.calendar.date(from: components)!
        return open.addingTimeInterval(Double(minutesAfterOpen) * 60)
    }

    private func makeBar(
        minutesAfterOpen: Int,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Double,
        symbol: String = "TEST"
    ) -> MinuteBar {
        MinuteBar(
            symbol: symbol,
            timestamp: regularSessionDate(minutesAfterOpen: minutesAfterOpen),
            open: open, high: high, low: low, close: close,
            volume: volume, tradeCount: 10, barVWAP: (open + close) / 2
        )
    }

    func testFirstAcceptedBarSeedsSessionOpenAndVWAP() {
        var state = SymbolState(symbol: "TEST")
        let bar = makeBar(minutesAfterOpen: 0, open: 10, high: 10.5, low: 9.5, close: 10, volume: 1000)

        let accepted = state.apply(bar: bar, includePremarket: false)

        XCTAssertTrue(accepted)
        XCTAssertEqual(state.sessionOpen, 10)
        XCTAssertEqual(state.last, 10)
        XCTAssertEqual(state.barsSeen, 1)
        // vwap == typicalPrice of the single bar when there's only one.
        XCTAssertEqual(state.vwap, bar.typicalPrice, accuracy: 0.0001)
    }

    func testVWAPWeightsLargerVolumeBarMoreHeavily() {
        var state = SymbolState(symbol: "TEST")
        _ = state.apply(bar: makeBar(minutesAfterOpen: 0, open: 10, high: 10, low: 10, close: 10, volume: 100), includePremarket: false)
        _ = state.apply(bar: makeBar(minutesAfterOpen: 1, open: 20, high: 20, low: 20, close: 20, volume: 900), includePremarket: false)

        // 90% of volume at price 20 should pull VWAP much closer to 20 than 10.
        XCTAssertGreaterThan(state.vwap, 18)
    }

    func testDuplicateOrStaleBarIsRejected() {
        var state = SymbolState(symbol: "TEST")
        let first = makeBar(minutesAfterOpen: 5, open: 10, high: 10.5, low: 9.5, close: 10, volume: 1000)
        XCTAssertTrue(state.apply(bar: first, includePremarket: false))

        // Same timestamp again — must not double-count volume.
        let repeated = makeBar(minutesAfterOpen: 5, open: 10, high: 10.5, low: 9.5, close: 10, volume: 1000)
        XCTAssertFalse(state.apply(bar: repeated, includePremarket: false))
        XCTAssertEqual(state.sumVolume, 1000)

        // An earlier timestamp (stale backfill after a reconnect) is rejected too.
        let stale = makeBar(minutesAfterOpen: 4, open: 10, high: 10.5, low: 9.5, close: 10, volume: 500)
        XCTAssertFalse(state.apply(bar: stale, includePremarket: false))
        XCTAssertEqual(state.sumVolume, 1000)
    }

    func testMalformedBarIsRejectedWithoutMutatingState() {
        var state = SymbolState(symbol: "TEST")
        // Zero volume, non-finite, and internally-inconsistent OHLC should
        // all be rejected rather than corrupting the accumulators.
        let zeroVolume = makeBar(minutesAfterOpen: 0, open: 10, high: 10, low: 10, close: 10, volume: 0)
        XCTAssertFalse(state.apply(bar: zeroVolume, includePremarket: false))

        let inconsistentHighLow = makeBar(minutesAfterOpen: 0, open: 10, high: 9, low: 10, close: 10, volume: 100)
        XCTAssertFalse(state.apply(bar: inconsistentHighLow, includePremarket: false))

        XCTAssertEqual(state.barsSeen, 0)
        XCTAssertEqual(state.sumVolume, 0)
    }

    func testWrongSymbolBarIsRejected() {
        var state = SymbolState(symbol: "AAPL")
        let bar = makeBar(minutesAfterOpen: 0, open: 10, high: 10, low: 10, close: 10, volume: 100, symbol: "MSFT")
        XCTAssertFalse(state.apply(bar: bar, includePremarket: false))
        XCTAssertEqual(state.barsSeen, 0)
    }

    func testPremarketBarUpdatesLastButNotVWAPUnlessIncluded() {
        var state = SymbolState(symbol: "TEST")
        // 8:00 ET is pre-market (04:00-09:30).
        var components = DateComponents()
        components.year = 2024; components.month = 1; components.day = 16
        components.hour = 8; components.minute = 0
        let premarketDate = MarketClock.calendar.date(from: components)!
        let bar = MinuteBar(symbol: "TEST", timestamp: premarketDate, open: 10, high: 10.2, low: 9.8, close: 10.1, volume: 500, tradeCount: 5, barVWAP: 10)

        let accepted = state.apply(bar: bar, includePremarket: false)

        XCTAssertFalse(accepted, "premarket bar shouldn't count as an accepted regular-session bar when excluded")
        XCTAssertEqual(state.premarketVolume, 500)
        XCTAssertEqual(state.last, 10.1, "last price still updates so the UI isn't blank before the open")
        XCTAssertEqual(state.sumVolume, 0, "premarket volume must never leak into the regular-session VWAP")
    }

    func testVWAPEventRequiresTwoConsecutiveBarsOnTheNewSide() {
        var state = SymbolState(symbol: "TEST")
        // Three bars below VWAP to establish currentSide and clear the
        // barsSeen >= 3 warm-up guard.
        for i in 0..<3 {
            _ = state.apply(bar: makeBar(minutesAfterOpen: i, open: 10, high: 10, low: 9.9, close: 9.9, volume: 100), includePremarket: false)
        }
        XCTAssertEqual(state.currentSide, .belowVWAP)
        XCTAssertEqual(state.lastEvent, .none)

        // One bar back above VWAP — a single wick shouldn't confirm a reclaim.
        _ = state.apply(bar: makeBar(minutesAfterOpen: 3, open: 9.9, high: 10.3, low: 9.9, close: 10.3, volume: 500), includePremarket: false)
        XCTAssertEqual(state.currentSide, .belowVWAP, "single bar above VWAP must not flip the confirmed side yet")
        XCTAssertEqual(state.lastEvent, .none)

        // A second consecutive bar on the new side confirms the reclaim.
        _ = state.apply(bar: makeBar(minutesAfterOpen: 4, open: 10.3, high: 10.5, low: 10.2, close: 10.4, volume: 500), includePremarket: false)
        XCTAssertEqual(state.currentSide, .aboveVWAP)
        XCTAssertEqual(state.lastEvent, .reclaim)
    }

    func testNewTradingDayRollsStateOverRatherThanAccumulating() {
        var state = SymbolState(symbol: "TEST")
        _ = state.apply(bar: makeBar(minutesAfterOpen: 0, open: 10, high: 10, low: 10, close: 10, volume: 1000), includePremarket: false)
        XCTAssertEqual(state.sumVolume, 1000)

        var nextDayComponents = DateComponents()
        nextDayComponents.year = 2024; nextDayComponents.month = 1; nextDayComponents.day = 17
        nextDayComponents.hour = 9; nextDayComponents.minute = 30
        let nextDayOpen = MarketClock.calendar.date(from: nextDayComponents)!
        let nextDayBar = MinuteBar(symbol: "TEST", timestamp: nextDayOpen, open: 20, high: 20, low: 20, close: 20, volume: 300, tradeCount: 3, barVWAP: 20)

        let accepted = state.apply(bar: nextDayBar, includePremarket: false)

        XCTAssertTrue(accepted)
        XCTAssertEqual(state.sumVolume, 300, "a new trading day must reset accumulators rather than carry the prior session's volume forward")
        XCTAssertEqual(state.sessionOpen, 20)
        XCTAssertEqual(state.barsSeen, 1)
    }
}
