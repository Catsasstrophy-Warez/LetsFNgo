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
    /// The run was cancelled by its caller.
    case cancellation
}

public enum AgentRunStatus: String, Sendable, Hashable {
    case running
    case completed
    /// The model declined the task.
    case refused
    /// Stopped early: step limit, truncated output or context overflow.
    case stopped
    /// Verification found an accountability violation.
    case failed
    /// The caller cancelled the run. Tool writes are all-or-nothing, so
    /// nothing half-done is left behind.
    case cancelled
}

/// Live progress of a run, for UI.
public enum AgentEvent: Sendable, Hashable {
    /// A ledger step was recorded.
    case step(AgentPhase, String)
    /// Model text as it streams.
    case textDelta(String)
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
///
/// Tools take one path whether the model returns `.toolUse` and the runtime
/// executes the calls, or the provider runs its own tool loop and calls back
/// through the `ToolHandler` it is given.
///
/// The context is fitted to the model's window every turn (`ContextBudget`).
/// Cancellation is cooperative: the runtime checks before each model turn and
/// before each tool, and a cancelled run ends with status `.cancelled`. A
/// tool call already under way (including one waiting for approval) is
/// allowed to finish its atomic batch before the run is closed.
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

    /// Runs `agent` on `request`. `onEvent` receives every ledger step and
    /// streamed text, in order, as they happen.
    public func run(
        _ request: AgentRequest,
        as agent: AgentProfile,
        approver: any ApprovalHandler,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async throws -> AgentRunResult {
        let focus = try store.objects(request.focus)
        let contextSize = 1_000 + focus.count * 200
        let model = try router.choose(for: TaskProfile(estimatedContextTokens: contextSize, privacy: request.privacy))
        let ledger = try Ledger(store: store, clock: clock, goal: request.goal, agent: agent.id, project: request.project, onEvent: onEvent)
        let state = RunState()
        return try await withTaskCancellationHandler {
            try await drive(request, as: agent, model: model, focus: focus, ledger: ledger, state: state, approver: approver, onEvent: onEvent)
        } onCancel: {
            state.cancel()
        }
    }

    private func drive(
        _ request: AgentRequest,
        as agent: AgentProfile,
        model: any LanguageModelProvider,
        focus: [ObjectRecord],
        ledger: Ledger,
        state: RunState,
        approver: any ApprovalHandler,
        onEvent: (@Sendable (AgentEvent) -> Void)?
    ) async throws -> AgentRunResult {
        var modelRef = model.descriptor.ref
        var usage = Usage()
        func finish(_ status: AgentRunStatus, _ output: String = "") throws -> AgentRunResult {
            try ledger.finish(status: status, output: output, model: modelRef, usage: usage, produced: state.produced)
        }
        func cancelled() async throws -> AgentRunResult {
            // A provider running its own tool loop may still be inside a tool call.
            await state.idle()
            try ledger.step(.cancellation, "Cancelled by caller")
            return try finish(.cancelled)
        }

        // Using a third-party model sends data off-device: an external action.
        if model.descriptor.tier == .thirdPartyCloud {
            let permission = PermissionRequest(
                agent: agent.id, action: "use_model", level: .externalAction, project: request.project,
                service: model.descriptor.ref.provider
            )
            guard try await authorize(permission, ledger: ledger, approver: approver, subject: "model \(model.descriptor.ref.modelID)") else {
                return try finish(.stopped, "Declined sending data to \(model.descriptor.ref.provider)")
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

        modelRef.promptHash = promptFingerprint(messages)
        let specs = agent.tools.sorted().compactMap { tools[$0]?.spec }
        let budget = ContextBudget(for: model.descriptor)
        let handler: ToolHandler = { [self] call in
            await handle(call, agent: agent, request: request, ledger: ledger, state: state, approver: approver)
        }

        for _ in 0..<agent.maxSteps {
            if state.isCancelled || Task.isCancelled { return try await cancelled() }

            // Fit the conversation to the window; trimming is kept for later turns.
            let turn: GenerationRequest
            do {
                let (fitted, trim) = try await budget.fit(GenerationRequest(messages: messages, tools: specs)) { try await model.countTokens($0) }
                if let trim {
                    try ledger.step(.context, trim.summary, payload: [
                        "shortenedResults": .int(Int64(trim.shortenedResults)), "droppedMessages": .int(Int64(trim.droppedMessages)),
                        "trimmedCharacters": .int(Int64(trim.trimmedCharacters)),
                    ])
                }
                turn = fitted
                messages = fitted.messages
            } catch AIError.contextTooLarge {
                try ledger.step(.error, "Context does not fit \(model.descriptor.ref.modelID) (\(model.descriptor.contextTokens) tokens)")
                return try finish(.stopped)
            }

            var final: ModelResponse?
            do {
                for try await event in model.stream(to: turn, toolHandler: handler) {
                    switch event {
                    case .textDelta(let text): onEvent?(.textDelta(text))
                    case .completed(let response): final = response
                    }
                }
            } catch {
                if state.isCancelled || Task.isCancelled { return try await cancelled() }
                throw error
            }
            if let failure = state.failure { throw failure }
            guard let response = final else {
                if state.isCancelled || Task.isCancelled { return try await cancelled() }
                throw AIError.incompleteResponse
            }

            usage = usage + response.usage
            try ledger.step(.plan, response.message.text.isEmpty ? "(tool calls)" : response.message.text, payload: [
                "stopReason": .string(response.stopReason.rawValue),
                "toolCalls": .list(response.message.toolCalls.map { .string($0.name) }),
            ])

            switch response.stopReason {
            case .refusal:
                return try finish(.refused)
            case .maxTokens:
                return try finish(.stopped, response.message.text)
            case .endTurn:
                if state.isCancelled || Task.isCancelled { return try await cancelled() }
                let status = try verify(state.produced, run: ledger.run, agent: agent.id, ledger: ledger)
                return try finish(status, response.message.text)
            case .toolUse:
                var results: [ToolResult] = []
                for call in response.message.toolCalls {
                    results.append(await handler(call))
                }
                if let failure = state.failure { throw failure }
                messages.append(response.message)
                messages.append(ChatMessage(role: .tool, toolResults: results))
            }
        }
        try ledger.step(.error, "Stopped after \(agent.maxSteps) steps")
        return try finish(.stopped)
    }

    /// The one path every tool call takes: availability, permission and
    /// approval, an atomic store batch, and a ledger step. It never throws,
    /// because providers cannot receive errors through a `ToolHandler`; a
    /// failed ledger write is kept in `state` and rethrown by the run.
    private func handle(
        _ call: ToolCall,
        agent: AgentProfile,
        request: AgentRequest,
        ledger: Ledger,
        state: RunState,
        approver: any ApprovalHandler
    ) async -> ToolResult {
        state.enter()
        defer { state.leave() }
        do {
            let (result, created) = try await execute(call, agent: agent, request: request, ledger: ledger, state: state, approver: approver)
            state.add(created)
            return result
        } catch {
            state.fail(error)
            return ToolResult(callID: call.id, content: "Error: \(error)", isError: true)
        }
    }

    private func execute(
        _ call: ToolCall,
        agent: AgentProfile,
        request: AgentRequest,
        ledger: Ledger,
        state: RunState,
        approver: any ApprovalHandler
    ) async throws -> (ToolResult, [ObjectID]) {
        let skipped = ToolResult(callID: call.id, content: "Cancelled before \(call.name) ran.", isError: true)
        if state.isCancelled || Task.isCancelled { return (skipped, []) }
        guard agent.tools.contains(call.name), let tool = tools[call.name] else {
            try ledger.step(.error, "Unknown or unavailable tool \(call.name)", payload: ["tool": .string(call.name)])
            return (ToolResult(callID: call.id, content: "Tool \(call.name) is not available to this agent.", isError: true), [])
        }
        let permission = PermissionRequest(agent: agent.id, action: call.name, level: tool.spec.permission, project: request.project)
        guard try await authorize(permission, ledger: ledger, approver: approver, subject: call.name, tool: call.name) else {
            return (ToolResult(callID: call.id, content: "Permission denied for \(call.name).", isError: true), [])
        }
        // Approval can take a while; the caller may have given up meanwhile.
        if state.isCancelled || Task.isCancelled { return (skipped, []) }

        let context = ToolContext(store: store, run: ledger.run, agentID: agent.id, project: request.project, clock: clock)
        do {
            let outcome = try store.batch { _ in try tool.run(call.arguments, in: context) }
            try ledger.step(.tool, "\(call.name): \(outcome.content)", subjects: outcome.touched + outcome.produced, payload: [
                "tool": .string(call.name), "arguments": .map(call.arguments),
                "produced": .list(outcome.produced.map(Value.reference)), "result": .string(outcome.content),
            ])
            return (ToolResult(callID: call.id, content: outcome.content), outcome.produced)
        } catch {
            try ledger.step(.error, "\(call.name) failed: \(error)", payload: ["tool": .string(call.name), "arguments": .map(call.arguments)])
            return (ToolResult(callID: call.id, content: "Error: \(error)", isError: true), [])
        }
    }

    private func authorize(
        _ request: PermissionRequest,
        ledger: Ledger,
        approver: any ApprovalHandler,
        subject: String,
        tool: String? = nil
    ) async throws -> Bool {
        var payload: [String: Value] = ["level": .int(Int64(request.level.rawValue))]
        if let tool { payload["tool"] = .string(tool) }
        switch permissions.evaluate(request) {
        case .allow:
            return true
        case .deny(let reason):
            try ledger.step(.permission, "Denied \(subject): \(reason)", payload: payload)
            return false
        case .needsApproval(let grant):
            let approved = await approver.approve(request, reason: "\(request.agent) wants to \(subject) (P\(request.level.rawValue))")
            payload["grant"] = .string(grant.rawValue)
            payload["approved"] = .bool(approved)
            try ledger.step(.approval, "\(approved ? "Approved" : "Declined") \(subject)", payload: payload)
            if approved { permissions.recordApproval(of: request, grant: grant) }
            return approved
        }
    }

    /// Accountability check: everything the run produced must exist, be
    /// attributed to this run, and be an interpretation, never a fact.
    private func verify(_ produced: [ObjectID], run: ObjectID, agent: String, ledger: Ledger) throws -> AgentRunStatus {
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

/// Mutable state of one run, shared with the `@Sendable` tool handler.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var producedIDs: [ObjectID] = []
    private var cancelled = false
    private var firstFailure: (any Error)?
    private var toolsInFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var produced: [ObjectID] { lock.withLock { producedIDs } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var failure: (any Error)? { lock.withLock { firstFailure } }

    func add(_ ids: [ObjectID]) { lock.withLock { producedIDs += ids } }
    func cancel() { lock.withLock { cancelled = true } }
    func fail(_ error: any Error) { lock.withLock { if firstFailure == nil { firstFailure = error } } }

    func enter() { lock.withLock { toolsInFlight += 1 } }

    func leave() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            toolsInFlight -= 1
            guard toolsInFlight == 0 else { return [] }
            defer { idleWaiters = [] }
            return idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once no tool call is running.
    func idle() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if toolsInFlight == 0 { return true }
                idleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Writes the run object and its step events.
struct Ledger: Sendable {
    let store: NexusStore
    let clock: NexusClock
    let run: ObjectID
    let onEvent: (@Sendable (AgentEvent) -> Void)?

    init(store: NexusStore, clock: NexusClock, goal: String, agent: String, project: ObjectID?, onEvent: (@Sendable (AgentEvent) -> Void)? = nil) throws {
        self.store = store
        self.clock = clock
        self.onEvent = onEvent
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
        onEvent?(.step(phase, summary))
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
