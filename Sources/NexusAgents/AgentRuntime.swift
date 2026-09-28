import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence

extension ObjectType {
    public static let agentRun: ObjectType = "agentRun"
}

extension RelationKind {
    /// Parent agent run → the sub-run it delegated to.
    public static let delegatedTo: RelationKind = "delegatedTo"
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
    /// Finished, but the answer states a value the run never read and does
    /// not label as modeled or estimated. The output is kept; don't trust
    /// its numbers.
    case unverified
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
    /// One line on what the agent is for, shown to the orchestrator.
    public var summary: String
    /// Words in a goal that point at this agent, for the orchestrator's
    /// deterministic fallback. Lowercase; matched as word prefixes.
    public var keywords: [String]

    public init(id: String, instructions: String, tools: Set<String>, maxSteps: Int = 12, summary: String = "", keywords: [String] = []) {
        self.id = id
        self.instructions = instructions
        self.tools = tools
        self.maxSteps = maxSteps
        self.summary = summary
        self.keywords = keywords
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

/// Timing and cost of one model call.
public struct ModelCallMetrics: Sendable, Hashable {
    public var latencyMs: Int
    public var usage: Usage
    /// From the provider's per-token price; nil when it has none.
    public var cost: Double?
}

public struct AgentRunResult: Sendable, Hashable {
    public var run: ObjectID
    public var status: AgentRunStatus
    public var output: String
    public var produced: [ObjectID]
    public var usage: Usage
    public var model: ModelRef
    /// The agent that ran.
    public var agent: String = ""
    /// Every model call, in order.
    public var calls: [ModelCallMetrics] = []
    /// The grounding check of the final answer, when the run got that far.
    public var grounding: GroundingReport?
    /// The run that delegated to this one.
    public var parentRun: ObjectID?

    public var latencyMs: Int { calls.reduce(0) { $0 + $1.latencyMs } }
    /// Total cost, or nil when no call had a price.
    public var cost: Double? {
        let priced = calls.compactMap(\.cost)
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }
}

/// A run whose specialist an `Orchestrator` picked.
public struct OrchestratedRun: Sendable, Hashable {
    public var choice: OrchestratorChoice
    public var result: AgentRunResult
}

/// Runs agents over the world model:
/// goal → context → plan → permission → tool → observation → … → output → verification.
///
/// Permission requests carry the tool's scope (object types, data source,
/// service), so policies and remembered approvals apply per scope.
///
/// Verification checks that what the run produced is attributable and an
/// interpretation (or, for claims, `claimed`), and that the final answer is
/// grounded (`GroundingCheck`): a run whose answer states an unread,
/// unlabeled value ends `unverified`.
///
/// Every model call's latency (from the injected clock) and, when the
/// provider has a price, its cost are recorded in the run's `usage`.
///
/// Delegation: a `DelegatingTool` runs another profile as a sub-run, with
/// its own ledger and the sub-agent's permissions, linked `delegatedTo`.
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
        try await run(request, as: agent, approver: approver, onEvent: onEvent, parent: nil, depth: 0, preface: [])
    }

