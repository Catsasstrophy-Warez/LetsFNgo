import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence

extension ObjectType {
    public static let agentRun: ObjectType = "agentRun"
}

/// Phases of the execution envelope, recorded as ledger steps.
public enum AgentPhase: String, Sendable, Hashable {
    case goal
    case context
    case plan
    case permission
    case approval
    case tool
    case error
    case output
    case verification
}

public enum AgentRunStatus: String, Sendable, Hashable {
    case running
    case completed
    /// The model declined the task.
    case refused
    /// Stopped early: step limit or truncated output.
    case stopped
    /// Verification found an accountability violation.
    case failed
}

public struct AgentProfile: Sendable, Hashable {
    public var id: String
    public var instructions: String
    /// Tool names this agent may use. Others are refused even if registered.
    public var tools: Set<String>
    public var maxSteps: Int

    public init(id: String, instructions: String, tools: Set<String>, maxSteps: Int = 12) {
        self.id = id
        self.instructions = instructions
        self.tools = tools
        self.maxSteps = maxSteps
    }
}

public struct AgentRequest: Sendable, Hashable {
    public var goal: String
    public var project: ObjectID?
    /// The selection the agent was invoked on; it becomes the run's context.
    public var focus: [ObjectID]
    public var privacy: PrivacyRequirement

    public init(goal: String, project: ObjectID? = nil, focus: [ObjectID] = [], privacy: PrivacyRequirement = .onDeviceOnly) {
        self.goal = goal
        self.project = project
        self.focus = focus
        self.privacy = privacy
    }
}

/// Asks a person. Returns true to approve.
public protocol ApprovalHandler: Sendable {
    func approve(_ request: PermissionRequest, reason: String) async -> Bool
}

public struct AgentRunResult: Sendable, Hashable {
    public var run: ObjectID
    public var status: AgentRunStatus
    public var output: String
    public var produced: [ObjectID]
    public var usage: Usage
    public var model: ModelRef
}

/// Runs agents over the world model:
/// goal → context → plan → permission → tool → observation → … → output → verification.
///
/// Every run is an `agentRun` object; every step is an `agentAction` event on
/// it. Outputs are agent interpretations linked `produced` from the run.
/// Each tool call runs in its own store batch, so a failure leaves the prior
/// valid state intact.
public final class AgentRuntime: Sendable {
    public let store: NexusStore
    public let router: ModelRouter
    public let permissions: PermissionEngine
    private let tools: [String: any AgentTool]
    private let clock: NexusClock

