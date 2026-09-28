import Foundation
import NexusAI
import NexusCore
import NexusFinance
import NexusModel
import NexusPermissions
import NexusPersistence

/// Tools over the finance domain. The read tools (P0) go through the same
/// `NexusFinance` types as the screens and label every value with its truth
/// class: balances and transactions are recorded, totals and budget actuals
/// derived, projections modeled and scenario assumptions claimed. The two
/// tools that change data are P3: running a forecast stores a modeled
/// projection on the scenario, and categorising writes an agent
/// interpretation that never replaces a person's category.
public enum FinanceTools {
    public static var all: [any AgentTool] {
        [FinanceBalances(), FinanceSpending(), FinanceBudgetStatus(), FinanceRecurring(), FinanceForecast(), RunForecast(), CategorizeTransaction()]
    }
}

extension ToolScope {
    /// Data source the finance tools declare.
    public static let finance = "finance"
}

private func typedArg(_ type: String, _ description: String) -> Value {
    .map(["type": .string(type), "description": .string(description)])
}

private func month(_ key: String, _ arguments: [String: Value], default fallback: YearMonth) throws -> YearMonth {
    guard let text = try arguments.optionalText(key, maxLength: 7) else { return fallback }
    guard let month = YearMonth(text) else { throw ToolError.invalidArgument(key) }
    return month
}

private func accountScope(_ arguments: [String: Value], in context: ToolContext) throws -> [Account] {
    let ledger = NexusFinance.Ledger(store: context.store, clock: context.clock)
    guard let id = try arguments.optionalObjectID("account") else { return try ledger.accounts() }
    do {
        return [try ledger.account(id)]
    } catch {
        throw ToolError.notFound("account \(id)")
    }
}

private func names(_ context: ToolContext) throws -> [ObjectID: String] {
    Dictionary(uniqueKeysWithValues: try NexusFinance.Ledger(store: context.store, clock: context.clock).categories().map { ($0.id, $0.name) })
}

/// P0. Accounts with their last stated balance and its truth.
public struct FinanceBalances: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "finance_balances", description: "List accounts with their last stated balance, its date and truth class.",
        parameters: schema(["account": objectArg("Account ID; all accounts when omitted")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.account], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let accounts = try accountScope(arguments, in: context)
        let lines = accounts.map { account -> String in
            let head = "\(account.id) \(account.name) [\(account.kind.rawValue), \(account.currency)]"
            guard let balance = account.balance, let asOf = account.balanceAsOf else { return "\(head): no stated balance" }
            return "\(head): \(balance) as of \(FinanceCalendar.isoDay(asOf)) (\((account.balanceTruth ?? .recorded).rawValue))"
        }
        return ToolOutcome(content: lines.isEmpty ? "No accounts." : lines.joined(separator: "\n"), touched: accounts.map(\.id))
    }
}

/// P0. Money in and out by category over one or more months.
public struct FinanceSpending: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "finance_spending",
        description: "Spending and income by category for a month or a range of months, from recorded transactions (derived totals).",
        parameters: schema(
            [
                "month": objectArg("First month, YYYY-MM; defaults to this month"),
                "through": objectArg("Last month, YYYY-MM; defaults to `month`"),
                "account": objectArg("Account ID; all accounts when omitted"),
            ], required: []),
        permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.account, .transaction, .transactionCategory], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let start = try month("month", arguments, default: YearMonth(context.clock.now()))
        let end = try month("through", arguments, default: start)
        guard start <= end, end.year * 12 + end.month - (start.year * 12 + start.month) < 120 else { throw ToolError.invalidArgument("through") }
        let accounts = try accountScope(arguments, in: context)
        let budgets = Budgets(store: context.store, clock: context.clock)
        let categoryNames = try names(context)
        let period = DateInterval(start: start.start, end: end.end)
        var lines = ["Period \(start) through \(end). Totals are derived from recorded transactions; transfers between own accounts are separate."]
        let byCurrency = Dictionary(grouping: accounts, by: \.currency)
        for currency in byCurrency.keys.sorted(by: { $0.code < $1.code }) {
            let ids = Set(byCurrency[currency]!.map(\.id))
            let flow = try budgets.cashFlow(during: period, currency: currency, accounts: ids)
            lines.append(
                "\(currency): in \(flow.inflow), out \(flow.outflow), net \(flow.net), transfers \(flow.transfers), \(flow.transactionCount) transactions (derived)"
            )
            let rows = flow.byCategory.sorted { $0.value.amount < $1.value.amount }
            for (category, amount) in rows {
                lines.append("- \(category.flatMap { categoryNames[$0] } ?? "Uncategorised"): \(amount)")
            }
        }
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: accounts.map(\.id))
    }
}

