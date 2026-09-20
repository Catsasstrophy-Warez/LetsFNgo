import Foundation

/// Flags contracts trading in a way that looks like fresh, deliberate
/// positioning rather than routine two-sided market-making.
///
/// Kept deliberately conservative and self-contained: everything here is
/// computed from Alpaca's own chain/quote data, with no dependency on a paid
/// flow provider (Unusual Whales, FlowAlgo, Cheddar Flow — see
/// `MASTER_COMPETITIVE_RESEARCH_200.md` for why those were scoped out of a
/// first release). This is a labeled hint, never a hidden score override on
/// the underlying's own day-trade ranking — the house rule the competitive
/// research is explicit about for every social/flow-style signal in the app.
enum UnusualActivityDetector {

    struct Signal: Identifiable, Sendable {
        var id: String { contract.symbol }
        let contract: OptionContract
        /// 0...1, purely a ranking aid — not a probability of anything.
        let score: Double
        let reasons: [String]
    }

    /// Scans every chain currently held for contracts worth surfacing.
    ///
    /// Note: `contract.volume` is the size of the latest trade print, not
    /// cumulative contracts traded today (see `OptionContract.volume`'s doc
    /// comment) — every ratio/surge computation below is against that same
    /// understated quantity, so it undercounts real daily activity more
    /// often than it overcounts.
    /// - Parameter history: recent (date, volume) samples per contract
    ///   symbol, used to judge whether the latest print is a surge relative
    ///   to this specific contract's own recent pace rather than only its
    ///   open interest.
    static func scan(
        chains: [String: OptionChain],
        history: [String: [(date: Date, volume: Int)]]
    ) -> [Signal] {
        chains.values
            .flatMap(\.contracts)
            .compactMap { contract in evaluate(contract, recentVolumes: history[contract.symbol]) }
            .sorted { $0.score > $1.score }
    }

    static func evaluate(
        _ contract: OptionContract,
        recentVolumes: [(date: Date, volume: Int)]?
    ) -> Signal? {
        guard let volume = contract.volume, volume > 0 else { return nil }

        var reasons: [String] = []
        var score = 0.0

        // 1. Volume against open interest. Trading more contracts today than
        //    exist in the entire open position is the single clearest sign of
        //    new positioning rather than existing holders trading among
        //    themselves.
        if let ratio = contract.volumeToOpenInterestRatio {
            if ratio >= 3.0 {
                score += 0.45
                reasons.append(String(format: "%.1f× trade size vs open interest", ratio))
            } else if ratio >= 1.0 {
                score += 0.25
                reasons.append(String(format: "%.1f× volume vs open interest", ratio))
            }
        }

        // 2. Volume against this contract's own recent pace, when history is
        //    available. Catches a surge even on a contract with naturally
        //    high open interest (an index ETF near-the-money strike), where
        //    the OI ratio alone would stay unremarkable.
        if let recentVolumes, recentVolumes.count >= 3 {
            let priorAverage = recentVolumes.dropLast().map(\.volume).reduce(0, +)
            let priorCount = max(recentVolumes.count - 1, 1)
            let average = Double(priorAverage) / Double(priorCount)
            if average > 0 {
                let surge = Double(volume) / average
                if surge >= 3.0 {
                    score += 0.25
                    reasons.append(String(format: "%.1f× this contract's recent pace", surge))
                }
            }
        }

        // 3. Sizeable single-session dollar volume. A thousand contracts on a
        //    $0.05 far-OTM lotto ticket is a different animal from a thousand
        //    contracts on a $5 near-the-money strike — weight by premium paid.
        if let mid = contract.mid, mid > 0 {
            let notional = mid * Double(volume) * 100
            if notional >= 500_000 {
                score += 0.20
                reasons.append("$\(Fmt.compactVolume(notional)) notional today")
            } else if notional >= 100_000 {
                score += 0.10
            }
        }

        // 4. Short-dated and meaningfully out-of-the-money is the classic
        //    "expecting a fast, specific move" shape — a cluster of these on
        //    the same underlying and same side is worth a second look even
        //    before checking any external catalyst.
        if contract.daysToExpiration <= 10 {
            score += 0.10
            reasons.append("\(contract.daysToExpiration)d to expiration")
        }

        guard score > 0, !reasons.isEmpty else { return nil }
        return Signal(contract: contract, score: min(score, 1.0), reasons: reasons)
    }
}
