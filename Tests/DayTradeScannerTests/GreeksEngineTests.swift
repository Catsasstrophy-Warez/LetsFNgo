import XCTest
import Foundation
@testable import DayTradeScanner

/// Benchmarked against the standard Black-Scholes textbook example (Hull,
/// "Options, Futures, and Other Derivatives"): S=100, K=100, T=1 year,
/// r=5%, sigma=20% gives a call price of ~10.4506 and a put price of
/// ~5.5735. Any correct Black-Scholes implementation reproduces those
/// figures to several decimal places, so they're a stronger check than an
/// arbitrary hand-picked input.
final class GreeksEngineTests: XCTestCase {

    private let textbookCall = GreeksEngine.Inputs(
        spot: 100, strike: 100, timeToExpiryYears: 1,
        riskFreeRate: 0.05, impliedVolatility: 0.20, type: .call
    )
    private let textbookPut = GreeksEngine.Inputs(
        spot: 100, strike: 100, timeToExpiryYears: 1,
        riskFreeRate: 0.05, impliedVolatility: 0.20, type: .put
    )

    func testTextbookCallPrice() throws {
        let price = try XCTUnwrap(GreeksEngine.price(textbookCall))
        XCTAssertEqual(price, 10.4506, accuracy: 0.01)
    }

    func testTextbookPutPrice() throws {
        let price = try XCTUnwrap(GreeksEngine.price(textbookPut))
        XCTAssertEqual(price, 5.5735, accuracy: 0.01)
    }

    /// Put-call parity: C - P = S - K·e^(-rT). This has to hold for any
    /// self-consistent Black-Scholes implementation regardless of the
    /// specific inputs, so it's a good cross-check independent of the
    /// textbook benchmark above.
    func testPutCallParity() throws {
        let call = try XCTUnwrap(GreeksEngine.price(textbookCall))
        let put = try XCTUnwrap(GreeksEngine.price(textbookPut))
        let expected = 100 - 100 * exp(-0.05 * 1.0)
        XCTAssertEqual(call - put, expected, accuracy: 0.005)
    }

    func testCallDeltaIsBoundedZeroToOne() throws {
        let greeks = try XCTUnwrap(GreeksEngine.greeks(textbookCall))
        XCTAssertGreaterThan(greeks.delta, 0)
        XCTAssertLessThan(greeks.delta, 1)
        // Textbook call delta at these inputs is ~0.6368.
        XCTAssertEqual(greeks.delta, 0.6368, accuracy: 0.01)
    }

    func testPutDeltaIsBoundedNegativeOneToZero() throws {
        let greeks = try XCTUnwrap(GreeksEngine.greeks(textbookPut))
        XCTAssertLessThan(greeks.delta, 0)
        XCTAssertGreaterThan(greeks.delta, -1)
        XCTAssertEqual(greeks.delta, -0.3632, accuracy: 0.01)
    }

    func testGammaIsPositiveAndIdenticalForCallAndPut() throws {
        // Gamma is the same for a call and a put at the same strike/expiry —
        // both measure the curvature of the same underlying price sensitivity.
        let callGreeks = try XCTUnwrap(GreeksEngine.greeks(textbookCall))
        let putGreeks = try XCTUnwrap(GreeksEngine.greeks(textbookPut))
        XCTAssertGreaterThan(callGreeks.gamma, 0)
        XCTAssertEqual(callGreeks.gamma, putGreeks.gamma, accuracy: 1e-6)
    }

    func testVegaIsPositiveAndIdenticalForCallAndPut() throws {
        let callGreeks = try XCTUnwrap(GreeksEngine.greeks(textbookCall))
        let putGreeks = try XCTUnwrap(GreeksEngine.greeks(textbookPut))
        XCTAssertGreaterThan(callGreeks.vega, 0)
        XCTAssertEqual(callGreeks.vega, putGreeks.vega, accuracy: 1e-6)
    }

