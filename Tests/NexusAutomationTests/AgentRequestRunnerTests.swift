import Foundation
import NexusAI
import NexusAgents
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing

@testable import NexusAutomation

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

private func call(_ name: String, _ arguments: [String: Value] = [:]) -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, arguments: arguments)
}

private func toolTurn(_ calls: ToolCall...) -> ModelResponse {
    ModelResponse(message: ChatMessage(role: .assistant, toolCalls: calls), stopReason: .toolUse, usage: Usage(inputTokens: 10, outputTokens: 5))
}

private func finalTurn(_ text: String) -> ModelResponse {
    ModelResponse(message: ChatMessage(role: .assistant, text: text), stopReason: .endTurn, usage: Usage(inputTokens: 10, outputTokens: 5))
}

/// A store with a sensor and its test point, an automation runtime and an
/// agent runtime over the same permission engine, on one manual clock.
private struct Bench {
    let clock: ManualClock
    let store: NexusStore
    let permissions: PermissionEngine
    let automation: AutomationRuntime
    let sensor: ObjectID
    let terminal: ObjectID

    init(location: NexusStore.Location = .inMemory, existing: (sensor: ObjectID, terminal: ObjectID)? = nil) throws {
        clock = ManualClock(t0)
        store = try NexusStore(location, clock: clock)
        permissions = try PermissionEngine(store: store)
        automation = AutomationRuntime(store: store, permissions: permissions, clock: clock)
        if let existing {
            sensor = existing.sensor
            terminal = existing.terminal
        } else {
            let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)
            sensor = try store.create(ObjectRecord(type: .sensor, title: "LT-101", provenance: recorded)).id
            terminal = try store.create(ObjectRecord(type: .testPoint, title: "TB-4", provenance: recorded)).id
            try store.relate(Relationship(kind: .contains, from: sensor, to: terminal, provenance: recorded))
        }
    }

    func runner(_ model: ScriptedModel, maxConcurrent: Int = 1, rateLimit: AgentRequestRunner.RateLimit = .init(count: 10, per: 3_600))
        -> AgentRequestRunner
    {
        let agents = AgentRuntime(store: store, router: ModelRouter(providers: [model]), permissions: permissions, tools: WorldTools.all, clock: clock)
        return AgentRequestRunner(agents: agents, maxConcurrent: maxConcurrent, rateLimit: rateLimit, clock: clock)
    }

    /// A rule that queues a diagnostic goal every time a note is recorded about the sensor, fired `count` times.
    @discardableResult
    func queue(_ count: Int, goal: String = "Diagnose {subject}", profile: String = "diagnostic") throws -> [ObjectID] {
        let rule = try automation.create(
            AutomationRule(
                title: "Ask the diagnostician", trigger: .event(kind: .note, subject: sensor),
                actions: [.startAgent(AgentGoalAction(profile: profile, goal: goal))], owner: tech),
            by: tech)
        try automation.start()
        for index in 0..<count {
            clock.advance(by: 1)
            try store.record(
                Event(
                    at: clock.now(), kind: .note, subjects: [sensor], summary: "Note \(index)",
                    provenance: Provenance(origin: tech, truth: .observed, timestamp: clock.now())))
        }
        automation.stop()
        _ = rule
        return try store.objects(ofType: .agentRequest).map(\.id)
    }

    func statusEvents(_ request: ObjectID) throws -> [String] {
        try store.events(about: request).filter { $0.kind == .agentRequestStatus }.compactMap {
            if case .string(let to)? = $0.payload["to"] { to } else { nil }
        }
    }
}

