import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct CategorizationTests {
    let person = Origin.user(id: "sam")

    struct Setup {
        let world: FinanceWorld
        let account: ObjectID
        let groceries: TransactionCategory
        let dining: TransactionCategory
        let housing: TransactionCategory
        let income: TransactionCategory
        let utilities: TransactionCategory
    }

    func setup() throws -> Setup {
        let world = try FinanceWorld()
        let result = try #require(try world.importer.importOFX(Data(Fixtures.sgmlOFX.utf8), named: "q2.ofx", by: person).first)
        return Setup(
            world: world, account: result.account.id,
            groceries: try world.ledger.addCategory("Groceries", by: person),
            dining: try world.ledger.addCategory("Dining", by: person),
            housing: try world.ledger.addCategory("Housing", by: person),
            income: try world.ledger.addCategory("Salary", kind: .income, by: person),
            utilities: try world.ledger.addCategory("Utilities", by: person)
        )
    }

    @Test func ruleConditions() throws {
        let s = try setup()
        let transactions = try s.world.ledger.transactions()
        let rent = try #require(transactions.first { $0.payee == "HARBOR VIEW APTS" })
        let salary = try #require(transactions.first { $0.payee == "ACME CORP PAYROLL" })
        #expect(CategoryRule(name: "", category: s.housing.id, payeeContains: ["harbor view"]).matches(rent))
        #expect(CategoryRule(name: "", category: s.housing.id, payeeContains: ["Rent"]).matches(rent), "The memo counts too")
        #expect(!CategoryRule(name: "", category: s.housing.id, payeeContains: ["harbor"], direction: .inflow).matches(rent))
        #expect(CategoryRule(name: "", category: s.housing.id, minimumAmount: 1000, maximumAmount: 2000).matches(rent))
        #expect(!CategoryRule(name: "", category: s.housing.id, minimumAmount: 1000, maximumAmount: 1500).matches(rent))
        #expect(CategoryRule(name: "", category: s.income.id, account: s.account).matches(salary))
        #expect(!CategoryRule(name: "", category: s.income.id, account: .make()).matches(salary))
    }

    @Test func rulesDeriveModelsInterpretPeopleRecord() async throws {
        let s = try setup()
        let rules = s.world.categorizer
        try rules.addRule(CategoryRule(name: "Groceries", category: s.groceries.id, payeeContains: ["grocer"]), by: person)
        try rules.addRule(CategoryRule(name: "Rent", category: s.housing.id, payeeContains: ["harbor view apts"], direction: .outflow), by: person)
        try rules.addRule(CategoryRule(name: "Salary", category: s.income.id, payeeContains: ["payroll"], direction: .inflow), by: person)
        // A broader, lower-priority rule loses to the specific ones.
        try rules.addRule(CategoryRule(name: "Anything big", category: s.utilities.id, minimumAmount: 1000, priority: -1), by: person)
        #expect(try rules.rules().map(\.name) == ["Groceries", "Rent", "Salary", "Anything big"])

        let report = try rules.applyRules()
        #expect(report.assigned.count == 9 && report.unmatched.count == 3)
        let ledger = s.world.ledger
        let rent = try #require(try ledger.transactions().first { $0.payee == "HARBOR VIEW APTS" })
        #expect(rent.category == s.housing.id && rent.categoryTruth == .derived)
        #expect(rent.categoryProvenance?.origin == .system && rent.categoryProvenance?.method == "rule: Rent")
        #expect(rent.truth == .recorded, "The transaction itself stays recorded")

        // A model fills only what has no category: coffee and the water bill.
        let coffee = try #require(try ledger.transactions().first { $0.payee == "BEAN THERE COFFEE" })
        let model = KeywordSuggester(keywords: ["COFFEE": s.dining.id, "WATER": s.utilities.id, "GROCER": s.dining.id], confidence: 0.8)
        let suggested = try await rules.suggestCategories(using: model)
        #expect(suggested.assigned.count == 3 && suggested.unchanged.count == 9)
        let interpreted = try ledger.transaction(coffee.id)
        #expect(interpreted.category == s.dining.id && interpreted.categoryTruth == .agentInterpretation)
        #expect(interpreted.categoryProvenance?.confidence == 0.8 && interpreted.categoryProvenance?.origin == .model(model.model))
        #expect(try ledger.transaction(rent.id).categoryTruth == .derived, "The model never replaces a rule's category")

        // Low confidence is dropped.
        let unsure = try await rules.suggestCategories(using: KeywordSuggester(keywords: ["": s.dining.id], confidence: 0.2))
        #expect(unsure.assigned.isEmpty)

        // A person recategorises the coffee; that is recorded truth.
        try ledger.setCategory(s.groceries.id, on: coffee.id, by: person)
        #expect(try ledger.transaction(coffee.id).categoryTruth == .recorded)

        // A later rule matching coffee does not touch the person's choice.
        try rules.addRule(CategoryRule(name: "Coffee", category: s.dining.id, payeeContains: ["coffee"], priority: 10), by: person)
        let rerun = try rules.applyRules()
        #expect(rerun.keptPersonCategory == [coffee.id])
        #expect(try ledger.transaction(coffee.id).category == s.groceries.id)
        // The other coffee (the model's guess) is replaced by the new rule: rules outrank models.
        let otherCoffee = try #require(try ledger.transactions().first { $0.payee == "BEAN THERE COFFEE" && $0.id != coffee.id })
        #expect(otherCoffee.categoryTruth == .derived && otherCoffee.category == s.dining.id)
        #expect(rerun.unchanged.contains(rent.id), "Same rule, same category: no new revision")

        // An agent cannot overwrite the person's category, and the store says why.
        #expect(throws: StoreError.truthConflict(object: coffee.id, attribute: FinanceKey.category, existing: .recorded, incoming: .agentInterpretation)) {
            try ledger.setCategory(s.dining.id, on: coffee.id, by: .agent(id: "finance", run: nil))
        }
        // Nor can a rule written straight at the store.
        #expect(throws: StoreError.self) {
            try s.world.store.update(coffee.id, by: .system) {
                $0.attributes[FinanceKey.category] = Attribute(
                    .reference(s.dining.id), provenance: Provenance(origin: .system, truth: .derived, timestamp: Fixtures.t0))
            }
        }
        let skipped = try await rules.suggestCategories(using: model, for: [coffee.id])
        #expect(skipped.keptPersonCategory == [coffee.id])
    }
}
