import Foundation

/// Call or put. Kept as a plain two-case enum rather than folding direction
/// into a signed number anywhere — every downstream consumer (chain grouping,
/// strategy legs, unusual-activity heuristics) reads more clearly against an
/// explicit case than against a sign convention nobody can remember six
/// months from now.
enum OptionType: String, Codable, Sendable {
    case call, put
}

/// Greeks for one contract at one point in time.
///
/// Alpaca returns server-computed greeks on the snapshot endpoint when
/// available; `GreeksEngine` recomputes the same fields locally both as a
/// fallback for a contract the snapshot omits and for what-if pricing in the
/// strategy builder (moving IV, spot, or days-to-expiry without a network
/// round trip).
struct Greeks: Codable, Hashable, Sendable {
    var delta: Double
    var gamma: Double
    var theta: Double
    var vega: Double
    var rho: Double

    static let zero = Greeks(delta: 0, gamma: 0, theta: 0, vega: 0, rho: 0)
}

/// One listed option contract, at whatever quote/greeks snapshot was last
/// fetched. Deliberately mirrors the shape of `SignalSnapshot` in spirit —
/// a candidate plus a "why" — even though options need a different set of
/// raw fields entirely.
struct OptionContract: Identifiable, Codable, Hashable, Sendable {
    /// The OCC-format contract symbol (e.g. "AAPL250117C00150000"), which is
    /// already globally unique — no synthetic id needed.
    var id: String { symbol }

    let symbol: String
    let underlying: String
    let expiration: Date
    let strike: Double
    let type: OptionType

    let bid: Double?
    let ask: Double?
    let lastPrice: Double?
    /// Contracts traded so far today.
    let volume: Int?
    /// Open contracts as of the last settlement — the denominator every
    /// unusual-activity heuristic compares today's volume against.
    let openInterest: Int?
    let impliedVolatility: Double?
    let greeks: Greeks?

    var mid: Double? {
        guard let bid, let ask, bid > 0, ask > 0 else { return lastPrice }
        return (bid + ask) / 2
    }

    /// Cents-wide spread as a share of the mid price. Options routinely trade
    /// with much wider relative spreads than the underlying — a contract can
    /// look attractive on the chain and be unfillable at anything near mid.
    var spreadPercent: Double? {
        guard let bid, let ask, let mid, mid > 0 else { return nil }
        return (ask - bid) / mid
    }

    var daysToExpiration: Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiration).day ?? 0)
    }

    /// Volume against open interest. The core unusual-activity ratio: a
    /// contract trading multiples of its entire open position in one session
    /// is either fresh positioning or an unwind, not routine market-making.
    var volumeToOpenInterestRatio: Double? {
        guard let volume, let openInterest, openInterest > 0 else { return nil }
        return Double(volume) / Double(openInterest)
    }

    /// Moneyness as (strike − spot) / spot for a call, mirrored for a put, so
    /// positive always means "out of the money" regardless of side.
    func moneynessPercent(spot: Double) -> Double? {
        guard spot > 0 else { return nil }
        switch type {
        case .call: return (strike - spot) / spot
        case .put: return (spot - strike) / spot
        }
    }
}

/// The full chain for one underlying, grouped by expiration the way a
/// trader actually scans it — nearest date first, calls and puts within
/// each expiration kept separate rather than interleaved by strike.
struct OptionChain: Sendable {
    let underlying: String
    let spotPrice: Double
    let asOf: Date
    let contracts: [OptionContract]

    var expirations: [Date] {
        Set(contracts.map(\.expiration)).sorted()
    }

    func contracts(for expiration: Date) -> (calls: [OptionContract], puts: [OptionContract]) {
        let matching = contracts.filter { $0.expiration == expiration }
        return (
            calls: matching.filter { $0.type == .call }.sorted { $0.strike < $1.strike },
            puts: matching.filter { $0.type == .put }.sorted { $0.strike < $1.strike }
        )
    }

    /// The strike closest to the current spot, per expiration and side —
    /// what a trader means by "the ATM contract" when they haven't specified
    /// a delta target.
    func atmContract(for expiration: Date, type: OptionType) -> OptionContract? {
        contracts
            .filter { $0.expiration == expiration && $0.type == type }
            .min { abs($0.strike - spotPrice) < abs($1.strike - spotPrice) }
    }
}
