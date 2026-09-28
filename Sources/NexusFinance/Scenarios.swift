import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A person's assumption about the future. Stored on the scenario as
/// **claimed** truth: it asserts something that has not happened.
public enum Assumption: Sendable, Hashable {
    /// A single dated amount (a bonus, a car purchase). Signed.
    case oneOff(label: String, date: Date, amount: Money, account: ObjectID)
    /// An amount every month on `day`, from `start` through `end` (open-ended when nil). Signed.
    case monthly(label: String, amount: Money, account: ObjectID, day: Int, start: YearMonth, end: YearMonth?)
    /// Scales a detected recurring series from `start` on (1.03 = a 3 % rise).
    case adjustRecurring(payee: String, factor: Decimal, start: YearMonth)
    /// Leaves a detected recurring series out (a cancelled subscription).
    case stopRecurring(payee: String, start: YearMonth)

    var value: Value {
        switch self {
        case .oneOff(let label, let date, let amount, let account):
            .map(["type": .string("oneOff"), "label": .string(label), "date": .date(date), "amount": amount.value, "account": .reference(account)])
        case .monthly(let label, let amount, let account, let day, let start, let end):
            .map(
                [
                    "type": .string("monthly"), "label": .string(label), "amount": amount.value, "account": .reference(account),
                    "day": .int(Int64(day)), "start": .string(start.description), "end": end.map { .string($0.description) } ?? .null,
                ])
        case .adjustRecurring(let payee, let factor, let start):
            .map(["type": .string("adjustRecurring"), "payee": .string(payee), "factor": factor.value, "start": .string(start.description)])
        case .stopRecurring(let payee, let start):
            .map(["type": .string("stopRecurring"), "payee": .string(payee), "start": .string(start.description)])
        }
    }

    init?(_ value: Value) {
        guard case .map(let fields) = value, case .string(let type)? = fields["type"] else { return nil }
        func string(_ key: String) -> String? { if case .string(let text)? = fields[key] { text } else { nil } }
        func month(_ key: String) -> YearMonth? { string(key).flatMap(YearMonth.init) }
        switch type {
        case "oneOff":
            guard let label = string("label"), case .date(let date)? = fields["date"], let amount = Money(fields["amount"]),
                case .reference(let account)? = fields["account"]
            else { return nil }
            self = .oneOff(label: label, date: date, amount: amount, account: account)
        case "monthly":
            guard let label = string("label"), let amount = Money(fields["amount"]), case .reference(let account)? = fields["account"],
                case .int(let day)? = fields["day"], let start = month("start")
            else { return nil }
            self = .monthly(label: label, amount: amount, account: account, day: Int(day), start: start, end: month("end"))
        case "adjustRecurring":
            guard let payee = string("payee"), let factor = Decimal(fields["factor"]), let start = month("start") else { return nil }
            self = .adjustRecurring(payee: payee, factor: factor, start: start)
        case "stopRecurring":
            guard let payee = string("payee"), let start = month("start") else { return nil }
            self = .stopRecurring(payee: payee, start: start)
        default:
            return nil
        }
    }
}

/// One month-end point of a projection.
public struct ForecastPoint: Sendable, Hashable {
    public var month: YearMonth
    public var balances: [ObjectID: Money]
    public var total: Money
}

/// A scenario's projection: **modeled** truth, stored only on the scenario.
public struct Forecast: Sendable, Hashable {
    public var scenario: ObjectID
    public var currency: Currency
    /// The recorded balances the projection started from.
    public var opening: [ObjectID: Money]
    public var points: [ForecastPoint]
    public var provenance: Provenance

    public var ending: Money? { points.last?.total }

    public var minimum: ForecastPoint? {
        points.min { $0.total.amount < $1.total.amount }
    }

    /// The first month whose total ends below zero.
    public var firstNegativeMonth: YearMonth? { points.first { $0.total.isNegative }?.month }
}

