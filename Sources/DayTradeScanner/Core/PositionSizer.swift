import Foundation

/// Whole-share sizing constrained by estimated stop risk and available capital.
struct PositionSizer {
    struct Input {
        var accountEquity: Double
        var riskPercent: Double        // e.g. 0.01 for 1%
        var entryPrice: Double
        var stopPrice: Double
        var direction: TradeDirection
        var buyingPower: Double? = nil
        var maxAllocationPercent: Double = 1
        var slippagePerShare: Double = 0
        var roundTripFee: Double = 0
        var targetPrice: Double? = nil
    }

    struct Result {
        let actualRisk: Double
        let unusedRisk: Double
        let capitalLimit: Double
        let isCapitalLimited: Bool
        let targetProfit: Double?
        let rewardRiskRatio: Double?
        let isTargetOnWrongSide: Bool
        let dollarRisk: Double
        let riskPerShare: Double
        let shares: Int
        let positionValue: Double
        /// Position value as a share of account equity — flags a stop so
        /// tight that the "1% risk" position would exceed the account's
        /// actual buying power, which a naive risk-per-share formula alone
        /// won't catch.
        let percentOfAccount: Double
        let isStopTooTight: Bool
        let isStopOnWrongSide: Bool
    }

    /// Returns nil for invalid or unrepresentable inputs. Invalid stop direction
    /// produces zero shares with a diagnostic flag.
    static func calculate(_ input: Input) -> Result? {
        let values = [input.accountEquity, input.entryPrice, input.stopPrice,
                      input.riskPercent, input.maxAllocationPercent,
                      input.slippagePerShare, input.roundTripFee]
        guard values.allSatisfy({ $0.isFinite }),
              input.accountEquity > 0, input.entryPrice > 0, input.stopPrice > 0,
              input.riskPercent > 0, input.riskPercent <= 1,
              input.maxAllocationPercent > 0, input.maxAllocationPercent <= 1,
              input.slippagePerShare >= 0, input.roundTripFee >= 0 else { return nil }
        if let power = input.buyingPower, !power.isFinite || power < 0 { return nil }
        if let target = input.targetPrice, !target.isFinite || target <= 0 { return nil }

        let isWrongSide = input.direction == .long
            ? input.stopPrice >= input.entryPrice : input.stopPrice <= input.entryPrice
        let distance = abs(input.entryPrice - input.stopPrice)
        // Slippage is the combined adverse entry/exit allowance per share.
        let riskPerShare = distance + input.slippagePerShare
        let dollarRisk = input.accountEquity * input.riskPercent
        let capitalLimit = min(input.buyingPower ?? input.accountEquity,
                               input.accountEquity * input.maxAllocationPercent)
        let riskShares = riskPerShare > 0
            ? floor(max(0, dollarRisk - input.roundTripFee) / riskPerShare) : 0
        let capitalShares = floor(max(0, capitalLimit - input.roundTripFee)
                                  / (input.entryPrice + input.slippagePerShare))
        let count = isWrongSide ? 0 : min(riskShares, capitalShares)
        guard count.isFinite, count >= 0, count < Double(Int.max) else { return nil }
        let shares = Int(count)
        let positionValue = Double(shares) * input.entryPrice
        let actualRisk = shares > 0 ? Double(shares) * riskPerShare + input.roundTripFee : 0
        let targetDistance = input.targetPrice.map {
            input.direction == .long ? $0 - input.entryPrice : input.entryPrice - $0
        }
        let wrongTarget = targetDistance.map { $0 <= 0 } ?? false
        let profit: Double? = targetDistance.flatMap { distance in
            guard !wrongTarget, shares > 0 else { return nil }
            return Double(shares) * (distance - input.slippagePerShare) - input.roundTripFee
        }
        return Result(
            actualRisk: actualRisk, unusedRisk: max(0, dollarRisk - actualRisk),
            capitalLimit: capitalLimit, isCapitalLimited: !isWrongSide && capitalShares < riskShares,
            targetProfit: profit, rewardRiskRatio: profit.flatMap { actualRisk > 0 ? $0 / actualRisk : nil },
            isTargetOnWrongSide: wrongTarget,
            dollarRisk: dollarRisk, riskPerShare: riskPerShare, shares: shares,
            positionValue: positionValue, percentOfAccount: positionValue / input.accountEquity,
            isStopTooTight: distance / input.entryPrice < 0.0015,
            isStopOnWrongSide: isWrongSide
        )
    }

    /// A stop derived from ATR, for when the person hasn't picked one yet.
    /// 1.5 ATR is a common day-trade default — tight enough to matter, wide
    /// enough to survive normal noise.
    static func suggestedStop(entry: Double, atr: Double, direction: TradeDirection, multiple: Double = 1.5) -> Double {
        switch direction {
        case .long: return entry - (atr * multiple)
        case .short: return entry + (atr * multiple)
        }
    }
}
