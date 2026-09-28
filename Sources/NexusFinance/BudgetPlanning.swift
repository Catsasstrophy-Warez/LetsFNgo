import Foundation
import NexusCore
import NexusModel
import NexusPersistence

// The budget screen's model: one row per category for a month, with the
// person's amount (recorded), the actual from recorded transactions
// (derived on read), what is left, and an optional rollover that carries
// each category's unspent or overspent amount into the next month.

/// Where a category stands against its budget.
public enum BudgetStatus: String, Sendable, Hashable, CaseIterable {
    /// No amount set for the category this month.
    case unbudgeted
    /// Spending below 85 % of what is available.
    case onTrack
    /// Spending between 85 % and 100 %.
    case nearLimit
    /// Spending above what is available.
    case over
    /// Income at or above its budget.
    case incomeMet
    /// Income below its budget so far.
    case incomeShort
}

/// One category in a month's budget.
public struct BudgetOverviewRow: Sendable, Hashable, Identifiable {
    public var id: ObjectID { category }
    public var category: ObjectID
    public var name: String
    public var kind: CategoryKind
    /// The person's amount for the month (recorded), or nil when unbudgeted.
    public var budgeted: Money?
    /// Carried in from earlier months under rollover (derived). Zero otherwise.
    public var carriedOver: Money
    /// `budgeted + carriedOver`.
    public var available: Money?
    /// Spending (expense) or earnings (income), positive, from recorded transactions (derived).
    public var actual: Money
    /// `available − actual`: left to spend, or still to come for income. Negative when over.
    public var remaining: Money?
    /// `actual / available`; above 1 when over. Nil when nothing is available.
    public var progress: Double?
    public var status: BudgetStatus
    public var transactionCount: Int
}

/// A month's budget against actuals.
public struct BudgetOverview: Sendable, Hashable {
    public var month: YearMonth
    public var currency: Currency
    /// The stored budget, when the month has one.
    public var budget: Budget?
    public var rollover: Bool
    /// Expense categories, then income, each by name.
    public var rows: [BudgetOverviewRow]
    /// Spending with no category, positive.
    public var uncategorized: Money
    /// Expense totals.
    public var totalBudgeted: Money
    public var totalAvailable: Money
    public var totalActual: Money
    public var totalRemaining: Money
    /// The truth of the budget amounts: recorded when a person wrote them.
    public var budgetTruth: TruthClass?

    public func row(_ category: ObjectID) -> BudgetOverviewRow? { rows.first { $0.category == category } }
}

extension Budget {
    /// Whether this month carries each category's leftover from the month before.
    public var rollover: Bool { record.bool(FinanceKey.rollover) ?? false }
}

extension Decimal {
    /// For display and progress bars only; money stays `Decimal`.
    public var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

extension Budgets {
    /// Reads an amount typed into a budget field: blank is nil (no budget),
    /// "1,200", "1200.50" and "$80" are accepted, anything else throws.
    public static func parseAmount(_ text: String, currency: Currency) throws -> Money? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Decimal(exactly: trimmed) ?? NumberFormat.us.parse(trimmed) else { throw FinanceError.unparsableAmount(text, line: 0) }
        return Money(value, currency).magnitude
    }

    /// Every stored budget, oldest month first.
    public func budgets() throws -> [Budget] {
        try store.objects(ofType: .budget).filter { $0.lifecycle == .active }.map(Budget.init).filter { $0.month != nil }.sorted { $0.month! < $1.month! }
    }

    /// Sets (or with nil, removes) one category's amount for the month,
    /// keeping the other lines. The amount is the person's own plan:
    /// recorded truth. A month with no budget gets one in the amount's currency.
    @discardableResult
    public func setAmount(_ amount: Money?, for category: ObjectID, in month: YearMonth, by author: Origin) throws -> Budget? {
        let existing = try budget(for: month)
        var lines = existing?.lines ?? [:]
        lines[category] = amount?.magnitude
        guard let currency = existing?.currency ?? amount?.currency else { return existing }
        if existing == nil && lines.isEmpty { return nil }
        return try setBudget(for: month, currency: currency, lines: lines, by: author)
    }

