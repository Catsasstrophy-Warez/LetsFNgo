import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct ScenarioTests {
    let person = Origin.user(id: "sam")

    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    /// Checking with a recorded balance of 5,000 on 30 June and three months
    /// of salary and rent, detected as recurring.
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
        #expect(try world.recurring.detectAndStore().count == 2)
        return (world, try world.ledger.account(account.id))
    }

    @Test func projectionIsModeledAndLivesOnTheScenario() throws {
        let (world, account) = try setup()
        let revisionsBefore = try world.store.revisions(of: account.id)
        let baseline = try world.scenarios.createScenario("Baseline", accounts: [account.id], start: YearMonth(2026, 7), months: 6, by: person)
        let forecast = try world.scenarios.run(baseline.id)
        #expect(forecast.points.map(\.total) == (try [7350, 9700, 12050, 14400, 16750, 19100].map { try usd("\($0)") }))
        #expect(try forecast.opening[account.id] == usd("5000"))
        #expect(forecast.provenance.truth == .modeled && forecast.provenance.origin == .simulation(run: baseline.id))
        #expect(Set(forecast.provenance.dependencies).isSuperset(of: [account.id]))

        let stored = try world.scenarios.scenario(baseline.id)
        #expect(stored.projectionTruth == .modeled)
        #expect(try world.scenarios.forecast(baseline.id) == forecast, "The stored projection reads back exactly")
        #expect(try world.store.events(about: baseline.id).contains { $0.kind == .simulated && $0.provenance.truth == .modeled })

        // The account is untouched: same balance, same truth, no new revision.
        let after = try world.ledger.account(account.id)
        #expect(try after.balance == usd("5000") && after.balanceTruth == .recorded)
        #expect(try world.store.revisions(of: account.id) == revisionsBefore)
    }

    @Test func aForecastCanNeverBecomeARecordedBalance() throws {
        let (world, account) = try setup()
        let scenario = try world.scenarios.createScenario("Baseline", accounts: [account.id], start: YearMonth(2026, 7), months: 3, by: person)
        let forecast = try world.scenarios.run(scenario.id)
        let projected = try #require(forecast.points.last?.balances[account.id])

        // The policy itself.
        #expect(!TruthPolicy.canReplace(existing: .recorded, with: .modeled))
        // The ledger refuses a modeled balance whoever offers it.
        #expect(throws: FinanceError.truthNotAllowed(.modeled, field: FinanceKey.balance)) {
            try world.ledger.recordBalance(projected, asOf: FinanceCalendar.day(2026, 9, 30), on: account.id, by: .simulation(run: scenario.id))
        }
        #expect(throws: FinanceError.truthNotAllowed(.modeled, field: FinanceKey.balance)) {
            try world.ledger.recordBalance(projected, asOf: FinanceCalendar.day(2026, 9, 30), on: account.id, provenance: forecast.provenance)
        }
        #expect(throws: FinanceError.truthNotAllowed(.agentInterpretation, field: FinanceKey.balance)) {
            try world.ledger.recordBalance(projected, asOf: FinanceCalendar.day(2026, 9, 30), on: account.id, by: .agent(id: "planner", run: nil))
        }
        // Written straight at the store, TruthPolicy refuses it.
        #expect(throws: StoreError.truthConflict(object: account.id, attribute: FinanceKey.balance, existing: .recorded, incoming: .modeled)) {
            try world.store.update(account.id, by: .simulation(run: scenario.id)) {
                $0.attributes[FinanceKey.balance] = Attribute(projected.value, provenance: forecast.provenance)
            }
        }
        #expect(try world.ledger.account(account.id).balance == usd("5000"))

        // A person's newer statement balance is fine.
        let updated = try world.ledger.recordBalance(try usd("5100"), asOf: FinanceCalendar.day(2026, 7, 31), on: account.id, by: person)
        #expect(try updated.balance == usd("5100"))
        // An older one is kept in the timeline but does not replace the newer balance.
        let stale = try world.ledger.recordBalance(try usd("1"), asOf: FinanceCalendar.day(2026, 1, 31), on: account.id, by: person)
        #expect(try stale.balance == usd("5100"))
    }

    @Test func assumptionsAreClaimedAndScenariosCompare() throws {
        let (world, account) = try setup()
        let baseline = try world.scenarios.createScenario("Baseline", accounts: [account.id], start: YearMonth(2026, 7), months: 6, by: person)
        let move = try world.scenarios.createScenario(
            "Move to a bigger flat", accounts: [account.id], start: YearMonth(2026, 7), months: 6,
            assumptions: [
                .adjustRecurring(payee: "harbor view apts", factor: Decimal(string: "1.2")!, start: YearMonth(2026, 9)),
                .oneOff(label: "Moving van", date: FinanceCalendar.day(2026, 8, 15), amount: try usd("-3000"), account: account.id),
                .monthly(label: "Parking", amount: try usd("-100"), account: account.id, day: 31, start: YearMonth(2026, 7), end: YearMonth(2026, 12)),
            ],
            by: person
        )
        #expect(move.assumptionsTruth == .claimed && move.assumptions.count == 3)
        let forecast = try world.scenarios.run(move.id)
        #expect(forecast.points.map(\.total) == (try [7250, 6500, 8380, 10260, 12140, 14020].map { try usd("\($0)") }))

        let comparison = try world.scenarios.compare(baseline.id, move.id)
        #expect(comparison.rows.count == 6)
        #expect(try comparison.rows[1].difference == usd("-3200"))
        #expect(try comparison.endingDifference == usd("-5080"))
        #expect(try comparison.firstMinimum == usd("7350") && comparison.secondMinimum == usd("6500"))
        #expect(comparison.firstNegativeMonth.first == nil && comparison.firstNegativeMonth.second == nil)

        // Losing the salary from October drives the balance negative by December.
        let jobLoss = try world.scenarios.createScenario(
            "Job loss", accounts: [account.id], start: YearMonth(2026, 7), months: 6,
            assumptions: [
                .stopRecurring(payee: "Acme Payroll", start: YearMonth(2026, 10)),
                .oneOff(label: "Car", date: FinanceCalendar.day(2026, 11, 2), amount: try usd("-12000"), account: account.id),
            ],
            by: person
        )
        let bleak = try world.scenarios.run(jobLoss.id)
        #expect(bleak.firstNegativeMonth == YearMonth(2026, 11))

        // Changing assumptions and re-running replaces the modeled projection.
        try world.scenarios.setAssumptions([], on: move.id, by: person)
        #expect(try world.scenarios.run(move.id).ending == usd("19100"))
        #expect(try world.scenarios.scenario(move.id).assumptionsTruth == .claimed)
    }

    @Test func aScenarioNeedsARecordedStartingBalance() throws {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "New", kind: .checking, currency: .usd, by: person)
        let scenario = try world.scenarios.createScenario("Empty", accounts: [account.id], start: YearMonth(2026, 7), months: 2, by: person)
        #expect(throws: FinanceError.missingBalance(account.id)) { try world.scenarios.run(scenario.id) }

        let euro = try world.ledger.addAccount(name: "Euro", kind: .savings, currency: .eur, by: person)
        try world.ledger.recordBalance(try usd("10"), asOf: Fixtures.t0, on: account.id, by: person)
        try world.ledger.recordBalance(try Money("10", .eur), asOf: Fixtures.t0, on: euro.id, by: person)
        let mixed = try world.scenarios.createScenario("Mixed", accounts: [account.id, euro.id], start: YearMonth(2026, 7), months: 2, by: person)
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) { try world.scenarios.run(mixed.id) }
    }
}
