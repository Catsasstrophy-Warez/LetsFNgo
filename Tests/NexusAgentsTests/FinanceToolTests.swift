import Foundation
import NexusAI
import NexusCore
import NexusFinance
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing

@testable import NexusAgents

/// A checking account with three months of salary, rent and groceries, a
/// recorded balance, a September budget and a scenario.
private struct Money3 {
    let bench: Bench
    let account: ObjectID
    let groceries: ObjectID
    let scenario: ObjectID
    let coffee: ObjectID
    let rent: ObjectID

    init() throws {
        bench = try Bench()
        let ledger = NexusFinance.Ledger(store: bench.store, clock: bench.clock)
        account = try ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: tech).id
        groceries = try ledger.addCategory("Groceries", by: tech).id
        let housing = try ledger.addCategory("Housing", by: tech).id
        var rent: ObjectID?
        for month in 7...9 {
            try ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, 1), amount: try Money("4200", .usd), payee: "Acme Payroll"), to: account, by: tech)
            let paid = try ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, 1), amount: try Money("-1850", .usd), payee: "Harbor View Apts"), to: account,
                by: tech)
            try ledger.setCategory(housing, on: paid.id, by: tech)
            rent = paid.id
            let food = try ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, 12), amount: try Money("-80.25", .usd), payee: "Green Grocer"), to: account, by: tech)
            try ledger.setCategory(groceries, on: food.id, by: tech)
        }
        self.rent = rent!
        coffee = try ledger.addTransaction(
            TransactionDraft(date: FinanceCalendar.day(2026, 9, 14), amount: try Money("-4.50", .usd), payee: "Bean There Coffee"), to: account, by: tech
        ).id
        try ledger.recordBalance(try Money("6000", .usd), asOf: FinanceCalendar.day(2026, 9, 30), on: account, by: tech)
        try Budgets(store: bench.store, clock: bench.clock).setBudget(
            for: YearMonth(2026, 9), currency: .usd, lines: [groceries: try Money("100", .usd)], by: tech)
        try RecurringDetector(store: bench.store, clock: bench.clock).detectAndStore()
        scenario = try Scenarios(store: bench.store, clock: bench.clock).createScenario(
            "Baseline", accounts: [account], start: YearMonth(2026, 10), months: 3,
            assumptions: [.oneOff(label: "Bonus", date: FinanceCalendar.day(2026, 12, 15), amount: try Money("1000", .usd), account: account)], by: tech
        ).id
    }
}

@Suite struct FinanceToolTests {
    @Test func readToolsAreP0AndWritingToolsAreP3() {
        let tools = FinanceTools.all
        #expect(Set(tools.map(\.spec.name)).isSubset(of: Set(WorldTools.all.map(\.spec.name))), "Registered with the world tools")
        let writers: Set<String> = ["run_forecast", "categorize_transaction"]
        for tool in tools {
            if writers.contains(tool.spec.name) {
                #expect(tool.spec.permission >= .modifyInternalState, "\(tool.spec.name) changes data")
            } else {
                #expect(tool.spec.permission == .observe, "\(tool.spec.name) only reads")
            }
            #expect(tool.declaredScope.dataSource == ToolScope.finance)
        }
        #expect(AgentProfile.finance.tools.isSuperset(of: Set(tools.map(\.spec.name))))
    }

    @Test func balancesSpendingBudgetAndRecurringCarryTheirTruth() throws {
        let world = try Money3()
        let bench = world.bench
        let balances = try bench.use(FinanceBalances(), [:], agent: "finance")
        #expect(balances.content.contains("Checking [checking, USD]: 6000.00 USD as of 2026-09-30 (recorded)"))
        #expect(balances.touched == [world.account])

        let spending = try bench.use(FinanceSpending(), ["month": .string("2026-09")], agent: "finance")
        #expect(spending.content.contains("USD: in 4200.00 USD, out 1934.75 USD, net 2265.25 USD"))
        #expect(spending.content.contains("(derived)") && spending.content.contains("- Housing: -1850.00 USD"))
        #expect(spending.content.contains("- Uncategorised: 4195.50 USD"), "Payroll -4.50 coffee")
        let quarter = try bench.use(FinanceSpending(), ["month": .string("2026-07"), "through": .string("2026-09")], agent: "finance")
        #expect(quarter.content.contains("- Groceries: -240.75 USD"))
        #expect(throws: ToolError.invalidArgument("month")) { try bench.use(FinanceSpending(), ["month": .string("Sept")], agent: "finance") }
        #expect(throws: ToolError.invalidArgument("through")) {
            try bench.use(FinanceSpending(), ["month": .string("2026-09"), "through": .string("2026-01")], agent: "finance")
        }