/// A typed view of a scenario object.
public struct Scenario: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var name: String { record.title }
    public var accounts: [ObjectID] {
        guard case .list(let values)? = record.attributes[FinanceKey.accounts]?.value else { return [] }
        return values.compactMap { if case .reference(let id) = $0 { id } else { nil } }
    }
    public var startMonth: YearMonth? { record.string(FinanceKey.startMonth).flatMap(YearMonth.init) }
    public var months: Int { record.int(FinanceKey.months) ?? 0 }
    public var includesRecurring: Bool { record.bool(FinanceKey.includeRecurring) ?? true }
    public var assumptions: [Assumption] {
        guard case .list(let values)? = record.attributes[FinanceKey.assumptions]?.value else { return [] }
        return values.compactMap(Assumption.init)
    }
    public var assumptionsTruth: TruthClass? { record.truth(of: FinanceKey.assumptions) }
    public var projectionTruth: TruthClass? { record.truth(of: FinanceKey.projection) }
}

/// Month-by-month comparison of two scenarios.
public struct ScenarioComparison: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public var month: YearMonth
        public var first: Money
        public var second: Money
        /// second − first.
        public var difference: Money
    }

    public var first: ObjectID
    public var second: ObjectID
    public var rows: [Row]
    public var endingDifference: Money?
    public var firstMinimum: Money?
    public var secondMinimum: Money?
    public var firstNegativeMonth: (first: YearMonth?, second: YearMonth?)

    public static func == (lhs: ScenarioComparison, rhs: ScenarioComparison) -> Bool {
        lhs.first == rhs.first && lhs.second == rhs.second && lhs.rows == rhs.rows && lhs.endingDifference == rhs.endingDifference
            && lhs.firstNegativeMonth.first == rhs.firstNegativeMonth.first && lhs.firstNegativeMonth.second == rhs.firstNegativeMonth.second
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(first)
        hasher.combine(second)
        hasher.combine(rows)
    }
}

