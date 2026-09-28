import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A typed view of an account object. The canonical state stays in the store.
public struct Account: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var name: String { record.title }
    public var kind: AccountKind { record.string(FinanceKey.kind).flatMap(AccountKind.init(rawValue:)) ?? .other }
    public var currency: Currency { (try? Currency(record.string(FinanceKey.currency) ?? "")) ?? .usd }
    public var institution: String? { record.string(FinanceKey.institution) }
    public var accountNumber: String? { record.string(FinanceKey.accountNumber) }
    /// The last balance a statement or a person stated (recorded or observed truth).
    public var balance: Money? { record.money(FinanceKey.balance) }
    public var balanceAsOf: Date? { record.date(FinanceKey.balanceAsOf) }
    public var balanceTruth: TruthClass? { record.truth(of: FinanceKey.balance) }
}

public struct TransactionCategory: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var name: String { record.title }
    public var kind: CategoryKind { record.string(FinanceKey.kind).flatMap(CategoryKind.init(rawValue:)) ?? .expense }
    public var parent: ObjectID? { record.reference(FinanceKey.parent) }
}

/// A transaction as entered or imported, before it is stored.
public struct TransactionDraft: Sendable, Hashable {
    public var date: Date
    /// Signed: negative is money leaving the account.
    public var amount: Money
    public var payee: String
    public var memo: String?
    /// The bank's unique transaction ID (OFX FITID), when there is one.
    public var fitID: String?
    public var checkNumber: String?
    /// OFX TRNTYPE or the CSV's own type column.
    public var type: String?

    public init(
        date: Date, amount: Money, payee: String, memo: String? = nil, fitID: String? = nil, checkNumber: String? = nil, type: String? = nil
    ) {
        self.date = FinanceCalendar.startOfDay(date)
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.fitID = fitID
        self.checkNumber = checkNumber
        self.type = type
    }

    /// The (date, amount, payee) hash used to find a duplicate when there is no FITID.
    public var contentHash: String {
        ContentHash.sha256("\(FinanceCalendar.isoDay(date))|\(amount.amount.plainString)|\(amount.currency.code)|\(normalizedPayee(payee))")
    }
}

/// A typed view of a transaction object.
public struct FinancialTransaction: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var account: ObjectID? { record.reference(FinanceKey.account) }
    public var date: Date { record.date(FinanceKey.date) ?? record.createdAt }
    public var amount: Money { record.money(FinanceKey.amount) ?? .zero(.usd) }
    public var payee: String { record.string(FinanceKey.payee) ?? record.title }
    public var memo: String? { record.string(FinanceKey.memo) }
    public var fitID: String? { record.string(FinanceKey.fitID) }
    public var contentKey: String? { record.string(FinanceKey.contentKey) }
    /// The transaction's own truth: recorded for anything imported or entered.
    public var truth: TruthClass { record.provenance.truth }
    public var category: ObjectID? { record.reference(FinanceKey.category) }
    /// Who set the category: recorded (a person), derived (a rule) or agentInterpretation (a model).
    public var categoryProvenance: Provenance? {
        record.attributes[FinanceKey.category].map { $0.provenance ?? record.provenance }
    }
    public var categoryTruth: TruthClass? { record.truth(of: FinanceKey.category) }
}