    /// Lets `orchestrator` pick the specialist, then runs it. The choice is
    /// the run's first plan step. The orchestrator asks the routed model only
    /// when it is not a third-party cloud model; otherwise, and whenever the
    /// model gives no usable answer, it falls back to keywords.
    public func run(
        _ request: AgentRequest,
        orchestrator: Orchestrator,
        approver: any ApprovalHandler,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async throws -> OrchestratedRun {
        let local = try? router.choose(for: TaskProfile(estimatedContextTokens: 1_000, needsTools: false, privacy: request.privacy))
        let model = local.flatMap { $0.descriptor.tier == .thirdPartyCloud ? nil : $0 }
        let focus = try store.objects(request.focus).map { "\($0.title) [\($0.type)]" }.joined(separator: "\n")
        let choice = await orchestrator.choose(for: request.goal, context: focus, model: model)
        let summary = "Orchestrator chose \(choice.profile.id) (\(choice.method.rawValue)): \(choice.reason)"
        let payload: [String: Value] = [
            "orchestrator": .map(["agent": .string(choice.profile.id), "method": .string(choice.method.rawValue)])
        ]
        let result = try await run(
            request, as: choice.profile, approver: approver, onEvent: onEvent, parent: nil, depth: 0, preface: [(.plan, summary, payload)]
        )
        return OrchestratedRun(choice: choice, result: result)
    }

    func run(
        _ request: AgentRequest,
        as agent: AgentProfile,
        approver: any ApprovalHandler,
        onEvent: (@Sendable (AgentEvent) -> Void)?,
        parent: ObjectID?,
        depth: Int,
        preface: [(AgentPhase, String, [String: Value])]
    ) async throws -> AgentRunResult {
        let focus = try store.objects(request.focus)
        let contextSize = 1_000 + focus.count * 200
        let model = try router.choose(for: TaskProfile(estimatedContextTokens: contextSize, privacy: request.privacy))
        let ledger = try Ledger(
            store: store, clock: clock, goal: request.goal, agent: agent.id, project: request.project, parent: parent, onEvent: onEvent
        )
        for (phase, summary, payload) in preface {
            try ledger.step(phase, summary, payload: payload)
        }
        let state = RunState(depth: depth)
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
        var calls: [ModelCallMetrics] = []
        var grounding: GroundingReport?
        func finish(_ status: AgentRunStatus, _ output: String = "") throws -> AgentRunResult {
            var result = try ledger.finish(
                status: status, output: output, model: modelRef, usage: usage, calls: calls, currency: model.descriptor.price?.currency,
                produced: state.produced
            )
            result.agent = agent.id
            result.calls = calls
            result.grounding = grounding
            result.parentRun = ledger.parent
            return result
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
            let started = clock.now()
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
            let latency = max(0, Int((clock.now().timeIntervalSince(started) * 1_000).rounded()))
            calls.append(ModelCallMetrics(latencyMs: latency, usage: response.usage, cost: model.descriptor.price?.cost(of: response.usage)))
            try ledger.step(.plan, response.message.text.isEmpty ? "(tool calls)" : response.message.text, payload: [
                "stopReason": .string(response.stopReason.rawValue),
                "toolCalls": .list(response.message.toolCalls.map { .string($0.name) }),
                "latencyMs": .int(Int64(latency)),
            ])

            switch response.stopReason {
            case .refusal:
                return try finish(.refused)
            case .maxTokens:
                return try finish(.stopped, response.message.text)
            case .endTurn:
                if state.isCancelled || Task.isCancelled { return try await cancelled() }
                let (status, report) = try verify(
                    state.produced, answer: response.message.text, read: [request.goal] + state.read, run: ledger.run, agent: agent.id, ledger: ledger
                )
                grounding = report
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
        let context = ToolContext(store: store, run: ledger.run, agentID: agent.id, project: request.project, clock: clock)
        let scope: ToolScope
        do {
            scope = try tool.scope(for: call.arguments, in: context)
        } catch {
            try ledger.step(.error, "\(call.name) failed: \(error)", payload: ["tool": .string(call.name), "arguments": .map(call.arguments)])
            return (ToolResult(callID: call.id, content: "Error: \(error)", isError: true), [])
        }
        let permission = PermissionRequest(
            agent: agent.id, action: call.name, level: tool.spec.permission, project: request.project, objectTypes: scope.objectTypes,
            dataSource: scope.dataSource, service: scope.service
        )
        guard try await authorize(permission, ledger: ledger, approver: approver, subject: call.name, tool: call.name) else {
            return (ToolResult(callID: call.id, content: "Permission denied for \(call.name).", isError: true), [])
        }
        // Approval can take a while; the caller may have given up meanwhile.
        if state.isCancelled || Task.isCancelled { return (skipped, []) }

        do {
            let outcome: ToolOutcome
            if let delegating = tool as? any DelegatingTool {
                let delegation = Delegation(parentRun: ledger.run, depth: state.depth + 1) { [self] profile, goal in
                    var sub = request
                    sub.goal = goal
                    return try await run(sub, as: profile, approver: approver, onEvent: nil, parent: ledger.run, depth: state.depth + 1, preface: [])
                }
                outcome = try await delegating.delegate(call.arguments, in: context, via: delegation)
            } else {
                outcome = try store.batch { _ in try tool.run(call.arguments, in: context) }
            }
            try ledger.step(.tool, "\(call.name): \(outcome.content)", subjects: outcome.touched + outcome.produced, payload: [
                "tool": .string(call.name), "arguments": .map(call.arguments),
                "produced": .list(outcome.produced.map(Value.reference)), "result": .string(outcome.content),
            ])
            state.remember(outcome.content)
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
        if !request.objectTypes.isEmpty { payload["objectTypes"] = .list(request.objectTypes.map(\.rawValue).sorted().map(Value.string)) }
        if let dataSource = request.dataSource { payload["dataSource"] = .string(dataSource) }
        if let service = request.service { payload["service"] = .string(service) }
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
    /// attributed to this run, and be an interpretation (a claim may be
    /// `claimed`: it records what a source asserts), never a fact. Then the
    /// grounding check: every quantity in the answer was read or is labeled.
    private func verify(
        _ produced: [ObjectID],
        answer: String,
        read: [String],
        run: ObjectID,
        agent: String,
        ledger: Ledger
    ) throws -> (AgentRunStatus, GroundingReport) {
        let records = try store.objects(produced)
        let violations = produced.filter { id in
            guard let record = records.first(where: { $0.id == id }) else { return true }
            return record.provenance.origin != .agent(id: agent, run: run) || !Self.acceptableTruth(of: record)
        }
        let grounding = GroundingCheck().check(answer, against: read)
        let status: AgentRunStatus = !violations.isEmpty ? .failed : grounding.passed ? .completed : .unverified
        var summary = violations.isEmpty ? "Verified \(produced.count) output(s)" : "Verification failed for \(violations.count) output(s)"
        summary += "; grounding: \(grounding.summary)"
        try ledger.step(
            .verification, summary, subjects: produced.filter { id in records.contains { $0.id == id } },
            payload: [
                "outputsVerified": .bool(violations.isEmpty),
                "grounding": .map([
                    "passed": .bool(grounding.passed), "checked": .int(Int64(grounding.checked)),
                    "grounded": .list(grounding.grounded.map(Value.string)), "labeled": .list(grounding.labeled.map(Value.string)),
                    "ungrounded": .list(grounding.ungrounded.map(Value.string)),
                ]),
            ]
        )
        return (status, grounding)
    }

    static func acceptableTruth(of record: ObjectRecord) -> Bool {
        record.provenance.truth == .agentInterpretation || (record.type == .claim && record.provenance.truth == .claimed)
    }
}

/// Mutable state of one run, shared with the `@Sendable` tool handler.
private final class RunState: @unchecked Sendable {
    /// Delegation depth of the run (0 for a top-level run).
    let depth: Int
    private let lock = NSLock()
    private var producedIDs: [ObjectID] = []
    private var readTexts: [String] = []
    private var cancelled = false
    private var firstFailure: (any Error)?
    private var toolsInFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(depth: Int = 0) {
        self.depth = depth
    }

    var produced: [ObjectID] { lock.withLock { producedIDs } }
    /// Every successful tool result, for the grounding check.
    var read: [String] { lock.withLock { readTexts } }
    func remember(_ text: String) { lock.withLock { readTexts.append(text) } }
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
    let parent: ObjectID?
    let onEvent: (@Sendable (AgentEvent) -> Void)?

    init(
        store: NexusStore,
        clock: NexusClock,
        goal: String,
        agent: String,
        project: ObjectID?,
        parent: ObjectID? = nil,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) throws {
        self.store = store
        self.clock = clock
        self.onEvent = onEvent
        self.parent = parent
        var attributes = ["agent": Attribute(.string(agent)), "status": Attribute(.string(AgentRunStatus.running.rawValue))]
        if let parent { attributes["parentRun"] = Attribute(.reference(parent)) }
        let record = try store.create(ObjectRecord(
            type: .agentRun, title: goal, attributes: attributes,
            provenance: Provenance(origin: .system, truth: .recorded, timestamp: clock.now(), method: "agent ledger")
        ))
        run = record.id
        if let parent {
            try store.relate(Relationship(
                kind: .delegatedTo, from: parent, to: run,
                provenance: Provenance(origin: .system, truth: .recorded, timestamp: clock.now(), method: "agent ledger")
            ))
        }
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

    func finish(
        status: AgentRunStatus,
        output: String,
        model: ModelRef,
        usage: Usage,
        calls: [ModelCallMetrics] = [],
        currency: String? = nil,
        produced: [ObjectID]
    ) throws -> AgentRunResult {
        let now = clock.now()
        let recorded = Provenance(origin: .system, truth: .recorded, timestamp: now, method: "agent ledger")
        try store.batch { store in
            try store.update(run, by: .system, instruction: "Run \(status.rawValue)") {
                $0.attributes["status"] = Attribute(.string(status.rawValue), provenance: recorded)
                $0.attributes["model"] = Attribute(.map([
                    "provider": .string(model.provider), "modelID": .string(model.modelID),
                    "promptHash": model.promptHash.map(Value.string) ?? .null,
                ]), provenance: recorded)
                let perCall: [Value] = calls.map { call in
                    var entry: [String: Value] = [
                        "latencyMs": .int(Int64(call.latencyMs)), "inputTokens": .int(Int64(call.usage.inputTokens)),
                        "outputTokens": .int(Int64(call.usage.outputTokens)),
                    ]
                    if let cost = call.cost { entry["cost"] = .double(cost) }
                    return .map(entry)
                }
                var usageMap: [String: Value] = [
                    "inputTokens": .int(Int64(usage.inputTokens)), "outputTokens": .int(Int64(usage.outputTokens)),
                    "latencyMs": .int(Int64(calls.reduce(0) { $0 + $1.latencyMs })), "calls": .list(perCall),
                ]
                let costs = calls.compactMap(\.cost)
                if !costs.isEmpty {
                    usageMap["cost"] = .double(costs.reduce(0, +))
                    usageMap["currency"] = .string(currency ?? "USD")
                }
                $0.attributes["usage"] = Attribute(.map(usageMap), provenance: recorded)
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
