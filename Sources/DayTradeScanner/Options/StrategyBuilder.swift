import Foundation

/// A single leg of a multi-leg strategy: buy or sell one contract, some
/// quantity of it.
struct StrategyLeg: Identifiable, Hashable, Sendable {
    var id: String { contract.symbol + (isLong ? "-long" : "-short") }
    let contract: OptionContract
    /// Positive = bought, negative = sold. Kept as a signed multiplier rather
    /// than a separate quantity + direction pair, since every payoff and
    /// greeks calculation below wants exactly that sign.
    let signedQuantity: Int

    var isLong: Bool { signedQuantity > 0 }

    /// Premium paid (positive) or received (negative) for this leg, using
    /// mid price. Real fills pay the spread; this is the planning number.
    var premium: Double {
        (contract.mid ?? 0) * Double(signedQuantity) * 100
    }
}

/// A named combination of legs, plus the derived risk shape that makes the
/// combination worth naming in the first place.
struct OptionStrategy: Identifiable, Sendable {
    var id: String { legs.map(\.id).joined(separator: "+") }
    let name: String
    let legs: [StrategyLeg]

    /// Net premium: negative means a net debit (you pay to open), positive
    /// means a net credit (you're paid to open).
    var netPremium: Double {
        legs.reduce(0) { $0 + $1.premium }
    }

    /// Portfolio greeks: each leg's per-contract greek, scaled by its signed
    /// quantity and the 100-share multiplier, summed.
    var netGreeks: Greeks {
        legs.reduce(Greeks.zero) { total, leg in
            guard let g = leg.contract.greeks else { return total }
            let scale = Double(leg.signedQuantity) * 100
            return Greeks(
                delta: total.delta + g.delta * scale,
                gamma: total.gamma + g.gamma * scale,
                theta: total.theta + g.theta * scale,
                vega: total.vega + g.vega * scale,
                rho: total.rho + g.rho * scale
            )
        }
    }

    /// Profit or loss at expiration for a given underlying price — pure
    /// intrinsic value per leg (options at expiry have no time value left),
    /// scaled by quantity, net of what was paid or received to open.
    func payoff(atExpirationSpot spot: Double) -> Double {
        let intrinsic = legs.reduce(0.0) { total, leg in
            let contractIntrinsic: Double
            switch leg.contract.type {
            case .call: contractIntrinsic = max(0, spot - leg.contract.strike)
            case .put: contractIntrinsic = max(0, leg.contract.strike - spot)
            }
            return total + contractIntrinsic * Double(leg.signedQuantity) * 100
        }
        return intrinsic + netPremium
    }

    /// Samples the payoff curve across a price range for charting. 61 points
    /// is enough resolution for a smooth line at any reasonable chart width
    /// without oversampling a piecewise-linear function.
    func payoffCurve(from low: Double, to high: Double, steps: Int = 60) -> [(spot: Double, pnl: Double)] {
        guard high > low, steps > 0 else { return [] }
        let step = (high - low) / Double(steps)
        return (0...steps).map { i in
            let spot = low + Double(i) * step
            return (spot, payoff(atExpirationSpot: spot))
        }
    }

    /// Breakevens: where the payoff curve crosses zero. Found by scanning a
    /// wide sampled range for sign changes and linearly interpolating within
    /// each — payoff is piecewise-linear in spot at expiration, so this is
    /// exact up to sampling resolution, not an approximation of a curve.
    func breakevens(searchLow: Double, searchHigh: Double) -> [Double] {
        let curve = payoffCurve(from: searchLow, to: searchHigh, steps: 400)
        var crossings: [Double] = []
        for i in 1..<curve.count {
            let (s0, p0) = curve[i - 1]
            let (s1, p1) = curve[i]
            if p0 == 0 { crossings.append(s0); continue }
            if (p0 < 0 && p1 > 0) || (p0 > 0 && p1 < 0) {
                let t = -p0 / (p1 - p0)
                crossings.append(s0 + t * (s1 - s0))
            }
        }
        return crossings
    }

