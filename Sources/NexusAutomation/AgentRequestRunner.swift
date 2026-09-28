import Foundation
import NexusAI
import NexusAgents
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence

extension EventKind {
    /// A queued agent goal changed status. Subjects: the request (and its run,
    /// once there is one). Payload: `from`, `to`, `attempt`, optional `run`,
    /// `reason` and `by`.
    public static let agentRequestStatus: EventKind = "agentRequestStatus"
}

extension RelationKind {
    /// Agent request → the agent run that carried out one attempt at it.
    public static let handledBy: RelationKind = "handledBy"
}

/// Where a queued agent goal is.
public enum AgentRequestStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Waiting for the runner.
    case pending
    /// Claimed by a runner; its agent run is under way.
    case running
    /// The run finished (completed or unverified; the run's own status says which).
    case done
    /// The run failed, refused, stopped early, or was interrupted.
    case failed
    /// The run needed a permission only a person can give. A person may
    /// approve it (the goal runs again with those permissions) or cancel it.
    case blocked
    case cancelled

    /// Nothing more will happen without a person.
    public var isFinal: Bool { self == .done || self == .failed || self == .cancelled }
}

public enum AgentRequestError: Error, Equatable, Sendable {
    case notAnAgentRequest(ObjectID)
    /// Only a person or the system may approve a blocked request.
    case requiresHuman(Origin)
    case notBlocked(ObjectID, AgentRequestStatus)
    case notCancellable(ObjectID, AgentRequestStatus)
}

extension AgentRequestError: ClassifiableError {
    public var classified: ClassifiedError {
        switch self {
        case .notAnAgentRequest:
            ClassifiedError(category: .dataSource, whatHappened: "That object isn't a queued agent goal.")
        case .requiresHuman:
            ClassifiedError(
                category: .agentTool, whatHappened: "Only a person can approve an agent goal.", whatSurvived: ["The goal is still blocked."])
        case .notBlocked(_, let status):
            ClassifiedError(
                category: .userInput, whatHappened: "This agent goal is \(status.rawValue), not waiting for approval.",
                nextActions: [NextAction("Refresh the list")])
        case .notCancellable(_, let status):
            ClassifiedError(
                category: .userInput, whatHappened: "This agent goal is \(status.rawValue) and can't be cancelled now.",
                nextActions: [NextAction("Refresh the list")])
        }
    }
}

/// A permission an unattended run asked for with nobody there to answer.
/// Kept on the request so a person can see exactly what they approve.
public struct NeededPermission: Codable, Sendable, Hashable {
    public var agent: String
    public var action: String
    public var level: PermissionLevel
    public var project: ObjectID?
    /// Sorted raw values.
    public var objectTypes: [String]
    public var dataSource: String?
    public var service: String?
    public var reason: String

    public init(_ request: PermissionRequest, reason: String) {
        agent = request.agent
        action = request.action
        level = request.level
        project = request.project
        objectTypes = request.objectTypes.map(\.rawValue).sorted()
        dataSource = request.dataSource
        service = request.service
        self.reason = reason
    }

    public var request: PermissionRequest {
        PermissionRequest(
            agent: agent, action: action, level: level, project: project, objectTypes: Set(objectTypes.map(ObjectType.init(rawValue:))),
            dataSource: dataSource, service: service)
    }

    /// Same permission, whatever the reason text.
    func covers(_ other: PermissionRequest) -> Bool { request == other }
}