/// Forward projections of account balances.
///
/// A scenario starts from each account's **recorded** balance and adds the
/// detected recurring series (derived) and the person's assumptions
/// (claimed). The result is **modeled** truth with a `simulation` origin
/// naming the scenario, and it is written to the scenario object only. This
/// type never writes to an account; `Ledger.recordBalance` refuses modeled
/// values, and the store's `TruthPolicy` refuses a modeled value over a
/// recorded balance.
public struct Scenarios: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    @discardableResult
    public func createScenario(
        _ name: String, accounts: [ObjectID], start: YearMonth, months: Int, assumptions: [Assumption] = [], includeRecurring: Bool = true,
        by author: Origin
    ) throws -> Scenario {
        let ledger = Ledger(store: store, clock: clock)
        for id in accounts { _ = try ledger.account(id) }
        return try store.batch { store in
            let now = clock.now()
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "scenario")
            let claimed = Provenance(origin: author, truth: .claimed, timestamp: now, method: "assumptions")
            let record = try store.create(
                ObjectRecord(
                    type: .financialScenario, title: name,
                    attributes: [
                        FinanceKey.accounts: Attribute(.list(accounts.map(Value.reference))),
                        FinanceKey.startMonth: Attribute(.string(start.description)),
                        FinanceKey.months: Attribute(.int(Int64(months))),
                        FinanceKey.includeRecurring: Attribute(.bool(includeRecurring)),
                        FinanceKey.assumptions: Attribute(.list(assumptions.map(\.value)), provenance: claimed),
                    ],
                    provenance: provenance
                ))
            for account in accounts {
                try store.relate(Relationship(kind: .projects, from: record.id, to: account, provenance: provenance))
            }
            return Scenario(record: record)
        }
    }

    public func scenario(_ id: ObjectID) throws -> Scenario {
        guard let record = try store.object(id), record.type == .financialScenario else { throw FinanceError.notFound(id, expected: .financialScenario) }
        return Scenario(record: record)
    }

    /// Replaces the scenario's assumptions (claimed truth).
    @discardableResult
    public func setAssumptions(_ assumptions: [Assumption], on scenarioID: ObjectID, by author: Origin) throws -> Scenario {
        _ = try scenario(scenarioID)
        let claimed = Provenance(origin: author, truth: .claimed, timestamp: clock.now(), method: "assumptions")
        return Scenario(
            record: try store.update(scenarioID, by: author, instruction: "Assumptions") {
                $0.attributes[FinanceKey.assumptions] = Attribute(.list(assumptions.map(\.value)), provenance: claimed)
            })
    }

    /// Runs the projection and stores it on the scenario as modeled truth.
    @discardableResult
    public func run(_ scenarioID: ObjectID) throws -> Forecast {
        let scenario = try scenario(scenarioID)
        guard let start = scenario.startMonth, scenario.months > 0, !scenario.accounts.isEmpty else {
            throw FinanceError.missingField(scenarioID, FinanceKey.startMonth)
        }
        let ledger = Ledger(store: store, clock: clock)
        let accounts = try scenario.accounts.map(ledger.account)
        let currency = accounts[0].currency
        var balances: [ObjectID: Money] = [:]
        var asOf: [ObjectID: Date] = [:]
        for account in accounts {
            guard account.currency == currency else { throw MoneyError.currencyMismatch(currency, account.currency) }
            guard let balance = account.balance, let date = account.balanceAsOf, let truth = account.balanceTruth,
                TruthPolicy.protected.contains(truth)
            else { throw FinanceError.missingBalance(account.id) }
            balances[account.id] = balance
            asOf[account.id] = date
        }
        let opening = balances
        let ids = Set(scenario.accounts)
        let series = scenario.includesRecurring ? try RecurringDetector(store: store, clock: clock).series(accounts: ids) : []
        let assumptions = scenario.assumptions
        let horizonEnd = start.adding(scenario.months).start

        // Every dated flow in the horizon, after the account's balance date.
        var flows: [(date: Date, account: ObjectID, amount: Money)] = []
        for item in series {
            guard let account = item.account, let cadence = item.cadence, let amount = item.amount, var date = item.nextDate else { continue }
            guard amount.currency == currency else { throw MoneyError.currencyMismatch(currency, amount.currency) }
            let payee = normalizedPayee(item.payee)
            while date < horizonEnd {
                let month = YearMonth(date)
                var scaled = amount
                var stopped = false
                for assumption in assumptions {
                    switch assumption {
                    case .adjustRecurring(let target, let factor, let from) where normalizedPayee(target) == payee && month >= from:
                        scaled = scaled * factor
                    case .stopRecurring(let target, let from) where normalizedPayee(target) == payee && month >= from:
                        stopped = true
                    default: break
                    }
                }
                if !stopped { flows.append((date, account, scaled)) }
                date = cadence.next(after: date)
            }
        }
        for assumption in assumptions {
            switch assumption {
            case .oneOff(_, let date, let amount, let account) where ids.contains(account):
                flows.append((FinanceCalendar.startOfDay(date), account, amount))
            case .monthly(_, let amount, let account, let day, let from, let until) where ids.contains(account):
                var month = from
                while month.start < horizonEnd, until.map({ month <= $0 }) ?? true {
                    let length = FinanceCalendar.calendar.range(of: .day, in: .month, for: month.start)?.count ?? 28
                    flows.append((FinanceCalendar.day(month.year, month.month, min(max(day, 1), length)), account, amount))
                    month = month.next
                }
            default: break
            }
        }
        for flow in flows where flow.amount.currency != currency { throw MoneyError.currencyMismatch(currency, flow.amount.currency) }
        flows = flows.filter { flow in flow.date > asOf[flow.account]! && flow.date < horizonEnd }.sorted { $0.date < $1.date }

        var points: [ForecastPoint] = []
        var cursor = 0
        for offset in 0..<scenario.months {
            let month = start.adding(offset)
            while cursor < flows.count, flows[cursor].date < month.end {
                balances[flows[cursor].account] = try balances[flows[cursor].account]! + flows[cursor].amount
                cursor += 1
            }
            let rounded = balances.mapValues { $0.rounded() }
            points.append(ForecastPoint(month: month, balances: rounded, total: try Money.sum(rounded.values, in: currency)))
        }

        let now = clock.now()
        let provenance = Provenance(
            origin: .simulation(run: scenarioID), truth: .modeled, timestamp: now,
            method: "balance projection: \(series.count) recurring series, \(assumptions.count) assumptions",
            dependencies: scenario.accounts + series.map(\.id), transformation: "forecast"
        )
        let forecast = Forecast(scenario: scenarioID, currency: currency, opening: opening, points: points, provenance: provenance)
        try store.batch { store in
            try store.update(scenarioID, by: .simulation(run: scenarioID), instruction: "Run forecast") {
                $0.attributes[FinanceKey.projection] = Attribute(Self.encode(forecast), provenance: provenance)
            }
            try store.record(
                Event(
                    at: now, kind: .simulated, subjects: [scenarioID], summary: "Forecast \(scenario.name): \(points.last.map { "\($0.total)" } ?? "")",
                    payload: ["months": .int(Int64(points.count))], provenance: provenance
                ))
        }
        return forecast
    }

    /// The projection last stored on the scenario, if it has been run.
    public func forecast(_ scenarioID: ObjectID) throws -> Forecast? {
        let scenario = try scenario(scenarioID)
        guard let attribute = scenario.record.attributes[FinanceKey.projection], let provenance = attribute.provenance else { return nil }
        return Self.decode(attribute.value, scenario: scenarioID, provenance: provenance)
    }

    /// Compares two scenarios month by month (running them first if needed).
    public func compare(_ first: ObjectID, _ second: ObjectID) throws -> ScenarioComparison {
        let a = try forecast(first) ?? run(first)
        let b = try forecast(second) ?? run(second)
        guard a.currency == b.currency else { throw MoneyError.currencyMismatch(a.currency, b.currency) }
        let byMonth = Dictionary(uniqueKeysWithValues: b.points.map { ($0.month, $0.total) })
        let rows = try a.points.compactMap { point -> ScenarioComparison.Row? in
            guard let other = byMonth[point.month] else { return nil }
            return ScenarioComparison.Row(month: point.month, first: point.total, second: other, difference: try other - point.total)
        }
        return ScenarioComparison(
            first: first, second: second, rows: rows, endingDifference: rows.last?.difference, firstMinimum: a.minimum?.total,
            secondMinimum: b.minimum?.total, firstNegativeMonth: (a.firstNegativeMonth, b.firstNegativeMonth)
        )
    }

    static func encode(_ forecast: Forecast) -> Value {
        .map([
            FinanceKey.currency: .string(forecast.currency.code),
            "opening": .map(Dictionary(uniqueKeysWithValues: forecast.opening.map { ($0.key.description, $0.value.value) })),
            "points": .list(
                forecast.points.map { point in
                    .map([
                        FinanceKey.month: .string(point.month.description),
                        "total": point.total.value,
                        "balances": .map(Dictionary(uniqueKeysWithValues: point.balances.map { ($0.key.description, $0.value.value) })),
                    ])
                }),
        ])
    }

    static func decode(_ value: Value, scenario: ObjectID, provenance: Provenance) -> Forecast? {
        func balances(_ value: Value?) -> [ObjectID: Money] {
            guard case .map(let fields)? = value else { return [:] }
            var result: [ObjectID: Money] = [:]
            for (key, value) in fields {
                if let id = ObjectID(key), let money = Money(value) { result[id] = money }
            }
            return result
        }
        guard case .map(let fields) = value, case .string(let code)? = fields[FinanceKey.currency], let currency = try? Currency(code),
            case .list(let list)? = fields["points"]
        else { return nil }
        let points = list.compactMap { item -> ForecastPoint? in
            guard case .map(let point) = item, case .string(let text)? = point[FinanceKey.month], let month = YearMonth(text),
                let total = Money(point["total"])
            else { return nil }
            return ForecastPoint(month: month, balances: balances(point["balances"]), total: total)
        }
        return Forecast(scenario: scenario, currency: currency, opening: balances(fields["opening"]), points: points, provenance: provenance)
    }
}
