import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// Money moving out of or into an account.
public enum Direction: String, Codable, Sendable, CaseIterable {
    case outflow
    case inflow
}

/// A categorisation rule. Every condition that is set must hold.
public struct CategoryRule: Sendable, Hashable {
    /// The stored rule object, once saved.
    public var id: ObjectID?
    public var name: String
    public var category: ObjectID
    /// Matches when the payee contains any of these (case and punctuation ignored).
    public var payeeContains: [String]
    /// Bounds on the amount's magnitude, inclusive.
    public var minimumAmount: Decimal?
    public var maximumAmount: Decimal?
    public var direction: Direction?
    public var account: ObjectID?
    /// Higher runs first; the first matching rule wins.
    public var priority: Int

    public init(
        name: String, category: ObjectID, payeeContains: [String] = [], minimumAmount: Decimal? = nil, maximumAmount: Decimal? = nil,
        direction: Direction? = nil, account: ObjectID? = nil, priority: Int = 0
    ) {
        self.name = name
        self.category = category
        self.payeeContains = payeeContains
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
        self.direction = direction
        self.account = account
        self.priority = priority
    }

    public func matches(_ transaction: FinancialTransaction) -> Bool {
        if let account, transaction.account != account { return false }
        let amount = transaction.amount.amount
        if let direction, direction != (amount < 0 ? .outflow : .inflow) { return false }
        if let minimumAmount, amount.magnitude < minimumAmount { return false }
        if let maximumAmount, amount.magnitude > maximumAmount { return false }
        if !payeeContains.isEmpty {
            let payee = normalizedPayee(transaction.payee + " " + (transaction.memo ?? ""))
            guard payeeContains.contains(where: { !normalizedPayee($0).isEmpty && payee.contains(normalizedPayee($0)) }) else { return false }
        }
        return true
    }

    init?(_ record: ObjectRecord) {
        guard record.type == .categoryRule, let category = record.reference(FinanceKey.category) else { return nil }
        var payees: [String] = []
        if case .list(let values)? = record.attributes[FinanceKey.payeeContains]?.value {
            payees = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        }
        self.init(
            name: record.title, category: category, payeeContains: payees, minimumAmount: record.decimal(FinanceKey.minimumAmount),
            maximumAmount: record.decimal(FinanceKey.maximumAmount), direction: record.string(FinanceKey.direction).flatMap(Direction.init(rawValue:)),
            account: record.reference(FinanceKey.account), priority: record.int(FinanceKey.priority) ?? 0
        )
        id = record.id
    }

    var attributes: [String: Attribute] {
        var attributes: [String: Attribute] = [
            FinanceKey.category: Attribute(.reference(category)),
            FinanceKey.payeeContains: Attribute(.list(payeeContains.map(Value.string))),
            FinanceKey.priority: Attribute(.int(Int64(priority))),
        ]
        if let minimumAmount { attributes[FinanceKey.minimumAmount] = Attribute(minimumAmount.value) }
        if let maximumAmount { attributes[FinanceKey.maximumAmount] = Attribute(maximumAmount.value) }
        if let direction { attributes[FinanceKey.direction] = Attribute(.string(direction.rawValue)) }
        if let account { attributes[FinanceKey.account] = Attribute(.reference(account)) }
        return attributes
    }
}

/// A model's suggested category for one transaction.
public struct CategorySuggestion: Sendable, Hashable {
    public var category: ObjectID
    /// 0...1.
    public var confidence: Double
    public var rationale: String?

    public init(category: ObjectID, confidence: Double, rationale: String? = nil) {
        self.category = category
        self.confidence = confidence
        self.rationale = rationale
    }
}

/// The hook a local or cloud model implements to suggest categories. It sees
/// the transaction and the person's categories and returns one, or nil.
public protocol CategorySuggester: Sendable {
    var model: ModelRef { get }
    func suggest(for transaction: FinancialTransaction, among categories: [TransactionCategory]) async throws -> CategorySuggestion?
}

/// What a categorisation pass did.
public struct CategorizationReport: Sendable, Hashable {
    /// Transactions whose category was set or changed.
    public var assigned: [ObjectID] = []
    /// Transactions left alone because a person set their category.
    public var keptPersonCategory: [ObjectID] = []
    /// Matched, but already had this category from the same source.
    public var unchanged: [ObjectID] = []
    /// No rule matched, or the model had no confident suggestion.
    public var unmatched: [ObjectID] = []
}

