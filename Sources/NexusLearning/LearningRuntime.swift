import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

public struct LearningRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock
    /// Simulator kinds this runtime can decode from stored scenarios.
    public var simulatorTypes: [any ScenarioSimulator.Type]

    public init(store: NexusStore, clock: NexusClock = SystemClock(), simulatorTypes: [any ScenarioSimulator.Type] = ScenarioSimulators.builtIn) {
        self.store = store
        self.clock = clock
        self.simulatorTypes = simulatorTypes
    }

    /// Builds an instrument-loop scenario from a resolved investigation.
    @discardableResult
    public func makeScenario(
        from investigation: ObjectID,
        loop: InstrumentLoop,
        fault: SimulatedFault,
        tests: [TestOption],
        by author: Origin
    ) throws -> TrainingScenario {
        try makeScenario(from: investigation, simulator: LoopScenarioSimulator(loop: loop, faults: [fault]), tests: tests, by: author)
    }

    /// Builds a scenario from a resolved investigation, finding the
    /// simulator from what it investigated (`simulator(for:)`).
    @discardableResult
    public func makeScenario(from investigation: ObjectID, by author: Origin) throws -> TrainingScenario {
        _ = try confirmedCause(of: investigation)
        guard let found = try simulator(for: investigation) else { throw LearningError.noSimulator(investigation) }
        return try makeScenario(from: investigation, simulator: found.simulator, tests: found.tests, by: author)
    }

    /// Builds a scenario from a resolved investigation with any simulator.
    @discardableResult
    public func makeScenario(
        from investigation: ObjectID,
        simulator: any ScenarioSimulator,
        tests: [TestOption],
        by author: Origin
    ) throws -> TrainingScenario {
        try store.batch { store in
            let investigations = InvestigationRuntime(store: store, clock: clock)
            guard let record = try store.object(investigation) else { throw StoreError.notFound(investigation) }
            let cause = try confirmedCause(of: investigation)

            let hypotheses = try investigations.hypotheses(of: investigation)
            let evidence = try store.relationships(from: investigation, kind: .contains).map(\.to)
            let readings = try evidence.compactMap { try store.measurement($0) }.sorted { ($0.sampledAt, $0.id) < ($1.sampledAt, $1.id) }
            var expertPath: [String] = []
            for reading in readings {
                if let test = tests.first(where: { $0.testPoint == reading.testPoint && $0.quantity == reading.quantityName }),
                    !expertPath.contains(test.title)
                {
                    expertPath.append(test.title)
                }
            }
            var divergence: String?
            if case .map(let detail)? = record.attributes["firstDivergence"]?.value, case .string(let summary)? = detail["summary"] {
                divergence = summary
            }
            var candidates: [String: [String: ReadingRange]] = [:]
            for hypothesis in hypotheses {
                for test in tests {
                    if let prediction = hypothesis.predictions.first(where: { $0.testPoint == test.testPoint && $0.quantity == test.quantity }) {
                        candidates[hypothesis.statement, default: [:]][test.title] = ReadingRange(
                            low: prediction.low, high: prediction.high, unit: prediction.unit
                        )
                    }
                }
            }

            let provenance = Provenance(
                origin: author, truth: .derived, timestamp: clock.now(), method: "scenario from investigation",
                dependencies: [investigation, cause.id] + readings.map(\.id)
            )
            let scenario = TrainingScenario(
                id: .make(), briefing: record.title, simulator: simulator,
                choices: hypotheses.map(\.statement).sorted(), tests: tests,
                cause: cause.statement, expertPath: expertPath, firstDivergence: divergence, candidateReadings: candidates
            )
            try store.create(
                ObjectRecord(
                    id: scenario.id, type: .trainingScenario, title: "Scenario: \(record.title)",
                    attributes: Self.attributes(of: scenario), provenance: provenance
                ))
            try store.relate(Relationship(kind: .derivedFrom, from: scenario.id, to: investigation, provenance: provenance))
            return scenario
        }
    }

    /// The simulator and tests that replay an investigation, when its
    /// subjects say which domain it is about. Today: a vehicle with a
    /// charging system and a charging cause gives `ChargingScenarioSimulator`,
    /// with the severity fitted to the readings that were assessed against
    /// the hypotheses. Nil when nothing fits (loops are bound by
    /// `ActionExecutor`).
    public func simulator(for investigation: ObjectID) throws -> (simulator: any ScenarioSimulator, tests: [TestOption])? {
        let cause = try confirmedCause(of: investigation)
        guard let kind = ChargingFaultKind(statement: cause.statement) else { return nil }
        let garage = VehicleRuntime(store: store, clock: clock)
        let subjects = try store.relationships(from: investigation, kind: .investigates).map(\.to)
        for subject in subjects {
            guard let vehicle = try? garage.vehicle(subject), let system = ChargingSystem(vehicle) else { continue }
            let diagnosis = ChargingDiagnosis(system: system)
            var readings: [ChargingTest: Double] = [:]
            for id in try store.relationships(from: investigation, kind: .contains).map(\.to) {
                guard let reading = try store.measurement(id), InvestigationRuntime.evidenceTruth.contains(reading.truth),
                    let test = ChargingTest(quantity: reading.quantityName), reading.testPoint == test.testPoint(in: system)
                else { continue }
                let assessed = try !store.relationships(from: id, kind: .supports).isEmpty || !store.relationships(from: id, kind: .contradicts).isEmpty
                if assessed { readings[test] = reading.value.value }
            }
            let severity = try diagnosis.fitSeverity(of: kind, to: readings)
            return (ChargingScenarioSimulator(system: system, cause: kind, severity: severity), diagnosis.testOptions)
        }
        return nil
    }

    func confirmedCause(of investigation: ObjectID) throws -> Hypothesis {
        guard let record = try store.object(investigation) else { throw StoreError.notFound(investigation) }
        guard case .reference(let causeID)? = record.attributes["cause"]?.value,
            let cause = try InvestigationRuntime(store: store, clock: clock).hypotheses(of: investigation).first(where: { $0.id == causeID })
        else { throw LearningError.investigationNotResolved(investigation) }
        return cause
    }

    public func scenario(_ id: ObjectID) throws -> TrainingScenario {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .trainingScenario else { throw LearningError.notAScenario(id) }
        return try Self.scenario(from: record, simulators: simulatorTypes)
    }

    /// Every stored scenario, oldest first.
    public func scenarios() throws -> [TrainingScenario] {
        try store.objects(ofType: .trainingScenario).map { try Self.scenario(from: $0, simulators: simulatorTypes) }
    }

    /// Scores a learner's run: the tests they chose, in order, and their
    /// diagnosis. Each tutor hint used costs `TutorPolicy.pointsPerHint`.
    @discardableResult
    public func grade(
        _ scenarioID: ObjectID,
        learner: Origin,
        testsRun: [String],
        diagnosis: String,
        hintsUsed: Int = 0
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
        score -= Double(max(0, hintsUsed)) * TutorPolicy.pointsPerHint
        let result = ScenarioAttemptResult(
            attempt: .make(), correctDiagnosis: correct, efficiency: efficiency, hazardousTests: hazardous,
            jumpedToConclusion: jumped, score: Int(min(100, max(0, score)).rounded())
        )

        let provenance = Provenance(origin: learner, truth: learner.defaultTruth, timestamp: clock.now(), method: "scenario attempt")
        var attributes: [String: Attribute] = [
            "testsRun": Attribute(.list(testsRun.map(Value.string))),
            "diagnosis": Attribute(.string(diagnosis)),
            "correct": Attribute(.bool(correct)),
            "efficiency": Attribute(.double(efficiency)),
            "score": Attribute(.int(Int64(result.score))),
        ]
        if hintsUsed > 0 { attributes["hintsUsed"] = Attribute(.int(Int64(hintsUsed))) }
        try store.batch { store in
            try store.create(
                ObjectRecord(
                    id: result.attempt, type: .scenarioAttempt, title: "Attempt: \(scenario.briefing)", attributes: attributes, provenance: provenance
                ))
            try store.relate(Relationship(kind: .dependsOn, from: result.attempt, to: scenarioID, provenance: provenance))
        }
        return result
    }

    /// A learner's stored attempts at a scenario, oldest first.
    public func attempts(at scenarioID: ObjectID, by learner: Origin) throws -> [ObjectRecord] {
        let ids = try store.relationships(to: scenarioID, kind: .dependsOn).map(\.from)
        return try store.objects(ids).filter { $0.type == .scenarioAttempt && $0.provenance.origin == learner }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    // MARK: Encoding

    static func attributes(of scenario: TrainingScenario) -> [String: Attribute] {
        var attributes: [String: Attribute] = [
            "briefing": Attribute(.string(scenario.briefing)),
            "simulator": Attribute(ScenarioSimulators.encode(scenario.simulator)),
            "choices": Attribute(.list(scenario.choices.map(Value.string))),
            "tests": Attribute(.list(scenario.tests.map(Self.encode))),
            "cause": Attribute(.string(scenario.cause)),
            "expertPath": Attribute(.list(scenario.expertPath.map(Value.string))),
            "topic": Attribute(.string(scenario.topic)),
        ]
        if let divergence = scenario.firstDivergence {
            attributes["firstDivergence"] = Attribute(.string(divergence))
        }
        if !scenario.candidateReadings.isEmpty {
            attributes["candidateReadings"] = Attribute(
                .map(
                    scenario.candidateReadings.mapValues { ranges in
                        .map(ranges.mapValues { .map(["low": .double($0.low), "high": .double($0.high), "unit": .string($0.unit)]) })
                    }))
        }
        return attributes
    }

    static func encode(_ test: TestOption) -> Value {
        var map: [String: Value] = [
            "title": .string(test.title), "testPoint": .reference(test.testPoint), "quantity": .string(test.quantity),
            "cost": .double(test.cost), "safety": .int(Int64(test.safety.rawValue)),
        ]
        if let condition = test.condition { map["condition"] = .string(condition) }
        return .map(map)
    }

    static func scenario(from record: ObjectRecord, simulators: [any ScenarioSimulator.Type] = ScenarioSimulators.builtIn) throws -> TrainingScenario {
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
        guard case .list(let testValues)? = record.attributes["tests"]?.value else { throw malformed }

        let simulator: any ScenarioSimulator
        do {
            if let stored = record.attributes["simulator"]?.value {
                simulator = try ScenarioSimulators.decode(stored, using: simulators)
            } else {
                // Stored before simulators were generalised: one loop, one fault.
                guard case .map(let loop)? = record.attributes["loop"]?.value, let fault = record.attributes["fault"]?.value else { throw malformed }
                simulator = LoopScenarioSimulator(loop: try ScenarioCodec.loop(loop), faults: [try ScenarioCodec.fault(fault)])
            }
        } catch is ScenarioCodingError {
            throw malformed
        }

        let tests = try testValues.map { value -> TestOption in
            guard case .map(let map) = value, case .string(let title)? = map["title"], case .string(let quantity)? = map["quantity"],
                case .reference(let testPoint)? = map["testPoint"], case .double(let cost)? = map["cost"],
                case .int(let safety)? = map["safety"], let level = TestSafety(rawValue: Int(safety))
            else { throw malformed }
            var condition: String?
            if case .string(let text)? = map["condition"] { condition = text }
            return TestOption(title: title, testPoint: testPoint, quantity: quantity, condition: condition, cost: cost, safety: level)
        }
        var divergence: String?
        if case .string(let text)? = record.attributes["firstDivergence"]?.value { divergence = text }
        var candidates: [String: [String: ReadingRange]] = [:]
        if case .map(let byChoice)? = record.attributes["candidateReadings"]?.value {
            for (choice, value) in byChoice {
                guard case .map(let byTest) = value else { throw malformed }
                for (test, range) in byTest {
                    guard case .map(let map) = range, case .double(let low)? = map["low"], case .double(let high)? = map["high"],
                        case .string(let unit)? = map["unit"]
                    else { throw malformed }
                    candidates[choice, default: [:]][test] = ReadingRange(low: low, high: high, unit: unit)
                }
            }
        }
        var topic: String?
        if case .string(let text)? = record.attributes["topic"]?.value { topic = text }

        return TrainingScenario(
            id: record.id, briefing: try string("briefing"), simulator: simulator,
            choices: try strings("choices"), tests: tests, cause: try string("cause"),
            expertPath: try strings("expertPath"), firstDivergence: divergence, candidateReadings: candidates, topic: topic
        )
    }
}
