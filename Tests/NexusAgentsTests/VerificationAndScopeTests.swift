import Foundation
import NexusAI
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing

@testable import NexusAgents

@Suite struct PermissionScopeTests {
    @Test func toolCallsCarryObjectTypesDataSourceAndService() async throws {
        let bench = try Bench()
        let approver = ScriptedApprover([true, true])
        let model = ScriptedModel(script: [
            toolTurn(
                call("get_object", ["id": .reference(bench.transmitter)]),
                call("annotate_object", ["id": .reference(bench.transmitter), "key": .string("note"), "value": .string("check")]),
                call("send_message", ["to": .string("supervisor"), "text": .string("TB-4"), "channel": .string("Email")])
            ),
            finalTurn("done"),
        ])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "x", project: bench.project), as: diagnostician, approver: approver)
        #expect(approver.asked.map(\.action) == ["annotate_object", "send_message"])
        #expect(approver.asked[0].objectTypes == [.sensor])
        #expect(approver.asked[1].service == "email")
        let approvals = try bench.store.events(about: result.run).filter { $0.payload["phase"] == .string("approval") }
        #expect(approvals.map { $0.payload["objectTypes"] } == [.list([.string("sensor")]), nil])
        #expect(approvals.last?.payload["service"] == .string("email"))
    }

    @Test func anObjectTypeNeverRuleBlocksTheCall() async throws {
        let bench = try Bench()
        bench.permissions.add(PolicyRule(objectType: .investigation, grant: .never))
        let model = ScriptedModel(script: [
            toolTurn(call("get_object", ["id": .reference(bench.investigation)]), call("get_object", ["id": .reference(bench.transmitter)])),
            toolTurn(call("propose_hypothesis", ["investigation": .reference(bench.investigation), "statement": .string("Open loop")])),
            finalTurn("done"),
        ])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover())
        let first = try #require(model.requests[1].messages.last?.toolResults)
        #expect(first.map(\.isError) == [true, false])
        #expect(first[0].content == "Permission denied for get_object.")
        let second = try #require(model.requests[2].messages.last?.toolResults.first)
        #expect(second.isError, "propose_hypothesis declares the investigation type")
        #expect(result.produced.isEmpty)
        #expect(try bench.steps(of: result.run).filter { $0 == "permission" }.count == 2)
    }

    @Test func serviceRulesTellChannelsApartAndApprovalsAreScoped() async throws {
        let bench = try Bench()
        bench.permissions.add(PolicyRule(service: "sms", grant: .never))
        let sms = call("send_message", ["to": .string("a"), "text": .string("b"), "channel": .string("sms")])
        let email = call("send_message", ["to": .string("a"), "text": .string("b"), "channel": .string("email")])
        let model = ScriptedModel(script: [toolTurn(sms, email), finalTurn("done")])
        let approver = ScriptedApprover([true])
        _ = try await bench.runtime(model).run(AgentRequest(goal: "x"), as: diagnostician, approver: approver)
        let results = try #require(model.requests.last?.messages.last?.toolResults)
        #expect(results.map(\.isError) == [true, false])
        #expect(approver.asked.count == 1 && approver.asked[0].service == "email")

        // Approving an annotation on a sensor does not approve one on a test point.
        let annotate = { (id: ObjectID) in call("annotate_object", ["id": .reference(id), "key": .string("n"), "value": .string("v")]) }
        let second = ScriptedModel(script: [
            toolTurn(annotate(bench.transmitter)), toolTurn(annotate(bench.transmitter)), toolTurn(annotate(bench.terminal)), finalTurn("done"),
        ])
        let asked = ScriptedApprover([true, true])
        _ = try await bench.runtime(second).run(AgentRequest(goal: "x", project: bench.project), as: diagnostician, approver: asked)
        #expect(asked.asked.map(\.objectTypes) == [[.sensor], [.testPoint]])
    }

    @Test func badChannelsAreRejected() async throws {
        let bench = try Bench()
        let model = ScriptedModel(script: [
            toolTurn(call("send_message", ["to": .string("a"), "text": .string("b"), "channel": .string("e mail!")])), finalTurn("done"),
        ])
        let approver = ScriptedApprover([true])
        _ = try await bench.runtime(model).run(AgentRequest(goal: "x"), as: diagnostician, approver: approver)
        #expect(approver.asked.isEmpty, "Scope could not be resolved, so nothing was asked or sent")
        #expect(model.requests.last?.messages.last?.toolResults.first?.isError == true)
    }
}

