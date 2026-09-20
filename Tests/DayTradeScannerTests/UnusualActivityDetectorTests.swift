import XCTest
import Foundation
@testable import DayTradeScanner

final class UnusualActivityDetectorTests: XCTestCase {

    private let expiry = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
    private let farExpiry = Calendar.current.date(byAdding: .day, value: 45, to: Date())!

    private func makeContract(
        volume: Int?,
        openInterest: Int?,
        bid: Double? = 1.95,
        ask: Double? = 2.05,
        expiration: Date? = nil
    ) -> OptionContract {
        OptionContract(
            symbol: "TESTC100",
            underlying: "TEST",
            expiration: expiration ?? expiry,
            strike: 100,
            type: .call,
            bid: bid, ask: ask, lastPrice: 2.0,
            volume: volume, openInterest: openInterest,
            impliedVolatility: 0.4, greeks: nil
        )
    }

    func testNoVolumeYieldsNoSignal() {
        let contract = makeContract(volume: nil, openInterest: 500)
        XCTAssertNil(UnusualActivityDetector.evaluate(contract, recentVolumes: nil))

        let zeroVolume = makeContract(volume: 0, openInterest: 500)
        XCTAssertNil(UnusualActivityDetector.evaluate(zeroVolume, recentVolumes: nil))
    }

    func testOrdinaryVolumeBelowOpenInterestYieldsNoSignal() {
        // Volume well under open interest, no history, small notional,
        // longer-dated — nothing here should look unusual.
        let contract = makeContract(volume: 50, openInterest: 5000, expiration: farExpiry)
        XCTAssertNil(UnusualActivityDetector.evaluate(contract, recentVolumes: nil))
    }

    func testHighVolumeToOpenInterestRatioScoresAndExplainsWhy() throws {
        // 3,000 volume against 500 open interest is a 6x ratio — squarely in
        // the "fresh positioning" band the detector is built to catch.
        let contract = makeContract(volume: 3000, openInterest: 500, expiration: farExpiry)
        let signal = try XCTUnwrap(UnusualActivityDetector.evaluate(contract, recentVolumes: nil))

        XCTAssertGreaterThan(signal.score, 0)
        XCTAssertLessThanOrEqual(signal.score, 1.0)
        XCTAssertTrue(signal.reasons.contains { $0.contains("volume vs open interest") })
    }

    func testModerateRatioScoresLessThanExtremeRatio() throws {
        let moderate = makeContract(volume: 600, openInterest: 500, expiration: farExpiry)   // 1.2x
        let extreme = makeContract(volume: 5000, openInterest: 500, expiration: farExpiry)    // 10x

        let moderateSignal = try XCTUnwrap(UnusualActivityDetector.evaluate(moderate, recentVolumes: nil))
        let extremeSignal = try XCTUnwrap(UnusualActivityDetector.evaluate(extreme, recentVolumes: nil))

        XCTAssertLessThan(moderateSignal.score, extremeSignal.score)
    }

    func testSurgeAgainstOwnRecentHistoryContributesEvenWithModerateOIRatio() throws {
        let now = Date()
        // Five days of quiet volume, then today's print is a clear surge —
        // this should register even though volume/OI alone isn't extreme.
        let history: [(date: Date, volume: Int)] = [
            (now.addingTimeInterval(-4 * 86400), 40),
            (now.addingTimeInterval(-3 * 86400), 35),
            (now.addingTimeInterval(-2 * 86400), 45),
            (now.addingTimeInterval(-1 * 86400), 38),
            (now, 400)
        ]
        let contract = makeContract(volume: 400, openInterest: 2000, expiration: farExpiry)
        let signal = try XCTUnwrap(UnusualActivityDetector.evaluate(contract, recentVolumes: history))

        XCTAssertTrue(signal.reasons.contains { $0.contains("recent pace") })
    }

    func testShortHistoryIsIgnoredRatherThanMisread() {
        // Fewer than 3 samples shouldn't be trusted as a baseline. Paired
        // with an otherwise unremarkable contract (low OI ratio, small
        // notional, longer-dated), the history being ignored means nothing
        // else fires either, so the whole evaluation comes back nil.
        let history: [(date: Date, volume: Int)] = [(Date(), 40), (Date(), 400)]
        let contract = makeContract(volume: 400, openInterest: 2000, expiration: farExpiry)
        XCTAssertNil(UnusualActivityDetector.evaluate(contract, recentVolumes: history))
    }

    func testLargeNotionalContributesToScore() throws {
        // High mid price × high volume = large dollar notional even at a
        // modest volume/OI ratio.
        let contract = makeContract(volume: 600, openInterest: 500, bid: 19.5, ask: 20.5, expiration: farExpiry)
        let signal = try XCTUnwrap(UnusualActivityDetector.evaluate(contract, recentVolumes: nil))
        XCTAssertTrue(signal.reasons.contains { $0.contains("notional") })
    }

    func testShortDatedContractAddsAReason() throws {
        let contract = makeContract(volume: 3000, openInterest: 500, expiration: expiry) // 5 days out
        let signal = try XCTUnwrap(UnusualActivityDetector.evaluate(contract, recentVolumes: nil))
        XCTAssertTrue(signal.reasons.contains { $0.contains("d to expiration") })
    }

    func testScoreIsClampedToOne() throws {
        // Stack every contributing factor to the extreme to make sure the
        // final score never exceeds the documented 0...1 range.
        let contract = makeContract(volume: 50000, openInterest: 100, bid: 49.5, ask: 50.5, expiration: expiry)
        let signal = try XCTUnwrap(UnusualActivityDetector.evaluate(contract, recentVolumes: nil))
        XCTAssertLessThanOrEqual(signal.score, 1.0)
    }

    // MARK: - scan()

    func testScanSortsDescendingByScore() {
        let quiet = makeContract(volume: 60, openInterest: 5000, expiration: farExpiry)
        let loud = OptionContract(
            symbol: "TESTC200", underlying: "TEST", expiration: expiry, strike: 200, type: .call,
            bid: 4.95, ask: 5.05, lastPrice: 5.0, volume: 8000, openInterest: 400,
            impliedVolatility: 0.6, greeks: nil
        )
        let chain = OptionChain(underlying: "TEST", spotPrice: 150, asOf: Date(), contracts: [quiet, loud])

        let signals = UnusualActivityDetector.scan(chains: ["TEST": chain], history: [:])

        // The quiet contract shouldn't even qualify; the loud one should be
        // first (and only) in a descending-sorted result.
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.contract.symbol, "TESTC200")
    }

    func testScanAcrossMultipleChainsOrdersGlobally() {
        let makeLoud: (String, Int, Int) -> OptionContract = { symbol, volume, oi in
            OptionContract(
                symbol: symbol, underlying: "X", expiration: self.farExpiry, strike: 100, type: .call,
                bid: 1.95, ask: 2.05, lastPrice: 2.0, volume: volume, openInterest: oi,
                impliedVolatility: 0.4, greeks: nil
            )
        }
        let moderate = makeLoud("A", 1000, 500)   // 2x
        let extreme = makeLoud("B", 5000, 500)    // 10x

        let chainA = OptionChain(underlying: "A", spotPrice: 100, asOf: Date(), contracts: [moderate])
        let chainB = OptionChain(underlying: "B", spotPrice: 100, asOf: Date(), contracts: [extreme])

        let signals = UnusualActivityDetector.scan(chains: ["A": chainA, "B": chainB], history: [:])

        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals.first?.contract.symbol, "B")
        XCTAssertGreaterThanOrEqual(signals[0].score, signals[1].score)
    }
}
