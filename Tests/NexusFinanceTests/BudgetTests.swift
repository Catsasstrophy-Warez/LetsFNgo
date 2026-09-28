import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct BudgetTests {
    let person = Origin.user(id: "sam")

    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    @Test func budgetVarianceAndCashFlow() throws {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: person)
        let savings = try world.ledger.addAccount(name: "Savings", kind: .savings, currency: .usd, by: person)
        let groceries = try world.ledger.addCategory("Groceries", by: person)
        let dining = try world.ledger.addCategory("Dining", by: person)
        let salary = try world.ledger.addCategory("Salary", kind: .income, by: person)
        let transfer = try world.ledger.addCategory("Transfer", kind: .transfer, by: person)
        func add(_ day: Int, _ amount: String, _ payee: String, _ category: TransactionCategory?, month: Int = 9) throws {
            let transaction = try world.ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, day), amount: try usd(amount), payee: payee), to: account.id, by: person)
            if let category { try world.ledger.setCategory(category.id, on: transaction.id, by: person) }
        }
        try add(1, "3000", "Payroll", salary)
        try add(3, "-120.40", "Market", groceries)
        try add(17, "-230.10", "Market", groceries)
        try add(20, "-45.00", "Bistro", dining)
        try add(21, "-500", "To savings", transfer)
        try add(25, "-12.99", "Kiosk", nil)
        try add(2, "-999", "Market", groceries, month: 10)

        // An agent's guessed transaction is not recorded, so it is not an actual.
        let guess = try world.store.create(
            ObjectRecord(
                type: .transaction, title: "Projected groceries",
                attributes: [
                    FinanceKey.account: Attribute(.reference(account.id)), FinanceKey.date: Attribute(.date(FinanceCalendar.day(2026, 9, 28))),
                    FinanceKey.amount: Attribute(try usd("-300").value), FinanceKey.payee: Attribute(.string("Market")),
                    FinanceKey.category: Attribute(.reference(groceries.id)),
                ],
                provenance: Provenance(origin: .agent(id: "planner", run: nil), truth: .agentInterpretation, timestamp: Fixtures.t0)
            ))
        #expect(guess.provenance.truth == .agentInterpretation)

        let september = YearMonth(2026, 9)
        try world.budgets.setBudget(
            for: september, currency: .usd, lines: [groceries.id: try usd("400"), dining.id: try usd("30"), salary.id: try usd("2800")], by: person)
        let report = try #require(try world.budgets.report(for: september))
        let groceriesLine = try #require(report.line(groceries.id))
        #expect(try groceriesLine.actual == usd("350.50") && groceriesLine.variance == usd("49.50"))
        #expect(groceriesLine.transactions.count == 2)
        let diningLine = try #require(report.line(dining.id))
        #expect(try diningLine.variance == usd("-15"), "Over budget is negative")
        let salaryLine = try #require(report.line(salary.id))
        #expect(try salaryLine.actual == usd("3000") && salaryLine.variance == usd("200"), "Income above budget is favourable")
        #expect(try report.unbudgeted[nil] == usd("-12.99"))
        #expect(report.unbudgeted[transfer.id] == nil, "Transfers are not spending")
        #expect(try report.totalBudgeted == usd("430") && report.totalActual == usd("395.50") && report.totalVariance == usd("34.50"))

        // Replacing the budget keeps one object per month.
        try world.budgets.setBudget(for: september, currency: .usd, lines: [groceries.id: try usd("300")], by: person)
        #expect(try world.store.objects(ofType: .budget).count == 1)
        #expect(try world.budgets.report(for: september)?.line(groceries.id)?.variance == usd("-50.50"))
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) {
            try world.budgets.setBudget(for: september, currency: .usd, lines: [groceries.id: try Money("1", .eur)], by: person)
        }

        let flow = try world.budgets.cashFlow(for: september, currency: .usd)
        #expect(try flow.inflow == usd("3000") && flow.outflow == usd("408.49") && flow.net == usd("2591.51"))
        #expect(try flow.transfers == usd("-500") && flow.transactionCount == 6)
        #expect(try flow.byCategory[groceries.id] == usd("-350.50") && flow.byCategory[nil] == usd("-12.99"))
        let series = try world.budgets.cashFlow(from: september, through: september.next, currency: .usd)
        #expect(series.map(\.net) == [try usd("2591.51"), try usd("-999")])
        #expect(try world.budgets.cashFlow(for: september, currency: .usd, accounts: [savings.id]).transactionCount == 0)
        #expect(throws: MoneyError.currencyMismatch(.eur, .usd)) { try world.budgets.cashFlow(for: september, currency: .eur) }
    }

    @Test func recurringRentIsDetectedAndDerived() throws {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: person)
        func add(_ month: Int, _ day: Int, _ amount: String, _ payee: String) throws {
            try world.ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, day), amount: try usd(amount), payee: payee), to: account.id, by: person)
        }
        for month in 1...5 { try add(month, 1, "-1850", "Harbor View Apts") }
        for month in 1...5 { try add(month, 14 + month % 2, "-\(60 + month).25", "City Power") }
        for week in 0..<4 { try add(3, 2 + 7 * week, "-9.99", "Gym") }
        try add(2, 3, "-40", "Cinema")
        try add(4, 20, "-40", "Cinema")
        try add(4, 22, "-40", "Cinema")

        let patterns = try world.recurring.detect()
        let rent = try #require(patterns.first { $0.payee == "Harbor View Apts" })
        #expect(try rent.cadence == .monthly && rent.amount == usd("-1850") && !rent.amountVaries)
        #expect(rent.nextDate == FinanceCalendar.day(2026, 6, 1) && rent.transactions.count == 5)
        let power = try #require(patterns.first { $0.payee == "City Power" })
        #expect(try power.cadence == .monthly && power.amountVaries && power.amount == usd("-63.25"))
        #expect(patterns.first { $0.payee == "Gym" }?.cadence == .weekly)
        #expect(!patterns.contains { $0.payee == "Cinema" }, "Irregular gaps are not a series")

        let stored = try world.recurring.detectAndStore()
        let series = try #require(stored.first { $0.payee == "Harbor View Apts" })
        #expect(series.truth == .derived && series.record.provenance.dependencies == rent.transactions)
        #expect(series.cadence == .monthly && series.nextDate == FinanceCalendar.day(2026, 6, 1))

        // A new month moves the same series forward rather than adding another.
        try add(6, 1, "-1850", "Harbor View Apts")
        let again = try world.recurring.detectAndStore()
        #expect(try world.store.objects(ofType: .recurringSeries).count == stored.count)
        #expect(again.first { $0.id == series.id }?.nextDate == FinanceCalendar.day(2026, 7, 1))
    }
}