/// An `agentRequest` object (queued by an automation's "start an agent goal"
/// action), read through a typed view.
///
/// Stored attributes: `goal`, `profile`, `status`, `subjects`, `automation`,
/// `requestedAt`, and as it runs `attempts`, `startedAt`, `finishedAt`,
/// `runner`, `run`, `runStatus`, `output`, `needs`, `approved`, `error`.
public struct QueuedAgentRequest: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var goal: String
    public var profile: String
    public var status: AgentRequestStatus
    public var subjects: [ObjectID]
    public var automation: ObjectID?
    public var requestedAt: Date
    public var attempts: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The latest agent run.
    public var run: ObjectID?
    /// The latest run's own status (`AgentRunStatus` raw value).
    public var runStatus: String?
    public var output: String?
    /// What a blocked request is waiting for.
    public var needs: [NeededPermission]
    /// What people have approved for this request.
    public var approved: [NeededPermission]
    public var error: String?
    /// The runner session that claimed it.
    var runner: String?
    public var record: ObjectRecord

    enum Keys {
        static let goal = "goal"
        static let profile = "profile"
        static let status = "status"
        static let subjects = "subjects"
        static let automation = "automation"
        static let requestedAt = "requestedAt"
        static let attempts = "attempts"
        static let startedAt = "startedAt"
        static let finishedAt = "finishedAt"
        static let runner = "runner"
        static let run = "run"
        static let runStatus = "runStatus"
        static let output = "output"
        static let needs = "needs"
        static let approved = "approved"
        static let error = "error"
    }

    public init(record: ObjectRecord) throws {
        guard record.type == .agentRequest else { throw AgentRequestError.notAnAgentRequest(record.id) }
        func string(_ key: String) -> String? {
            if case .string(let text)? = record.attributes[key]?.value { text } else { nil }
        }
        func date(_ key: String) -> Date? {
            if case .date(let date)? = record.attributes[key]?.value { date } else { nil }
        }
        func reference(_ key: String) -> ObjectID? {
            if case .reference(let id)? = record.attributes[key]?.value { id } else { nil }
        }
        func permissions(_ key: String) -> [NeededPermission] {
            record.attributes[key].flatMap { try? ValueCoding.decode([NeededPermission].self, from: $0.value) } ?? []
        }
        id = record.id
        goal = string(Keys.goal) ?? record.title
        profile = string(Keys.profile) ?? ""
        status = string(Keys.status).flatMap(AgentRequestStatus.init(rawValue:)) ?? .pending
        if case .list(let values)? = record.attributes[Keys.subjects]?.value {
            subjects = values.compactMap { if case .reference(let id) = $0 { id } else { nil } }
        } else {
            subjects = []
        }
        automation = reference(Keys.automation)
        requestedAt = date(Keys.requestedAt) ?? record.createdAt
        attempts = record.attributes[Keys.attempts]?.value.number.map { Int($0) } ?? 0
        startedAt = date(Keys.startedAt)
        finishedAt = date(Keys.finishedAt)
        run = reference(Keys.run)
        runStatus = string(Keys.runStatus)
        output = string(Keys.output)
        needs = permissions(Keys.needs)
        approved = permissions(Keys.approved)
        error = string(Keys.error)
        runner = string(Keys.runner)
        self.record = record
    }
}

