import Foundation
import NexusAI
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing
@testable import NexusAgents

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

/// Records every approval prompt and answers from a fixed list.
private final class ScriptedApprover: ApprovalHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var asked: [PermissionRequest] = []

    init(_ answers: [Bool] = []) { self.answers = answers }

    func approve(_ request: PermissionRequest, reason: String) async -> Bool {
        lock.withLock {
            asked.append(request)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }
}

private func call(_ name: String, _ arguments: [String: Value] = [:]) -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, arguments: arguments)
}

private func toolTurn(_ calls: ToolCall...) -> ModelResponse {
    ModelResponse(message: ChatMessage(role: .assistant, toolCalls: calls), stopReason: .toolUse, usage: Usage(inputTokens: 100, outputTokens: 20))
}

private func finalTurn(_ text: String) -> ModelResponse {
    ModelResponse(message: ChatMessage(role: .assistant, text: text), stopReason: .endTurn, usage: Usage(inputTokens: 150, outputTokens: 40))
}

private struct Bench {
    let clock = ManualClock(t0)
    let store: NexusStore
    let permissions = PermissionEngine()
    var extraTools: [any AgentTool] = []
    let project: ObjectID
    let terminal: ObjectID
    let transmitter: ObjectID
    let investigation: ObjectID
    let reading: ObjectID

    init() throws {
        store = try NexusStore(.inMemory, clock: clock)
        let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)
        project = try store.create(ObjectRecord(type: .project, title: "Level loop", provenance: recorded)).id
        transmitter = try store.create(ObjectRecord(
            type: .sensor, title: "LT-101 level transmitter", attributes: ["tag": Attribute(.string("LT-101"))], provenance: recorded
        )).id
        terminal = try store.create(ObjectRecord(type: .testPoint, title: "TB-4", provenance: recorded)).id
        try store.relate(Relationship(kind: .contains, from: project, to: transmitter, provenance: recorded))
        try store.relate(Relationship(kind: .connectedTo, from: transmitter, to: terminal, provenance: recorded))
        let measurement = MeasurementRecord(
            quantityName: "terminalVoltage", value: Quantity(12, "V"), testPoint: terminal, loading: "high level", sampledAt: t0,
            provenance: Provenance(origin: .instrument(id: terminal), truth: .observed, timestamp: t0)
        )
        try store.add(measurement)
        reading = measurement.id
        investigation = try InvestigationRuntime(store: store, clock: clock)
            .open(symptom: "Reading clamps at 86.9 %", subjects: [transmitter], by: tech).id
    }

    func runtime(_ model: any LanguageModelProvider) -> AgentRuntime {
        AgentRuntime(
            store: store, router: ModelRouter(providers: [model]), permissions: permissions,
            tools: WorldTools.all + extraTools, clock: clock
        )
    }

    func steps(of run: ObjectID) throws -> [String] {
        try store.events(about: run).filter { $0.kind == .agentAction }.compactMap {
            if case .string(let phase)? = $0.payload["phase"] { phase } else { nil }
        }
    }
}

private let diagnostician = AgentProfile(
    id: "diagnostic", instructions: "You diagnose instrument loops.",
    tools: ["search_objects", "get_object", "related_objects", "get_measurements", "propose_hypothesis", "annotate_object", "send_message"]
)

