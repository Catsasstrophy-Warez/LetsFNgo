import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

/// The finance domain end to end on one SQLite file: import, dedup,
/// categorise, budget, detect recurring rent, forecast, save and reload.
/// Recorded data, rule-derived categories, a person's category, detected
/// series and a modeled forecast all sit in the same store, each with its
/// own truth class, and nothing modeled ever reaches a recorded balance.
@Suite struct FinanceSliceTests {
    @Test func importCategoriseBudgetForecastAndReload() async throws {
        let url = Fixtures.tempURL("finance")
        defer { Fixtures.remove(url) }
        let clock = ManualClock(Fixtures.t0)
        var world = try FinanceWorld(.file(url), clock: clock)
        let sam = Origin.user(id: "sam")
        func usd(_ text: String) throws -> Money { try Money(text, .usd) }

        // 1. Import: the bank's OFX (SGML), the card's OFX (XML), then a CSV export overlapping June.
        let checking = try #require(try world.importer.importOFX(Data(Fixtures.sgmlOFX.utf8), named: "checking-q2.ofx", by: sam).first)
        let card = try #require(try world.importer.importOFX(Data(Fixtures.xmlOFX.utf8), named: "card-june.qfx", by: sam).first)
        clock.advance(by: 60)
        let csv = try world.importer.importCSV(
            Data(Fixtures.europeanCSV.utf8), named: "checking-jun-jul.csv", into: checking.account.id, mapping: Fixtures.europeanMapping, by: sam)
        #expect(checking.created.count == 12 && card.created.count == 3 && card.account.kind == .creditCard)

        // 2. Dedup: June's three CSV rows match the OFX rows by (date, amount, payee).
        #expect(csv.created.count == 5 && csv.duplicates.count == 3)
        #expect(try world.ledger.transactions().count == 12 + 3 + 5)
        #expect(try world.ledger.transactions().allSatisfy { $0.truth == .recorded })
        let documents = try world.store.objects(ofType: .document)
        #expect(documents.count == 3)
        for transaction in try world.ledger.transactions() {
            guard case .importer(let source) = transaction.record.provenance.origin else {
                Issue.record("not imported")
                continue
            }
            #expect(documents.map(\.id).contains(source))
        }

        // 3. Categorise: rules derive, a person overrides, and a later rule run leaves the person's choice alone.
        let ledger = world.ledger
        let groceries = try ledger.addCategory("Groceries", by: sam)
        let dining = try ledger.addCategory("Dining", by: sam)
        let housing = try ledger.addCategory("Housing", by: sam)
        let salary = try ledger.addCategory("Salary", kind: .income, by: sam)
        let subscriptions = try ledger.addCategory("Subscriptions", by: sam)
        let rules = world.categorizer
        try rules.addRule(CategoryRule(name: "Groceries", category: groceries.id, payeeContains: ["grocer"]), by: sam)
        try rules.addRule(CategoryRule(name: "Rent", category: housing.id, payeeContains: ["harbor view"], direction: .outflow), by: sam)
        try rules.addRule(CategoryRule(name: "Payroll", category: salary.id, payeeContains: ["payroll"], direction: .inflow), by: sam)
        try rules.addRule(CategoryRule(name: "Coffee", category: dining.id, payeeContains: ["coffee"], maximumAmount: 10), by: sam)
        let firstRun = try rules.applyRules()
        #expect(firstRun.assigned.count == 16 && firstRun.unmatched.count == 4)

        // Sam decides the July grocery run was a dinner party.
        let julyGrocer = try #require(try ledger.transactions().first { $0.payee == "Green Grocer #22" && YearMonth($0.date) == YearMonth(2026, 7) })
        #expect(julyGrocer.categoryTruth == .derived)
        clock.advance(by: 60)
        try ledger.setCategory(dining.id, on: julyGrocer.id, by: sam)
        // A model fills what the rules left, but not the card payment it has no category for.
        let model = KeywordSuggester(keywords: ["STREAMFLIX": subscriptions.id], confidence: 0.9)
        let suggested = try await rules.suggestCategories(using: model)
        #expect(suggested.assigned.count == 1 && suggested.keptPersonCategory == [julyGrocer.id])
        // A new, higher-priority rule would claim every grocer row; it skips Sam's.
        try rules.addRule(CategoryRule(name: "All food", category: groceries.id, payeeContains: ["grocer"], priority: 5), by: sam)
        let secondRun = try rules.applyRules()
        #expect(secondRun.keptPersonCategory == [julyGrocer.id])
        let override = try ledger.transaction(julyGrocer.id)
        #expect(override.category == dining.id && override.categoryTruth == .recorded && override.categoryProvenance?.origin == sam)
        let streamflix = try #require(try ledger.transactions().first { $0.payee == "STREAMFLIX" })
        #expect(streamflix.categoryTruth == .agentInterpretation)

        // 4. Budget for July: actuals come from recorded transactions only.
        let july = YearMonth(2026, 7)
        try world.budgets.setBudget(
            for: july, currency: .usd, lines: [groceries.id: try usd("150"), dining.id: try usd("100"), housing.id: try usd("1850")], by: sam)
        let budget = try #require(try world.budgets.report(for: july, accounts: [checking.account.id]))
        #expect(try budget.line(groceries.id)?.actual == usd("0") && budget.line(groceries.id)?.variance == usd("150"))
        #expect(try budget.line(dining.id)?.actual == usd("112.90") && budget.line(dining.id)?.variance == usd("-12.90"))
        #expect(try budget.line(housing.id)?.variance == usd("0"))
        let flow = try world.budgets.cashFlow(for: july, currency: .usd, accounts: [checking.account.id])
        #expect(try flow.inflow == usd("4200") && flow.outflow == usd("1962.90") && flow.net == usd("2237.10"))

        // 5. Recurring rent: April to June from the OFX, July from the CSV.
        let series = try world.recurring.detectAndStore(accounts: [checking.account.id])
        let rent = try #require(series.first { normalizedPayee($0.payee) == "HARBOR VIEW APTS" })
        #expect(try rent.cadence == .monthly && rent.amount == usd("-1850") && rent.truth == .derived)
        #expect(rent.nextDate == FinanceCalendar.day(2026, 8, 1) && rent.record.provenance.dependencies.count == 4)
        #expect(series.contains { $0.cadence == .monthly && $0.amount == (try? usd("4200")) })

        // 6. Forecast (modeled) on a scenario; the recorded balance never moves.
        let balanceBefore = try world.ledger.account(checking.account.id)
        #expect(try balanceBefore.balance == usd("7078.23") && balanceBefore.balanceTruth == .recorded)
        let scenario = try world.scenarios.createScenario(
            "Next quarter", accounts: [checking.account.id], start: YearMonth(2026, 8), months: 3,
            assumptions: [.oneOff(label: "Laptop", date: FinanceCalendar.day(2026, 9, 10), amount: try usd("-1400"), account: checking.account.id)],
            by: sam
        )
        let forecast = try world.scenarios.run(scenario.id)
        #expect(forecast.points.map(\.total) == [try usd("9428.23"), try usd("10378.23"), try usd("12728.23")])
        #expect(forecast.provenance.truth == .modeled)
        #expect(throws: StoreError.truthConflict(object: checking.account.id, attribute: FinanceKey.balance, existing: .recorded, incoming: .modeled)) {
            try world.store.update(checking.account.id, by: .simulation(run: scenario.id)) {
                $0.attributes[FinanceKey.balance] = Attribute(forecast.points[2].total.value, provenance: forecast.provenance)
            }
        }
        #expect(throws: FinanceError.truthNotAllowed(.modeled, field: FinanceKey.balance)) {
            try world.ledger.recordBalance(
                forecast.points[2].total, asOf: FinanceCalendar.day(2026, 10, 31), on: checking.account.id, provenance: forecast.provenance)
        }
        let balanceAfter = try world.ledger.account(checking.account.id)
        #expect(balanceAfter == balanceBefore)

        // 7. Save, reload, and compare everything.
        let before = try Snapshot(world)
        let budgetBefore = budget
        world = try FinanceWorld(.file(url), clock: clock)
        let after = try Snapshot(world)
        #expect(after == before)
        #expect(try world.budgets.report(for: july, accounts: [checking.account.id]) == budgetBefore)
        #expect(try world.scenarios.forecast(scenario.id) == forecast)
        #expect(try world.recurring.series(accounts: [checking.account.id]) == series)
        #expect(try world.ledger.transaction(julyGrocer.id).categoryTruth == .recorded)
        #expect(try world.store.blobData(sha256: ContentHash.sha256(Data(Fixtures.europeanCSV.utf8))) == Data(Fixtures.europeanCSV.utf8))
    }
}

/// Every finance object, its revisions and relationships, the timeline and the imported files, read back through public APIs.
private struct Snapshot: Equatable {
    static let types: [ObjectType] = [
        .account, .transaction, .transactionCategory, .categoryRule, .budget, .recurringSeries, .financialScenario, .document,
    ]
    var objects: [ObjectRecord]
    var revisions: [ObjectID: [Revision]]
    var relationships: [ObjectID: [Relationship]]
    var timeline: [Event]
    var files: [ObjectID: Data]

    init(_ world: FinanceWorld) throws {
        objects = try Self.types.flatMap { try world.store.objects(ofType: $0) }
        revisions = Dictionary(uniqueKeysWithValues: try objects.map { ($0.id, try world.store.revisions(of: $0.id)) })
        relationships = Dictionary(uniqueKeysWithValues: try objects.map { ($0.id, try world.store.relationships(from: $0.id)) })
        timeline = try world.store.timeline()
        var files: [ObjectID: Data] = [:]
        for document in objects where document.type == .document {
            if case .string(let digest)? = document.attributes[FinanceKey.blob]?.value {
                files[document.id] = try world.store.blobData(sha256: digest)
            }
        }
        self.files = files
    }
}