    func testCallThetaIsNegative() throws {
        // Long options decay; a positive theta here would mean the model is
        // paying the holder for the passage of time, which is wrong for any
        // simple long call away from deep, deep ITM with heavy carry.
        let greeks = try XCTUnwrap(GreeksEngine.greeks(textbookCall))
        XCTAssertLessThan(greeks.theta, 0)
    }

    func testZeroTimeCollapsesToIntrinsicValue() {
        let expiredITMCall = GreeksEngine.Inputs(
            spot: 110, strike: 100, timeToExpiryYears: 0,
            impliedVolatility: 0.20, type: .call
        )
        XCTAssertEqual(GreeksEngine.price(expiredITMCall), 10, accuracy: 1e-9)

        let expiredOTMCall = GreeksEngine.Inputs(
            spot: 90, strike: 100, timeToExpiryYears: 0,
            impliedVolatility: 0.20, type: .call
        )
        XCTAssertEqual(GreeksEngine.price(expiredOTMCall), 0, accuracy: 1e-9)

        let expiredITMPut = GreeksEngine.Inputs(
            spot: 90, strike: 100, timeToExpiryYears: 0,
            impliedVolatility: 0.20, type: .put
        )
        XCTAssertEqual(GreeksEngine.price(expiredITMPut), 10, accuracy: 1e-9)
    }

    func testDegenerateInputsReturnNilRatherThanCrashing() {
        let zeroVol = GreeksEngine.Inputs(spot: 100, strike: 100, timeToExpiryYears: 1, impliedVolatility: 0, type: .call)
        XCTAssertNil(GreeksEngine.greeks(zeroVol))

        let zeroSpot = GreeksEngine.Inputs(spot: 0, strike: 100, timeToExpiryYears: 1, impliedVolatility: 0.2, type: .call)
        XCTAssertNil(GreeksEngine.greeks(zeroSpot))
    }

    /// The implied-volatility solver has to be the inverse of `price`: feed
    /// it a price generated at a known volatility, and it should recover
    /// that same volatility.
    func testImpliedVolatilityRoundTrip() throws {
        let knownVol = 0.35
        let inputs = GreeksEngine.Inputs(
            spot: 142.50, strike: 150, timeToExpiryYears: 0.25,
            riskFreeRate: 0.045, impliedVolatility: knownVol, type: .call
        )
        let marketPrice = try XCTUnwrap(GreeksEngine.price(inputs))

        let solved = try XCTUnwrap(GreeksEngine.impliedVolatility(
            marketPrice: marketPrice, spot: inputs.spot, strike: inputs.strike,
            timeToExpiryYears: inputs.timeToExpiryYears, riskFreeRate: inputs.riskFreeRate,
            type: .call
        ))
        XCTAssertEqual(solved, knownVol, accuracy: 0.001)
    }

    func testImpliedVolatilityRoundTripForPut() throws {
        let knownVol = 0.55
        let inputs = GreeksEngine.Inputs(
            spot: 42.0, strike: 38.0, timeToExpiryYears: 0.083,
            riskFreeRate: 0.045, impliedVolatility: knownVol, type: .put
        )
        let marketPrice = try XCTUnwrap(GreeksEngine.price(inputs))

        let solved = try XCTUnwrap(GreeksEngine.impliedVolatility(
            marketPrice: marketPrice, spot: inputs.spot, strike: inputs.strike,
            timeToExpiryYears: inputs.timeToExpiryYears, riskFreeRate: inputs.riskFreeRate,
            type: .put
        ))
        XCTAssertEqual(solved, knownVol, accuracy: 0.001)
    }

    func testImpliedVolatilityReturnsNilForNonsensicalInputs() {
        XCTAssertNil(GreeksEngine.impliedVolatility(
            marketPrice: -5, spot: 100, strike: 100, timeToExpiryYears: 1, type: .call
        ))
        XCTAssertNil(GreeksEngine.impliedVolatility(
            marketPrice: 5, spot: 100, strike: 100, timeToExpiryYears: 0, type: .call
        ))
    }
}
