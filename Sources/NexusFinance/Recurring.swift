import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// How often a recurring transaction repeats.
public enum Cadence: String, Codable, Sendable, CaseIterable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case annual

    /// Gaps in days accepted as this cadence.
    var gapRange: ClosedRange<Int> {
        switch self {
        case .weekly: 6...8
        case .biweekly: 13...15
        case .monthly: 27...34
        case .quarterly: 85...97
        case .annual: 355...375
        }
    }

    /// The next occurrence after `date`. Monthly and longer keep the day of
    /// month (clamped at month end), shorter ones add days.
    public func next(after date: Date) -> Date {
        switch self {
        case .weekly: FinanceCalendar.adding(days: 7, to: date)
        case .biweekly: FinanceCalendar.adding(days: 14, to: date)
        case .monthly: FinanceCalendar.adding(months: 1, to: date)
        case .quarterly: FinanceCalendar.adding(months: 3, to: date)
        case .annual: FinanceCalendar.adding(months: 12, to: date)
        }
    }
}

/// A detected run of transactions from one payee on one account at a steady cadence.
public struct RecurringPattern: Sendable, Hashable {
    public var account: ObjectID
    public var payee: String
    public var cadence: Cadence
    /// The median amount (signed).
    public var amount: Money
    /// Whether the amounts differ (a utility bill) rather than repeat exactly (rent).
    public var amountVaries: Bool
    public var lastDate: Date
    public var nextDate: Date
    public var transactions: [ObjectID]

    /// Identity of the series across detection runs.
    public var key: String { "\(account)|\(normalizedPayee(payee))|\(amount.isNegative ? "out" : "in")|\(cadence.rawValue)" }
}

/// A stored `recurringSeries` object.
public struct RecurringSeries: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var account: ObjectID? { record.reference(FinanceKey.account) }
    public var payee: String { record.string(FinanceKey.payee) ?? record.title }
    public var cadence: Cadence? { record.string(FinanceKey.cadence).flatMap(Cadence.init(rawValue:)) }
    public var amount: Money? { record.money(FinanceKey.amount) }
    public var nextDate: Date? { record.date(FinanceKey.nextDate) }
    public var lastDate: Date? { record.date(FinanceKey.lastDate) }
    public var truth: TruthClass { record.provenance.truth }
}

/// Finds recurring transactions (rent, salary, subscriptions) in recorded
/// data. A series is a calculation over recorded transactions, so it is
/// stored as **derived** truth with those transactions as dependencies.
public struct RecurringDetector: Sendable {
    public let store: NexusStore
    let clock: NexusClock
    /// At least this many transactions make a series.
    public var minimumOccurrences: Int
    /// Amounts may differ from the median by this fraction (0.1 = 10 %).
    public var amountTolerance: Decimal

    public init(store: NexusStore, clock: NexusClock = SystemClock(), minimumOccurrences: Int = 3, amountTolerance: Decimal = 0.1) {
        self.store = store
        self.clock = clock
        self.minimumOccurrences = minimumOccurrences
        self.amountTolerance = amountTolerance
    }

    /// Detects series among recorded transactions without storing anything.
    public func detect(accounts: Set<ObjectID>? = nil) throws -> [RecurringPattern] {
        let transactions = try Ledger(store: store, clock: clock).transactions(in: accounts).filter { $0.truth == .recorded }
        let groups = Dictionary(grouping: transactions) { transaction in
            "\(transaction.account?.description ?? "")|\(normalizedPayee(transaction.payee))|\(transaction.amount.isNegative)"
        }
        var patterns: [RecurringPattern] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            guard group.count >= minimumOccurrences, let account = group[0].account, !normalizedPayee(group[0].payee).isEmpty else { continue }
            let gaps = zip(group, group.dropFirst()).map { FinanceCalendar.days(from: $0.date, to: $1.date) }
            guard let cadence = Cadence.allCases.first(where: { cadence in gaps.allSatisfy(cadence.gapRange.contains) }) else { continue }
            let currency = group[0].amount.currency
            guard group.allSatisfy({ $0.amount.currency == currency }) else { continue }
            let amounts = group.map(\.amount.amount).sorted()
            let median = amounts.count % 2 == 1 ? amounts[amounts.count / 2] : (amounts[amounts.count / 2 - 1] + amounts[amounts.count / 2]) / 2
            let limit = median.magnitude * amountTolerance
            guard amounts.allSatisfy({ ($0 - median).magnitude <= limit }) else { continue }
            let last = group[group.count - 1].date
            patterns.append(
                RecurringPattern(
                    account: account, payee: group[group.count - 1].payee, cadence: cadence, amount: Money(median, currency),
                    amountVaries: Set(amounts).count > 1, lastDate: last, nextDate: cadence.next(after: last), transactions: group.map(\.id)
                ))
        }
        return patterns
    }

    /// Detects series and stores each as a derived `recurringSeries` object,
    /// updating the object from an earlier run rather than adding another.
    @discardableResult
    public func detectAndStore(accounts: Set<ObjectID>? = nil) throws -> [RecurringSeries] {
        let patterns = try detect(accounts: accounts)
        return try store.batch { store in
            let existing = Dictionary(
                try store.objects(ofType: .recurringSeries).compactMap { record in record.string(FinanceKey.seriesKey).map { ($0, record) } },
                uniquingKeysWith: { first, _ in first })
            return try patterns.map { pattern in
                let provenance = Provenance(
                    origin: .system, truth: .derived, timestamp: clock.now(),
                    method: "recurring detection: \(pattern.transactions.count) × \(pattern.cadence.rawValue)", dependencies: pattern.transactions,
                    transformation: "recurringDetection"
                )
                let attributes: [String: Attribute] = [
                    FinanceKey.seriesKey: Attribute(.string(pattern.key)),
                    FinanceKey.account: Attribute(.reference(pattern.account)),
                    FinanceKey.payee: Attribute(.string(pattern.payee)),
                    FinanceKey.cadence: Attribute(.string(pattern.cadence.rawValue)),
                    FinanceKey.amount: Attribute(pattern.amount.value),
                    FinanceKey.amountVaries: Attribute(.bool(pattern.amountVaries)),
                    FinanceKey.lastDate: Attribute(.date(pattern.lastDate)),
                    FinanceKey.nextDate: Attribute(.date(pattern.nextDate)),
                    FinanceKey.occurrences: Attribute(.int(Int64(pattern.transactions.count))),
                ]
                if let record = existing[pattern.key] {
                    return RecurringSeries(
                        record: try store.update(record.id, by: .system, instruction: "Recurring detection") {
                            $0.provenance = provenance
                            $0.attributes = attributes
                        })
                }
                let record = try store.create(
                    ObjectRecord(
                        type: .recurringSeries, title: "\(pattern.payee) (\(pattern.cadence.rawValue))", attributes: attributes, provenance: provenance
                    ))
                try store.relate(Relationship(kind: .belongsTo, from: record.id, to: pattern.account, provenance: provenance))
                return RecurringSeries(record: record)
            }
        }
    }

    /// Stored series, optionally for some accounts.
    public func series(accounts: Set<ObjectID>? = nil) throws -> [RecurringSeries] {
        try store.objects(ofType: .recurringSeries).filter { $0.lifecycle == .active }.map(RecurringSeries.init)
            .filter { series in accounts.map { set in series.account.map(set.contains) ?? false } ?? true }
    }
}
