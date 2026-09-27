import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusSearch
import NexusSimulation

extension DiagnosisCase {
    /// How a value reads in an answer: "12.03 V (observed)".
    static func cite(_ value: Double, _ unit: String, _ truth: TruthClass) -> String {
        let shown = unit == "ratio" || unit == "bool" ? Numbers.text(value) : "\(Numbers.text(value)) \(unit)"
        return "\(shown) (\(truth.rawValue))"
    }

    var conclusion: String {
        if survivors == [kind] {
            return "Cause: \(kind.statement) [\(kind.rawValue)]."
        }
        let names = survivors.map(\.rawValue).joined(separator: ", ")
        return "Still indistinguishable: \(names). Most likely cause: \(kind.statement) [\(kind.rawValue)]."
    }

    var divergenceSentence: String {
        guard let divergence else {
            return "The field never departed from the healthy twin on the watched signals."
        }
        return "First divergence from the healthy twin: \(divergence.quantity) at \(divergence.object), t = \(Numbers.text(divergence.seconds)) s, "
            + "\(Self.cite(divergence.actual, divergence.unit, .observed)) where the model expects \(Self.cite(divergence.expected, divergence.unit, .modeled))."
    }

    var nextTestSentence: String {
        guard let top = ranking.first, let test = LoopTest.allCases.first(where: { $0.title == top.title }) else {
            return "No safe test splits the candidates."
        }
        return "Next test: \(top.title). TestSelector ranks it first with \(Numbers.text(top.informationGain)) bits of expected information "
            + "for \(Numbers.text(access.cost(of: test))) min."
    }

    func diagnosisExample(id: String, split: DatasetSplit) -> TrainingExample {
        let steps = expertPath.map { "\($0.test): \(Self.cite($0.value, $0.unit, $0.truth))" }.joined(separator: "; ")
        let text = [
            nextTestSentence,
            "Expert path: \(steps).",
            conclusion,
            divergenceSentence,
        ].joined(separator: " ")
        return TrainingExample(
            id: id, kind: .diagnosis, split: split, seed: seed, prompt: symptom, observations: observations,
            tests: testExamples, hypotheses: hypothesisExamples, scenario: scenarioExample, messages: nil, ladder: nil,
            answer: AnswerKey(
                cause: kind.rawValue, nextTest: nextTest, text: text, ranking: ranking, expertPath: expertPath,
                firstDivergence: divergence, trail: nil, blockers: nil
            )
        )
    }

    // MARK: Tool transcripts