@Suite struct AgentRequestRunnerTests {
    @Test func queuedGoalRunsThroughTheAgentRuntime() async throws {
        let bench = try Bench()
        let ids = try bench.queue(1)
        #expect(ids.count == 1)
        let model = ScriptedModel(script: [
            toolTurn(call("get_object", ["id": .reference(bench.sensor)])),
            finalTurn("LT-101 has nothing recorded that points to a fault yet."),
        ])
        let runner = bench.runner(model)
        #expect(try runner.requests().map(\.status) == [.pending])

        let finished = try await runner.drain()
        let request = try #require(finished.first)
        #expect(request.status == .done)
        #expect(request.attempts == 1 && request.runStatus == "completed")
        #expect(request.output == "LT-101 has nothing recorded that points to a fault yet.")
        let run = try #require(request.run)

        // The run is a normal ledgered agent run, focused on the trigger's subject, and linked back.
        let runRecord = try #require(try bench.store.object(run))
        #expect(runRecord.type == .agentRun && runRecord.title == "Diagnose LT-101")
        #expect(try bench.store.relationships(from: request.id).contains { $0.kind == .handledBy && $0.to == run })
        #expect(model.requests.first?.messages.first?.text.contains("LT-101") == true)

        // Status history: attributes keep provenance, events record every transition.
        #expect(try bench.statusEvents(request.id) == ["running", "done"])
        let status = try #require(request.record.attributes["status"])
        #expect(status.provenance?.origin == .system && status.provenance?.truth == .recorded)
        #expect(status.provenance?.dependencies.contains(run) == true)
        #expect(request.record.attributes["output"]?.provenance?.truth == .agentInterpretation)

        // Draining again never reruns it.
        #expect(try await runner.drain().isEmpty)
        #expect(model.requests.count == 2)
    }

    @Test func toolNeedingApprovalBlocksUntilAPersonApproves() async throws {
        let bench = try Bench()
        let id = try #require(try bench.queue(1).first)
        let annotate = call("annotate_object", ["id": .reference(bench.sensor), "key": .string("suspect"), "value": .string("loop wiring")])
        let model = ScriptedModel(script: [
            toolTurn(annotate), finalTurn("Could not annotate."),
            toolTurn(annotate), finalTurn("Annotated LT-101 as suspect."),
        ])
        let runner = bench.runner(model)

        // P3 annotate asks once per project: unattended, nobody answers, so it's declined and remembered.
        let blocked = try #require(try await runner.drain().first)
        #expect(blocked.status == .blocked)
        #expect(blocked.needs.map(\.action) == ["annotate_object"])
        #expect(blocked.needs.first?.level == .modifyInternalState)
        #expect(try bench.store.object(bench.sensor)?.attributes["suspect"] == nil)
        // Blocked requests are not retried on their own.
        #expect(try await runner.drain().isEmpty)

        // Agents can't approve; a person can.
        #expect(throws: AgentRequestError.requiresHuman(.agent(id: "planner", run: nil))) {
            try runner.approve(id, by: .agent(id: "planner", run: nil))
        }
        let approved = try runner.approve(id, by: tech)
        #expect(approved.status == .pending && approved.needs.isEmpty && approved.approved.map(\.action) == ["annotate_object"])
        #expect(approved.record.attributes["approved"]?.provenance?.origin == tech)