    public init(store: NexusStore, router: ModelRouter, permissions: PermissionEngine, tools: [any AgentTool], clock: NexusClock = SystemClock()) {
        self.store = store
        self.router = router
        self.permissions = permissions
        self.tools = Dictionary(tools.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.clock = clock
    }

    public func run(_ request: AgentRequest, as agent: AgentProfile, approver: any ApprovalHandler) async throws -> AgentRunResult {
        let focus = try store.objects(request.focus)
        let contextSize = 1_000 + focus.count * 200
        let model = try router.choose(for: TaskProfile(estimatedContextTokens: contextSize, privacy: request.privacy))
        var ledger = try Ledger(store: store, clock: clock, goal: request.goal, agent: agent.id, project: request.project)

        // Using a third-party model sends data off-device: an external action.
        if model.descriptor.tier == .thirdPartyCloud {
            let permission = PermissionRequest(
                agent: agent.id, action: "use_model", level: .externalAction, project: request.project,
                service: model.descriptor.ref.provider
            )
            guard try await authorize(permission, ledger: &ledger, approver: approver, subject: "model \(model.descriptor.ref.modelID)") else {
                return try ledger.finish(status: .stopped, output: "Declined sending data to \(model.descriptor.ref.provider)", model: model.descriptor.ref, usage: Usage(), produced: [])
            }
        }

        let focusText = focus.map { "- \($0.id) [\($0.type)] \($0.title)" }.joined(separator: "\n")
        let system = """
            \(agent.instructions)
            Values you report must come from tool results. Say which truth class each value has.
            \(focus.isEmpty ? "" : "Selected objects:\n\(focusText)")
            """
        var messages: [ChatMessage] = [.system(system), .user(request.goal)]
        try ledger.step(.context, "Context: \(focus.count) selected object(s)", subjects: focus.map(\.id))

        var modelRef = model.descriptor.ref
        modelRef.promptHash = promptFingerprint(messages)
        let specs = agent.tools.sorted().compactMap { tools[$0]?.spec }
        var usage = Usage()
        var produced: [ObjectID] = []

        for _ in 0..<agent.maxSteps {
            let response = try await model.respond(to: GenerationRequest(messages: messages, tools: specs))
            usage = usage + response.usage
            try ledger.step(.plan, response.message.text.isEmpty ? "(tool calls)" : response.message.text, payload: [
                "stopReason": .string(response.stopReason.rawValue),
                "toolCalls": .list(response.message.toolCalls.map { .string($0.name) }),
            ])

            switch response.stopReason {
            case .refusal:
                return try ledger.finish(status: .refused, output: "", model: modelRef, usage: usage, produced: produced)
            case .maxTokens:
                return try ledger.finish(status: .stopped, output: response.message.text, model: modelRef, usage: usage, produced: produced)
            case .endTurn:
                let status = try verify(produced, run: ledger.run, agent: agent.id, ledger: &ledger)
                return try ledger.finish(status: status, output: response.message.text, model: modelRef, usage: usage, produced: produced)
            case .toolUse:
                var results: [ToolResult] = []
                for call in response.message.toolCalls {
                    let (result, created) = try await execute(call, agent: agent, request: request, ledger: &ledger, approver: approver)
                    results.append(result)
                    produced += created
                }
                messages.append(response.message)
                messages.append(ChatMessage(role: .tool, toolResults: results))
            }
        }
        try ledger.step(.error, "Stopped after \(agent.maxSteps) steps")
        return try ledger.finish(status: .stopped, output: "", model: modelRef, usage: usage, produced: produced)
    }

    private func execute(
        _ call: ToolCall,
        agent: AgentProfile,
        request: AgentRequest,
        ledger: inout Ledger,
        approver: any ApprovalHandler
    ) async throws -> (ToolResult, [ObjectID]) {
        guard agent.tools.contains(call.name), let tool = tools[call.name] else {
            try ledger.step(.error, "Unknown or unavailable tool \(call.name)")
            return (ToolResult(callID: call.id, content: "Tool \(call.name) is not available to this agent.", isError: true), [])
        }
        let permission = PermissionRequest(agent: agent.id, action: call.name, level: tool.spec.permission, project: request.project)
        guard try await authorize(permission, ledger: &ledger, approver: approver, subject: call.name) else {
            return (ToolResult(callID: call.id, content: "Permission denied for \(call.name).", isError: true), [])
        }

        let context = ToolContext(store: store, run: ledger.run, agentID: agent.id, project: request.project, clock: clock)
        do {
            let outcome = try store.batch { _ in try tool.run(call.arguments, in: context) }
            try ledger.step(.tool, "\(call.name): \(outcome.content)", subjects: outcome.touched + outcome.produced, payload: [
                "tool": .string(call.name), "arguments": .map(call.arguments),
                "produced": .list(outcome.produced.map(Value.reference)),
            ])
            return (ToolResult(callID: call.id, content: outcome.content), outcome.produced)
        } catch {
            try ledger.step(.error, "\(call.name) failed: \(error)", payload: ["tool": .string(call.name), "arguments": .map(call.arguments)])
            return (ToolResult(callID: call.id, content: "Error: \(error)", isError: true), [])
        }
    }

    private func authorize(_ request: PermissionRequest, ledger: inout Ledger, approver: any ApprovalHandler, subject: String) async throws -> Bool {
        switch permissions.evaluate(request) {
        case .allow:
            return true
        case .deny(let reason):
            try ledger.step(.permission, "Denied \(subject): \(reason)", payload: ["level": .int(Int64(request.level.rawValue))])
            return false
        case .needsApproval(let grant):
            let approved = await approver.approve(request, reason: "\(request.agent) wants to \(subject) (P\(request.level.rawValue))")
            try ledger.step(.approval, "\(approved ? "Approved" : "Declined") \(subject)", payload: [
                "level": .int(Int64(request.level.rawValue)), "grant": .string(grant.rawValue), "approved": .bool(approved),
            ])
            if approved { permissions.recordApproval(of: request, grant: grant) }
            return approved
        }
    }

    /// Accountability check: everything the run produced must exist, be
    /// attributed to this run, and be an interpretation, never a fact.
    private func verify(_ produced: [ObjectID], run: ObjectID, agent: String, ledger: inout Ledger) throws -> AgentRunStatus {
        let records = try store.objects(produced)
        let violations = produced.filter { id in
            guard let record = records.first(where: { $0.id == id }) else { return true }
            return record.provenance.origin != .agent(id: agent, run: run) || record.provenance.truth != .agentInterpretation
        }
        try ledger.step(
            .verification,
            violations.isEmpty ? "Verified \(produced.count) output(s)" : "Verification failed for \(violations.count) output(s)",
            subjects: produced.filter { id in records.contains { $0.id == id } }
        )
        return violations.isEmpty ? .completed : .failed
    }
}

/// Writes the run object and its step events.
struct Ledger {
    let store: NexusStore
    let clock: NexusClock
    let run: ObjectID

