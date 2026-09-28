import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct BudgetPlanningTests {
    let person = Origin.user(id: "sam")

    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    /// Groceries, dining, salary and a transfer over July to September.
    struct Setup {
        let world: FinanceWorld
        let account: Account
        let groceries: TransactionCategory
        let dining: TransactionCategory
        let salary: TransactionCategory
        let transfer: TransactionCategory
    }

    func setup() throws -> Setup {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: person)
        let groceries = try world.ledger.addCategory("Groceries", by: person)
        let dining = try world.ledger.addCategory("Dining", by: person)
        let salary = try world.ledger.addCategory("Salary", kind: .income, by: person)
        let transfer = try world.ledger.addCategory("Transfer", kind: .transfer, by: person)
        func add(_ month: Int, _ day: Int, _ amount: String, _ payee: String, _ category: TransactionCategory?) throws {
            let transaction = try world.ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, day), amount: try usd(amount), payee: payee), to: account.id, by: person)
            if let category { try world.ledger.setCategory(category.id, on: transaction.id, by: person) }
        }
        try add(7, 10, "-400", "Market", groceries)
        try add(8, 10, "-250", "Market", groceries)
        try add(9, 1, "3000", "Payroll", salary)
        try add(9, 3, "-120.40", "Market", groceries)
        try add(9, 17, "-230.10", "Market", groceries)
        try add(9, 20, "-45.00", "Bistro", dining)
        try add(9, 21, "-500", "To savings", transfer)
        try add(9, 25, "-12.99", "Kiosk", nil)
        return Setup(world: world, account: account, groceries: groceries, dining: dining, salary: salary, transfer: transfer)
    }

    @Test func editingOneAmountKeepsTheOthersAsRecordedTruth() throws {
        let s = try setup()
        let september = YearMonth(2026, 9)
        let budgets = s.world.budgets
        #expect(try budgets.setAmount(nil, for: s.groceries.id, in: september, by: person) == nil, "Clearing an unbudgeted month stores nothing")
        try budgets.setAmount(try usd("400"), for: s.groceries.id, in: september, by: person)
        try budgets.setAmount(try usd("30"), for: s.dining.id, in: september, by: person)
        try budgets.setAmount(try usd("2800"), for: s.salary.id, in: september, by: person)
        let budget = try #require(try budgets.budget(for: september))
        #expect(try budget.lines == [s.groceries.id: usd("400"), s.dining.id: usd("30"), s.salary.id: usd("2800")])
        #expect(budget.record.truth(of: FinanceKey.lines) == .recorded)
        #expect(budget.record.attributes[FinanceKey.lines]?.provenance?.origin == person)
        try budgets.setAmount(nil, for: s.dining.id, in: september, by: person)
        #expect(try budgets.budget(for: september)?.lines[s.dining.id] == nil)
        #expect(try budgets.budgets().count == 1)

        #expect(try Budgets.parseAmount("1,200", currency: .usd) == usd("1200"))
        #expect(try Budgets.parseAmount(" $80.50 ", currency: .usd) == usd("80.50"))
        #expect(try Budgets.parseAmount("-50", currency: .usd) == usd("50"), "Budget amounts are positive")
        #expect(try Budgets.parseAmount("  ", currency: .usd) == nil)
        #expect(throws: FinanceError.self) { try Budgets.parseAmount("lots", currency: .usd) }
    }

    @Test func overviewShowsActualProgressAndStatus() throws {
        let s = try setup()
        let september = YearMonth(2026, 9)
        try s.world.budgets.setBudget(
            for: september, currency: .usd, lines: [s.groceries.id: try usd("400"), s.dining.id: try usd("30"), s.salary.id: try usd("2800")],
            by: person)
        let overview = try s.world.budgets.overview(for: september)
        #expect(overview.rows.map(\.name) == ["Dining", "Groceries", "Salary"], "Expenses by name, then income; no transfers")
        let groceries = try #require(overview.row(s.groceries.id))
        #expect(try groceries.actual == usd("350.50") && groceries.remaining == usd("49.50") && groceries.transactionCount == 2)
        #expect(groceries.status == .nearLimit && abs(groceries.progress! - 0.87625) < 0.0001)
        let dining = try #require(overview.row(s.dining.id))
        #expect(try dining.status == .over && dining.remaining == usd("-15"))
        let salary = try #require(overview.row(s.salary.id))
        #expect(salary.status == .incomeMet)
        #expect(try overview.uncategorized == usd("12.99"))
        #expect(try overview.totalBudgeted == usd("430") && overview.totalActual == usd("395.50") && overview.totalRemaining == usd("34.50"))
        #expect(overview.budgetTruth == .recorded && !overview.rollover)

        // A month without a budget still lists every category, unbudgeted.
        let october = try s.world.budgets.overview(for: YearMonth(2026, 10))
        #expect(october.budget == nil && october.rows.allSatisfy { $0.status == .unbudgeted && $0.budgeted == nil })
        #expect(october.currency == .usd)
    }

    @Test func rolloverCarriesLeftoversForwardAndChains() throws {
        let s = try setup()
        let budgets = s.world.budgets
        let (july, august, september) = (YearMonth(2026, 7), YearMonth(2026, 8), YearMonth(2026, 9))
        for month in [july, august, september] {
            try budgets.setAmount(try usd("300"), for: s.groceries.id, in: month, by: person)
        }
        // Without rollover each month stands alone.
        #expect(try budgets.overview(for: september).row(s.groceries.id)?.carriedOver == usd("0"))

        // August carries July's overspend (300 − 400 = −100).
        try budgets.setRollover(true, for: august, currency: .usd, by: person)
        let augustRow = try #require(try budgets.overview(for: august).row(s.groceries.id))
        #expect(try augustRow.carriedOver == usd("-100") && augustRow.available == usd("200") && augustRow.remaining == usd("-50"))
        #expect(augustRow.status == .over)

        // September carries August's result, which already includes July's.
        try budgets.setRollover(true, for: september, currency: .usd, by: person)
        let overview = try budgets.overview(for: september)
        let row = try #require(overview.row(s.groceries.id))
        #expect(try row.carriedOver == usd("-50") && row.available == usd("250") && row.remaining == usd("-100.50"))
        #expect(overview.rollover && overview.budget?.record.truth(of: FinanceKey.rollover) == .recorded)

        // Turning August's rollover off stops the chain there.
        try budgets.setRollover(false, for: august, currency: .usd, by: person)
        #expect(try budgets.overview(for: september).row(s.groceries.id)?.carriedOver == usd("50"))

        // Copying a month copies its amounts and its rollover.
        let copy = try #require(try budgets.copyBudget(from: september, to: YearMonth(2026, 10), by: person))
        #expect(try copy.lines == [s.groceries.id: usd("300")] && copy.rollover)
        #expect(try budgets.copyBudget(from: YearMonth(2025, 1), to: YearMonth(2026, 11), by: person) == nil)
    }

    @Test func actualsCountRecordedTransactionsOnly() throws {
        let s = try setup()
        let september = YearMonth(2026, 9)
        try s.world.budgets.setAmount(try usd("400"), for: s.groceries.id, in: september, by: person)
        _ = try s.world.store.create(
            ObjectRecord(
                type: .transaction, title: "Projected groceries",
                attributes: [
                    FinanceKey.account: Attribute(.reference(s.account.id)), FinanceKey.date: Attribute(.date(FinanceCalendar.day(2026, 9, 28))),
                    FinanceKey.amount: Attribute(try usd("-300").value), FinanceKey.payee: Attribute(.string("Market")),
                    FinanceKey.category: Attribute(.reference(s.groceries.id)),
                ],
                provenance: Provenance(origin: .agent(id: "planner", run: nil), truth: .agentInterpretation, timestamp: Fixtures.t0)
            ))
        #expect(try s.world.budgets.overview(for: september).row(s.groceries.id)?.actual == usd("350.50"))
    }
}