    /// Turns rollover on or off for the month (the person's setting,
    /// recorded). A month without a budget gets an empty one in `currency`.
    @discardableResult
    public func setRollover(_ enabled: Bool, for month: YearMonth, currency: Currency, by author: Origin) throws -> Budget {
        let existing = try budget(for: month) ?? setBudget(for: month, currency: currency, lines: [:], by: author)
        let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "budget rollover")
        return Budget(
            record: try store.update(existing.id, by: author, instruction: "Rollover \(enabled ? "on" : "off") for \(month)") {
                $0.attributes[FinanceKey.rollover] = Attribute(.bool(enabled), provenance: provenance)
            })
    }

    /// Copies one month's amounts (and its rollover setting) into another,
    /// replacing what that month had.
    @discardableResult
    public func copyBudget(from source: YearMonth, to target: YearMonth, by author: Origin) throws -> Budget? {
        guard let budget = try budget(for: source), let currency = budget.currency else { return nil }
        let copy = try setBudget(for: target, currency: currency, lines: budget.lines, by: author)
        return budget.rollover ? try setRollover(true, for: target, currency: currency, by: author) : copy
    }

    /// Net recorded amount per category in the month (nil = uncategorised),
    /// leaving out transfers and transactions in other currencies' accounts.
    func actuals(for month: YearMonth, currency: Currency, accounts: Set<ObjectID>?, kinds: [ObjectID: CategoryKind]) throws
        -> (net: [ObjectID?: Money], counts: [ObjectID?: Int], uncategorizedOutflow: Money)
    {
        let scope = try accounts ?? Set(ledger.accounts().filter { $0.currency == currency }.map(\.id))
        var net: [ObjectID?: Money] = [:]
        var counts: [ObjectID?: Int] = [:]
        var outflow = Money.zero(currency)
        for transaction in try recordedTransactions(during: month.interval, accounts: scope) where transaction.amount.currency == currency {
            if let category = transaction.category, kinds[category] == .transfer { continue }
            net[transaction.category] = try (net[transaction.category] ?? .zero(currency)) + transaction.amount
            counts[transaction.category, default: 0] += 1
            if transaction.category == nil, transaction.amount.isNegative { outflow = try outflow + transaction.amount.magnitude }
        }
        return (net, counts, outflow)
    }

    /// What rolls into `month` for an expense category: the previous month's
    /// available amount less its spending, when `month` has rollover on and
    /// the previous month has a budget. Chains back at most `depth` months.
    func carry(
        into month: YearMonth, category: ObjectID, currency: Currency, accounts: Set<ObjectID>?, kinds: [ObjectID: CategoryKind], depth: Int = 24
    ) throws -> Money {
        guard depth > 0, let budget = try budget(for: month), budget.rollover, kinds[category] != .income else { return .zero(currency) }
        let previous = month.adding(-1)
        guard let earlier = try self.budget(for: previous), earlier.currency == currency, let planned = earlier.lines[category] else {
            return .zero(currency)
        }
        let carried = try carry(into: previous, category: category, currency: currency, accounts: accounts, kinds: kinds, depth: depth - 1)
        let spent = -(try actuals(for: previous, currency: currency, accounts: accounts, kinds: kinds).net[category] ?? .zero(currency))
        return try planned + carried - spent
    }

    /// The month's budget against actuals, one row per category (expense
    /// and income) whether budgeted or not. `currency` is used when the month
    /// has no budget yet (default: the first account's, else USD).
    public func overview(for month: YearMonth, currency: Currency? = nil, accounts: Set<ObjectID>? = nil) throws -> BudgetOverview {
        let budget = try budget(for: month)
        let currency = try budget?.currency ?? currency ?? ledger.accounts().first?.currency ?? .usd
        let categories = try ledger.categories().filter { $0.kind != .transfer }
        let kinds = Dictionary(uniqueKeysWithValues: try ledger.categories().map { ($0.id, $0.kind) })
        let (net, counts, uncategorized) = try actuals(for: month, currency: currency, accounts: accounts, kinds: kinds)
        let lines = budget?.lines ?? [:]
        var rows: [BudgetOverviewRow] = []
        for category in categories {
            let signed = net[category.id] ?? .zero(currency)
            let actual = category.kind == .income ? signed : -signed
            let budgeted = lines[category.id]
            let carried =
                budgeted == nil ? .zero(currency) : try carry(into: month, category: category.id, currency: currency, accounts: accounts, kinds: kinds)
            let available = try budgeted.map { try $0 + carried }
            let remaining = try available.map { try $0 - actual }
            let progress = available.flatMap { $0.amount > 0 ? (actual.amount / $0.amount).doubleValue : nil }
            let status: BudgetStatus
            switch (category.kind, progress) {
            case (_, nil) where available == nil: status = .unbudgeted
            case (.income, let value): status = (value ?? 0) >= 1 ? .incomeMet : .incomeShort
            case (_, let value?): status = value > 1 ? .over : value >= 0.85 ? .nearLimit : .onTrack
            case (_, nil): status = actual.amount > 0 ? .over : .onTrack
            }
            rows.append(
                BudgetOverviewRow(
                    category: category.id, name: category.name, kind: category.kind, budgeted: budgeted, carriedOver: carried, available: available,
                    actual: actual, remaining: remaining, progress: progress, status: status, transactionCount: counts[category.id] ?? 0
                ))
        }
        rows.sort { ($0.kind == .income ? 1 : 0, $0.name.lowercased()) < ($1.kind == .income ? 1 : 0, $1.name.lowercased()) }
        let expense = rows.filter { $0.kind == .expense && $0.budgeted != nil }
        return BudgetOverview(
            month: month, currency: currency, budget: budget, rollover: budget?.rollover ?? false, rows: rows,
            uncategorized: uncategorized,
            totalBudgeted: try Money.sum(expense.compactMap(\.budgeted), in: currency),
            totalAvailable: try Money.sum(expense.compactMap(\.available), in: currency),
            totalActual: try Money.sum(expense.map(\.actual), in: currency),
            totalRemaining: try Money.sum(expense.compactMap(\.remaining), in: currency),
            budgetTruth: budget?.record.truth(of: FinanceKey.lines)
        )
    }
}