/// Reads agent requests and applies people's decisions on them (approve,
/// cancel). Needs no model, so the app can show and manage the queue before
/// one is installed; `AgentRequestRunner` runs what's pending.
public struct AgentRequestQueue: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Every agent request that isn't deleted, oldest first.
    public func requests() throws -> [QueuedAgentRequest] {
        try store.objects(ofType: .agentRequest).filter { $0.lifecycle != .deleted }.compactMap { try? QueuedAgentRequest(record: $0) }
            .sorted { ($0.requestedAt, $0.id) < ($1.requestedAt, $1.id) }
    }

    public func request(_ id: ObjectID) throws -> QueuedAgentRequest {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        return try QueuedAgentRequest(record: record)
    }

    /// A person approves what a blocked request needs: it goes back to
    /// pending, and its next attempt is allowed exactly those permissions.
    @discardableResult
    public func approve(_ id: ObjectID, by author: Origin) throws -> QueuedAgentRequest {
        guard AutomationRuntime.isHuman(author) else { throw AgentRequestError.requiresHuman(author) }
        return try store.batch { _ in
            let request = try self.request(id)
            guard request.status == .blocked else { throw AgentRequestError.notBlocked(id, request.status) }
            var approved = request.approved
            for need in request.needs where !approved.contains(where: { $0.covers(need.request) }) { approved.append(need) }
            return try transition(
                id, to: .pending, by: author,
                reason: "Approved " + request.needs.map { "\($0.action) (P\($0.level.rawValue))" }.joined(separator: ", "),
                changes: [QueuedAgentRequest.Keys.approved: try ValueCoding.encode(approved), QueuedAgentRequest.Keys.needs: .list([])])
        }
    }

    /// Cancels a pending or blocked request.
    @discardableResult
    public func cancel(_ id: ObjectID, by author: Origin) throws -> QueuedAgentRequest {
        try store.batch { _ in
            let request = try self.request(id)
            guard request.status == .pending || request.status == .blocked else { throw AgentRequestError.notCancellable(id, request.status) }
            return try transition(id, to: .cancelled, by: author, reason: "Cancelled", changes: [:])
        }
    }

    // MARK: Writing

    /// Writes the status and `changes` as one revision, with provenance, and
    /// records the `agentRequestStatus` event, in one batch. A `.null` change
    /// removes the attribute.
    @discardableResult
    func transition(
        _ id: ObjectID,
        to status: AgentRequestStatus,
        by author: Origin,
        reason: String,
        run: ObjectID? = nil,
        changes: [String: Value]
    ) throws -> QueuedAgentRequest {
        try store.batch { store in
            let now = clock.now()
            let before = try request(id)
            var dependencies = [id]
            if let run { dependencies.append(run) }
            let provenance = Provenance(
                origin: author, truth: author.defaultTruth, timestamp: now, method: "agent request runner", dependencies: dependencies)
            let record = try store.update(id, by: author, instruction: "Agent request \(status.rawValue)") {
                $0.attributes[QueuedAgentRequest.Keys.status] = Attribute(.string(status.rawValue), provenance: provenance)
                for (key, value) in changes {
                    $0.attributes[key] = value == .null ? nil : Attribute(value, provenance: provenance)
                }
            }
            let after = try QueuedAgentRequest(record: record)
            var payload: [String: Value] = [
                "from": .string(before.status.rawValue), "to": .string(status.rawValue), "reason": .string(reason),
                "attempt": .int(Int64(after.attempts)), "by": .string(String(describing: author)),
            ]
            if let run { payload["run"] = .reference(run) }
            try store.record(
                Event(
                    at: now, kind: .agentRequestStatus, subjects: [id] + (run.map { [$0] } ?? []),
                    summary: "Agent goal \(status.rawValue): \(before.goal)", payload: payload, provenance: provenance))
            return after
        }
    }
}

/// Runs the agent goals automations queue (`agentRequest` objects) through
/// the `AgentRuntime`, with its permission engine.
///
/// - **Status.** pending → running → done / failed / blocked, each change an
///   attribute revision with provenance plus an `agentRequestStatus` event.
///   The request is linked `handledBy` to each agent run, and keeps the latest
///   run, its status and output.
/// - **Never twice.** A request is claimed (pending → running) in one store
///   batch before its run starts. A request left `running` by an earlier
///   session (the app quit mid-run) is marked failed, not run again. Only a
///   person approving a blocked request sends it back to pending.
/// - **Nobody auto-approves.** Unattended runs answer every approval prompt
///   "no" and remember what was asked. A run that needed one ends `blocked`
///   with those permissions listed. A person who approves them lets the next
///   attempt use exactly those permissions; nothing else changes. Policy
///   grants and earlier approvals apply as they do for interactive runs.
/// - **Limits.** At most `maxConcurrent` runs at once, and at most
///   `rateLimit.count` starts per `rateLimit.per` seconds, counted from the
///   store so a restart doesn't reset it.
///
/// Run one runner per store.
public final class AgentRequestRunner: @unchecked Sendable {
    public struct RateLimit: Sendable, Hashable {
        public var count: Int
        public var per: TimeInterval

        public init(count: Int, per: TimeInterval) {
            self.count = count
            self.per = per
        }
    }

    public let agents: AgentRuntime
    public var store: NexusStore { agents.store }
    /// Profiles by id; a request naming another profile fails.
    public let profiles: [String: AgentProfile]
    public let maxConcurrent: Int
    public let rateLimit: RateLimit
    /// Default privacy for runs; `drain(privacy:)` can override it.
    public let privacy: PrivacyRequirement
    public let queue: AgentRequestQueue
    let clock: NexusClock
    /// Identifies this runner's claims, to tell its own runs from interrupted
    /// ones. Runners that replace each other within one app launch share it.
    let session: String

