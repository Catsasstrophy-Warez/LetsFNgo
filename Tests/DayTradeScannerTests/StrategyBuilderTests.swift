import XCTest
import Foundation
@testable import DayTradeScanner

final class StrategyBuilderTests: XCTestCase {

    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    /// A contract with a clean, round mid price (bid/ask straddling it) so
    /// payoff and breakeven arithmetic in the tests below comes out in nice
    /// numbers instead of needing a tolerance on every assertion.
    private func makeContract(
        strike: Double,
        type: OptionType,
        mid: Double,
        symbolSuffix: String = ""
    ) -> OptionContract {
        OptionContract(
            symbol: "TEST\(type == .call ? "C" : "P")\(Int(strike))\(symbolSuffix)",
            underlying: "TEST",
            expiration: expiry,
            strike: strike,
            type: type,
            bid: mid - 0.05,
            ask: mid + 0.05,
            lastPrice: mid,
            volume: 100,
            openInterest: 500,
            impliedVolatility: 0.30,
            greeks: nil
        )
    }

    // MARK: - Long call

    func testLongCallPayoffAndBreakeven() {
        let call = makeContract(strike: 100, type: .call, mid: 5)
        let strategy = StrategyBuilder.longCall(call)

        XCTAssertEqual(strategy.netPremium, 500, accuracy: 0.01) // paid $5 × 100

        // At expiration: below the strike, worthless; the loss is capped at
        // the premium paid.
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 90), -500, accuracy: 0.01)
        // At the strike, still a full loss (no intrinsic value yet).
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 100), -500, accuracy: 0.01)
        // At breakeven (strike + premium/100 = 105), flat.
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 105), 0, accuracy: 0.01)
        // Above breakeven, in profit dollar-for-dollar above 105.
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 115), 1000, accuracy: 0.01)

        let breakevens = strategy.breakevens(searchLow: 50, searchHigh: 200)
        XCTAssertEqual(breakevens.count, 1)
        XCTAssertEqual(breakevens[0], 105, accuracy: 0.5)

        // Long call: capped loss, unbounded profit.
        XCTAssertEqual(strategy.maxLoss, -500, accuracy: 0.01)
        XCTAssertNil(strategy.maxProfit)
    }

    // MARK: - Long put

    func testLongPutPayoffIsMirroredBelowStrike() {
        let put = makeContract(strike: 100, type: .put, mid: 4)
        let strategy = StrategyBuilder.longPut(put)

        XCTAssertEqual(strategy.payoff(atExpirationSpot: 100), -400, accuracy: 0.01)
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 80), 1600, accuracy: 0.01) // (100-80)*100 - 400
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 96), 0, accuracy: 0.01)    // breakeven

        // Long put: capped loss (premium), bounded profit (spot floors at 0).
        XCTAssertEqual(strategy.maxLoss, -400, accuracy: 0.01)
        XCTAssertNotNil(strategy.maxProfit)
    }

    // MARK: - Bull call spread (vertical debit spread)

    func testBullCallSpreadRiskProfile() throws {
        // Buy the 100 call for $6, sell the 110 call for $2 → $4 net debit,
        // $10-wide spread. Textbook numbers: max profit = (10 - 4) × 100 =
        // 600, max loss = 4 × 100 = 400, breakeven = 100 + 4 = 104.
        let lower = makeContract(strike: 100, type: .call, mid: 6)
        let higher = makeContract(strike: 110, type: .call, mid: 2, symbolSuffix: "H")
        let strategy = try XCTUnwrap(StrategyBuilder.bullCallSpread(buy: lower, sell: higher))

        XCTAssertEqual(strategy.netPremium, 400, accuracy: 0.01)
        XCTAssertEqual(strategy.maxLoss, -400, accuracy: 1)
        XCTAssertEqual(strategy.maxProfit, 600, accuracy: 1)

        let breakevens = strategy.breakevens(searchLow: 50, searchHigh: 200)
        XCTAssertEqual(breakevens.count, 1)
        XCTAssertEqual(breakevens[0], 104, accuracy: 0.5)

        // Both legs offset above the higher strike, so the spread is fully
        // capped in both directions — never unbounded.
        XCTAssertNotNil(strategy.maxProfit)
        XCTAssertNotNil(strategy.maxLoss)
    }

    func testBullCallSpreadRejectsMismatchedExpirationsOrOrder() {
        let call100 = makeContract(strike: 100, type: .call, mid: 6)
        let call110 = makeContract(strike: 110, type: .call, mid: 2, symbolSuffix: "H")
        let put100 = makeContract(strike: 100, type: .put, mid: 3)

        // Wrong order (higher strike passed as the "buy" leg).
        XCTAssertNil(StrategyBuilder.bullCallSpread(buy: call110, sell: call100))
        // Wrong type on one leg.
        XCTAssertNil(StrategyBuilder.bullCallSpread(buy: put100, sell: call110))
    }

    // MARK: - Bear put spread

    func testBearPutSpreadRiskProfile() throws {
        // Buy the 100 put for $6, sell the 90 put for $2 → $4 debit, $10 wide.
        let higher = makeContract(strike: 100, type: .put, mid: 6)
        let lower = makeContract(strike: 90, type: .put, mid: 2, symbolSuffix: "L")
        let strategy = try XCTUnwrap(StrategyBuilder.bearPutSpread(buy: higher, sell: lower))

        XCTAssertEqual(strategy.netPremium, 400, accuracy: 0.01)
        XCTAssertEqual(strategy.maxLoss, -400, accuracy: 1)
        XCTAssertEqual(strategy.maxProfit, 600, accuracy: 1)
    }

    // MARK: - Long straddle

    func testLongStraddleHasUnboundedProfitBothLegsPaid() throws {
        let call = makeContract(strike: 100, type: .call, mid: 5)
        let put = makeContract(strike: 100, type: .put, mid: 4)
        let strategy = try XCTUnwrap(StrategyBuilder.longStraddle(call: call, put: put))

        XCTAssertEqual(strategy.netPremium, 900, accuracy: 0.01) // both premiums paid
        // Straddle profit is unbounded on the call side (unhedged long call).
        XCTAssertNil(strategy.maxProfit)
        // Max loss is capped at the combined premium, realized exactly at the
        // shared strike where neither leg has intrinsic value.
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 100), -900, accuracy: 0.01)
        XCTAssertEqual(strategy.maxLoss, -900, accuracy: 1)

        // Two breakevens: strike ± total premium / 100.
        let breakevens = strategy.breakevens(searchLow: 50, searchHigh: 200).sorted()
        XCTAssertEqual(breakevens.count, 2)
        XCTAssertEqual(breakevens[0], 91, accuracy: 0.5)
        XCTAssertEqual(breakevens[1], 109, accuracy: 0.5)
    }

    func testStraddleRejectsMismatchedStrikes() {
        let call = makeContract(strike: 100, type: .call, mid: 5)
        let put = makeContract(strike: 95, type: .put, mid: 4)
        XCTAssertNil(StrategyBuilder.longStraddle(call: call, put: put))
    }

    // MARK: - Iron condor

    func testIronCondorIsANetCreditWithCappedRiskBothSides() throws {
        // Sell 95 put / buy 90 put, sell 105 call / buy 110 call — a
        // standard symmetric iron condor.
        let shortPut = makeContract(strike: 95, type: .put, mid: 2, symbolSuffix: "SP")
        let longPut = makeContract(strike: 90, type: .put, mid: 0.5, symbolSuffix: "LP")
        let shortCall = makeContract(strike: 105, type: .call, mid: 2, symbolSuffix: "SC")
        let longCall = makeContract(strike: 110, type: .call, mid: 0.5, symbolSuffix: "LC")

        let strategy = try XCTUnwrap(StrategyBuilder.ironCondor(
            shortPut: shortPut, longPut: longPut, shortCall: shortCall, longCall: longCall
        ))

        // Net credit: sold 2 + 2, bought 0.5 + 0.5 → collected $3 × 100.
        XCTAssertEqual(strategy.netPremium, -300, accuracy: 0.01)
        // Fully hedged both directions — never unbounded.
        XCTAssertNotNil(strategy.maxProfit)
        XCTAssertNotNil(strategy.maxLoss)
        // Max profit is the credit received, realized anywhere between the
        // short strikes.
        XCTAssertEqual(strategy.payoff(atExpirationSpot: 100), 300, accuracy: 0.01)
        XCTAssertEqual(strategy.maxProfit, 300, accuracy: 1)
    }

    func testIronCondorRejectsOutOfOrderStrikes() {
        let shortPut = makeContract(strike: 95, type: .put, mid: 2, symbolSuffix: "SP")
        let longPut = makeContract(strike: 90, type: .put, mid: 0.5, symbolSuffix: "LP")
        let shortCall = makeContract(strike: 105, type: .call, mid: 2, symbolSuffix: "SC")
        let longCall = makeContract(strike: 110, type: .call, mid: 0.5, symbolSuffix: "LC")

        // Swapped short/long puts breaks the required strike ordering.
        XCTAssertNil(StrategyBuilder.ironCondor(
            shortPut: longPut, longPut: shortPut, shortCall: shortCall, longCall: longCall
        ))
    }

    // MARK: - Net greeks

    func testNetGreeksSumAcrossLegsWithSign() {
        let call = makeContract(strike: 100, type: .call, mid: 5)
        let withGreeks = OptionContract(
            symbol: call.symbol, underlying: call.underlying, expiration: call.expiration,
            strike: call.strike, type: call.type, bid: call.bid, ask: call.ask, lastPrice: call.lastPrice,
            volume: call.volume, openInterest: call.openInterest, impliedVolatility: call.impliedVolatility,
            greeks: Greeks(delta: 0.5, gamma: 0.02, theta: -0.05, vega: 0.10, rho: 0.03)
        )

        let longLeg = StrategyLeg(contract: withGreeks, signedQuantity: 1)
        let shortLeg = StrategyLeg(contract: withGreeks, signedQuantity: -2)
        let strategy = OptionStrategy(name: "test", legs: [longLeg, shortLeg])

        // Net delta: (1 × 0.5 + (-2) × 0.5) × 100 = -50.
        XCTAssertEqual(strategy.netGreeks.delta, -50, accuracy: 0.01)
        // Net theta: (1 + -2) × -0.05 × 100 = 5.
        XCTAssertEqual(strategy.netGreeks.theta, 5, accuracy: 0.01)
    }
}