@Suite struct AgentRuntimeTests {
    @Test func diagnosticRunIsFullyRecorded() async throws {
        let bench = try Bench()
        let model = ScriptedModel(script: [
            toolTurn(call("search_objects", ["query": .string("LT-101")]), call("get_measurements", ["test_point": .reference(bench.terminal)])),
            toolTurn(call("propose_hypothesis", [
                "investigation": .reference(bench.investigation), "statement": .string("Loop resistance too high"),
                "test_point": .reference(bench.terminal), "quantity": .string("terminalVoltage"), "unit": .string("V"),
                "low": .double(10.5), "high": .double(12.5),
            ])),
            finalTurn("Terminal voltage is 12.0 V (observed), at lift-off. Proposed excess loop resistance."),
        ])
        let approver = ScriptedApprover()
        let result = try await bench.runtime(model).run(
            AgentRequest(goal: "Why does LT-101 clamp?", project: bench.project, focus: [bench.transmitter]), as: diagnostician, approver: approver
        )

        #expect(result.status == .completed)
        #expect(approver.asked.isEmpty, "P0 and P2 tools need no approval")
        #expect(result.usage == Usage(inputTokens: 350, outputTokens: 80))
        #expect(try bench.steps(of: result.run) == ["goal", "context", "plan", "tool", "tool", "plan", "tool", "plan", "verification", "output"])

        // Tool results were fed back, all results for a turn in one message.
        let second = try #require(model.requests.dropFirst().first)
        let toolMessage = try #require(second.messages.last)
        #expect(toolMessage.role == .tool && toolMessage.toolResults.count == 2)
        #expect(toolMessage.toolResults[0].content.contains(bench.transmitter.description))
        #expect(toolMessage.toolResults[1].content.contains("12.0 V (observed, high level)"))
        #expect(model.requests.first?.messages.first?.text.contains("LT-101 level transmitter") == true)

        // The hypothesis is an attributable interpretation, linked from the run.
        let hypothesis = try #require(result.produced.first)
        let record = try #require(try bench.store.object(hypothesis))
        #expect(record.provenance.origin == .agent(id: "diagnostic", run: result.run))
        #expect(record.provenance.truth == .agentInterpretation)
        #expect(try bench.store.relationships(from: result.run, kind: .produced).map(\.to) == [hypothesis])
        #expect(try bench.store.relationships(from: bench.project, kind: .contains).contains { $0.to == result.run })

        let run = try #require(try bench.store.object(result.run))
        #expect(run.attributes["status"]?.value == .string("completed"))
        #expect(run.truth(of: "output") == .agentInterpretation)
        #expect(run.attributes["output"]?.provenance?.dependencies == [hypothesis])
        guard case .map(let modelInfo)? = run.attributes["model"]?.value else { Issue.record("No model info"); return }
        #expect(modelInfo["promptHash"] != .null)
    }

    @Test func internalChangesAskOncePerProjectAndDeclinesChangeNothing() async throws {
        let bench = try Bench()
        let annotate = call("annotate_object", ["id": .reference(bench.transmitter), "key": .string("note"), "value": .string("check TB-4")])
        let model = ScriptedModel(script: [toolTurn(annotate), toolTurn(annotate), toolTurn(annotate), finalTurn("done")])
        let approver = ScriptedApprover([false, true])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Annotate", project: bench.project), as: diagnostician, approver: approver)

        #expect(approver.asked.count == 2, "Declined once, approved once, then remembered for the project")
        let results = model.requests.dropFirst().map { $0.messages.last!.toolResults[0] }
        #expect(results.map(\.isError) == [true, false, false])
        #expect(try bench.store.revisions(of: bench.transmitter).count == 3)
        #expect(try bench.store.object(bench.transmitter)?.truth(of: "note") == .agentInterpretation)
        #expect(try bench.steps(of: result.run).filter { $0 == "approval" }.count == 2)
    }

    @Test func externalActionsAskEveryTimeAndPolicyCanForbid() async throws {
        let bench = try Bench()
        let send = call("send_message", ["to": .string("supervisor"), "text": .string("TB-4 needs work")])
        let approver = ScriptedApprover([true, true])
        let model = ScriptedModel(script: [toolTurn(send), toolTurn(send), finalTurn("sent")])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Notify", project: bench.project), as: diagnostician, approver: approver)
        #expect(approver.asked.count == 2)
        #expect(try bench.store.events(about: result.run).filter { $0.kind == .message }.count == 2)

        bench.permissions.add(PolicyRule(action: "send_message", grant: .never))
        let blocked = ScriptedApprover([true])
        let second = ScriptedModel(script: [toolTurn(send), finalTurn("could not send")])
        let run = try await bench.runtime(second).run(AgentRequest(goal: "Notify", project: bench.project), as: diagnostician, approver: blocked)
        #expect(blocked.asked.isEmpty)
        #expect(try bench.store.events(about: run.run).filter { $0.kind == .message }.isEmpty)
        #expect(try bench.steps(of: run.run).contains("permission"))
    }

    @Test func agentsCannotOverwriteRecordedTruth() async throws {
        let bench = try Bench()
        bench.permissions.add(PolicyRule(agent: "diagnostic", level: .modifyInternalState, grant: .always))
        let overwrite = call("annotate_object", ["id": .reference(bench.transmitter), "key": .string("tag"), "value": .string("LT-999")])
        let model = ScriptedModel(script: [toolTurn(overwrite), finalTurn("tried")])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Retag"), as: diagnostician, approver: ScriptedApprover())
        let toolResult = try #require(model.requests.last?.messages.last?.toolResults.first)
        #expect(toolResult.isError && toolResult.content.contains("truthConflict"))
        #expect(try bench.store.object(bench.transmitter)?.attributes["tag"]?.value == .string("LT-101"))
        #expect(result.status == .completed)
        #expect(try bench.steps(of: result.run).contains("error"))
    }