/// Accounts, categories, transactions and stated balances, all as objects,
/// relationships and events in the shared store.
public struct Ledger: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Accounts

    @discardableResult
    public func addAccount(
        name: String, kind: AccountKind, currency: Currency, institution: String? = nil, accountNumber: String? = nil, bankID: String? = nil,
        by author: Origin
    ) throws -> Account {
        var attributes: [String: Attribute] = [
            FinanceKey.kind: Attribute(.string(kind.rawValue)),
            FinanceKey.currency: Attribute(.string(currency.code)),
        ]
        if let institution { attributes[FinanceKey.institution] = Attribute(.string(institution)) }
        if let accountNumber { attributes[FinanceKey.accountNumber] = Attribute(.string(accountNumber)) }
        if let bankID { attributes[FinanceKey.bankID] = Attribute(.string(bankID)) }
        let record = try store.create(
            ObjectRecord(
                type: .account, title: name, attributes: attributes,
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now())
            ))
        return Account(record: record)
    }

    public func account(_ id: ObjectID) throws -> Account {
        guard let record = try store.object(id), record.type == .account else { throw FinanceError.notFound(id, expected: .account) }
        return Account(record: record)
    }

    public func accounts() throws -> [Account] {
        try store.objects(ofType: .account).filter { $0.lifecycle != .deleted }.map(Account.init)
    }

    public func account(number: String, bankID: String? = nil) throws -> Account? {
        try accounts().first {
            $0.accountNumber == number && (bankID == nil || $0.record.string(FinanceKey.bankID) == nil || $0.record.string(FinanceKey.bankID) == bankID)
        }
    }

    /// Records a balance a statement or a person stated for the account.
    ///
    /// Only recorded or observed truth may sit on an account balance. A
    /// forecast is modeled truth and lives on its scenario; offering one here
    /// throws `truthNotAllowed`, and the store's `TruthPolicy` would refuse it
    /// anyway. An older statement never replaces a newer balance.
    @discardableResult
    public func recordBalance(_ balance: Money, asOf date: Date, on accountID: ObjectID, by author: Origin, method: String? = nil) throws -> Account {
        try recordBalance(
            balance, asOf: date, on: accountID, provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: method))
    }

    @discardableResult
    public func recordBalance(_ balance: Money, asOf date: Date, on accountID: ObjectID, provenance: Provenance) throws -> Account {
        guard TruthPolicy.protected.contains(provenance.truth) else { throw FinanceError.truthNotAllowed(provenance.truth, field: FinanceKey.balance) }
        return try store.batch { store in
            let account = try account(accountID)
            guard balance.currency == account.currency else { throw MoneyError.currencyMismatch(account.currency, balance.currency) }
            try store.record(
                Event(
                    at: date, kind: .balanceStated, subjects: [accountID], summary: "Balance \(balance)",
                    payload: [FinanceKey.balance: balance.value], provenance: provenance
                ))
            if let current = account.balanceAsOf, current > date { return account }
            let updated = try store.update(accountID, by: provenance.origin, instruction: "Balance as of \(FinanceCalendar.isoDay(date))") {
                $0.attributes[FinanceKey.balance] = Attribute(balance.value, provenance: provenance)
                $0.attributes[FinanceKey.balanceAsOf] = Attribute(.date(date), provenance: provenance)
            }
            return Account(record: updated)
        }
    }

    // MARK: Categories

    @discardableResult
    public func addCategory(_ name: String, kind: CategoryKind = .expense, parent: ObjectID? = nil, by author: Origin) throws -> TransactionCategory {
        var attributes: [String: Attribute] = [FinanceKey.kind: Attribute(.string(kind.rawValue))]
        if let parent { attributes[FinanceKey.parent] = Attribute(.reference(parent)) }
        let record = try store.create(
            ObjectRecord(
                type: .transactionCategory, title: name, attributes: attributes,
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now())
            ))
        return TransactionCategory(record: record)
    }

    public func categories() throws -> [TransactionCategory] {
        try store.objects(ofType: .transactionCategory).filter { $0.lifecycle != .deleted }.map(TransactionCategory.init)
    }

    public func category(_ id: ObjectID) throws -> TransactionCategory {
        guard let record = try store.object(id), record.type == .transactionCategory else {
            throw FinanceError.notFound(id, expected: .transactionCategory)
        }
        return TransactionCategory(record: record)
    }

    public func category(named name: String) throws -> TransactionCategory? {
        try categories().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Transactions

    /// Stores one transaction. Its truth comes from the provenance: recorded
    /// for an importer or a person. The currency must match the account's.
    @discardableResult
    public func addTransaction(_ draft: TransactionDraft, to accountID: ObjectID, by author: Origin) throws -> FinancialTransaction {
        try addTransaction(
            draft, to: accountID, contentKey: draft.contentHash + "#1",
            provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "entered")
        )
    }

    func addTransaction(_ draft: TransactionDraft, to accountID: ObjectID, contentKey: String, provenance: Provenance) throws -> FinancialTransaction {
        try store.batch { store in
            let account = try account(accountID)
            guard draft.amount.currency == account.currency else { throw MoneyError.currencyMismatch(account.currency, draft.amount.currency) }
            var attributes: [String: Attribute] = [
                FinanceKey.account: Attribute(.reference(accountID)),
                FinanceKey.date: Attribute(.date(draft.date)),
                FinanceKey.amount: Attribute(draft.amount.value),
                FinanceKey.payee: Attribute(.string(draft.payee)),
                FinanceKey.contentKey: Attribute(.string(contentKey)),
            ]
            if let memo = draft.memo, !memo.isEmpty { attributes[FinanceKey.memo] = Attribute(.string(memo)) }
            if let fitID = draft.fitID, !fitID.isEmpty { attributes[FinanceKey.fitID] = Attribute(.string(fitID)) }
            if let check = draft.checkNumber, !check.isEmpty { attributes[FinanceKey.checkNumber] = Attribute(.string(check)) }
            if let type = draft.type, !type.isEmpty { attributes[FinanceKey.transactionType] = Attribute(.string(type)) }
            let title = draft.payee.isEmpty ? "Transaction \(FinanceCalendar.isoDay(draft.date))" : draft.payee
            let record = try store.create(ObjectRecord(type: .transaction, title: title, attributes: attributes, provenance: provenance))
            try store.relate(Relationship(kind: .postedTo, from: record.id, to: accountID, validFrom: draft.date, provenance: provenance))
            return FinancialTransaction(record: record)
        }
    }

    public func transaction(_ id: ObjectID) throws -> FinancialTransaction {
        guard let record = try store.object(id), record.type == .transaction else { throw FinanceError.notFound(id, expected: .transaction) }
        return FinancialTransaction(record: record)
    }

    /// Live transactions, oldest first, optionally for some accounts and a
    /// date interval (start inclusive, end exclusive).
    public func transactions(in accounts: Set<ObjectID>? = nil, during interval: DateInterval? = nil) throws -> [FinancialTransaction] {
        try store.objects(ofType: .transaction).lazy
            .filter { $0.lifecycle == .active }
            .map(FinancialTransaction.init)
            .filter { transaction in
                if let accounts, !(transaction.account.map(accounts.contains) ?? false) { return false }
                if let interval, !(transaction.date >= interval.start && transaction.date < interval.end) { return false }
                return true
            }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    /// A person sets a transaction's category. This is recorded truth, which
    /// no rule run or model suggestion may overwrite afterwards.
    @discardableResult
    public func setCategory(_ categoryID: ObjectID, on transactionID: ObjectID, by author: Origin) throws -> FinancialTransaction {
        _ = try category(categoryID)
        let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "set by hand")
        let record = try store.update(transactionID, by: author, instruction: "Categorise") {
            guard $0.type == .transaction else { throw FinanceError.notFound(transactionID, expected: .transaction) }
            $0.attributes[FinanceKey.category] = Attribute(.reference(categoryID), provenance: provenance)
        }
        return FinancialTransaction(record: record)
    }
}
