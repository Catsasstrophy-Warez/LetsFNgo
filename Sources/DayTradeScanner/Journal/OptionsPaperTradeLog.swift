import Foundation
import SwiftData
import Observation

/// A frozen record of one leg at the moment a strategy was opened.
///
/// Deliberately not a reference to a live `OptionContract` — those come from
/// `OptionsEngine`'s in-memory chain cache and disappear the moment that
/// chain refreshes or the app relaunches. The journal needs its own durable
/// copy of exactly what was traded, the same reasoning `PaperTrade` already
/// applies to `SignalSnapshot`.
struct OptionLegRecord: Codable, Hashable, Sendable {
    let contractSymbol: String
    let underlying: String
    let expiration: Date
    let strike: Double
    let type: OptionType
    /// Positive = bought, negative = sold — matches `StrategyLeg.signedQuantity`.
    let signedQuantity: Int
    let entryMid: Double

    /// Cash paid (positive) or received (negative) for this leg at entry,
    /// contracts × 100.
    var entryPremium: Double {
        entryMid * Double(signedQuantity) * 100
    }
}

/// One recorded options strategy, from open to close.
///
/// A single-leg long call and a four-leg iron condor are the same kind of
/// record here — `legs` just has one entry or four. Everything downstream
/// (mark-to-market, P&L) is expressed as a sum over legs rather than
/// special-cased per strategy shape, mirroring how `OptionStrategy` itself
/// works in `StrategyBuilder.swift`.
@Model
final class OptionsPaperTrade {
    @Attribute(.unique) var id: UUID
    var underlying: String
    var strategyName: String
    var openedAt: Date
    var closedAt: Date?
    var statusRaw: String

    /// JSON-encoded `[OptionLegRecord]`.
    var legsData: Data

    /// Net premium at open: positive = net debit paid, negative = net credit
    /// received. Cost basis for every P&L calculation below.
    var netPremiumAtOpen: Double
    var underlyingSpotAtOpen: Double

    /// Current mark, in the same sign convention as `netPremiumAtOpen` —
    /// updated by `OptionsPaperTradeLog.markToMarket` whenever fresh quotes
    /// are available for every leg. Nil until the first successful mark.
    var currentValue: Double?
    var currentValueAsOf: Date?

    /// Frozen at close, so a closed trade's P&L doesn't drift if a leg's
    /// contract symbol later reappears with a stale quote.
    var closedValue: Double?

    var note: String

    init(
        underlying: String,
        strategyName: String,
        openedAt: Date,
        legs: [OptionLegRecord],
        underlyingSpotAtOpen: Double
    ) {
        self.id = UUID()
        self.underlying = underlying
        self.strategyName = strategyName
        self.openedAt = openedAt
        self.statusRaw = TradeStatus.open.rawValue
        self.legsData = (try? JSONEncoder().encode(legs)) ?? Data()
        self.netPremiumAtOpen = legs.reduce(0) { $0 + $1.entryPremium }
        self.underlyingSpotAtOpen = underlyingSpotAtOpen
        self.note = ""
    }

    var status: TradeStatus { TradeStatus(rawValue: statusRaw) ?? .open }

    var legs: [OptionLegRecord] {
        (try? JSONDecoder().decode([OptionLegRecord].self, from: legsData)) ?? []
    }

    var legCount: Int { legs.count }

    /// P&L to date: current mark minus cost basis while open, or the frozen
    /// closing value minus cost basis once closed. Works uniformly across
    /// long and short legs because `netPremiumAtOpen` and `currentValue`
    /// share one sign convention — see `StrategyBuilder.OptionStrategy.netPremium`.
    var profitAndLoss: Double? {
        switch status {
        case .open: return currentValue.map { $0 - netPremiumAtOpen }
        case .closed: return closedValue.map { $0 - netPremiumAtOpen }
        }
    }

    /// P&L as a share of capital at risk. Capital at risk for a debit
    /// strategy is what was paid; for a credit strategy there's no single
    /// "amount risked" without knowing the strategy's max loss, so this is
    /// only meaningful for a net-debit position and returns nil otherwise —
    /// showing a misleading percentage is worse than showing none.
    var profitAndLossPercent: Double? {
        guard netPremiumAtOpen > 0, let pnl = profitAndLoss else { return nil }
        return pnl / netPremiumAtOpen
    }
}

