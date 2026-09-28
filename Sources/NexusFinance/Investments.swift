import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A typed view of a security object.
public struct Security: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var symbol: String { record.string(FinanceKey.symbol) ?? record.title }
    public var name: String { record.title }
    public var assetClass: AssetClass { record.string(FinanceKey.assetClass).flatMap(AssetClass.init(rawValue:)) ?? .other }
    public var currency: Currency { (try? Currency(record.string(FinanceKey.currency) ?? "")) ?? .usd }
}

public enum TradeSide: String, Codable, Sendable, CaseIterable {
    case buy
    case sell
}

public struct TradeDraft: Sendable, Hashable {
    public var date: Date
    public var side: TradeSide
    /// Units, positive. Fractional shares are exact decimals.
    public var quantity: Decimal
    /// Price per unit.
    public var price: Money
    public var fees: Money?

    public init(date: Date, side: TradeSide, quantity: Decimal, price: Money, fees: Money? = nil) {
        self.date = FinanceCalendar.startOfDay(date)
        self.side = side
        self.quantity = quantity
        self.price = price
        self.fees = fees
    }
}

/// A typed view of a trade object.
public struct Trade: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var date: Date { record.date(FinanceKey.date) ?? record.createdAt }
    public var side: TradeSide { record.string(FinanceKey.side).flatMap(TradeSide.init(rawValue:)) ?? .buy }
    public var quantity: Decimal { record.decimal(FinanceKey.quantity) ?? 0 }
    public var price: Money? { record.money(FinanceKey.price) }
    public var fees: Money? { record.money(FinanceKey.fees) }
    public var security: ObjectID? { record.reference(FinanceKey.security) }
    public var account: ObjectID? { record.reference(FinanceKey.account) }
}

/// A price for a security, with the truth of whoever stated it.
public struct PriceQuote: Sendable, Hashable {
    public var security: ObjectID
    public var price: Money
    public var at: Date
    public var provenance: Provenance
    public var truth: TruthClass { provenance.truth }
}

/// Units bought together at one cost.
public struct Lot: Sendable, Hashable {
    public var acquired: Date
    public var quantity: Decimal
    /// Total cost of the units still held, fees included.
    public var cost: Money
    public var unitCost: Money { (try? cost.divided(by: quantity)) ?? cost }
}

public enum CostBasisMethod: String, Codable, Sendable, CaseIterable {
    /// First in, first out: a sale consumes the oldest lots first.
    case fifo
    /// Average cost: every unit carries the pool's average cost.
    case average
}

/// A holding's derived state from its recorded trades and prices.
public struct Position: Sendable, Hashable {
    public var account: ObjectID
    public var security: ObjectID
    public var method: CostBasisMethod
    public var quantity: Decimal
    /// Open lots (a single pooled lot under average cost).
    public var lots: [Lot]
    public var costBasis: Money
    public var realizedGain: Money
    /// The latest **recorded** price; claimed prices are never used for gains.
    public var price: PriceQuote?
    public var marketValue: Money?
    public var unrealizedGain: Money?
}

public struct AllocationSlice: Sendable, Hashable {
    public var assetClass: AssetClass
    public var value: Money
    /// Share of the priced total, 0...1.
    public var weight: Decimal
}

public struct Allocation: Sendable, Hashable {
    public var slices: [AllocationSlice]
    public var total: Money
    /// Securities held without a recorded price, left out of the total.
    public var unpriced: [ObjectID]
}

