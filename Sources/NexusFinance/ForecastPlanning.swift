import Foundation
import NexusCore
import NexusModel
import NexusPersistence

// The forecast screen's model: scenarios with their claimed assumptions,
// an assumption form that turns text fields into an `Assumption`, and the
// projection as chart points, each point labelled recorded (the opening
// balance) or modeled (the projection).

/// One point on a projected-balance chart.
public struct ForecastChartPoint: Sendable, Hashable, Identifiable {
    public var id: Date { date }
    /// The opening point sits at the start of the first month; projected
    /// points at the end of their month.
    public var date: Date
    public var month: YearMonth
    /// For the chart only; the stored amounts stay `Decimal`.
    public var total: Double
    public var money: Money
    /// Recorded for the opening balance, modeled for the projection.
    public var truth: TruthClass
}

/// A scenario as the list shows it.
public struct ScenarioSummary: Sendable, Hashable, Identifiable {
    public var id: ObjectID { scenario.id }
    public var scenario: Scenario
    public var forecast: Forecast?
    public var ending: Money? { forecast?.ending }
    public var lowest: Money? { forecast?.minimum?.total }
    public var firstNegativeMonth: YearMonth? { forecast?.firstNegativeMonth }
    /// When the projection was last run.
    public var lastRun: Date? { forecast?.provenance.timestamp }
}

extension Forecast {
    /// The opening balance (recorded) followed by one modeled point per month.
    public func chartPoints() throws -> [ForecastChartPoint] {
        guard let first = points.first else { return [] }
        let opening = try Money.sum(self.opening.values, in: currency)
        var result = [
            ForecastChartPoint(date: first.month.start, month: first.month, total: opening.amount.doubleValue, money: opening, truth: .recorded)
        ]
        for point in points {
            result.append(
                ForecastChartPoint(
                    date: FinanceCalendar.adding(days: -1, to: point.month.end), month: point.month, total: point.total.amount.doubleValue,
                    money: point.total, truth: provenance.truth))
        }
        return result
    }
}

extension Assumption {
    /// A short name for lists.
    public var label: String {
        switch self {
        case .oneOff(let label, _, _, _), .monthly(let label, _, _, _, _, _): label
        case .adjustRecurring(let payee, _, _): "Change \(payee)"
        case .stopRecurring(let payee, _): "Stop \(payee)"
        }
    }

    /// What the assumption claims, in words.
    public var summary: String {
        func signed(_ money: Money) -> String { money.isNegative ? money.description : "+\(money.description)" }
        switch self {
        case .oneOff(let label, let date, let amount, _):
            return "\(label): \(signed(amount)) on \(FinanceCalendar.isoDay(date))"
        case .monthly(let label, let amount, _, let day, let start, let end):
            return "\(label): \(signed(amount)) monthly on day \(day), from \(start)\(end.map { " through \($0)" } ?? "")"
        case .adjustRecurring(let payee, let factor, let start):
            let percent = ((factor - 1) * 100).rounded(scale: 2)
            return "\(payee): \(percent >= 0 ? "+" : "")\(percent.plainString) % from \(start)"
        case .stopRecurring(let payee, let start):
            return "\(payee): stops from \(start)"
        }
    }
}

/// The assumption form: text fields as the person types them, turned into
/// an `Assumption` (claimed truth once stored on the scenario).
public struct AssumptionDraft: Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case oneOff
        case monthly
        case adjustRecurring
        case stopRecurring

        public var title: String {
            switch self {
            case .oneOff: "One-off amount"
            case .monthly: "Monthly amount"
            case .adjustRecurring: "Change a recurring payment"
            case .stopRecurring: "Stop a recurring payment"
            }
        }
    }

    public var kind: Kind
    public var label: String
    /// Signed: "-1200" is money out. "1,234.50" and "(40)" are accepted.
    public var amount: String
    public var date: Date
    public var day: Int
    public var start: YearMonth
    public var end: YearMonth?
    /// The recurring payee to change or stop.
    public var payee: String
    /// Percent change for `adjustRecurring`: "20" is a 20 % rise, "-10" a 10 % cut.
    public var percent: String
    public var account: ObjectID?

    public init(
        kind: Kind = .oneOff, label: String = "", amount: String = "", date: Date = Date(), day: Int = 1, start: YearMonth = YearMonth(Date()),
        end: YearMonth? = nil, payee: String = "", percent: String = "", account: ObjectID? = nil
    ) {
        self.kind = kind
        self.label = label
        self.amount = amount
        self.date = date
        self.day = day
        self.start = start
        self.end = end
        self.payee = payee
        self.percent = percent
        self.account = account
    }

    static func number(_ text: String) throws -> Decimal {
        guard let value = Decimal(exactly: text) ?? NumberFormat.us.parse(text) else { throw FinanceError.unparsableAmount(text, line: 0) }
        return value
    }

    /// The assumption, with amounts in `currency`. Throws on a blank label,
    /// payee or account, or an amount or percent that doesn't parse.
    public func assumption(currency: Currency) throws -> Assumption {
        let label = label.trimmingCharacters(in: .whitespaces)
        let payee = payee.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .oneOff, .monthly:
            guard !label.isEmpty else { throw FinanceError.missingInput("label") }
            guard let account else { throw FinanceError.missingInput(FinanceKey.account) }
            let money = Money(try Self.number(amount), currency)
            if kind == .oneOff { return .oneOff(label: label, date: FinanceCalendar.startOfDay(date), amount: money, account: account) }
            return .monthly(label: label, amount: money, account: account, day: min(max(day, 1), 31), start: start, end: end)
        case .adjustRecurring:
            guard !payee.isEmpty else { throw FinanceError.missingInput(FinanceKey.payee) }
            return .adjustRecurring(payee: payee, factor: 1 + (try Self.number(percent)) / 100, start: start)
        case .stopRecurring:
            guard !payee.isEmpty else { throw FinanceError.missingInput(FinanceKey.payee) }
            return .stopRecurring(payee: payee, start: start)
        }
    }
}

extension Scenarios {
    /// Every scenario, newest first.
    public func scenarios() throws -> [Scenario] {
        try store.objects(ofType: .financialScenario).filter { $0.lifecycle == .active }.map(Scenario.init)
            .sorted { ($0.record.createdAt, $0.id) > ($1.record.createdAt, $1.id) }
    }

    /// Scenarios with their last stored projection.
    public func summaries() throws -> [ScenarioSummary] {
        try scenarios().map { ScenarioSummary(scenario: $0, forecast: try forecast($0.id)) }
    }

    /// Adds one assumption to the scenario's list (claimed truth).
    @discardableResult
    public func addAssumption(_ assumption: Assumption, to scenarioID: ObjectID, by author: Origin) throws -> Scenario {
        try setAssumptions(scenario(scenarioID).assumptions + [assumption], on: scenarioID, by: author)
    }

    /// Removes the assumption at `index` from the scenario's list.
    @discardableResult
    public func removeAssumption(at index: Int, from scenarioID: ObjectID, by author: Origin) throws -> Scenario {
        var assumptions = try scenario(scenarioID).assumptions
        guard assumptions.indices.contains(index) else { return try scenario(scenarioID) }
        assumptions.remove(at: index)
        return try setAssumptions(assumptions, on: scenarioID, by: author)
    }

    /// The recurring series the scenario's accounts have, for the change
    /// and stop pickers.
    public func recurringPayees(for scenarioID: ObjectID) throws -> [String] {
        let accounts = Set(try scenario(scenarioID).accounts)
        return Array(Set(try RecurringDetector(store: store, clock: clock).series(accounts: accounts).map(\.payee))).sorted()
    }
}
