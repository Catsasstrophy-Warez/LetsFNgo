import Foundation
import NexusCore
import NexusModel

extension EventKind {
    /// A task moved between statuses. Payload: `from`, `to`, optional `reason`.
    public static let taskStatusChanged: EventKind = "taskStatusChanged"
}

extension RelationKind {
    /// Task → an object offered as evidence that the task's work was done.
    public static let evidencedBy: RelationKind = "evidencedBy"
}

/// Where a task is in its lifecycle.
///
/// - `open`, `inProgress` and `blocked` move freely among each other, except
///   that a blocked task must be unblocked before it can be done.
/// - Any of them can be cancelled; `open` and `inProgress` can be done.
/// - `done` and `cancelled` are terminal except for an explicit reopen to `open`.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case open
    case inProgress
    case blocked
    case done
    case cancelled

    /// Statuses this one may move to.
    public var allowedNext: Set<TaskStatus> {
        switch self {
        case .open: [.inProgress, .blocked, .done, .cancelled]
        case .inProgress: [.open, .blocked, .done, .cancelled]
        case .blocked: [.open, .inProgress, .cancelled]
        case .done, .cancelled: [.open]
        }
    }

    public func canMove(to next: TaskStatus) -> Bool { allowedNext.contains(next) }

    /// Work on the task is finished, one way or the other.
    public var isClosed: Bool { self == .done || self == .cancelled }
}

/// Evidence that must exist before a task can be marked done.
public enum EvidenceRequirement: Sendable, Hashable {
    /// This specific object must exist and not be deleted, e.g. a verification measurement.
    case object(ObjectID)
    /// At least one live object of this type must be attached with `attachEvidence`.
    case attached(ObjectType)

    var value: Value {
        switch self {
        case .object(let id): .map(["kind": .string("object"), "id": .reference(id)])
        case .attached(let type): .map(["kind": .string("attached"), "type": .string(type.rawValue)])
        }
    }

    init?(_ value: Value) {
        guard case .map(let fields) = value, case .string(let kind)? = fields["kind"] else { return nil }
        switch (kind, fields["id"], fields["type"]) {
        case ("object", .reference(let id)?, _): self = .object(id)
        case ("attached", _, .string(let type)?): self = .attached(ObjectType(rawValue: type))
        default: return nil
        }
    }
}

public enum TaskError: Error, Equatable, Sendable {
    case notATask(ObjectID)
    case corruptTask(ObjectID, field: String)
    case invalidTransition(ObjectID, from: TaskStatus, to: TaskStatus)
    /// Agents and models may only create tasks as drafts for a person to approve.
    case agentMustDraft(Origin)
    /// Only a person or the system may mark a task done or approve a draft.
    case requiresHuman(Origin)
    /// A draft must be approved before work on it can start.
    case draftNotApproved(ObjectID)
    /// Only drafts can be approved.
    case notADraft(ObjectID)
    case notActive(ObjectID, Lifecycle)
    case dependencyCycle(path: [ObjectID])
    case notADependency(task: ObjectID, dependency: ObjectID)
    /// Completion gate: unfinished dependencies and missing evidence.
    case gateClosed(ObjectID, unfinishedDependencies: [ObjectID], missingEvidence: [EvidenceRequirement])
}