    private let lock = NSLock()
    private var inFlight: Set<ObjectID> = []
    private var recovered = false

    public init(
        agents: AgentRuntime,
        profiles: [AgentProfile] = AgentProfile.specialists + [.coordinator],
        maxConcurrent: Int = 1,
        rateLimit: RateLimit = RateLimit(count: 10, per: 3_600),
        privacy: PrivacyRequirement = .onDeviceOnly,
        session: String = UUID().uuidString,
        clock: NexusClock = SystemClock()
    ) {
        self.agents = agents
        self.profiles = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.maxConcurrent = max(1, maxConcurrent)
        self.rateLimit = rateLimit
        self.privacy = privacy
        self.session = session
        self.clock = clock
        queue = AgentRequestQueue(store: agents.store, clock: clock)
    }

    // MARK: Reading and decisions

    public func requests() throws -> [QueuedAgentRequest] { try queue.requests() }

    public func request(_ id: ObjectID) throws -> QueuedAgentRequest { try queue.request(id) }

    /// See `AgentRequestQueue.approve(_:by:)`.
    @discardableResult
    public func approve(_ id: ObjectID, by author: Origin) throws -> QueuedAgentRequest { try queue.approve(id, by: author) }

    /// See `AgentRequestQueue.cancel(_:by:)`.
    @discardableResult
    public func cancel(_ id: ObjectID, by author: Origin) throws -> QueuedAgentRequest { try queue.cancel(id, by: author) }

    // MARK: Running

    /// Claims what the limits allow and runs it; returns once those runs end.
    /// Safe to call often and from several places: a request is only ever
    /// claimed once, and calls beyond the concurrency limit claim nothing.
    @discardableResult
    public func drain(privacy: PrivacyRequirement? = nil) async throws -> [QueuedAgentRequest] {
        try recoverInterrupted()
        let claimed = try claim()
        let privacy = privacy ?? self.privacy
        guard !claimed.isEmpty else { return [] }
        let finished = await withTaskGroup(of: QueuedAgentRequest?.self) { group in
            for request in claimed {
                group.addTask { await self.execute(request, privacy: privacy) }
            }
            var finished: [QueuedAgentRequest] = []
            for await request in group {
                if let request { finished.append(request) }
            }
            return finished
        }
        return finished.sorted { ($0.requestedAt, $0.id) < ($1.requestedAt, $1.id) }
    }

    /// Requests left `running` by another session were interrupted: they are
    /// marked failed, once, and never run again.
    func recoverInterrupted() throws {
        let first = lock.withLock {
            defer { recovered = true }
            return !recovered
        }
        guard first else { return }
        for request in try requests() where request.status == .running && request.runner != session {
            try queue.transition(
                request.id, to: .failed, by: .system, reason: "Interrupted before it finished (the app stopped); not run again",
                changes: [QueuedAgentRequest.Keys.error: .string("Interrupted before it finished; not run again")])
        }
    }

    /// Moves pending requests to running, oldest first, within the limits.
    func claim() throws -> [QueuedAgentRequest] {
        try lock.withLock {
            let now = clock.now()
            let all = try requests()
            let recent = all.filter { $0.startedAt.map { now.timeIntervalSince($0) < rateLimit.per } ?? false }.count
            let room = min(maxConcurrent - inFlight.count, rateLimit.count - recent)
            guard room > 0 else { return [] }
            let pending = all.filter { $0.status == .pending && !inFlight.contains($0.id) }.prefix(room)
            var claimed: [QueuedAgentRequest] = []
            for request in pending {
                let updated = try store.batch { _ -> QueuedAgentRequest? in
                    // Re-read inside the batch: only a request still pending is claimed.
                    guard try queue.request(request.id).status == .pending else { return nil }
                    return try queue.transition(
                        request.id, to: .running, by: .system, reason: "Started attempt \(request.attempts + 1)",
                        changes: [
                            QueuedAgentRequest.Keys.attempts: .int(Int64(request.attempts + 1)), QueuedAgentRequest.Keys.startedAt: .date(now),
                            QueuedAgentRequest.Keys.runner: .string(session), QueuedAgentRequest.Keys.error: .null,
                        ])
                }
                if let updated {
                    inFlight.insert(updated.id)
                    claimed.append(updated)
                }
            }
            return claimed
        }
    }