@Suite struct GroundingTests {
    private func run(_ answer: String) async throws -> (Bench, AgentRunResult) {
        let bench = try Bench()
        let model = ScriptedModel(script: [
            toolTurn(call("get_measurements", ["test_point": .reference(bench.terminal)])), finalTurn(answer),
        ])
        let result = try await bench.runtime(model).run(
            AgentRequest(goal: "Why does LT-101 clamp at 86.9 %?"), as: diagnostician, approver: ScriptedApprover()
        )
        return (bench, result)
    }

    @Test func groundedAnswersComplete() async throws {
        let (_, result) = try await run("TB-4 reads 12 V (observed); the display clamps at 86.9 %.")
        #expect(result.status == .completed)
        #expect(result.grounding?.grounded == ["12 V", "86.9 %"])
    }

    @Test func inventedValuesMakeTheRunUnverifiedNotFailed() async throws {
        let (bench, result) = try await run("TB-4 reads 12.0 V, so loop current must be 14.2 mA.")
        #expect(result.status == .unverified)
        #expect(result.output.contains("14.2 mA"), "The answer is kept")
        #expect(result.grounding?.ungrounded == ["14.2 mA"])
        let verification = try #require(try bench.store.events(about: result.run).first { $0.payload["phase"] == .string("verification") })
        guard case .map(let grounding)? = verification.payload["grounding"] else { Issue.record("No grounding payload"); return }
        #expect(grounding["passed"] == .bool(false))
        #expect(grounding["ungrounded"] == .list([.string("14.2 mA")]))
        #expect(verification.summary.contains("ungrounded: 14.2 mA"))
        #expect(try bench.store.object(result.run)?.attributes["status"]?.value == .string("unverified"))
    }

    @Test func labeledEstimatesPass() async throws {
        let (_, result) = try await run("Reads 12 V. Loop current is an estimated 14.2 mA; the modeled drop is 1.5 V.")
        #expect(result.status == .completed)
        #expect(result.grounding?.labeled == ["14.2 mA", "1.5 V"])
    }

    @Test func checkRules() {
        let check = GroundingCheck()
        let sources = ["terminalVoltage = 12.03 V (observed)", "LT-101 range 0-100 %"]
        #expect(check.check("It reads 12 V.", against: sources).passed, "Within 1 %")
        #expect(!check.check("It reads 12.5 V.", against: sources).passed)
        #expect(check.check("LT-101 and TB-4 are wired; 3 checks remain.", against: []).checked == 0, "Tags and counts are not quantities")
        // A label in another sentence does not count.
        let report = check.check("This is estimated. It reads 13 V.", against: sources)
        #expect(report.ungrounded == ["13 V"])
        #expect(check.check("Simulated: 13 V at the output.", against: sources).labeled == ["13 V"])
        #expect(check.check("The level is 100 %.", against: sources).grounded == ["100 %"])
    }
}

@Suite struct UsageMetricsTests {
    @Test func latencyAndCostAreRecordedPerCall() async throws {
        let bench = try Bench()
        let clock = bench.clock
        let priced = ModelDescriptor(
            ref: ModelRef(provider: "test", modelID: "priced"), tier: .onDevice, contextTokens: 100_000,
            price: ModelPrice(inputPerMillionTokens: 5, outputPerMillionTokens: 25)
        )
        let turns = LockedBox([toolTurn(call("search_objects", ["query": .string("LT-101")])), finalTurn("Found it.")])
        let model = ScriptedModel(descriptor: priced) { _ in
            clock.advance(by: 0.25)
            return turns.withLock { $0.removeFirst() }
        }
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Find LT-101"), as: diagnostician, approver: ScriptedApprover())
        #expect(result.calls.map(\.latencyMs) == [250, 250])
        #expect(result.latencyMs == 500)
        // 250 input + 60 output tokens at $5 / $25 per million.
        #expect(abs((result.cost ?? 0) - 0.00275) < 1e-12)

        let run = try #require(try bench.store.object(result.run))
        guard case .map(let usage)? = run.attributes["usage"]?.value else { Issue.record("No usage"); return }
        #expect(usage["latencyMs"] == .int(500))
        #expect(usage["currency"] == .string("USD"))
        guard case .list(let calls)? = usage["calls"], case .map(let first)? = calls.first else { Issue.record("No calls"); return }
        #expect(calls.count == 2)
        #expect(first["latencyMs"] == .int(250) && first["inputTokens"] == .int(100))
        #expect(first["cost"] != nil)
    }

