import Foundation

/// Gamma exposure (GEX): how much delta-hedging pressure dealers are likely
/// carrying at each strike, and whether that pressure dampens or amplifies
/// price moves near the current spot.
///
/// This is the single most-requested-by-competitors options feature that
/// turns out to be honestly buildable from free chain data — Unusual Whales
/// and SpotGamma both charge $50–2000/month partly for this exact chart, and
/// the underlying math is public: `OI × gamma × 100 × spot² × 0.01` per
/// contract. What isn't public is which side of each trade dealers actually
/// took, so every GEX tracker in the market — this one included — uses the
/// same convention rather than real position data: assume dealers are net
/// short the calls retail buys and net long the puts retail buys, which
/// makes call gamma exposure positive and put gamma exposure negative. This
/// is a widely-used approximation of dealer hedging flow, not a claim about
/// any specific dealer's actual book, and the UI should say so.
enum GammaExposureCalculator {

    struct StrikeExposure: Identifiable, Sendable {
        var id: Double { strike }
        let strike: Double
        /// Positive = call-side (assumed dealer-short) gamma dominates at
        /// this strike; negative = put-side (assumed dealer-long) dominates.
        let netGamma: Double
        let callGamma: Double
        let putGamma: Double
    }

    struct Result: Sendable {
        let byStrike: [StrikeExposure]
        let netTotal: Double
        /// The strike nearest to where net cumulative gamma crosses zero,
        /// interpolated between the two bracketing strikes. Above this
        /// level dealers are conventionally long gamma (moves get dampened,
        /// a "pinning" effect); below it they're short gamma (moves tend to
        /// accelerate). Nil when every sampled strike has the same sign —
        /// there's no crossing to report.
        let zeroGammaLevel: Double?
    }

    /// One contract's dollar gamma exposure, signed by the retail-flow
    /// convention described above. Requires open interest and a gamma value
    /// (server-provided or `GreeksEngine`-computed fallback) — a contract
    /// missing either contributes nothing rather than a guessed number.
    static func exposure(for contract: OptionContract) -> Double? {
        guard let oi = contract.openInterest, oi > 0,
              let gamma = contract.greeks?.gamma, gamma > 0 else { return nil }
        // Multiplier 100 (shares per contract) × spot² × 0.01 is the
        // standard normalization so the number reads as "dollars of delta
        // exposure per 1% move in the underlying" — the units every public
        // GEX chart uses, which is what makes cross-checking against a
        // competitor's chart meaningful.
        let magnitude = Double(oi) * gamma * 100 * contract.strike * contract.strike * 0.01
        return contract.type == .call ? magnitude : -magnitude
    }

    /// Aggregates one expiration (or a whole chain) into per-strike and net
    /// exposure, optionally restricted to 0/1-DTE contracts — SpotGamma's
    /// "0DTE gamma" view, isolating same-day hedging dynamics from
    /// longer-dated term structure. 0DTE trades now account for a majority
    /// of SPX volume on many sessions, and its gamma behaves differently
    /// enough from term gamma that blending them together hides both.
    static func compute(contracts: [OptionContract], dteFilter: ClosedRange<Int>? = nil) -> Result {
        let scoped = dteFilter.map { range in
            contracts.filter { range.contains($0.daysToExpiration) }
        } ?? contracts

        var byStrike: [Double: (call: Double, put: Double)] = [:]
        for contract in scoped {
            guard let exposure = exposure(for: contract) else { continue }
            var entry = byStrike[contract.strike] ?? (0, 0)
            if contract.type == .call { entry.call += exposure } else { entry.put += exposure }
            byStrike[contract.strike] = entry
        }

        let rows = byStrike
            .map { strike, pair in
                StrikeExposure(strike: strike, netGamma: pair.call + pair.put, callGamma: pair.call, putGamma: pair.put)
            }
            .sorted { $0.strike < $1.strike }

        let netTotal = rows.reduce(0) { $0 + $1.netGamma }
        let zeroGamma = findZeroGammaCrossing(rows)

        return Result(byStrike: rows, netTotal: netTotal, zeroGammaLevel: zeroGamma)
    }

    /// Linear interpolation between the two adjacent strikes whose
    /// cumulative net gamma changes sign — the "gamma flip" level every
    /// competitor researched treats as a de facto support/resistance line.
    /// Cumulative rather than per-strike net, since the flip is about the
    /// running total of exposure below a given price, not any single
    /// strike's own sign.
    private static func findZeroGammaCrossing(_ rows: [StrikeExposure]) -> Double? {
        guard rows.count >= 2 else { return nil }
        var cumulative = 0.0
        var previousStrike = rows[0].strike
        var previousCumulative = 0.0

        for row in rows {
            cumulative += row.netGamma
            defer {
                previousStrike = row.strike
                previousCumulative = cumulative
            }
            guard row.strike != rows.first?.strike else { continue }
            if (previousCumulative < 0 && cumulative >= 0) || (previousCumulative > 0 && cumulative <= 0) {
                let span = cumulative - previousCumulative
                guard span != 0 else { return row.strike }
                let t = -previousCumulative / span
                return previousStrike + t * (row.strike - previousStrike)
            }
        }
        return nil
    }
}
