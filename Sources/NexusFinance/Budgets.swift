import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A typed view of a monthly budget object.
public struct Budget: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var month: YearMonth? { record.string(FinanceKey.month).flatMap(YearMonth.init) }
    public var currency: Currency? { try? Currency(record.string(FinanceKey.currency) ?? "") }

    /// Budgeted amount per category, as positive numbers.
    public var lines: [ObjectID: Money] {
        guard case .map(let fields)? = record.attributes[FinanceKey.lines]?.value else { return [:] }
        var lines: [ObjectID: Money] = [:]
        for (key, value) in fields {
            if let id = ObjectID(key), let money = Money(value) { lines[id] = money }
        }
        return lines
    }
}

public struct BudgetLine: Sendable, Hashable {
    public var category: ObjectID
    public var kind: CategoryKind
    public var budgeted: Money
    /// Spending (expense) or earnings (income) in the month, as a positive amount.
    public var actual: Money
    /// Favourable is positive: under budget for an expense, above budget for income.
    public var variance: Money
    /// Transactions counted in `actual`.
    public var transactions: [ObjectID]
}

public struct BudgetReport: Sendable, Hashable {
    public var month: YearMonth
    public var lines: [BudgetLine]
    /// Recorded spending in categories the budget does not cover, by category (nil = uncategorised).
    public var unbudgeted: [ObjectID?: Money]
    public var totalBudgeted: Money
    public var totalActual: Money
    public var totalVariance: Money

    public func line(_ category: ObjectID) -> BudgetLine? { lines.first { $0.category == category } }
}

/// A cash-flow statement for one period.
public struct CashFlowStatement: Sendable, Hashable {
    public var period: DateInterval
    public var currency: Currency
    /// Money in, excluding transfers.
    public var inflow: Money
    /// Money out, excluding transfers, as a positive amount.
    public var outflow: Money
    public var net: Money
    /// Net per category (nil = uncategorised), excluding transfers.
    public var byCategory: [ObjectID?: Money]
    /// Net of transactions categorised as transfers between own accounts.
    public var transfers: Money
    public var transactionCount: Int
}