/// Securities, trades, holdings, prices, cost basis and allocation.
///
/// - Trades are **recorded** (a broker statement or the person).
/// - A price quote from an importer (or a person) is **recorded**; from an
///   agent or a model it is **claimed**. Gains and allocation use recorded
///   prices only.
/// - Lots, cost basis, realised and unrealised gains are **derived** on read.
///   The holding object carries the latest quantity and FIFO cost basis as
///   derived attributes for search and display.
public struct Portfolio: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Securities

    @discardableResult
    public func addSecurity(symbol: String, name: String, assetClass: AssetClass, currency: Currency, by author: Origin) throws -> Security {
        let symbol = symbol.uppercased()
        if try security(symbol: symbol) != nil { throw FinanceError.duplicateSymbol(symbol) }
        let record = try store.create(
            ObjectRecord(
                type: .security, title: name,
                attributes: [
                    FinanceKey.symbol: Attribute(.string(symbol)),
                    FinanceKey.assetClass: Attribute(.string(assetClass.rawValue)),
                    FinanceKey.currency: Attribute(.string(currency.code)),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now())
            ))
        return Security(record: record)
    }

    public func security(_ id: ObjectID) throws -> Security {
        guard let record = try store.object(id), record.type == .security else { throw FinanceError.notFound(id, expected: .security) }
        return Security(record: record)
    }

    public func security(symbol: String) throws -> Security? {
        try store.objects(ofType: .security).map(Security.init).first { $0.symbol == symbol.uppercased() }
    }

    // MARK: Trades

    /// Records a buy or sell as a trade object on the account's holding. A
    /// sale larger than the position throws.
    @discardableResult
    public func recordTrade(_ draft: TradeDraft, of securityID: ObjectID, in accountID: ObjectID, by author: Origin) throws -> Trade {
        guard draft.quantity > 0 else { throw FinanceError.invalidQuantity(draft.quantity) }
        let security = try security(securityID)
        _ = try Ledger(store: store, clock: clock).account(accountID)
        guard draft.price.currency == security.currency else { throw MoneyError.currencyMismatch(security.currency, draft.price.currency) }
        if let fees = draft.fees, fees.currency != security.currency { throw MoneyError.currencyMismatch(security.currency, fees.currency) }
        return try store.batch { store in
            if draft.side == .sell {
                let held = try position(of: securityID, in: accountID, asOf: draft.date).quantity
                guard held >= draft.quantity else { throw FinanceError.insufficientQuantity(available: held, requested: draft.quantity) }
            }
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "trade")
            var attributes: [String: Attribute] = [
                FinanceKey.date: Attribute(.date(draft.date)),
                FinanceKey.side: Attribute(.string(draft.side.rawValue)),
                FinanceKey.quantity: Attribute(draft.quantity.value),
                FinanceKey.price: Attribute(draft.price.value),
                FinanceKey.security: Attribute(.reference(securityID)),
                FinanceKey.account: Attribute(.reference(accountID)),
            ]
            if let fees = draft.fees { attributes[FinanceKey.fees] = Attribute(fees.value) }
            let title = "\(draft.side == .buy ? "Buy" : "Sell") \(draft.quantity.plainString) \(security.symbol) @ \(draft.price)"
            let record = try store.create(ObjectRecord(type: .trade, title: title, attributes: attributes, provenance: provenance))
            try store.relate(Relationship(kind: .postedTo, from: record.id, to: accountID, validFrom: draft.date, provenance: provenance))
            try store.relate(Relationship(kind: .ofSecurity, from: record.id, to: securityID, provenance: provenance))
            let holding = try ensureHolding(of: security, in: accountID, provenance: provenance)
            let position = try position(of: securityID, in: accountID)
            let derived = Provenance(
                origin: .system, truth: .derived, timestamp: clock.now(), method: "FIFO over recorded trades", dependencies: [record.id],
                transformation: "costBasis"
            )
            try store.update(holding.id, by: .system, instruction: "Trade \(title)") {
                $0.attributes[FinanceKey.quantity] = Attribute(position.quantity.value, provenance: derived)
                $0.attributes[FinanceKey.costBasis] = Attribute(position.costBasis.value, provenance: derived)
            }
            return Trade(record: record)
        }
    }

    private func ensureHolding(of security: Security, in accountID: ObjectID, provenance: Provenance) throws -> ObjectRecord {
        if let existing = try holding(of: security.id, in: accountID) { return existing }
        let holding = try store.create(
            ObjectRecord(
                type: .holding, title: "\(security.symbol) holding",
                attributes: [FinanceKey.security: Attribute(.reference(security.id)), FinanceKey.account: Attribute(.reference(accountID))],
                provenance: provenance
            ))
        try store.relate(Relationship(kind: .holds, from: accountID, to: holding.id, provenance: provenance))
        try store.relate(Relationship(kind: .ofSecurity, from: holding.id, to: security.id, provenance: provenance))
        return holding
    }

    public func holding(of securityID: ObjectID, in accountID: ObjectID) throws -> ObjectRecord? {
        try store.objects(try store.relationships(from: accountID, kind: .holds).map(\.to)).first { $0.reference(FinanceKey.security) == securityID }
    }

    /// Holdings in an account, as (holding, security).
    public func holdings(in accountID: ObjectID) throws -> [(holding: ObjectRecord, security: Security)] {
        try store.objects(try store.relationships(from: accountID, kind: .holds).map(\.to)).compactMap { holding in
            guard let id = holding.reference(FinanceKey.security) else { return nil }
            return (holding, try security(id))
        }
    }

    public func trades(of securityID: ObjectID, in accountID: ObjectID) throws -> [Trade] {
        try store.objects(try store.relationships(to: accountID, kind: .postedTo).map(\.from)).filter { $0.type == .trade && $0.lifecycle == .active }
            .map(Trade.init).filter { $0.security == securityID }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    // MARK: Prices

    /// Records a price quote as an event on the security. The truth follows
    /// the source: an importer or a person records it; an agent or a model
    /// only claims it.
    @discardableResult
    public func recordPrice(_ price: Money, of securityID: ObjectID, at date: Date, by author: Origin, method: String? = nil) throws -> PriceQuote {
        let security = try security(securityID)
        guard price.currency == security.currency else { throw MoneyError.currencyMismatch(security.currency, price.currency) }
        let truth: TruthClass
        switch author {
        case .agent, .model: truth = .claimed
        default: truth = author.defaultTruth
        }
        let provenance = Provenance(origin: author, truth: truth, timestamp: clock.now(), method: method ?? "price quote")
        try store.record(
            Event(
                at: date, kind: .priceQuote, subjects: [securityID], summary: "\(security.symbol) \(price)", payload: [FinanceKey.price: price.value],
                provenance: provenance
            ))
        return PriceQuote(security: securityID, price: price, at: date, provenance: provenance)
    }

    /// Quotes for a security, oldest first, optionally only of some truth classes.
    public func prices(of securityID: ObjectID, truth: Set<TruthClass>? = nil) throws -> [PriceQuote] {
        try store.events(about: securityID).filter { $0.kind == .priceQuote }.compactMap { event in
            guard let price = Money(event.payload[FinanceKey.price]) else { return nil }
            if let truth, !truth.contains(event.provenance.truth) { return nil }
            return PriceQuote(security: securityID, price: price, at: event.at, provenance: event.provenance)
        }
    }

    /// The latest recorded price at or before `date`.
    public func latestRecordedPrice(of securityID: ObjectID, asOf date: Date? = nil) throws -> PriceQuote? {
        try prices(of: securityID, truth: [.recorded, .observed]).filter { date == nil || $0.at <= date! }.last
    }

    // MARK: Positions

    /// Quantity, lots, cost basis and gains from the recorded trades up to `date`.
    public func position(of securityID: ObjectID, in accountID: ObjectID, method: CostBasisMethod = .fifo, asOf date: Date? = nil) throws -> Position {
        let security = try security(securityID)
        let currency = security.currency
        var lots: [Lot] = []
        var realized = Money.zero(currency)
        for trade in try trades(of: securityID, in: accountID) where trade.record.provenance.truth == .recorded {
            if let date, trade.date > date { break }
            guard let price = trade.price else { continue }
            let fees = trade.fees ?? .zero(currency)
            let gross = price * trade.quantity
            switch trade.side {
            case .buy:
                let cost = try gross + fees
                switch method {
                case .fifo:
                    lots.append(Lot(acquired: trade.date, quantity: trade.quantity, cost: cost))
                case .average:
                    if let pool = lots.first {
                        lots = [Lot(acquired: pool.acquired, quantity: pool.quantity + trade.quantity, cost: try pool.cost + cost)]
                    } else {
                        lots = [Lot(acquired: trade.date, quantity: trade.quantity, cost: cost)]
                    }
                }
            case .sell:
                var remaining = trade.quantity
                var removed = Money.zero(currency)
                while remaining > 0, !lots.isEmpty {
                    let take = min(remaining, lots[0].quantity)
                    let share = take == lots[0].quantity ? lots[0].cost : lots[0].cost * (take / lots[0].quantity)
                    removed = try removed + share
                    lots[0] = Lot(acquired: lots[0].acquired, quantity: lots[0].quantity - take, cost: try lots[0].cost - share)
                    if lots[0].quantity == 0 { lots.removeFirst() }
                    remaining -= take
                }
                guard remaining == 0 else { throw FinanceError.insufficientQuantity(available: trade.quantity - remaining, requested: trade.quantity) }
                realized = try realized + (try gross - fees - removed)
            }
        }
        let quantity = lots.reduce(Decimal(0)) { $0 + $1.quantity }
        let costBasis = try Money.sum(lots.map(\.cost), in: currency)
        let quote = try latestRecordedPrice(of: securityID, asOf: date)
        let marketValue = quote.map { ($0.price * quantity) }
        return Position(
            account: accountID, security: securityID, method: method, quantity: quantity, lots: lots, costBasis: costBasis.rounded(),
            realizedGain: realized.rounded(), price: quote, marketValue: marketValue?.rounded(),
            unrealizedGain: try marketValue.map { try ($0 - costBasis).rounded() }
        )
    }

    /// Market value by asset class across accounts, from recorded prices.
    /// Every holding must be in `currency`; there is no implicit conversion.
    public func allocation(accounts: [ObjectID], currency: Currency, asOf date: Date? = nil) throws -> Allocation {
        var values: [AssetClass: Money] = [:]
        var unpriced: [ObjectID] = []
        for account in accounts {
            for (_, security) in try holdings(in: account) {
                let position = try position(of: security.id, in: account, asOf: date)
                guard position.quantity != 0 else { continue }
                guard let value = position.marketValue else {
                    unpriced.append(security.id)
                    continue
                }
                guard value.currency == currency else { throw MoneyError.currencyMismatch(currency, value.currency) }
                values[security.assetClass] = try (values[security.assetClass] ?? .zero(currency)) + value
            }
        }
        let total = try Money.sum(values.values, in: currency)
        let slices = try AssetClass.allCases.compactMap { assetClass -> AllocationSlice? in
            guard let value = values[assetClass] else { return nil }
            let weight = total.isZero ? 0 : try value.ratio(to: total)
            return AllocationSlice(assetClass: assetClass, value: value, weight: weight)
        }
        return Allocation(slices: slices, total: total, unpriced: unpriced)
    }
}