// MARK: - Store

@MainActor
@Observable
final class OptionsPaperTradeLog {
    private var context: ModelContext?

    private(set) var trades: [OptionsPaperTrade] = []

    func attach(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        guard let context else { return }
        let descriptor = FetchDescriptor<OptionsPaperTrade>(
            sortBy: [SortDescriptor(\.openedAt, order: .reverse)]
        )
        trades = (try? context.fetch(descriptor)) ?? []
    }

    /// Opens a paper position from a built strategy. Mirrors
    /// `PaperTradeLog.open(from:)`'s shape: freeze exactly what was seen at
    /// entry rather than holding a reference to anything live.
    func open(strategy: OptionStrategy, underlyingSpot: Double) {
        guard let context, !strategy.legs.isEmpty else { return }

        let records = strategy.legs.map { leg in
            OptionLegRecord(
                contractSymbol: leg.contract.symbol,
                underlying: leg.contract.underlying,
                expiration: leg.contract.expiration,
                strike: leg.contract.strike,
                type: leg.contract.type,
                signedQuantity: leg.signedQuantity,
                entryMid: leg.contract.mid ?? 0
            )
        }

        let trade = OptionsPaperTrade(
            underlying: strategy.legs[0].contract.underlying,
            strategyName: strategy.name,
            openedAt: Date(),
            legs: records,
            underlyingSpotAtOpen: underlyingSpot
        )
        context.insert(trade)
        try? context.save()
        refresh()
    }

    /// Marks every open trade against fresh contract quotes.
    /// - Parameter midsByContractSymbol: current mid price per OCC contract
    ///   symbol, as pulled from `OptionsEngine`'s live chains. A trade with a
    ///   leg missing from this dictionary (an expired or delisted contract)
    ///   keeps its last known mark rather than being zeroed out.
    func markToMarket(midsByContractSymbol: [String: Double]) {
        guard let context else { return }
        var didChange = false
        let now = Date()

        for trade in trades where trade.status == .open {
            let legs = trade.legs
            guard !legs.isEmpty else { continue }

            var total = 0.0
            var missing = false
            for leg in legs {
                guard let mid = midsByContractSymbol[leg.contractSymbol] else { missing = true; break }
                total += mid * Double(leg.signedQuantity) * 100
            }
            guard !missing else { continue }

            trade.currentValue = total
            trade.currentValueAsOf = now
            didChange = true
        }

        if didChange { try? context.save() }
    }

    /// Closes a trade at its last mark. Options don't force-close at the
    /// bell the way a day trade does — a spread can be held to expiration or
    /// closed early by choice, so this is always an explicit user action
    /// rather than something `markToMarket` decides on its own.
    func close(_ trade: OptionsPaperTrade) {
        guard let context else { return }
        trade.closedValue = trade.currentValue ?? trade.netPremiumAtOpen
        trade.closedAt = Date()
        trade.statusRaw = TradeStatus.closed.rawValue
        try? context.save()
        refresh()
    }

    func delete(_ trade: OptionsPaperTrade) {
        guard let context else { return }
        context.delete(trade)
        try? context.save()
        refresh()
    }

    func deleteAll() {
        guard let context else { return }
        for trade in trades { context.delete(trade) }
        try? context.save()
        refresh()
    }

    func setNote(_ note: String, on trade: OptionsPaperTrade) {
        trade.note = note
        try? context?.save()
    }

    // MARK: - Summary

    var openCount: Int { trades.filter { $0.status == .open }.count }

    var summary: (total: Int, resolved: Int, winRate: Double, averagePLPercent: Double?) {
        let resolved = trades.compactMap { trade -> Double? in
            guard trade.status == .closed else { return nil }
            return trade.profitAndLoss
        }
        guard !resolved.isEmpty else { return (trades.count, 0, 0, nil) }
        let winRate = Double(resolved.filter { $0 > 0 }.count) / Double(resolved.count)
        let percents = trades.compactMap { $0.status == .closed ? $0.profitAndLossPercent : nil }
        let avgPercent = percents.isEmpty ? nil : percents.reduce(0, +) / Double(percents.count)
        return (trades.count, resolved.count, winRate, avgPercent)
    }
}
