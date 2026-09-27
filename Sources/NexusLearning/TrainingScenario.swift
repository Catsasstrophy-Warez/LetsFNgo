import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

extension ObjectType {
    public static let trainingScenario: ObjectType = "trainingScenario"
    public static let scenarioAttempt: ObjectType = "scenarioAttempt"
}

public enum LearningError: Error, Equatable, Sendable {
    case investigationNotResolved(ObjectID)
    case notAScenario(ObjectID)
    case malformed(ObjectID)
    case unknownTest(String)
}

/// A replayable exercise distilled from a resolved investigation.
///
/// The learner sees only the briefing, the candidate causes and the tests
/// they may run; the answer key (cause, expert path, first divergence) stays
/// in the scenario for scoring. The fault is stored as a simulation
/// parameter override, so the field can be rebuilt and measured again.
public struct TrainingScenario: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var briefing: String
    public var loop: InstrumentLoop
    public var fault: SimulatedFault
    public var choices: [String]
    public var tests: [TestOption]
    public var cause: String
    /// Test titles in the order the resolving technician ran them.
    public var expertPath: [String]
    public var firstDivergence: String?

    /// A fresh field simulation with the case's fault, settled and run to
    /// the operating point where the symptom appeared.
    public func makeField(dt: Double = 0.5, runFor seconds: Double = 600) throws -> SimulationRuntime {
        let runtime = try SimulationRuntime(dt: dt, state: loop.healthyState(), solvers: loop.solvers)
        runtime.inject(fault)
        try runtime.start()
        try runtime.run(for: seconds)
        return runtime
    }
}

public struct ScenarioAttemptResult: Sendable, Hashable {
    public var attempt: ObjectID
    public var correctDiagnosis: Bool
    /// Cost of the expert-path tests the learner ran ÷ the learner's total cost.
    /// 1 means no wasted tests; 0 means none of the discriminating tests were run.
    public var efficiency: Double
    public var hazardousTests: [String]
    /// Chose a cause without running any test that splits the candidates.
    public var jumpedToConclusion: Bool
    /// 0–100.
    public var score: Int
}