    /// Runs one claimed request to its end state. Nil only when even
    /// recording the outcome failed; the request then stays `running` and is
    /// recovered as interrupted by the next session.
    private func execute(_ request: QueuedAgentRequest, privacy: PrivacyRequirement) async -> QueuedAgentRequest? {
        defer { _ = lock.withLock { inFlight.remove(request.id) } }
        guard let profile = profiles[request.profile] else {
            return try? queue.transition(
                request.id, to: .failed, by: .system, reason: "Unknown agent profile \"\(request.profile)\"",
                changes: [QueuedAgentRequest.Keys.error: .string("Unknown agent profile \(request.profile)")])
        }
        let approver = UnattendedApprover(approved: request.approved)
        do {
            let goal = AgentRequest(goal: request.goal, project: try project(of: request), focus: request.subjects, privacy: privacy)
            let result = try await agents.run(goal, as: profile, approver: approver)
            let needs = approver.declined
            let status: AgentRequestStatus =
                if !needs.isEmpty {
                    .blocked
                } else {
                    switch result.status {
                    case .completed, .unverified: .done
                    case .cancelled: .cancelled
                    case .running, .refused, .stopped, .failed: .failed
                    }
                }
            var changes: [String: Value] = [
                QueuedAgentRequest.Keys.run: .reference(result.run), QueuedAgentRequest.Keys.runStatus: .string(result.status.rawValue),
                QueuedAgentRequest.Keys.needs: try ValueCoding.encode(needs), QueuedAgentRequest.Keys.finishedAt: .date(clock.now()),
            ]
            if status == .failed { changes[QueuedAgentRequest.Keys.error] = .string("The agent run ended \(result.status.rawValue)") }
            let reason =
                needs.isEmpty
                ? "Agent run \(result.status.rawValue)"
                : "Needs a person to approve: " + needs.map { "\($0.action) (P\($0.level.rawValue))" }.joined(separator: ", ")
            return try store.batch { store in
                if !result.output.isEmpty {
                    try store.update(request.id, by: .system, instruction: "Agent output") {
                        $0.attributes[QueuedAgentRequest.Keys.output] = Attribute(
                            .string(result.output),
                            provenance: Provenance(
                                origin: .agent(id: profile.id, run: result.run), truth: .agentInterpretation, timestamp: clock.now(),
                                method: "agent run", dependencies: [result.run]))
                    }
                }
                try store.relate(
                    Relationship(
                        kind: .handledBy, from: request.id, to: result.run,
                        provenance: Provenance(origin: .system, truth: .recorded, timestamp: clock.now(), method: "agent request runner")))
                return try queue.transition(request.id, to: status, by: .system, reason: reason, run: result.run, changes: changes)
            }
        } catch {
            return try? queue.transition(
                request.id, to: .failed, by: .system, reason: "The agent run failed: \(error)",
                changes: [QueuedAgentRequest.Keys.error: .string(String(describing: error)), QueuedAgentRequest.Keys.finishedAt: .date(clock.now())])
        }
    }

    /// The project of the automation that queued the request, for permission scoping.
    private func project(of request: QueuedAgentRequest) throws -> ObjectID? {
        guard let automation = request.automation, let record = try store.object(automation) else { return nil }
        if case .reference(let project)? = record.attributes[AutomationRule.Keys.project]?.value { return project }
        return nil
    }
}

/// The approver for unattended runs: says yes only to what a person already
/// approved for this request, and no to everything else, remembering it.
final class UnattendedApprover: ApprovalHandler, @unchecked Sendable {
    private let lock = NSLock()
    private let approved: [NeededPermission]
    private var asked: [NeededPermission] = []

    init(approved: [NeededPermission]) {
        self.approved = approved
    }

    var declined: [NeededPermission] { lock.withLock { asked } }

    func approve(_ request: PermissionRequest, reason: String) async -> Bool {
        lock.withLock {
            if approved.contains(where: { $0.covers(request) }) { return true }
            if !asked.contains(where: { $0.covers(request) }) { asked.append(NeededPermission(request, reason: reason)) }
            return false
        }
    }
}
