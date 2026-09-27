import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing
@testable import NexusAgents

/// Streams each final answer as fixed text deltas.
private final class StreamingModel: LanguageModelProvider, @unchecked Sendable {
    let inner: ScriptedModel
    let deltas: [String]
    var descriptor: ModelDescriptor { inner.descriptor }

    init(_ inner: ScriptedModel, deltas: [String]) {
        self.inner = inner
        self.deltas = deltas
    }

    func respond(to request: GenerationRequest) async throws -> ModelResponse {
        try await inner.respond(to: request)
    }

    func stream(to request: GenerationRequest, toolHandler: @escaping ToolHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await inner.respond(to: request)
                    if response.stopReason == .endTurn { for delta in deltas { continuation.yield(.textDelta(delta)) } }
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Collects events from a `@Sendable` callback.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentEvent] = []
    var events: [AgentEvent] { lock.withLock { stored } }
    func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
}

/// Cancels a run's task from inside the run, the moment it is asked to approve.
private final class CancellingApprover: ApprovalHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<AgentRunResult, Error>?
    private(set) var asked = 0

    func attach(_ task: Task<AgentRunResult, Error>) { lock.withLock { self.task = task } }

    func approve(_ request: PermissionRequest, reason: String) async -> Bool {
        while lock.withLock({ task == nil }) { await Task.yield() }
        lock.withLock {
            asked += 1
            task?.cancel()
        }
        return true
    }
}

/// Returns a large blob, to overflow small context windows.
private struct DumpTool: AgentTool {
    let spec = ToolSpec(name: "dump", description: "Dumps a lot of text.", permission: .observe)

    func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        ToolOutcome(content: String(repeating: "0123456789", count: 2_000))
    }
}

@Suite struct StreamingAndCancellationTests {
    @Test func textDeltasAndStepsAreForwardedInOrder() async throws {
        let bench = try Bench()
        let scripted = ScriptedModel(script: [toolTurn(call("search_objects", ["query": .string("LT-101")])), finalTurn("LT-101 is fine.")])
        let model = StreamingModel(scripted, deltas: ["LT-", "101 is", " fine."])
        let log = EventLog()
        let result = try await bench.runtime(model).run(
            AgentRequest(goal: "Check LT-101"), as: diagnostician, approver: ScriptedApprover(), onEvent: log.append
        )

        #expect(result.status == .completed && result.output == "LT-101 is fine.")
        let deltas = log.events.compactMap { event -> String? in if case .textDelta(let text) = event { text } else { nil } }
        #expect(deltas == ["LT-", "101 is", " fine."])
        let phases = log.events.compactMap { event -> String? in if case .step(let phase, _) = event { phase.rawValue } else { nil } }
        #expect(phases == (try bench.steps(of: result.run)))
        // Text arrives before the plan step that records it.
        let firstDelta = try #require(log.events.firstIndex(of: .textDelta("LT-")))
        let lastPlan = try #require(log.events.lastIndex { if case .step(.plan, _) = $0 { true } else { false } })
        #expect(firstDelta < lastPlan)
    }

    @Test func cancelledBeforeStartingNothingReachesTheModel() async throws {
        let bench = try Bench()
        let model = ScriptedModel(script: [finalTurn("never")])
        let runtime = bench.runtime(model)
        let task = Task { () async throws -> AgentRunResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.run(AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover())
        }
        let result = try await task.value
        #expect(result.status == .cancelled)
        #expect(model.requests.isEmpty)
        #expect(try bench.steps(of: result.run) == ["goal", "context", "cancellation", "output"])
        #expect(try bench.store.object(result.run)?.attributes["status"]?.value == .string("cancelled"))
    }

    @Test(arguments: ToolPath.allCases)
    func cancellingMidRunSkipsRemainingToolsAndWritesNothingHalfDone(_ path: ToolPath) async throws {
        let bench = try Bench()
        let annotate = call("annotate_object", ["id": .reference(bench.transmitter), "key": .string("note"), "value": .string("check TB-4")])
        let second = call("annotate_object", ["id": .reference(bench.terminal), "key": .string("note"), "value": .string("loose")])
        let (model, scripted) = path.model([toolTurn(annotate, second), toolTurn(annotate), finalTurn("done")])
        let runtime = bench.runtime(model)
        let approver = CancellingApprover()
        let task = Task { try await runtime.run(AgentRequest(goal: "Annotate", project: bench.project), as: diagnostician, approver: approver) }
        approver.attach(task)
        let result = try await task.value

        #expect(result.status == .cancelled)
        #expect(approver.asked == 1)
        #expect(try bench.store.revisions(of: bench.transmitter).count == 1, "The approved call was skipped: cancellation came first")
        #expect(try bench.store.revisions(of: bench.terminal).count == 1)
        // Stopping a self-looping provider is best effort; whatever it still
        // asks for after cancellation is refused without touching the store.
        let later = scripted.requests.dropFirst().flatMap { $0.messages.filter { $0.role == .tool }.flatMap(\.toolResults) }
        #expect(later.allSatisfy { $0.isError && $0.content.hasPrefix("Cancelled") })
        if path == .toolUse { #expect(scripted.requests.count == 1) }
        let steps = try bench.steps(of: result.run)
        #expect(steps.contains("cancellation") && !steps.contains("tool") && steps.last == "output")
    }
}

@Suite struct ContextBudgetRuntimeTests {
    @Test func oversizedToolResultsAreTrimmedAndRecorded() async throws {
        var bench = try Bench()
        bench.extraTools = [DumpTool()]
        let profile = AgentProfile(id: "diagnostic", instructions: "", tools: ["dump"])
        let model = ScriptedModel(script: [toolTurn(call("dump")), toolTurn(call("dump")), finalTurn("done")])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Dump"), as: profile, approver: ScriptedApprover())

        #expect(result.status == .completed)
        let firstResult = try #require(model.requests[1].messages.last?.toolResults.first)
        #expect(firstResult.content == ContextBudget.marker(trimming: 20_000))
        #expect(model.requests[2].messages.filter { $0.role == .tool }.allSatisfy { $0.toolResults[0].content.hasPrefix("[Trimmed") })
        #expect(try bench.steps(of: result.run) == [
            "goal", "context", "plan", "tool", "context", "plan", "tool", "context", "plan", "verification", "output",
        ])
        let trims = try bench.store.events(about: result.run).filter { $0.payload["shortenedResults"] != nil }
        #expect(trims.count == 2 && trims.allSatisfy { $0.payload["shortenedResults"] == .int(1) }, "\(trims.map(\.payload))")
    }

    @Test func runsThatCannotFitStopCleanly() async throws {
        let bench = try Bench()
        let tiny = ScriptedModel(
            descriptor: ModelDescriptor(ref: ModelRef(provider: "test", modelID: "tiny"), tier: .onDevice, contextTokens: 4_000),
            script: [finalTurn("never")]
        )
        let result = try await bench.runtime(tiny).run(AgentRequest(goal: "x"), as: diagnostician, approver: ScriptedApprover())
        #expect(result.status == .stopped)
        #expect(tiny.requests.isEmpty)
        #expect(try bench.steps(of: result.run) == ["goal", "context", "error", "output"])
    }
}