    @Test func failingToolsLeaveNoPartialWrites() async throws {
        var bench = try Bench()
        bench.extraTools = [HalfFinishedTool()]
        let profile = AgentProfile(id: "diagnostic", instructions: "", tools: ["half_finished", "get_object"])
        let model = ScriptedModel(script: [toolTurn(call("half_finished"), call("nonexistent"), call("send_message")), finalTurn("oops")])
        _ = try await bench.runtime(model).run(AgentRequest(goal: "Try"), as: profile, approver: ScriptedApprover())
        #expect(try bench.store.search("half written").isEmpty)
        let results = try #require(model.requests.last?.messages.last?.toolResults)
        #expect(results.map(\.isError) == [true, true, true])
        #expect(results[1].content.contains("not available") && results[2].content.contains("not available"))
    }

    @Test func verificationFailsRunsThatForgeFacts() async throws {
        var bench = try Bench()
        bench.extraTools = [ForgingTool()]
        let profile = AgentProfile(id: "diagnostic", instructions: "", tools: ["forge"])
        let model = ScriptedModel(script: [toolTurn(call("forge")), finalTurn("done")])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Forge"), as: profile, approver: ScriptedApprover())
        #expect(result.status == .failed)
    }

    @Test func refusalsStepLimitsAndTruncationStopCleanly() async throws {
        let bench = try Bench()
        let refusal = ScriptedModel(script: [ModelResponse(message: ChatMessage(role: .assistant), stopReason: .refusal)])
        #expect(try await bench.runtime(refusal).run(AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover()).status == .refused)

        let looping = ScriptedModel(responder: { _ in toolTurn(call("search_objects", ["query": .string("LT")])) })
        var limited = diagnostician
        limited.maxSteps = 3
        let stopped = try await bench.runtime(looping).run(AgentRequest(goal: "x"), as: limited, approver: ScriptedApprover())
        #expect(stopped.status == .stopped)
        #expect(looping.requests.count == 3)

        let truncated = ScriptedModel(script: [ModelResponse(message: ChatMessage(role: .assistant, text: "partial"), stopReason: .maxTokens)])
        let cut = try await bench.runtime(truncated).run(AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover())
        #expect(cut.status == .stopped && cut.output == "partial")
    }

    @Test func thirdPartyModelsNeedApprovalBeforeAnyDataLeaves() async throws {
        let bench = try Bench()
        let cloud = ScriptedModel(
            descriptor: ModelDescriptor(ref: ModelRef(provider: "anthropic", modelID: "claude-opus-5"), tier: .thirdPartyCloud, contextTokens: 1_000_000),
            script: [finalTurn("answer")]
        )
        let request = AgentRequest(goal: "Summarize", privacy: .thirdPartyAllowed)
        let declined = try await bench.runtime(cloud).run(request, as: diagnostician, approver: ScriptedApprover([false]))
        #expect(declined.status == .stopped)
        #expect(cloud.requests.isEmpty, "Nothing was sent")

        let approved = try await bench.runtime(cloud).run(request, as: diagnostician, approver: ScriptedApprover([true]))
        #expect(approved.status == .completed && approved.model.provider == "anthropic")

        // On-device-only tasks never reach it.
        await #expect(throws: AIError.noEligibleModel) {
            try await bench.runtime(cloud).run(AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover())
        }
    }
}

/// Writes an object, then fails.
private struct HalfFinishedTool: AgentTool {
    let spec = ToolSpec(name: "half_finished", description: "", permission: .createDraft)

    func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        try context.store.create(ObjectRecord(type: .task, title: "half written", provenance: context.provenance()))
        throw ToolError.invalidArgument("boom")
    }
}

/// Claims an observation it never made.
private struct ForgingTool: AgentTool {
    let spec = ToolSpec(name: "forge", description: "", permission: .createDraft)

    func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let record = try context.store.create(ObjectRecord(
            type: .task, title: "forged", provenance: Provenance(origin: context.origin, truth: .observed, timestamp: context.clock.now())
        ))
        return ToolOutcome(content: "ok", produced: [record.id])
    }
}
