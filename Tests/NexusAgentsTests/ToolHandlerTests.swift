import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing
@testable import NexusAgents

/// A provider that runs its own tool loop, the way Apple's Foundation Models
/// session does: it executes every tool call through the handler it is
/// given and only ever returns a final response. The turns come from an
/// inner `ScriptedModel`, whose recorded requests show what the model saw.
final class SelfLoopingModel: LanguageModelProvider, @unchecked Sendable {
    let inner: ScriptedModel
    var descriptor: ModelDescriptor { inner.descriptor }

    init(_ inner: ScriptedModel) { self.inner = inner }

    func respond(to request: GenerationRequest) async throws -> ModelResponse {
        Issue.record("A self-looping provider must be given a tool handler")
        return try await inner.respond(to: request)
    }

    func respond(to request: GenerationRequest, toolHandler: @escaping ToolHandler) async throws -> ModelResponse {
        var messages = request.messages
        var usage = Usage()
        while true {
            try Task.checkCancellation()
            let turn = try await inner.respond(to: GenerationRequest(messages: messages, tools: request.tools, maxOutputTokens: request.maxOutputTokens))
            usage = usage + turn.usage
            guard turn.stopReason == .toolUse else { return ModelResponse(message: turn.message, stopReason: turn.stopReason, usage: usage) }
            var results: [ToolResult] = []
            for call in turn.message.toolCalls {
                results.append(await toolHandler(call))
            }
            messages += [turn.message, ChatMessage(role: .tool, toolResults: results)]
        }
    }
}

/// How tools reach the runtime.
enum ToolPath: String, CaseIterable, Sendable {
    /// The model returns `.toolUse`; the runtime executes the calls.
    case toolUse
    /// The provider executes the calls itself through the handler.
    case selfLooping

    func model(_ script: [ModelResponse]) -> (provider: any LanguageModelProvider, scripted: ScriptedModel) {
        let scripted = ScriptedModel(script: script)
        return (self == .toolUse ? scripted : SelfLoopingModel(scripted), scripted)
    }
}

extension Bench {
    /// Ledger phases other than `plan`: plan steps follow model turns, which a
    /// self-looping provider keeps to itself.
    func actions(of run: ObjectID) throws -> [String] {
        try steps(of: run).filter { $0 != "plan" }
    }
}

@Suite struct ToolHandlerTests {
    @Test(arguments: ToolPath.allCases)
    func toolsRunTheSamePathEitherWay(_ path: ToolPath) async throws {
        let bench = try Bench()
        let (model, scripted) = path.model([
            toolTurn(call("search_objects", ["query": .string("LT-101")]), call("get_measurements", ["test_point": .reference(bench.terminal)])),
            toolTurn(call("propose_hypothesis", [
                "investigation": .string(bench.investigation.description), "statement": .string("Loop resistance too high"),
                "test_point": .string(bench.terminal.description), "quantity": .string("terminalVoltage"), "unit": .string("V"),
                "low": .double(10.5), "high": .double(12.5),
            ])),
            finalTurn("Terminal voltage is 12.0 V (observed)."),
        ])
        let result = try await bench.runtime(model).run(
            AgentRequest(goal: "Why does LT-101 clamp?", project: bench.project, focus: [bench.transmitter]), as: diagnostician,
            approver: ScriptedApprover()
        )

        #expect(result.status == .completed)
        #expect(result.usage == Usage(inputTokens: 350, outputTokens: 80))
        #expect(try bench.actions(of: result.run) == ["goal", "context", "tool", "tool", "tool", "verification", "output"])
        #expect(try bench.steps(of: result.run).filter { $0 == "plan" }.count == (path == .toolUse ? 3 : 1))

        // The model saw the same tool results.
        let toolMessage = try #require(scripted.requests[1].messages.last)
        #expect(toolMessage.role == .tool && toolMessage.toolResults.count == 2)
        #expect(toolMessage.toolResults[1].content.contains("12.0 V (observed, high level)"))

        // The hypothesis was collected, verified and linked from the run.
        let hypothesis = try #require(result.produced.first)
        #expect(result.produced.count == 1)
        #expect(try bench.store.object(hypothesis)?.provenance.truth == .agentInterpretation)
        #expect(try bench.store.relationships(from: result.run, kind: .produced).map(\.to) == [hypothesis])
    }

    @Test(arguments: ToolPath.allCases)
    func permissionsAndApprovalsApplyEitherWay(_ path: ToolPath) async throws {
        let bench = try Bench()
        let annotate = call("annotate_object", ["id": .reference(bench.transmitter), "key": .string("note"), "value": .string("check TB-4")])
        let send = call("send_message", ["to": .string("supervisor"), "text": .string("TB-4")])
        bench.permissions.add(PolicyRule(action: "send_message", grant: .never))
        let (model, scripted) = path.model([toolTurn(annotate), toolTurn(annotate, send), toolTurn(annotate), finalTurn("done")])
        let approver = ScriptedApprover([false, true])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Annotate", project: bench.project), as: diagnostician, approver: approver)

        #expect(approver.asked.map(\.action) == ["annotate_object", "annotate_object"])
        let results = scripted.requests.dropFirst().map { $0.messages.last!.toolResults }
        #expect(results.map { $0.map(\.isError) } == [[true], [false, true], [false]])
        #expect(try bench.store.revisions(of: bench.transmitter).count == 3)
        #expect(try bench.store.events(about: result.run).filter { $0.kind == .message }.isEmpty)
        #expect(try bench.actions(of: result.run) == ["goal", "context", "approval", "approval", "tool", "permission", "tool", "verification", "output"])
    }

    @Test(arguments: ToolPath.allCases)
    func failuresRollBackAndVerificationBitesEitherWay(_ path: ToolPath) async throws {
        var bench = try Bench()
        bench.extraTools = [HalfFinishedTool(), ForgingTool()]
        let profile = AgentProfile(id: "diagnostic", instructions: "", tools: ["half_finished", "forge"])
        let (model, scripted) = path.model([toolTurn(call("half_finished"), call("nonexistent"), call("forge")), finalTurn("done")])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Try"), as: profile, approver: ScriptedApprover())

        #expect(try bench.store.search("half written").isEmpty, "The failed tool's write was rolled back")
        let results = try #require(scripted.requests.last?.messages.last?.toolResults)
        #expect(results.map(\.isError) == [true, true, false])
        #expect(results[1].content.contains("not available"))
        #expect(result.produced.count == 1)
        #expect(result.status == .failed, "The forged observation fails verification")
        #expect(try bench.actions(of: result.run) == ["goal", "context", "error", "error", "tool", "verification", "output"])
    }
}
