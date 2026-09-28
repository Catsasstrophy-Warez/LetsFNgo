import Foundation
import NexusAgents
import NexusAI
import NexusCore
import NexusGraph
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusSimulation
import Testing
@testable import NexusTrainingData

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private struct NeverApprove: ApprovalHandler {
    func approve(_ request: PermissionRequest, reason: String) async -> Bool { false }
}

@Suite struct DatasetGeneratorTests {
    @Test func splitsDrawFromDisjointSeedRanges() {
        for runSeed: UInt64 in [0, 1, 42, 1 << 30, UInt64.max] {
            for index in [0, 1, 999, DatasetSplit.maximumCount - 1] {
                let train = DatasetSplit.train.scenarioSeed(runSeed: runSeed, index: index)
                let eval = DatasetSplit.eval.scenarioSeed(runSeed: runSeed, index: index)
                #expect(DatasetSplit.containing(train) == .train)
                #expect(DatasetSplit.containing(eval) == .eval)
            }
        }
        // Consecutive run seeds address non-overlapping blocks within a split.
        let first = Set((0..<1_000).map { DatasetSplit.train.scenarioSeed(runSeed: 42, index: $0) })
        let second = Set((0..<1_000).map { DatasetSplit.train.scenarioSeed(runSeed: 43, index: $0) })
        #expect(first.isDisjoint(with: second) && first.count == 1_000)
    }

    @Test func generationIsDeterministicAndRotatesKinds() throws {
        func lines(_ seed: UInt64) throws -> [String] {
            var lines: [String] = []
            try DatasetGenerator().generate(count: 8, seed: seed, split: .eval) { lines.append(try DatasetGenerator.jsonLine($0)) }
            return lines
        }
        let first = try lines(7)
        #expect(first == (try lines(7)))
        #expect(first != (try lines(8)))
        let decoded = try first.map { try JSONDecoder().decode(TrainingExample.self, from: Data($0.utf8)) }
        #expect(decoded.map(\.kind) == [.diagnosis, .diagnosis, .toolTranscript, .ladderWhy, .diagnosis, .diagnosis, .toolTranscript, .ladderWhy])
        #expect(decoded.allSatisfy { $0.split == .eval && DatasetSplit.containing($0.seed) == .eval })
        #expect(Set(decoded.map(\.id)).count == decoded.count)
    }

    @Test func diagnosisCasesAreSolvableAndConsistent() throws {
        let factory = LoopScenarioFactory()
        var resolved = 0
        let seeds: [UInt64] = Array(100..<116)
        for seed in seeds {
            let worked = try factory.makeCase(seed: seed)
            // The true cause is never contradicted by the field's own readings.
            #expect(worked.survivors.contains(worked.kind), "seed \(seed): \(worked.kind) rejected")
            for (test, range) in worked.predictions[worked.kind]! {
                #expect(range.contains(worked.readings[test]!), "seed \(seed): \(test) outside \(worked.kind)'s prediction")
            }
            if worked.survivors == [worked.kind] {
                resolved += 1
            }
            // The answer key's next test is TestSelector's first choice, never the hazardous one.
            #expect(worked.nextTest == worked.ranking.first?.title)
            #expect(!worked.ranking.contains { $0.title == LoopTest.busVoltage.title })
            #expect(worked.ranking.first!.informationGain > 0)
            #expect(worked.divergence != nil)
            // Every scenario shows the operator something.
            #expect(worked.symptom.contains(worked.names.tag))
        }
        #expect(resolved >= seeds.count * 9 / 10, "Expert paths should usually single out the cause (\(resolved)/\(seeds.count))")
    }

    @Test func firstDivergenceIsWhereTheFaultEntersTheSignalPath() throws {
        let factory = LoopScenarioFactory()
        let expected: [(LoopFaultKind, String)] = [
            (.contactResistance, "terminalVoltage"), (.supplySag, "terminalVoltage"), (.openWire, "terminalVoltage"),
            (.cardReadsLow, "readCurrent"), (.cardChannelStuck, "readCurrent"), (.wrongScaling, "measuredLevel"),
        ]
        for (kind, quantity) in expected {
            let worked = try factory.makeCase(seed: 7, forcing: kind)
            #expect(worked.divergence?.quantity == quantity, "\(kind)")
            #expect(worked.divergence?.tick == 0, "\(kind) departs from the twin immediately")
        }
    }

    @Test func referenceAnswersAreGroundedAndLabeled() throws {
        let generator = DatasetGenerator()
        let examples = try (0..<12).map { try generator.example(split: .train, runSeed: 3, index: $0) }
        let evaluator = Evaluator()
        for example in examples {
            let check = evaluator.checkAnswer(example.answer.text, against: example)
            #expect(check.ungrounded == 0, "\(example.id): \(example.answer.text)")
            #expect(check.labeled == check.cited, "\(example.id): \(example.answer.text)")
        }
        let perfect = examples.map {
            ModelPrediction(id: $0.id, predictedCause: $0.answer.cause, predictedNextTest: $0.answer.nextTest, answer: $0.answer.text)
        }
        let report = evaluator.evaluate(examples: examples, predictions: perfect)
        #expect(report.rootCauseAccuracy == 1 && report.nextTestAgreement == 1)
        #expect(report.hallucinatedValueRate == 0 && report.truthClassDiscipline == 1)
        #expect(report.citedValues > 0)
    }