        let budget = try bench.use(FinanceBudgetStatus(), ["month": .string("2026-09")], agent: "finance")
        #expect(budget.content.contains("amounts recorded; actuals derived"))
        #expect(budget.content.contains("- Groceries [expense]: budget 100.00 USD, actual 80.25 USD, remaining 19.75 USD, onTrack"))
        #expect(budget.content.contains("- Housing: not budgeted, actual 1850.00 USD"))
        #expect(budget.content.contains("- Uncategorised spending: 4.50 USD"), "Spending only, not uncategorised income")
        let none = try bench.use(FinanceBudgetStatus(), ["month": .string("2027-01")], agent: "finance")
        #expect(none.content == "No budget is set for 2027-01.")

        let recurring = try bench.use(FinanceRecurring(), [:], agent: "finance")
        #expect(recurring.content.contains("derived from recorded transactions"))
        #expect(recurring.content.contains("- Harbor View Apts: -1850.00 USD monthly, 3 times"))
        #expect(recurring.content.contains("- Acme Payroll: 4200.00 USD monthly"))
    }

    @Test func forecastsAreReadAsModeledAndRunOnlyByTheP3Tool() throws {
        let world = try Money3()
        let bench = world.bench
        let list = try bench.use(FinanceForecast(), [:], agent: "finance")
        #expect(list.content.contains("Baseline: 3 months from 2026-10, 1 assumptions, not run yet"))
        let before = try bench.use(FinanceForecast(), ["scenario": .reference(world.scenario)], agent: "finance")
        #expect(before.content.contains("Assumptions (claimed):") && before.content.contains("- Bonus: +1000.00 USD on 2026-12-15"))
        #expect(before.content.contains("Not run yet"))
        #expect(try Scenarios(store: bench.store, clock: bench.clock).forecast(world.scenario) == nil, "Reading never runs a projection")

        let run = try bench.use(RunForecast(), ["scenario": .reference(world.scenario)], agent: "finance")
        #expect(run.content.contains("(modeled): ends at"))
        let after = try bench.use(FinanceForecast(), ["scenario": .string(world.scenario.description)], agent: "finance")
        #expect(after.content.contains("Projection (modeled"))
        #expect(after.content.contains("- opening 6000.00 USD (recorded balances)"))
        #expect(after.content.contains("- 2026-10: 8269.75 USD"))
        let account = try NexusFinance.Ledger(store: bench.store, clock: bench.clock).account(world.account)
        #expect(try account.balance == Money("6000", .usd) && account.balanceTruth == .recorded, "A forecast never becomes a balance")
        #expect(throws: ToolError.notFound("scenario \(world.account)")) {
            try bench.use(RunForecast(), ["scenario": .reference(world.account)], agent: "finance")
        }
    }

    @Test func categorisingIsAnInterpretationThatNeverReplacesAPerson() throws {
        let world = try Money3()
        let bench = world.bench
        let ledger = NexusFinance.Ledger(store: bench.store, clock: bench.clock)
        let outcome = try bench.use(
            CategorizeTransaction(),
            ["transaction": .reference(world.coffee), "category": .string("groceries"), "reason": .string("Food"), "confidence": .double(0.6)],
            agent: "finance")
        #expect(outcome.content.contains("as Groceries (agentInterpretation)"))
        let coffee = try ledger.transaction(world.coffee)
        #expect(coffee.category == world.groceries && coffee.categoryTruth == .agentInterpretation)
        #expect(coffee.categoryProvenance?.confidence == 0.6 && coffee.categoryProvenance?.method == "Food")
        if case .agent(let id, _)? = coffee.categoryProvenance?.origin { #expect(id == "finance") } else { Issue.record("Not attributed to the agent") }

        // The rent's category was set by a person: refused, and left as it was.
        #expect(throws: ToolError.self) {
            try bench.use(CategorizeTransaction(), ["transaction": .reference(world.rent), "category": .reference(world.groceries)], agent: "finance")
        }
        #expect(try ledger.transaction(world.rent).categoryTruth == .recorded)
        #expect(throws: ToolError.notFound("category Travel")) {
            try bench.use(CategorizeTransaction(), ["transaction": .reference(world.coffee), "category": .string("Travel")], agent: "finance")
        }
    }

    @Test func theRuntimeAsksBeforeAP3FinanceTool() async throws {
        let world = try Money3()
        let bench = world.bench
        let model = ScriptedModel(script: [
            toolTurn(call("finance_balances"), call("run_forecast", ["scenario": .reference(world.scenario)])),
            finalTurn("Checking holds 6000.00 USD (recorded)."),
        ])
        let approver = ScriptedApprover([false])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "What's my balance and forecast?"), as: .finance, approver: approver)
        #expect(result.status == .completed)
        #expect(approver.asked.map(\.action) == ["run_forecast"], "Reading balances needs no approval")
        #expect(approver.asked.first?.level == .modifyInternalState && approver.asked.first?.dataSource == ToolScope.finance)
        #expect(try Scenarios(store: bench.store, clock: bench.clock).forecast(world.scenario) == nil, "Denied, so nothing was stored")
    }
}