    @Test func unpricedModelsRecordLatencyOnly() async throws {
        let bench = try Bench()
        let result = try await bench.runtime(ScriptedModel(script: [finalTurn("ok")])).run(
            AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover()
        )
        #expect(result.cost == nil && result.calls.count == 1 && result.latencyMs == 0)
        let run = try #require(try bench.store.object(result.run))
        guard case .map(let usage)? = run.attributes["usage"]?.value else { Issue.record("No usage"); return }
        #expect(usage["cost"] == nil && usage["latencyMs"] == .int(0))
    }
}

/// A tiny lock-protected box for test closures.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

@Suite struct HypothesisDraftTests {
    private func draftJSON(_ bench: Bench, testPoint: String? = nil, low: Double = 10.5, high: Double = 12.5) -> JSONValue {
        .object([
            "statement": .string("Loop resistance too high"),
            "predictions": .array([
                .object([
                    "testPoint": .string(testPoint ?? bench.terminal.description), "quantity": .string("terminalVoltage"),
                    "low": .double(low), "high": .double(high), "unit": .string("V"),
                ])
            ]),
            "prior": .int(2),
            "safetyNotes": .array([.string("Loop is energized")]),
        ])
    }

    @Test func validDraftsAreProposedThroughTheInvestigation() throws {
        let bench = try Bench()
        let draft = try HypothesisDraft(json: draftJSON(bench))
        #expect(draft.prior == 2 && draft.predictions.first?.low == 10.5)
        #expect(JSONSchema.conforms(draft.json, to: HypothesisDraft.schema))
        let runtime = InvestigationRuntime(store: bench.store, clock: bench.clock)
        let agent = Origin.agent(id: "diagnostic", run: nil)
        let hypothesis = try draft.propose(in: bench.investigation, using: runtime, dependsOn: [bench.reading], by: agent)
        #expect(hypothesis.statement == "Loop resistance too high")
        #expect(hypothesis.predictions == [Prediction(testPoint: bench.terminal, quantity: "terminalVoltage", unit: "V", low: 10.5, high: 12.5)])
        #expect(hypothesis.safetyNotes == ["Loop is energized"])
        #expect(hypothesis.record.provenance.truth == .agentInterpretation)
        #expect(try runtime.hypotheses(of: bench.investigation).map(\.id) == [hypothesis.id])
    }

    @Test func invalidDraftsAreRejected() throws {
        let bench = try Bench()
        #expect(throws: HypothesisDraftError.invalidInterval(0)) { try HypothesisDraft(json: draftJSON(bench, low: 13, high: 12)) }
        let schemaError = #expect(throws: HypothesisDraftError.self) { try HypothesisDraft(json: .object(["statement": .string("x")])) }
        if case .schema(let problems)? = schemaError { #expect(problems.contains("$.predictions: required")) } else { Issue.record("Expected schema error") }
        #expect(throws: HypothesisDraftError.invalidPrior(0)) {
            var json = draftJSON(bench).objectValue!
            json["prior"] = .int(0)
            return try HypothesisDraft(json: .object(json))
        }

        let runtime = InvestigationRuntime(store: bench.store, clock: bench.clock)
        let unknown = try HypothesisDraft(json: draftJSON(bench, testPoint: "not-an-id"))
        #expect(throws: HypothesisDraftError.unknownTestPoint("not-an-id")) { try unknown.propose(in: bench.investigation, using: runtime, by: tech) }
        let sensor = try HypothesisDraft(json: draftJSON(bench, testPoint: bench.transmitter.description))
        #expect(throws: HypothesisDraftError.notATestPoint(bench.transmitter.description)) {
            try sensor.propose(in: bench.investigation, using: runtime, by: tech)
        }
        #expect(try runtime.hypotheses(of: bench.investigation).isEmpty)
    }

    @Test func modelsGenerateDraftsWithStructuredOutput() async throws {
        let bench = try Bench()
        let json = draftJSON(bench)
        let model = ScriptedModel(script: [
            ModelResponse(message: ChatMessage(role: .assistant, text: json.serialized), stopReason: .endTurn),
            ModelResponse(message: ChatMessage(role: .assistant, text: "I think it is the loop."), stopReason: .endTurn),
        ])
        let draft = try await HypothesisDraft.generate(context: "Symptom: clamps. Test point TB-4 = \(bench.terminal)", model: model)
        #expect(draft.statement == "Loop resistance too high")
        #expect(model.requests.first?.responseSchema == HypothesisDraft.schema)
        await #expect(throws: HypothesisDraftError.noStructuredOutput) { try await HypothesisDraft.generate(context: "x", model: model) }
    }
}