/// Rules and model-assisted categorisation.
///
/// A category is an attribute on the transaction with its own provenance:
/// - set by a rule: **derived** (`system` origin, the rule in its dependencies);
/// - suggested by a model: **agentInterpretation** (`model` origin, with confidence);
/// - set by a person (`Ledger.setCategory`): **recorded**.
///
/// A person's category is never overwritten: both passes skip it, and the
/// store's `TruthPolicy` would refuse the write anyway. Rules outrank a
/// model: a rule replaces a model's suggestion, and the model only fills
/// transactions that have no category yet.
public struct Categorizer: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Stores a rule as a `categoryRule` object.
    @discardableResult
    public func addRule(_ rule: CategoryRule, by author: Origin) throws -> CategoryRule {
        let record = try store.create(
            ObjectRecord(
                type: .categoryRule, title: rule.name, attributes: rule.attributes,
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now())
            ))
        return CategoryRule(record)!
    }

    /// Active rules, highest priority first, then oldest first.
    public func rules() throws -> [CategoryRule] {
        try store.objects(ofType: .categoryRule).filter { $0.lifecycle == .active }.compactMap(CategoryRule.init)
            .enumerated().sorted { ($0.element.priority, -$0.offset) > ($1.element.priority, -$1.offset) }.map(\.element)
    }

    static func isPersonCategory(_ transaction: FinancialTransaction) -> Bool {
        transaction.categoryTruth.map(TruthPolicy.protected.contains) ?? false
    }

    /// Runs the rules over transactions (all live ones by default).
    @discardableResult
    public func applyRules(to transactionIDs: [ObjectID]? = nil) throws -> CategorizationReport {
        let rules = try rules()
        let ledger = Ledger(store: store, clock: clock)
        let transactions = try transactionIDs.map { try $0.map(ledger.transaction) } ?? ledger.transactions()
        var report = CategorizationReport()
        try store.batch { store in
            for transaction in transactions {
                if Self.isPersonCategory(transaction) {
                    report.keptPersonCategory.append(transaction.id)
                    continue
                }
                guard let rule = rules.first(where: { $0.matches(transaction) }), let ruleID = rule.id else {
                    report.unmatched.append(transaction.id)
                    continue
                }
                if transaction.category == rule.category, transaction.categoryTruth == .derived,
                    transaction.categoryProvenance?.dependencies == [ruleID]
                {
                    report.unchanged.append(transaction.id)
                    continue
                }
                let provenance = Provenance(
                    origin: .system, truth: .derived, timestamp: clock.now(), method: "rule: \(rule.name)", dependencies: [ruleID],
                    transformation: "categoryRule"
                )
                try store.update(transaction.id, by: .system, instruction: "Rule \(rule.name)") {
                    $0.attributes[FinanceKey.category] = Attribute(.reference(rule.category), provenance: provenance)
                }
                report.assigned.append(transaction.id)
            }
        }
        return report
    }

    /// Asks the model for a category for every transaction that has none.
    /// Suggestions below `minimumConfidence`, or naming an unknown category,
    /// are dropped.
    @discardableResult
    public func suggestCategories(
        using suggester: some CategorySuggester, for transactionIDs: [ObjectID]? = nil, minimumConfidence: Double = 0.5
    ) async throws -> CategorizationReport {
        let ledger = Ledger(store: store, clock: clock)
        let categories = try ledger.categories()
        let known = Set(categories.map(\.id))
        let transactions = try transactionIDs.map { try $0.map(ledger.transaction) } ?? ledger.transactions()
        var report = CategorizationReport()
        for transaction in transactions {
            if Self.isPersonCategory(transaction) {
                report.keptPersonCategory.append(transaction.id)
                continue
            }
            guard transaction.category == nil else {
                report.unchanged.append(transaction.id)
                continue
            }
            guard let suggestion = try await suggester.suggest(for: transaction, among: categories), known.contains(suggestion.category),
                suggestion.confidence >= minimumConfidence, (0...1).contains(suggestion.confidence)
            else {
                report.unmatched.append(transaction.id)
                continue
            }
            let origin = Origin.model(suggester.model)
            let provenance = Provenance(
                origin: origin, truth: .agentInterpretation, timestamp: clock.now(), method: suggestion.rationale ?? "model suggestion",
                confidence: suggestion.confidence, dependencies: [transaction.id]
            )
            try store.update(transaction.id, by: origin, instruction: "Suggest category") {
                $0.attributes[FinanceKey.category] = Attribute(.reference(suggestion.category), provenance: provenance)
            }
            report.assigned.append(transaction.id)
        }
        return report
    }
}