/// P0. A month's budget against actuals.
public struct FinanceBudgetStatus: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "finance_budget_status",
        description: "A month's budget per category: the person's amount (recorded), actual and remaining (derived), and status.",
        parameters: schema(["month": objectArg("YYYY-MM; defaults to this month")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.budget, .transaction, .transactionCategory], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let month = try month("month", arguments, default: YearMonth(context.clock.now()))
        let overview = try Budgets(store: context.store, clock: context.clock).overview(for: month)
        guard let budget = overview.budget else { return ToolOutcome(content: "No budget is set for \(month).") }
        var lines = [
            "Budget \(month) in \(overview.currency) (amounts \((overview.budgetTruth ?? .recorded).rawValue); actuals derived)"
                + (overview.rollover ? ", rollover on" : "")
        ]
        for row in overview.rows where row.budgeted != nil {
            var text = "- \(row.name) [\(row.kind.rawValue)]: budget \(row.budgeted!)"
            if !row.carriedOver.isZero { text += ", carried \(row.carriedOver)" }
            text += ", actual \(row.actual), remaining \(row.remaining.map(\.description) ?? "-"), \(row.status.rawValue)"
            lines.append(text)
        }
        let unbudgeted = overview.rows.filter { $0.budgeted == nil && !$0.actual.isZero }
        for row in unbudgeted { lines.append("- \(row.name): not budgeted, actual \(row.actual)") }
        if !overview.uncategorized.isZero { lines.append("- Uncategorised spending: \(overview.uncategorized)") }
        lines.append("Expenses: budget \(overview.totalBudgeted), actual \(overview.totalActual), remaining \(overview.totalRemaining)")
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: [budget.id])
    }
}

/// P0. Recurring charges and income detected in recorded transactions.
public struct FinanceRecurring: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "finance_recurring",
        description: "Recurring charges and income (subscriptions, rent, salary) detected in recorded transactions (derived).",
        parameters: schema(["account": objectArg("Account ID; all accounts when omitted")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.transaction, .recurringSeries], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let accounts = try accountScope(arguments, in: context)
        let patterns = try RecurringDetector(store: context.store, clock: context.clock).detect(accounts: Set(accounts.map(\.id)))
        let lines = patterns.sorted { $0.amount.amount < $1.amount.amount }.map { pattern in
            "- \(pattern.payee): \(pattern.amount) \(pattern.cadence.rawValue)\(pattern.amountVaries ? " (varies)" : ""), "
                + "\(pattern.transactions.count) times, last \(FinanceCalendar.isoDay(pattern.lastDate)), next about \(FinanceCalendar.isoDay(pattern.nextDate))"
        }
        guard !lines.isEmpty else { return ToolOutcome(content: "No recurring transactions found.", touched: accounts.map(\.id)) }
        return ToolOutcome(
            content: (["Recurring series (derived from recorded transactions; next dates are estimates):"] + lines).joined(separator: "\n"),
            touched: accounts.map(\.id) + patterns.flatMap(\.transactions).prefix(200)
        )
    }
}