    @Test func transcriptsCallRealToolsWithValidArguments() throws {
        let generator = DatasetGenerator()
        let transcripts = try [2, 6, 10, 14].map { try generator.example(split: .train, runSeed: 11, index: $0) }
        let tools = Evaluator.toolRequirements
        for example in transcripts {
            #expect(example.kind == .toolTranscript)
            let messages = try #require(example.messages)
            #expect(messages.first?.role == "system" && messages[1].role == "user")
            #expect(messages.last?.role == "assistant" && messages.last?.content == example.answer.text)
            let calls = messages.flatMap { $0.toolCalls ?? [] }
            #expect(calls.count >= 4)
            #expect(calls.allSatisfy { Evaluator.isValid($0, tools: tools) })
            let results = messages.filter { $0.role == "tool" }
            #expect(results.compactMap(\.toolCallID) == calls.map(\.id), "Every call gets exactly one result, in order")
            #expect(results.first?.content.contains("[sensor]") == true)
            #expect(results.contains { $0.content.contains("(display)") } && results.contains { $0.content.contains("(modeled)") })
        }
        // Both goals occur: the next test before measuring, and the cause after the readings.
        let askedForCause = transcripts.filter { $0.answer.nextTest == nil }
        #expect(!askedForCause.isEmpty && askedForCause.count < transcripts.count)
        for example in askedForCause {
            #expect(example.observations.contains { $0.truth == .observed || $0.source.hasPrefix("Read the AI") })
            #expect(example.answer.text.contains("must confirm"))
        }
    }

    @Test func renderedToolResultsMatchTheRealWorldTools() async throws {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let recorded = Provenance(origin: .user(id: "tech"), truth: .recorded, timestamp: t0)
        let transmitter = try store.create(ObjectRecord(
            type: .sensor, title: "LT-555 level transmitter", attributes: ["tag": Attribute(.string("LT-555"))], provenance: recorded
        )).id
        let terminal = try store.create(ObjectRecord(type: .testPoint, title: "TB-2 terminals 3/4", provenance: recorded)).id
        let tank = try store.create(ObjectRecord(type: .equipment, title: "Tank T-5", provenance: recorded)).id
        try store.relate(Relationship(kind: .contains, from: tank, to: transmitter, provenance: recorded))
        try store.relate(Relationship(kind: .connectedTo, from: transmitter, to: terminal, provenance: recorded))
        try store.add(MeasurementRecord(
            quantityName: "terminalVoltage", value: Quantity(12.03, "V"), testPoint: terminal, sampledAt: t0,
            provenance: Provenance(origin: .instrument(id: terminal), truth: .observed, timestamp: t0)
        ))
        try store.add(MeasurementRecord(
            quantityName: "loopCurrent", value: Quantity(17.9, "mA"), testPoint: terminal, sampledAt: t0,
            provenance: Provenance(origin: .simulation(run: tank), truth: .modeled, timestamp: t0)
        ))
        let graph = ObjectGraph(store: store, clock: clock)
        let rendered = [
            try DiagnosisCase.searchResult("LT-555", store: store, graph: graph),
            try DiagnosisCase.relatedResult(transmitter, store: store, graph: graph),
            try DiagnosisCase.measurementsResult(terminal, store: store),
        ]

        let model = ScriptedModel(script: [
            ModelResponse(
                message: ChatMessage(role: .assistant, toolCalls: [
                    ToolCall(id: "a", name: "search_objects", arguments: ["query": .string("LT-555")]),
                    ToolCall(id: "b", name: "related_objects", arguments: ["id": .reference(transmitter)]),
                    ToolCall(id: "c", name: "get_measurements", arguments: ["test_point": .reference(terminal)]),
                ]),
                stopReason: .toolUse
            ),
            ModelResponse(message: ChatMessage(role: .assistant, text: "Done."), stopReason: .endTurn),
        ])
        let runtime = AgentRuntime(
            store: store, router: ModelRouter(providers: [model]), permissions: PermissionEngine(), tools: WorldTools.all, clock: clock
        )
        let profile = AgentProfile(id: "reader", instructions: "Read.", tools: ["search_objects", "related_objects", "get_measurements"])
        let result = try await runtime.run(AgentRequest(goal: "Check the loop"), as: profile, approver: NeverApprove())
        #expect(result.status == .completed)
        let toolMessage = try #require(model.requests.dropFirst().first?.messages.last)
        #expect(toolMessage.toolResults.map(\.content) == rendered)
    }

    @Test func ladderQuestionsExplainTheBlockedOutput() throws {
        for seed: UInt64 in 0..<24 {
            let example = try LadderExamples.example(seed: seed, id: "ladder-\(seed)", split: .train)
            let ladder = try #require(example.ladder)
            let trail = try #require(example.answer.trail)
            #expect(example.prompt.hasPrefix("Why isn't \(ladder.target) on?"))
            #expect(trail.first?.kind == "symptom" && trail.last?.kind == "rootCondition", "seed \(seed)")
            // The root cause is an input whose recorded value fails its contact.
            let value = try #require(example.observations.first { $0.name == example.answer.cause }).value
            let examinedOn = ladder.rungs.contains { $0.text.contains("XIC(\(example.answer.cause))") }
            #expect((value == 1) != examinedOn, "seed \(seed)")
            #expect(example.answer.blockers?.isEmpty == false)
            #expect(example.answer.text.contains("Root condition: \(example.answer.cause)"))
        }
        let again = try LadderExamples.example(seed: 5, id: "x", split: .train)
        #expect(again == (try LadderExamples.example(seed: 5, id: "x", split: .train)))
    }
}
