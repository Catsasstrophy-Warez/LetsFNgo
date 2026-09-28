import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct ForecastPlanningTests {
    let person = Origin.user(id: "sam")

    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    /// Checking with 5,000 recorded on 30 June and recurring salary and rent.
    func setup() throws -> (FinanceWorld, Account) {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: person)
        for month in 4...6 {
            try world.ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, 1), amount: try usd("4200"), payee: "Acme Payroll"), to: account.id, by: person)
            try world.ledger.addTransaction(
                TransactionDraft(date: FinanceCalendar.day(2026, month, 1), amount: try usd("-1850"), payee: "Harbor View Apts"), to: account.id,
                by: person)
        }
        try world.ledger.recordBalance(try usd("5000"), asOf: FinanceCalendar.day(2026, 6, 30), on: account.id, by: person)
        try world.recurring.detectAndStore()
        return (world, try world.ledger.account(account.id))
    }

    @Test func assumptionFormsBecomeAssumptions() throws {
        let account = ObjectID.make()
        var draft = AssumptionDraft(kind: .oneOff, label: "New car", amount: "-12,500.00", date: FinanceCalendar.day(2026, 9, 15), account: account)
        #expect(
            try draft.assumption(currency: .usd) == .oneOff(label: "New car", date: FinanceCalendar.day(2026, 9, 15), amount: usd("-12500"), account: account))
        draft.kind = .monthly
        draft.amount = "(40)"
        draft.day = 40
        draft.start = YearMonth(2026, 8)
        #expect(
            try draft.assumption(currency: .usd)
                == .monthly(label: "New car", amount: usd("-40"), account: account, day: 31, start: YearMonth(2026, 8), end: nil))
        draft.kind = .adjustRecurring
        draft.payee = "Harbor View Apts"
        draft.percent = "20"
        #expect(try draft.assumption(currency: .usd) == .adjustRecurring(payee: "Harbor View Apts", factor: Decimal(string: "1.2")!, start: YearMonth(2026, 8)))
        draft.kind = .stopRecurring
        #expect(try draft.assumption(currency: .usd) == .stopRecurring(payee: "Harbor View Apts", start: YearMonth(2026, 8)))

        #expect(throws: FinanceError.missingInput("label")) { try AssumptionDraft(kind: .oneOff, amount: "1", account: account).assumption(currency: .usd) }
        #expect(throws: FinanceError.missingInput(FinanceKey.account)) {
            try AssumptionDraft(kind: .oneOff, label: "x", amount: "1").assumption(currency: .usd)
        }
        #expect(throws: FinanceError.unparsableAmount("ten", line: 0)) {
            try AssumptionDraft(kind: .oneOff, label: "x", amount: "ten", account: account).assumption(currency: .usd)
        }
        #expect(throws: FinanceError.missingInput(FinanceKey.payee)) { try AssumptionDraft(kind: .stopRecurring).assumption(currency: .usd) }
    }

    @Test func summariesDescribeWhatIsClaimed() throws {
        let account = ObjectID.make()
        #expect(
            try Assumption.oneOff(label: "Bonus", date: FinanceCalendar.day(2026, 12, 15), amount: usd("2000"), account: account).summary
                == "Bonus: +2000.00 USD on 2026-12-15")
        #expect(
            try Assumption.monthly(label: "Daycare", amount: usd("-900"), account: account, day: 5, start: YearMonth(2026, 9), end: YearMonth(2027, 6))
                .summary == "Daycare: -900.00 USD monthly on day 5, from 2026-09 through 2027-06")
        #expect(Assumption.adjustRecurring(payee: "Rent", factor: Decimal(string: "1.2")!, start: YearMonth(2026, 9)).summary == "Rent: +20 % from 2026-09")
        #expect(Assumption.adjustRecurring(payee: "Gym", factor: Decimal(string: "0.9")!, start: YearMonth(2026, 9)).summary == "Gym: -10 % from 2026-09")
        #expect(Assumption.stopRecurring(payee: "Streamflix", start: YearMonth(2026, 9)).label == "Stop Streamflix")
    }

    @Test func scenarioListChartAndAssumptionEditing() throws {
        let (world, account) = try setup()
        let scenarios = world.scenarios
        let baseline = try scenarios.createScenario("Baseline", accounts: [account.id], start: YearMonth(2026, 7), months: 3, by: person)
        world.clock.advance(by: 60)
        let raise = try scenarios.createScenario("Rent rises", accounts: [account.id], start: YearMonth(2026, 7), months: 3, by: person)
        #expect(try scenarios.scenarios().map(\.name) == ["Rent rises", "Baseline"], "Newest first")
        #expect(try scenarios.recurringPayees(for: raise.id) == ["Acme Payroll", "Harbor View Apts"])

        let rent = AssumptionDraft(kind: .adjustRecurring, start: YearMonth(2026, 8), payee: "Harbor View Apts", percent: "20")
        try scenarios.addAssumption(try rent.assumption(currency: .usd), to: raise.id, by: person)
        let bonus = AssumptionDraft(kind: .oneOff, label: "Bonus", amount: "1000", date: FinanceCalendar.day(2026, 9, 15), account: account.id)
        let stored = try scenarios.addAssumption(try bonus.assumption(currency: .usd), to: raise.id, by: person)
        #expect(stored.assumptions.count == 2 && stored.assumptionsTruth == .claimed)
        #expect(stored.record.attributes[FinanceKey.assumptions]?.provenance?.origin == person)
        let removed = try scenarios.removeAssumption(at: 1, from: raise.id, by: person)
        #expect(removed.assumptions.map(\.label) == ["Change Harbor View Apts"])
        #expect(try scenarios.removeAssumption(at: 9, from: raise.id, by: person).assumptions.count == 1, "An index out of range changes nothing")

        #expect(try scenarios.summaries().allSatisfy { $0.forecast == nil && $0.ending == nil })
        let forecast = try scenarios.run(raise.id)
        let points = try forecast.chartPoints()
        #expect(points.count == 4)
        #expect(points[0].truth == .recorded && points[0].date == FinanceCalendar.day(2026, 7, 1) && points[0].total == 5000)
        #expect(points.dropFirst().allSatisfy { $0.truth == .modeled })
        #expect(points[1].date == FinanceCalendar.day(2026, 7, 31) && points[3].month == YearMonth(2026, 9))
        // July: +4200 −1850; August on: rent × 1.2 = 2220.
        #expect(try points.map(\.money) == [usd("5000"), usd("7350"), usd("9330"), usd("11310")])

        let summary = try #require(try scenarios.summaries().first { $0.id == raise.id })
        #expect(try summary.ending == usd("11310") && summary.lowest == usd("7350") && summary.firstNegativeMonth == nil)
        #expect(summary.lastRun == world.clock.now())
        #expect(try scenarios.summaries().first { $0.id == baseline.id }?.forecast == nil, "Running one scenario leaves the other alone")
        #expect(try world.ledger.account(account.id).balance == usd("5000"), "The recorded balance is untouched")
    }
}