/// A task: a `.task` object in the canonical store, read through a typed view.
/// All state lives in the object's attributes and relationships; this struct
/// is never stored on its own.
public struct TaskItem: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public init(record: ObjectRecord) throws {
        guard record.type == .task else { throw TaskError.notATask(record.id) }
        guard case .string(let raw)? = record.attributes[Keys.status]?.value, TaskStatus(rawValue: raw) != nil else {
            throw TaskError.corruptTask(record.id, field: Keys.status)
        }
        // A missing owner falls back to the creator; a malformed one is corruption.
        if let ownerValue = record.attributes[Keys.owner]?.value, Origin(value: ownerValue) == nil {
            throw TaskError.corruptTask(record.id, field: Keys.owner)
        }
        self.record = record
    }

    public var id: ObjectID { record.id }
    public var title: String { record.title }
    public var lifecycle: Lifecycle { record.lifecycle }
    public var isDraft: Bool { record.lifecycle == .draft }

    public var status: TaskStatus {
        guard case .string(let raw)? = record.attributes[Keys.status]?.value else { return .open }
        return TaskStatus(rawValue: raw) ?? .open
    }

    /// Who is responsible for the task. Defaults to its creator.
    public var owner: Origin {
        record.attributes[Keys.owner].flatMap { Origin(value: $0.value) } ?? record.provenance.origin
    }

    /// What "done" means, in words a person can check.
    public var successCondition: String? {
        guard case .string(let text)? = record.attributes[Keys.successCondition]?.value else { return nil }
        return text
    }

    public var dueAt: Date? {
        guard case .date(let date)? = record.attributes[Keys.dueAt]?.value else { return nil }
        return date
    }

    public var requiredEvidence: [EvidenceRequirement] {
        guard case .list(let values)? = record.attributes[Keys.requiredEvidence]?.value else { return [] }
        return values.compactMap(EvidenceRequirement.init)
    }

    enum Keys {
        static let status = "status"
        static let owner = "owner"
        static let successCondition = "successCondition"
        static let dueAt = "dueAt"
        static let requiredEvidence = "requiredEvidence"
        static let completedAt = "completedAt"
    }
}

extension Origin {
    /// Agents and models: authors whose work a person must approve.
    var isAI: Bool {
        switch self {
        case .agent, .model: true
        default: false
        }
    }

    var isHuman: Bool {
        switch self {
        case .user, .system: true
        default: false
        }
    }

    /// Structured attribute form, so an owner stays queryable and readable
    /// in the stored JSON rather than being an opaque string.
    var value: Value {
        switch self {
        case .user(let id): return .map(["kind": .string("user"), "id": .string(id)])
        case .agent(let id, let run):
            return .map(["kind": .string("agent"), "id": .string(id), "run": run.map(Value.reference) ?? .null])
        case .importer(let source): return .map(["kind": .string("importer"), "source": .reference(source)])
        case .simulation(let run): return .map(["kind": .string("simulation"), "run": .reference(run)])
        case .instrument(let id): return .map(["kind": .string("instrument"), "id": .reference(id)])
        case .model(let ref):
            var fields: [String: Value] = [
                "kind": .string("model"), "provider": .string(ref.provider), "modelID": .string(ref.modelID),
            ]
            if let adapterID = ref.adapterID { fields["adapterID"] = .string(adapterID) }
            if let adapterVersion = ref.adapterVersion { fields["adapterVersion"] = .string(adapterVersion) }
            if let promptHash = ref.promptHash { fields["promptHash"] = .string(promptHash) }
            return .map(fields)
        case .system: return .map(["kind": .string("system")])
        }
    }

    init?(value: Value) {
        guard case .map(let fields) = value, case .string(let kind)? = fields["kind"] else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let text)? = fields[key] { return text }
            return nil
        }
        func reference(_ key: String) -> ObjectID? {
            if case .reference(let id)? = fields[key] { return id }
            return nil
        }
        switch kind {
        case "user":
            guard let id = string("id") else { return nil }
            self = .user(id: id)
        case "agent":
            guard let id = string("id") else { return nil }
            self = .agent(id: id, run: reference("run"))
        case "importer":
            guard let source = reference("source") else { return nil }
            self = .importer(source: source)
        case "simulation":
            guard let run = reference("run") else { return nil }
            self = .simulation(run: run)
        case "instrument":
            guard let id = reference("id") else { return nil }
            self = .instrument(id: id)
        case "model":
            guard let provider = string("provider"), let modelID = string("modelID") else { return nil }
            self = .model(ModelRef(
                provider: provider, modelID: modelID, adapterID: string("adapterID"),
                adapterVersion: string("adapterVersion"), promptHash: string("promptHash")
            ))
        case "system":
            self = .system
        default:
            return nil
        }
    }
}