/// P0. Scenarios, or one scenario's stored projection and assumptions.
/// Reading never runs a projection; `run_forecast` does.
public struct FinanceForecast: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "finance_forecast",
        description: "List forecast scenarios, or read one scenario's last projection (modeled) and its assumptions (claimed).",
        parameters: schema(["scenario": objectArg("Scenario ID; lists scenarios when omitted")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.financialScenario], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let scenarios = Scenarios(store: context.store, clock: context.clock)
        guard let id = try arguments.optionalObjectID("scenario") else {
            let summaries = try scenarios.summaries()
            let lines = summaries.map { summary in
                "\(summary.id) \(summary.scenario.name): \(summary.scenario.months) months from \(summary.scenario.startMonth.map(\.description) ?? "?"), "
                    + "\(summary.scenario.assumptions.count) assumptions, "
                    + (summary.ending.map { "ends at \($0) (modeled)" } ?? "not run yet")
            }
            return ToolOutcome(content: lines.isEmpty ? "No scenarios." : lines.joined(separator: "\n"), touched: summaries.map(\.id))
        }
        let scenario: Scenario
        do { scenario = try scenarios.scenario(id) } catch { throw ToolError.notFound("scenario \(id)") }
        var lines = ["\(scenario.name): \(scenario.months) months from \(scenario.startMonth.map(\.description) ?? "?")"]
        lines.append("Assumptions (\((scenario.assumptionsTruth ?? .claimed).rawValue)):")
        lines += scenario.assumptions.isEmpty ? ["- none"] : scenario.assumptions.map { "- \($0.summary)" }
        if let forecast = try scenarios.forecast(id) {
            lines.append("Projection (\(forecast.provenance.truth.rawValue), run \(FinanceCalendar.isoDay(forecast.provenance.timestamp))):")
            lines.append("- opening \(try Money.sum(forecast.opening.values, in: forecast.currency)) (recorded balances)")
            lines += forecast.points.map { "- \($0.month): \($0.total)" }
            if let lowest = forecast.minimum { lines.append("Lowest: \(lowest.total) in \(lowest.month)") }
            if let negative = forecast.firstNegativeMonth { lines.append("First month below zero: \(negative)") }
        } else {
            lines.append("Not run yet; run_forecast computes the projection.")
        }
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: [id] + scenario.accounts)
    }
}

/// P3. Runs a scenario and stores its projection on the scenario as modeled
/// truth. It never writes an account balance.
public struct RunForecast: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "run_forecast", description: "Run a forecast scenario and store its projection (modeled) on the scenario.",
        parameters: schema(["scenario": objectArg("Scenario ID")], required: ["scenario"]), permission: .modifyInternalState
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.financialScenario], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("scenario")
        let scenarios = Scenarios(store: context.store, clock: context.clock)
        do { _ = try scenarios.scenario(id) } catch { throw ToolError.notFound("scenario \(id)") }
        let forecast = try scenarios.run(id)
        var text = "Projection stored on \(id) (modeled): ends at \(forecast.ending.map(\.description) ?? "-")"
        if let lowest = forecast.minimum { text += ", lowest \(lowest.total) in \(lowest.month)" }
        if let negative = forecast.firstNegativeMonth { text += ", first below zero \(negative)" }
        return ToolOutcome(content: text, touched: [id])
    }
}

/// P3. Suggests a category for a transaction, stored as the agent's
/// interpretation. A category a person set is refused, and a rule run later
/// replaces the agent's guess.
public struct CategorizeTransaction: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "categorize_transaction",
        description: "Set a transaction's category as your interpretation. Never replaces a category a person set.",
        parameters: schema(
            [
                "transaction": objectArg("Transaction ID"), "category": objectArg("Category ID or exact name"),
                "reason": objectArg("Why this category"), "confidence": typedArg("number", "0...1"),
            ], required: ["transaction", "category"]),
        permission: .modifyInternalState
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.transaction, .transactionCategory], dataSource: ToolScope.finance) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let ledger = NexusFinance.Ledger(store: context.store, clock: context.clock)
        let id = try arguments.objectID("transaction")
        let transaction: FinancialTransaction
        do { transaction = try ledger.transaction(id) } catch { throw ToolError.notFound("transaction \(id)") }
        let name: String
        if case .reference(let reference)? = arguments["category"] {
            name = reference.description
        } else {
            name = try arguments.text("category", maxLength: 200)
        }
        let category: TransactionCategory
        if let categoryID = ObjectID(name), let found = try? ledger.category(categoryID) {
            category = found
        } else if let found = try ledger.category(named: name) {
            category = found
        } else {
            throw ToolError.notFound("category \(name)")
        }
        if let truth = transaction.categoryTruth, TruthPolicy.protected.contains(truth) {
            throw ToolError.refused("a person set this transaction's category (\(truth.rawValue)); it is not changed")
        }
        let confidence = try arguments.optionalDouble("confidence", in: 0...1)
        let reason = try arguments.optionalText("reason", maxLength: 500)
        let provenance = Provenance(
            origin: context.origin, truth: .agentInterpretation, timestamp: context.clock.now(), method: reason ?? "agent categorisation",
            confidence: confidence, dependencies: [id]
        )
        try context.store.update(id, by: context.origin, instruction: "Categorise as \(category.name)") {
            $0.attributes[FinanceKey.category] = Attribute(.reference(category.id), provenance: provenance)
        }
        return ToolOutcome(content: "Categorised \(transaction.payee) as \(category.name) (agentInterpretation)", touched: [id, category.id])
    }
}