    init(store: NexusStore, clock: NexusClock, goal: String, agent: String, project: ObjectID?) throws {
        self.store = store
        self.clock = clock
        let record = try store.create(ObjectRecord(
            type: .agentRun, title: goal,
            attributes: ["agent": Attribute(.string(agent)), "status": Attribute(.string(AgentRunStatus.running.rawValue))],
            provenance: Provenance(origin: .system, truth: .recorded, timestamp: clock.now(), method: "agent ledger")
        ))
        run = record.id
        if let project {
            try store.relate(Relationship(
                kind: .contains, from: project, to: run,
                provenance: Provenance(origin: .system, truth: .recorded, timestamp: clock.now())
            ))
        }
        try step(.goal, goal)
    }

    func step(_ phase: AgentPhase, _ summary: String, subjects: [ObjectID] = [], payload: [String: Value] = [:]) throws {
        var payload = payload
        payload["phase"] = .string(phase.rawValue)
        var seen: Set<ObjectID> = []
        let existing = Set(try store.objects(subjects).map(\.id))
        let subjects = ([run] + subjects).filter { existing.contains($0) || $0 == run }.filter { seen.insert($0).inserted }
        try store.record(Event(
            at: clock.now(), kind: .agentAction, subjects: subjects, summary: summary, payload: payload,
            provenance: Provenance(origin: .system, truth: .recorded, timestamp: clock.now(), method: "agent ledger")
        ))
    }

    func finish(status: AgentRunStatus, output: String, model: ModelRef, usage: Usage, produced: [ObjectID]) throws -> AgentRunResult {
        let now = clock.now()
        let recorded = Provenance(origin: .system, truth: .recorded, timestamp: now, method: "agent ledger")
        try store.batch { store in
            try store.update(run, by: .system, instruction: "Run \(status.rawValue)") {
                $0.attributes["status"] = Attribute(.string(status.rawValue), provenance: recorded)
                $0.attributes["model"] = Attribute(.map([
                    "provider": .string(model.provider), "modelID": .string(model.modelID),
                    "promptHash": model.promptHash.map(Value.string) ?? .null,
                ]), provenance: recorded)
                $0.attributes["usage"] = Attribute(.map([
                    "inputTokens": .int(Int64(usage.inputTokens)), "outputTokens": .int(Int64(usage.outputTokens)),
                ]), provenance: recorded)
                if !output.isEmpty {
                    $0.attributes["output"] = Attribute(
                        .string(output),
                        provenance: Provenance(origin: .model(model), truth: .agentInterpretation, timestamp: now, dependencies: produced)
                    )
                }
            }
            for id in produced where try store.object(id) != nil {
                try store.relate(Relationship(kind: .produced, from: run, to: id, provenance: recorded))
            }
        }
        try step(.output, "Finished: \(status.rawValue)")
        return AgentRunResult(run: run, status: status, output: output, produced: produced, usage: usage, model: model)
    }
}