    /// Nil means unbounded in that direction (e.g. a naked short call's loss,
    /// or a long call's profit above the highest strike).
    var maxProfit: Double? {
        let wide = legs.map(\.contract.strike)
        guard let lowStrike = wide.min(), let highStrike = wide.max() else { return nil }
        let span = max(highStrike - lowStrike, 10)
        let sampled = payoffCurve(from: max(0.01, lowStrike - span), to: highStrike + span)
        guard let best = sampled.map(\.pnl).max() else { return nil }
        // Profit still rising at the sampled edges means it's unbounded.
        let atLowEdge = sampled.first?.pnl ?? 0
        let atHighEdge = sampled.last?.pnl ?? 0
        if atHighEdge >= best - 0.01, hasUnhedgedLongCall { return nil }
        if atLowEdge >= best - 0.01, hasUnhedgedLongPut { return nil }
        return best
    }

    var maxLoss: Double? {
        let wide = legs.map(\.contract.strike)
        guard let lowStrike = wide.min(), let highStrike = wide.max() else { return nil }
        let span = max(highStrike - lowStrike, 10)
        let sampled = payoffCurve(from: max(0.01, lowStrike - span), to: highStrike + span)
        guard let worst = sampled.map(\.pnl).min() else { return nil }
        let atLowEdge = sampled.first?.pnl ?? 0
        let atHighEdge = sampled.last?.pnl ?? 0
        if atHighEdge <= worst + 0.01, hasUnhedgedShortCall { return nil }
        if atLowEdge <= worst + 0.01, hasUnhedgedShortPut { return nil }
        return worst
    }

    private var hasUnhedgedLongCall: Bool {
        legs.contains { $0.contract.type == .call && $0.isLong } && !isFullyHedgedAbove
    }
    private var hasUnhedgedShortCall: Bool {
        legs.contains { $0.contract.type == .call && !$0.isLong } && !isFullyHedgedAbove
    }
    private var hasUnhedgedLongPut: Bool {
        legs.contains { $0.contract.type == .put && $0.isLong } && !isFullyHedgedBelow
    }
    private var hasUnhedgedShortPut: Bool {
        legs.contains { $0.contract.type == .put && !$0.isLong } && !isFullyHedgedBelow
    }
    /// Net call quantity across all legs settles to zero far above every
    /// strike, meaning upside is capped by an offsetting leg (a spread).
    private var isFullyHedgedAbove: Bool {
        legs.filter { $0.contract.type == .call }.reduce(0) { $0 + $1.signedQuantity } == 0
    }
    private var isFullyHedgedBelow: Bool {
        legs.filter { $0.contract.type == .put }.reduce(0) { $0 + $1.signedQuantity } == 0
    }

    /// Rough probability of profit at expiration, using each leg's own delta
    /// as a stand-in for "probability this leg finishes ITM" — the same
    /// approximation every retail options platform uses, not a rigorous
    /// distributional estimate. Only meaningful for simple, single-breakeven
    /// shapes (a long/short single, or a two-leg spread); returns nil rather
    /// than a misleading number for anything wider.
    var approximateProbabilityOfProfit: Double? {
        guard legs.count <= 2 else { return nil }
        guard let primary = legs.first, let delta = primary.contract.greeks?.delta else { return nil }
        // A long call/put profits below/above its breakeven with probability
        // related to (1 - |delta|) at the strike vs. at the breakeven; as a
        // first-order approximation, use the OTM probability implied by delta
        // directly, which is the standard retail shorthand.
        switch (primary.contract.type, primary.isLong) {
        case (.call, true): return 1 - abs(delta)
        case (.call, false): return abs(delta)
        case (.put, true): return 1 - abs(delta)
        case (.put, false): return abs(delta)
        }
    }
}

/// Builds the standard named strategies from a chain, centered on a chosen
/// expiration and (where relevant) width. Every builder returns nil rather
/// than a malformed strategy when the chain is missing a needed strike.
enum StrategyBuilder {

    static func longCall(_ contract: OptionContract) -> OptionStrategy {
        OptionStrategy(name: "Long call", legs: [StrategyLeg(contract: contract, signedQuantity: 1)])
    }

