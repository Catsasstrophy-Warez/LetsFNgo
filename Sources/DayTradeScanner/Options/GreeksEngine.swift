import Foundation

/// Black-Scholes pricing and greeks, computed locally.
///
/// This exists for two reasons a live quote feed can't cover on its own:
/// 1. **Fallback.** Not every contract snapshot includes server-computed
///    greeks (thin names, momentary gaps), and a chain row with a blank
///    delta column is worse than an approximate one.
/// 2. **What-if pricing.** The strategy builder needs to reprice a leg under
///    a moved spot, a different IV, or fewer days to expiry without a round
///    trip to the data provider — that's the entire mechanism behind a
///    payoff diagram.
///
/// European-style Black-Scholes is used throughout rather than an American
/// binomial tree. Nearly all single-name US equity options are technically
/// American (early-exercise eligible), but the early-exercise premium is
/// negligible for the non-dividend-paying, reasonably liquid names this app
/// already screens for — and a closed-form model is fast enough to reprice
/// an entire chain on every UI interaction, which a tree is not.
enum GreeksEngine {

    /// Standard normal PDF.
    private static func phi(_ x: Double) -> Double {
        exp(-0.5 * x * x) / (2 * Double.pi).squareRoot()
    }

    /// Standard normal CDF via the Abramowitz-Stegun approximation — accurate
    /// to ~1e-7, which is far tighter than the pricing inputs (a quoted IV)
    /// ever justify.
    private static func normalCDF(_ x: Double) -> Double {
        let b1 = 0.319381530, b2 = -0.356563782, b3 = 1.781477937
        let b4 = -1.821255978, b5 = 1.330274429, p = 0.2316419
        let sign: Double = x < 0 ? -1 : 1
        let ax = abs(x)
        let t = 1 / (1 + p * ax)
        let poly = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))))
        let cdf = 1 - phi(ax) * poly
        return 0.5 + sign * (cdf - 0.5)
    }

    struct Inputs: Sendable {
        var spot: Double
        var strike: Double
        /// Years to expiration, e.g. 30 days ≈ 0.0822.
        var timeToExpiryYears: Double
        var riskFreeRate: Double = 0.045
        var impliedVolatility: Double
        var type: OptionType
    }

    private static func d1d2(_ i: Inputs) -> (d1: Double, d2: Double)? {
        guard i.spot > 0, i.strike > 0, i.timeToExpiryYears > 0, i.impliedVolatility > 0 else { return nil }
        let sigmaSqrtT = i.impliedVolatility * i.timeToExpiryYears.squareRoot()
        guard sigmaSqrtT > 0 else { return nil }
        let d1 = (log(i.spot / i.strike) + (i.riskFreeRate + 0.5 * i.impliedVolatility * i.impliedVolatility) * i.timeToExpiryYears) / sigmaSqrtT
        let d2 = d1 - sigmaSqrtT
        return (d1, d2)
    }

    /// Theoretical price. Nil for an expired or degenerate input (zero time,
    /// zero vol) rather than a divide-by-zero crash — those cases are common
    /// at expiration and the caller should treat them as "no model price".
    static func price(_ i: Inputs) -> Double? {
        guard let (d1, d2) = d1d2(i) else {
            // At expiry the theoretical price collapses to intrinsic value.
            if i.timeToExpiryYears <= 0 {
                switch i.type {
                case .call: return max(0, i.spot - i.strike)
                case .put: return max(0, i.strike - i.spot)
                }
            }
            return nil
        }
        let discountedStrike = i.strike * exp(-i.riskFreeRate * i.timeToExpiryYears)
        switch i.type {
        case .call:
            return i.spot * normalCDF(d1) - discountedStrike * normalCDF(d2)
        case .put:
            return discountedStrike * normalCDF(-d2) - i.spot * normalCDF(-d1)
        }
    }

    /// Full greek set. Delta and gamma are per $1 move in the underlying,
    /// theta is per calendar day (not per year — that's the unit a trader
    /// actually reads off a position), vega is per 1 percentage point of IV,
    /// rho is per 1 percentage point of rate.
    static func greeks(_ i: Inputs) -> Greeks? {
        guard let (d1, d2) = d1d2(i) else { return nil }
        let sqrtT = i.timeToExpiryYears.squareRoot()
        let discountedStrike = i.strike * exp(-i.riskFreeRate * i.timeToExpiryYears)
        let pdf = phi(d1)

        let delta: Double
        switch i.type {
        case .call: delta = normalCDF(d1)
        case .put: delta = normalCDF(d1) - 1
        }

        let gamma = pdf / (i.spot * i.impliedVolatility * sqrtT)

        let thetaAnnual: Double
        switch i.type {
        case .call:
            thetaAnnual = -(i.spot * pdf * i.impliedVolatility) / (2 * sqrtT)
                - i.riskFreeRate * discountedStrike * normalCDF(d2)
        case .put:
            thetaAnnual = -(i.spot * pdf * i.impliedVolatility) / (2 * sqrtT)
                + i.riskFreeRate * discountedStrike * normalCDF(-d2)
        }
        let thetaPerDay = thetaAnnual / 365.0

        let vegaPerPoint = i.spot * pdf * sqrtT / 100.0

        let rhoPerPoint: Double
        switch i.type {
        case .call: rhoPerPoint = discountedStrike * i.timeToExpiryYears * normalCDF(d2) / 100.0
        case .put: rhoPerPoint = -discountedStrike * i.timeToExpiryYears * normalCDF(-d2) / 100.0
        }

        return Greeks(delta: delta, gamma: gamma, theta: thetaPerDay, vega: vegaPerPoint, rho: rhoPerPoint)
    }

    /// Solves for implied volatility from an observed market price via
    /// Newton-Raphson, falling back to bisection when the Newton step would
    /// leave the search bracket (a common failure mode near expiry or deep
    /// in/out of the money, where vega is nearly flat).
    static func impliedVolatility(
        marketPrice: Double,
        spot: Double,
        strike: Double,
        timeToExpiryYears: Double,
        riskFreeRate: Double = 0.045,
        type: OptionType,
        maxIterations: Int = 60
    ) -> Double? {
        guard marketPrice > 0, spot > 0, strike > 0, timeToExpiryYears > 0 else { return nil }

        var low = 0.001, high = 5.0
        var guess = 0.3

        for _ in 0..<maxIterations {
            let inputs = Inputs(
                spot: spot, strike: strike, timeToExpiryYears: timeToExpiryYears,
                riskFreeRate: riskFreeRate, impliedVolatility: guess, type: type
            )
            guard let modelPrice = price(inputs), let g = greeks(inputs) else { break }
            let diff = modelPrice - marketPrice

            if diff > 0 { high = guess } else { low = guess }

            // vega here is per-percentage-point; convert back to per-unit-vol
            // for the Newton step.
            let vegaPerUnit = g.vega * 100.0
            let newtonStep = vegaPerUnit > 1e-8 ? guess - diff / vegaPerUnit : Double.nan

            let next = (newtonStep.isFinite && newtonStep > low && newtonStep < high)
                ? newtonStep
                : (low + high) / 2

            if abs(next - guess) < 1e-6 { return next }
            guess = next
        }
        return guess
    }
}