        let done = try #require(try await runner.drain().first)
        #expect(done.status == .done && done.attempts == 2)
        #expect(try bench.store.object(bench.sensor)?.attributes["suspect"]?.value == .string("loop wiring"))
        #expect(try bench.statusEvents(id) == ["running", "blocked", "pending", "running", "done"])
        #expect(try bench.store.relationships(from: id).filter { $0.kind == .handledBy }.count == 2)
    }

    @Test func externalActionsAreNeverAutoApproved() async throws {
        let bench = try Bench()
        _ = try bench.queue(1)
        // Even a project-wide grant for P3 doesn't cover sending a message (P4, asked every time).
        try bench.permissions.add(PolicyRule(agent: "diagnostic", level: .modifyInternalState, grant: .always), by: tech)
        let model = ScriptedModel(script: [
            toolTurn(call("send_message", ["to": .string("ops"), "text": .string("LT-101 is low")])), finalTurn("Tried to tell ops."),
        ])
        let request = try #require(try await bench.runner(model).drain().first)
        #expect(request.status == .blocked)
        #expect(request.needs.map(\.action) == ["send_message"] && request.needs.first?.service == "message")
        #expect(try bench.store.timeline().filter { $0.kind == .message }.isEmpty)
    }

    @Test func cancelStopsPendingAndBlockedRequests() async throws {
        let bench = try Bench()
        let id = try #require(try bench.queue(1).first)
        let model = ScriptedModel(script: [])
        let runner = bench.runner(model)
        let cancelled = try runner.cancel(id, by: tech)
        #expect(cancelled.status == .cancelled)
        #expect(try await runner.drain().isEmpty)
        #expect(model.requests.isEmpty)
        #expect(throws: AgentRequestError.notCancellable(id, .cancelled)) { try runner.cancel(id, by: tech) }
        #expect(throws: AgentRequestError.notBlocked(id, .cancelled)) { try runner.approve(id, by: tech) }
    }

    @Test func unknownProfileAndModelErrorsFail() async throws {
        let bench = try Bench()
        _ = try bench.queue(1, profile: "astrologer")
        let request = try #require(try await bench.runner(ScriptedModel(script: [])).drain().first)
        #expect(request.status == .failed)
        #expect(request.error?.contains("astrologer") == true)

        let other = try Bench()
        _ = try other.queue(1)
        // An empty script throws from the model: the run fails, the request records why.
        let failed = try #require(try await other.runner(ScriptedModel(script: [])).drain().first)
        #expect(failed.status == .failed && failed.error != nil)
    }

    @Test func concurrencyAndRateAreLimited() async throws {
        let bench = try Bench()
        _ = try bench.queue(4)
        let model = ScriptedModel { _ in finalTurn("Nothing to add.") }

        // Two at a time, and at most three starts an hour.
        let runner = bench.runner(model, maxConcurrent: 2, rateLimit: .init(count: 3, per: 3_600))
        #expect(try await runner.drain().count == 2)
        #expect(try await runner.drain().count == 1)
        #expect(try await runner.drain().isEmpty)
        #expect(try runner.requests().map(\.status) == [.done, .done, .done, .pending])

        // The window is counted from the store, so a new runner (a restart) keeps it.
        let restarted = bench.runner(model, maxConcurrent: 2, rateLimit: .init(count: 3, per: 3_600))
        #expect(try await restarted.drain().isEmpty)
        bench.clock.advance(by: 3_601)
        #expect(try await restarted.drain().count == 1)
        #expect(try restarted.requests().allSatisfy { $0.status == .done })
    }

    @Test func interruptedRunIsNotRunAgainAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-requests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nexus.sqlite")

        let id: ObjectID
        let existing: (sensor: ObjectID, terminal: ObjectID)
        do {
            let bench = try Bench(location: .file(url))
            existing = (bench.sensor, bench.terminal)
            id = try #require(try bench.queue(1).first)
            // The app claims the request, then quits before the run ends.
            let claimed = try bench.runner(ScriptedModel(script: [])).claim()
            #expect(claimed.map(\.id) == [id])
        }

        let bench = try Bench(location: .file(url), existing: existing)
        bench.clock.advance(by: 600)
        let model = ScriptedModel { _ in finalTurn("Should not run.") }
        let runner = bench.runner(model)
        #expect(try await runner.drain().isEmpty)
        #expect(model.requests.isEmpty)
        let request = try runner.request(id)
        #expect(request.status == .failed && request.attempts == 1)
        #expect(request.error?.contains("Interrupted") == true)
        #expect(try bench.statusEvents(id) == ["running", "failed"])
    }

    @Test func runUsesTheAutomationsProject() async throws {
        let bench = try Bench()
        let project = try bench.store.create(
            ObjectRecord(type: .project, title: "Level loop", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0))
        ).id
        _ = try bench.automation.create(
            AutomationRule(
                title: "Ask", trigger: .event(kind: .note, subject: bench.sensor),
                actions: [.startAgent(AgentGoalAction(profile: "diagnostic", goal: "Look at {subject}"))], owner: tech, project: project),
            by: tech)
        try bench.automation.start()
        try bench.store.record(
            Event(at: t0, kind: .note, subjects: [bench.sensor], summary: "n", provenance: Provenance(origin: tech, truth: .observed, timestamp: t0)))
        let request = try #require(try await bench.runner(ScriptedModel { _ in finalTurn("Fine.") }).drain().first)
        let run = try #require(request.run)
        #expect(try bench.store.relationships(from: project).contains { $0.kind == .contains && $0.to == run })
    }
}