    static func longPut(_ contract: OptionContract) -> OptionStrategy {
        OptionStrategy(name: "Long put", legs: [StrategyLeg(contract: contract, signedQuantity: 1)])
    }

    static func coveredCall(_ shortCall: OptionContract) -> OptionStrategy {
        // Share ownership isn't modeled as a leg here — the strategy tab
        // shows the option side only and notes the assumed 100-share hold
        // separately, since a leg with no `OptionContract` doesn't fit this
        // model without a synthetic contract.
        OptionStrategy(name: "Covered call (option leg)", legs: [StrategyLeg(contract: shortCall, signedQuantity: -1)])
    }

    static func cashSecuredPut(_ shortPut: OptionContract) -> OptionStrategy {
        OptionStrategy(name: "Cash-secured put", legs: [StrategyLeg(contract: shortPut, signedQuantity: -1)])
    }

    /// Bull call spread: buy the lower strike, sell the higher, same
    /// expiration. Debit strategy — caps both cost and upside.
    static func bullCallSpread(buy lower: OptionContract, sell higher: OptionContract) -> OptionStrategy? {
        guard lower.type == .call, higher.type == .call, lower.strike < higher.strike,
              lower.expiration == higher.expiration else { return nil }
        return OptionStrategy(
            name: "Bull call spread",
            legs: [
                StrategyLeg(contract: lower, signedQuantity: 1),
                StrategyLeg(contract: higher, signedQuantity: -1)
            ]
        )
    }

    /// Bear put spread: buy the higher strike, sell the lower.
    static func bearPutSpread(buy higher: OptionContract, sell lower: OptionContract) -> OptionStrategy? {
        guard higher.type == .put, lower.type == .put, higher.strike > lower.strike,
              higher.expiration == lower.expiration else { return nil }
        return OptionStrategy(
            name: "Bear put spread",
            legs: [
                StrategyLeg(contract: higher, signedQuantity: 1),
                StrategyLeg(contract: lower, signedQuantity: -1)
            ]
        )
    }

    static func longStraddle(call: OptionContract, put: OptionContract) -> OptionStrategy? {
        guard call.type == .call, put.type == .put,
              call.strike == put.strike, call.expiration == put.expiration else { return nil }
        return OptionStrategy(
            name: "Long straddle",
            legs: [
                StrategyLeg(contract: call, signedQuantity: 1),
                StrategyLeg(contract: put, signedQuantity: 1)
            ]
        )
    }

    static func longStrangle(call: OptionContract, put: OptionContract) -> OptionStrategy? {
        guard call.type == .call, put.type == .put, call.strike > put.strike,
              call.expiration == put.expiration else { return nil }
        return OptionStrategy(
            name: "Long strangle",
            legs: [
                StrategyLeg(contract: call, signedQuantity: 1),
                StrategyLeg(contract: put, signedQuantity: 1)
            ]
        )
    }

    /// Iron condor: sell a call spread above the money and a put spread
    /// below it, same expiration on all four legs. A net-credit, range-bound
    /// strategy — the chain's four nearest strikes bracketing a target width
    /// are the typical construction, chosen by the caller.
    static func ironCondor(
        shortPut: OptionContract, longPut: OptionContract,
        shortCall: OptionContract, longCall: OptionContract
    ) -> OptionStrategy? {
        let expiry = shortPut.expiration
        guard shortPut.type == .put, longPut.type == .put,
              shortCall.type == .call, longCall.type == .call,
              longPut.strike < shortPut.strike, shortPut.strike < shortCall.strike, shortCall.strike < longCall.strike,
              [longPut, shortCall, longCall].allSatisfy({ $0.expiration == expiry }) else { return nil }
        return OptionStrategy(
            name: "Iron condor",
            legs: [
                StrategyLeg(contract: shortPut, signedQuantity: -1),
                StrategyLeg(contract: longPut, signedQuantity: 1),
                StrategyLeg(contract: shortCall, signedQuantity: -1),
                StrategyLeg(contract: longCall, signedQuantity: 1)
            ]
        )
    }
}