/// Monthly budgets and cash flow. Actuals and cash flow count **recorded**
/// transactions only: imported or entered by a person, never modeled or
/// interpreted ones. They are computed on read, so they are derived views
/// and never stored beside the data they summarise.
public struct Budgets: Sendable {
    public let store: NexusStore
    let clock: NexusClock
    let ledger: Ledger

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
        self.ledger = Ledger(store: store, clock: clock)
    }

    /// Creates or replaces the budget for `month`. Amounts are positive and in one currency.
    @discardableResult
    public func setBudget(for month: YearMonth, currency: Currency, lines: [ObjectID: Money], by author: Origin) throws -> Budget {
        for money in lines.values where money.currency != currency { throw MoneyError.currencyMismatch(currency, money.currency) }
        for id in lines.keys { _ = try ledger.category(id) }
        let map = Value.map(Dictionary(uniqueKeysWithValues: lines.map { ($0.key.description, $0.value.magnitude.value) }))
        let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "budget")
        if let existing = try budget(for: month) {
            return Budget(
                record: try store.update(existing.id, by: author, instruction: "Budget \(month)") {
                    $0.attributes[FinanceKey.currency] = Attribute(.string(currency.code), provenance: provenance)
                    $0.attributes[FinanceKey.lines] = Attribute(map, provenance: provenance)
                })
        }
        return Budget(
            record: try store.create(
                ObjectRecord(
                    type: .budget, title: "Budget \(month)",
                    attributes: [
                        FinanceKey.month: Attribute(.string(month.description)),
                        FinanceKey.currency: Attribute(.string(currency.code)),
                        FinanceKey.lines: Attribute(map),
                    ],
                    provenance: provenance
                )))
    }

    public func budget(for month: YearMonth) throws -> Budget? {
        try store.objects(ofType: .budget).filter { $0.lifecycle == .active }.map(Budget.init).first { $0.month == month }
    }

    /// Recorded transactions in the period, for the given accounts (all by default).
    func recordedTransactions(during interval: DateInterval, accounts: Set<ObjectID>?) throws -> [FinancialTransaction] {
        try ledger.transactions(in: accounts, during: interval).filter { $0.truth == .recorded }
    }

    /// Budget against actuals for the month. A transaction in another
    /// currency than the budget's throws: amounts are never mixed.
    public func report(for month: YearMonth, accounts: Set<ObjectID>? = nil) throws -> BudgetReport? {
        guard let budget = try budget(for: month), let currency = budget.currency else { return nil }
        let categories = Dictionary(uniqueKeysWithValues: try ledger.categories().map { ($0.id, $0) })
        var actuals: [ObjectID?: Money] = [:]
        var members: [ObjectID?: [ObjectID]] = [:]
        for transaction in try recordedTransactions(during: month.interval, accounts: accounts) {
            let key = transaction.category
            if let key, categories[key]?.kind == .transfer { continue }
            actuals[key] = try (actuals[key] ?? .zero(currency)) + transaction.amount
            members[key, default: []].append(transaction.id)
        }
        let budgeted = budget.lines
        var lines: [BudgetLine] = []
        for (category, amount) in budgeted.sorted(by: { $0.key < $1.key }) {
            let kind = categories[category]?.kind ?? .expense
            let net = actuals[category] ?? .zero(currency)
            let actual = kind == .income ? net : -net
            let variance = try kind == .income ? actual - amount : amount - actual
            lines.append(
                BudgetLine(category: category, kind: kind, budgeted: amount, actual: actual, variance: variance, transactions: members[category] ?? []))
        }
        var unbudgeted: [ObjectID?: Money] = [:]
        for (category, net) in actuals where category.map({ budgeted[$0] == nil }) ?? true {
            unbudgeted[category] = net
        }
        let expenseLines = lines.filter { $0.kind == .expense }
        return BudgetReport(
            month: month, lines: lines, unbudgeted: unbudgeted,
            totalBudgeted: try Money.sum(expenseLines.map(\.budgeted), in: currency),
            totalActual: try Money.sum(expenseLines.map(\.actual), in: currency),
            totalVariance: try Money.sum(expenseLines.map(\.variance), in: currency)
        )
    }

    /// The cash-flow statement for any period (start inclusive, end exclusive).
    public func cashFlow(during period: DateInterval, currency: Currency, accounts: Set<ObjectID>? = nil) throws -> CashFlowStatement {
        let kinds = Dictionary(uniqueKeysWithValues: try ledger.categories().map { ($0.id, $0.kind) })
        var inflow = Money.zero(currency)
        var outflow = Money.zero(currency)
        var transfers = Money.zero(currency)
        var byCategory: [ObjectID?: Money] = [:]
        let transactions = try recordedTransactions(during: period, accounts: accounts)
        for transaction in transactions {
            let amount = transaction.amount
            if let category = transaction.category, kinds[category] == .transfer {
                transfers = try transfers + amount
                continue
            }
            if amount.isNegative { outflow = try outflow + amount.magnitude } else { inflow = try inflow + amount }
            byCategory[transaction.category] = try (byCategory[transaction.category] ?? .zero(currency)) + amount
        }
        return CashFlowStatement(
            period: period, currency: currency, inflow: inflow, outflow: outflow, net: try inflow - outflow, byCategory: byCategory,
            transfers: transfers, transactionCount: transactions.count
        )
    }

    public func cashFlow(for month: YearMonth, currency: Currency, accounts: Set<ObjectID>? = nil) throws -> CashFlowStatement {
        try cashFlow(during: month.interval, currency: currency, accounts: accounts)
    }

    /// One statement per month from `start` through `end`.
    public func cashFlow(from start: YearMonth, through end: YearMonth, currency: Currency, accounts: Set<ObjectID>? = nil) throws -> [CashFlowStatement] {
        var statements: [CashFlowStatement] = []
        var month = start
        while month <= end {
            statements.append(try cashFlow(for: month, currency: currency, accounts: accounts))
            month = month.next
        }
        return statements
    }
}