    /// A user goal worked through WorldTools. Tool results are produced by the
    /// same public store, graph and search calls the tools make, over a store
    /// holding this case's objects and readings, so formats match exactly.
    /// A coin drawn from the seed decides the goal: the next test before
    /// anything is measured, or the cause after the expert path's readings are in.
    func transcriptExample(id: String, split: DatasetSplit) throws -> TrainingExample {
        var rng = SplitMix64(seed: SplitMix64.mix(seed ^ 0x7472_616E_7363_7269))
        let askForCause = rng.chance(0.5)
        let clock = ManualClock(LoopScenarioFactory.t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let recorded = Provenance(origin: .user(id: "plant-engineer"), truth: .recorded, timestamp: clock.now())

        let objects: [(ObjectID, ObjectType, String, [String: Attribute])] = [
            (ids[.tank]!, .equipment, names.tank, [:]),
            (ids[.transmitter]!, .sensor, names.transmitter, ["tag": Attribute(.string(names.tag))]),
            (ids[.terminal]!, .testPoint, names.terminal, [:]),
            (ids[.card]!, .component, names.card, [:]),
            (loop.controller, .component, names.controller, [:]),
            (loop.valve, .component, names.valve, [:]),
        ]
        for (objectID, type, title, attributes) in objects {
            try store.create(ObjectRecord(id: objectID, type: type, title: title, attributes: attributes, provenance: recorded))
        }
        let links: [(RelationKind, ObjectID, ObjectID)] = [
            (.contains, ids[.tank]!, ids[.transmitter]!),
            (.connectedTo, ids[.transmitter]!, ids[.terminal]!),
            (.connectedTo, ids[.terminal]!, ids[.card]!),
            (.connectedTo, ids[.card]!, loop.controller),
            (.connectedTo, loop.controller, loop.valve),
        ]
        for (kind, from, to) in links {
            try store.relate(Relationship(id: rng.objectID(), kind: kind, from: from, to: to, provenance: recorded))
        }

        let hmi = observations.first { $0.name == "measuredLevel" }!.value
        let twinRun = rng.objectID()
        var shown = [
            ObservationExample(name: "measuredLevel", object: names.card, value: hmi, unit: "%", truth: .display, source: "HMI"),
            ObservationExample(name: "terminalVoltage", object: names.terminal, value: twin["terminalVoltage"]!, unit: "V", truth: .modeled, source: "healthy twin"),
            ObservationExample(name: "loopCurrent", object: names.terminal, value: twin["loopCurrent"]!, unit: "mA", truth: .modeled, source: "healthy twin"),
        ]
        try store.add(MeasurementRecord(
            id: rng.objectID(), quantityName: "measuredLevel", value: Quantity(hmi, "%"), testPoint: ids[.card]!, sampledAt: clock.now(),
            provenance: Provenance(origin: .importer(source: ids[.card]!), truth: .display, timestamp: clock.now(), method: "HMI")
        ))
        for name in ["terminalVoltage", "loopCurrent"] {
            try store.add(MeasurementRecord(
                id: rng.objectID(), quantityName: name, value: Quantity(twin[name]!, name == "loopCurrent" ? "mA" : "V"),
                testPoint: ids[.terminal]!, sampledAt: clock.now(),
                provenance: Provenance(origin: .simulation(run: twinRun), truth: .modeled, timestamp: clock.now(), method: "healthy twin")
            ))
        }
        let meter = rng.objectID()
        if askForCause {
            for step in expertPath {
                guard let test = LoopTest.allCases.first(where: { $0.title == step.test }) else { continue }
                clock.advance(by: access.cost(of: test) * 60)
                let origin: Origin = step.truth == .recorded ? .importer(source: ids[.card]!) : .instrument(id: meter)
                try store.add(MeasurementRecord(
                    id: rng.objectID(), quantityName: test.quantity, value: Quantity(step.value, step.unit), testPoint: ids[test.site]!,
                    sampledAt: clock.now(), provenance: Provenance(origin: origin, truth: step.truth, timestamp: clock.now(), method: test.title)
                ))
                shown.append(ObservationExample(
                    name: test.quantity, object: title(of: test.site), value: step.value, unit: step.unit, truth: step.truth, source: test.title
                ))
            }
        }

        let graph = ObjectGraph(store: store, clock: clock)
        var messages = [MessageExample(
            role: "system",
            content: "You are Nexus's diagnostic assistant. Use the tools to read the world model; never invent a value. "
                + "Label every value you cite with its truth class (observed, recorded, display, modeled, derived, claimed, agentInterpretation).",
            toolCalls: nil, toolCallID: nil
        )]
        let goal = askForCause
            ? "\(symptom) The technician's readings are in Nexus. What is the most likely cause?"
            : "\(symptom) What should I measure next?"
        messages.append(MessageExample(role: "user", content: goal, toolCalls: nil, toolCallID: nil))

        var callNumber = 0
        func turn(_ calls: [(String, [String: String], String)]) {
            var toolCalls: [ToolCallExample] = []
            var results: [MessageExample] = []
            for (name, arguments, result) in calls {
                callNumber += 1
                let callID = "call-\(callNumber)"
                toolCalls.append(ToolCallExample(id: callID, name: name, arguments: arguments))
                results.append(MessageExample(role: "tool", content: result, toolCalls: nil, toolCallID: callID))
            }
            messages.append(MessageExample(role: "assistant", content: "", toolCalls: toolCalls, toolCallID: nil))
            messages += results
        }

        turn([("search_objects", ["query": names.tag], try Self.searchResult(names.tag, store: store, graph: graph))])
        turn([("related_objects", ["id": ids[.transmitter]!.description], try Self.relatedResult(ids[.transmitter]!, store: store, graph: graph))])
        turn([
            ("get_measurements", ["test_point": ids[.card]!.description], try Self.measurementsResult(ids[.card]!, store: store)),
            ("get_measurements", ["test_point": ids[.terminal]!.description], try Self.measurementsResult(ids[.terminal]!, store: store)),
        ])
        if askForCause {
            let measuredSites = Set(expertPath.compactMap { step in LoopTest.allCases.first { $0.title == step.test }?.site })
            var calls: [(String, [String: String], String)] = []
            for site in [LoopTest.Site.tank, .transmitter] where measuredSites.contains(site) {
                let point = ids[site]!
                calls.append(("get_measurements", ["test_point": point.description], try Self.measurementsResult(point, store: store)))
            }
            if !calls.isEmpty {
                turn(calls)
            }
        }

        let context = "\(names.tag) shows \(Self.cite(hmi, "%", .display)) against a \(Self.cite(point.setpoint, "%", .recorded)) setpoint. "
            + "The healthy twin expects \(Self.cite(twin["terminalVoltage"]!, "V", .modeled)) and \(Self.cite(twin["loopCurrent"]!, "mA", .modeled)) at \(names.terminal)."
        let answer: String
        if askForCause {
            let readings = expertPath.map { step -> String in
                let quantity = LoopTest.allCases.first { $0.title == step.test }?.quantity ?? step.test
                return "\(quantity) = \(Self.cite(step.value, step.unit, step.truth))"
            }
            answer = "\(context) The technician measured \(readings.joined(separator: ", ")). \(conclusion) "
                + "This is my interpretation; a technician must confirm it before it is recorded as the cause."
        } else {
            answer = "\(context) Nothing has been measured in the field yet, so no candidate cause is ruled out. \(nextTestSentence)"
        }
        messages.append(MessageExample(role: "assistant", content: answer, toolCalls: nil, toolCallID: nil))

        return TrainingExample(
            id: id, kind: .toolTranscript, split: split, seed: seed, prompt: goal,
            observations: observations.filter { $0.name == "setpoint" } + shown, tests: testExamples, hypotheses: hypothesisExamples, scenario: scenarioExample,
            messages: messages, ladder: nil,
            answer: AnswerKey(
                cause: kind.rawValue, nextTest: askForCause ? nil : nextTest, text: answer, ranking: askForCause ? nil : ranking,
                expertPath: askForCause ? expertPath : nil, firstDivergence: nil, trail: nil, blockers: nil
            )
        )
    }

    // The three renderers below mirror `SearchObjects`, `RelatedObjects` and
    // `GetMeasurements` in NexusAgents line for line (a test holds them to it).

    static func searchResult(_ query: String, store: NexusStore, graph: ObjectGraph) throws -> String {
        let engine = SearchEngine(store: store, graph: graph)
        let results = try engine.search(SearchQuery(query, scope: nil, limit: 10))
        let lines = results.map { "\($0.id) [\($0.type)] \($0.title)" }
        return lines.isEmpty ? "No matches." : lines.joined(separator: "\n")
    }

    static func relatedResult(_ id: ObjectID, store: NexusStore, graph: ObjectGraph) throws -> String {
        let edges = try graph.edges(of: id)
        let neighbors = try store.objects(edges.map(\.neighbor))
        let titles = Dictionary(uniqueKeysWithValues: neighbors.map { ($0.id, $0.title) })
        let lines = edges.map { edge in
            let arrow = edge.direction == .outgoing ? "→" : "←"
            return "\(arrow) \(edge.relationship.kind) \(edge.neighbor) \(titles[edge.neighbor] ?? "?")"
        }
        return lines.isEmpty ? "No relationships." : lines.joined(separator: "\n")
    }

    static func measurementsResult(_ point: ObjectID, store: NexusStore) throws -> String {
        let readings = try store.measurements(at: point)
        let lines = readings.map { "\($0.id) \($0.quantityName) = \($0.value.value) \($0.value.unit) (\($0.truth.rawValue)\($0.loading.map { ", " + $0 } ?? ""))" }
        return lines.isEmpty ? "No readings." : lines.joined(separator: "\n")
    }
}