public struct LearningRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Builds a scenario from a resolved investigation.
    @discardableResult
    public func makeScenario(
        from investigation: ObjectID,
        loop: InstrumentLoop,
        fault: SimulatedFault,
        tests: [TestOption],
        by author: Origin
    ) throws -> TrainingScenario {
        try store.batch { store in
            let investigations = InvestigationRuntime(store: store, clock: clock)
            guard let record = try store.object(investigation) else { throw StoreError.notFound(investigation) }
            guard case .reference(let causeID)? = record.attributes["cause"]?.value,
                  let cause = try investigations.hypotheses(of: investigation).first(where: { $0.id == causeID })
            else { throw LearningError.investigationNotResolved(investigation) }

            let hypotheses = try investigations.hypotheses(of: investigation)
            let evidence = try store.relationships(from: investigation, kind: .contains).map(\.to)
            let readings = try evidence.compactMap { try store.measurement($0) }.sorted { ($0.sampledAt, $0.id) < ($1.sampledAt, $1.id) }
            var expertPath: [String] = []
            for reading in readings {
                if let test = tests.first(where: { $0.testPoint == reading.testPoint && $0.quantity == reading.quantityName }),
                   !expertPath.contains(test.title) {
                    expertPath.append(test.title)
                }
            }
            var divergence: String?
            if case .map(let detail)? = record.attributes["firstDivergence"]?.value, case .string(let summary)? = detail["summary"] {
                divergence = summary
            }

            let provenance = Provenance(
                origin: author, truth: .derived, timestamp: clock.now(), method: "scenario from investigation",
                dependencies: [investigation, causeID] + readings.map(\.id)
            )
            let scenario = TrainingScenario(
                id: .make(), briefing: record.title, loop: loop, fault: fault,
                choices: hypotheses.map(\.statement).sorted(), tests: tests,
                cause: cause.statement, expertPath: expertPath, firstDivergence: divergence
            )
            try store.create(ObjectRecord(
                id: scenario.id, type: .trainingScenario, title: "Scenario: \(record.title)",
                attributes: Self.attributes(of: scenario), provenance: provenance
            ))
            try store.relate(Relationship(kind: .derivedFrom, from: scenario.id, to: investigation, provenance: provenance))
            return scenario
        }
    }

    public func scenario(_ id: ObjectID) throws -> TrainingScenario {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .trainingScenario else { throw LearningError.notAScenario(id) }
        return try Self.scenario(from: record)
    }

    /// Scores a learner's run: the tests they chose, in order, and their diagnosis.
    @discardableResult
    public func grade(
        _ scenarioID: ObjectID,
        learner: Origin,
        testsRun: [String],
        diagnosis: String
    ) throws -> ScenarioAttemptResult {
        let scenario = try scenario(scenarioID)
        let chosen = try testsRun.map { title in
            try scenario.tests.first { $0.title == title }.orThrow(LearningError.unknownTest(title))
        }
        let cost = { (titles: [String]) in titles.compactMap { title in scenario.tests.first { $0.title == title }?.cost }.reduce(0, +) }
        // Credit only the discriminating work actually done: the expert-path
        // tests the learner ran, against everything the learner spent.
        let learnerCost = cost(testsRun)
        let usefulCost = cost(scenario.expertPath.filter(testsRun.contains))
        let efficiency = learnerCost == 0 ? 0 : min(1, usefulCost / learnerCost)
        let hazardous = chosen.filter { $0.safety == .hazardous }.map(\.title)
        let correct = diagnosis == scenario.cause
        let jumped = Set(testsRun).isDisjoint(with: scenario.expertPath)

        var score = correct ? 60.0 : 0
        score += 30 * efficiency
        score += jumped ? 0 : 10
        score -= Double(hazardous.count) * 25
        let result = ScenarioAttemptResult(
            attempt: .make(), correctDiagnosis: correct, efficiency: efficiency, hazardousTests: hazardous,
            jumpedToConclusion: jumped, score: Int(min(100, max(0, score)).rounded())
        )

        let provenance = Provenance(origin: learner, truth: learner.defaultTruth, timestamp: clock.now(), method: "scenario attempt")
        try store.batch { store in
            try store.create(ObjectRecord(
                id: result.attempt, type: .scenarioAttempt, title: "Attempt: \(scenario.briefing)",
                attributes: [
                    "testsRun": Attribute(.list(testsRun.map(Value.string))),
                    "diagnosis": Attribute(.string(diagnosis)),
                    "correct": Attribute(.bool(correct)),
                    "efficiency": Attribute(.double(efficiency)),
                    "score": Attribute(.int(Int64(result.score))),
                ],
                provenance: provenance
            ))
            try store.relate(Relationship(kind: .dependsOn, from: result.attempt, to: scenarioID, provenance: provenance))
        }
        return result
    }

    // MARK: Encoding

    static func attributes(of scenario: TrainingScenario) -> [String: Attribute] {
        var attributes: [String: Attribute] = [
            "briefing": Attribute(.string(scenario.briefing)),
            "loop": Attribute(.map([
                "tank": .reference(scenario.loop.tank), "transmitter": .reference(scenario.loop.transmitter),
                "terminal": .reference(scenario.loop.terminal), "card": .reference(scenario.loop.card),
                "controller": .reference(scenario.loop.controller), "valve": .reference(scenario.loop.valve),
            ])),
            "fault": Attribute(.map([
                "id": .reference(scenario.fault.id), "object": .reference(scenario.fault.parameter.object), "parameter": .string(scenario.fault.parameter.quantity),
                "value": .double(scenario.fault.value), "summary": .string(scenario.fault.summary),
            ])),
            "choices": Attribute(.list(scenario.choices.map(Value.string))),
            "tests": Attribute(.list(scenario.tests.map { test in
                var map: [String: Value] = [
                    "title": .string(test.title), "testPoint": .reference(test.testPoint), "quantity": .string(test.quantity),
                    "cost": .double(test.cost), "safety": .int(Int64(test.safety.rawValue)),
                ]
                if let condition = test.condition { map["condition"] = .string(condition) }
                return .map(map)
            })),
            "cause": Attribute(.string(scenario.cause)),
            "expertPath": Attribute(.list(scenario.expertPath.map(Value.string))),
        ]
        if let divergence = scenario.firstDivergence {
            attributes["firstDivergence"] = Attribute(.string(divergence))
        }
        return attributes
    }

    static func scenario(from record: ObjectRecord) throws -> TrainingScenario {
        let malformed = LearningError.malformed(record.id)
        func string(_ key: String) throws -> String {
            guard case .string(let text)? = record.attributes[key]?.value else { throw malformed }
            return text
        }
        func strings(_ key: String) throws -> [String] {
            guard case .list(let values)? = record.attributes[key]?.value else { throw malformed }
            return try values.map { value in
                guard case .string(let text) = value else { throw malformed }
                return text
            }
        }
        func reference(_ map: [String: Value], _ key: String) throws -> ObjectID {
            guard case .reference(let id)? = map[key] else { throw malformed }
            return id
        }
        guard case .map(let loop)? = record.attributes["loop"]?.value,
              case .map(let fault)? = record.attributes["fault"]?.value,
              case .string(let parameter)? = fault["parameter"], case .double(let value)? = fault["value"],
              case .string(let summary)? = fault["summary"],
              case .list(let testValues)? = record.attributes["tests"]?.value
        else { throw malformed }

        let tests = try testValues.map { value -> TestOption in
            guard case .map(let map) = value, case .string(let title)? = map["title"], case .string(let quantity)? = map["quantity"],
                  case .double(let cost)? = map["cost"], case .int(let safety)? = map["safety"],
                  let level = TestSafety(rawValue: Int(safety))
            else { throw malformed }
            var condition: String?
            if case .string(let text)? = map["condition"] { condition = text }
            return TestOption(title: title, testPoint: try reference(map, "testPoint"), quantity: quantity, condition: condition, cost: cost, safety: level)
        }
        var divergence: String?
        if case .string(let text)? = record.attributes["firstDivergence"]?.value { divergence = text }

        return TrainingScenario(
            id: record.id, briefing: try string("briefing"),
            loop: InstrumentLoop(
                tank: try reference(loop, "tank"), transmitter: try reference(loop, "transmitter"), terminal: try reference(loop, "terminal"),
                card: try reference(loop, "card"), controller: try reference(loop, "controller"), valve: try reference(loop, "valve")
            ),
            fault: SimulatedFault(
                id: try reference(fault, "id"), parameter: StateKey(try reference(fault, "object"), parameter), value: value, summary: summary
            ),
            choices: try strings("choices"), tests: tests, cause: try string("cause"),
            expertPath: try strings("expertPath"), firstDivergence: divergence
        )
    }
}

extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
