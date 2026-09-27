import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence

/// What stands between a task and `done`.
public struct TaskGate: Sendable, Hashable {
    /// Dependencies not yet done. A cancelled dependency still blocks until it
    /// is removed: cancelling prerequisite work does not make it happen.
    public var unfinishedDependencies: [ObjectID]
    public var missingEvidence: [EvidenceRequirement]

    public var isOpen: Bool { unfinishedDependencies.isEmpty && missingEvidence.isEmpty }
}

/// Task and workflow runtime over the canonical store.
///
/// Tasks are `.task` objects; dependencies are current `dependsOn`
/// relationships between tasks; project membership is `contains` from the
/// project; evidence is `evidencedBy` from the task. Every status change is a
/// new revision of the task plus a `taskStatusChanged` event, in one batch.
///
/// Agents and models may propose work but not commit to it: they create tasks
/// only as `.draft` for a person to approve, and can never mark a task done.
/// The store's `TruthPolicy` applies as usual, so an agent cannot overwrite
/// the status of a task a person recorded.
public struct TaskRuntime: Sendable {
    public let store: NexusStore
    public let graph: ObjectGraph
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.graph = ObjectGraph(store: store, clock: clock)
        self.clock = clock
    }

    // MARK: Creating

    /// Creates an open task.
    ///
    /// - Parameters:
    ///   - owner: who is responsible; defaults to `author`.
    ///   - dependsOn: tasks that must be done first.
    ///   - project: container that should `contain` the task.
    ///   - lifecycle: defaults to `.draft` for agents and models, `.active`
    ///     otherwise. Agents and models may not ask for anything but `.draft`.
    ///   - attributes: extra domain attributes (a meeting line, the case a
    ///     repair belongs to). They cannot replace the task's own fields.
    @discardableResult
    public func create(
        _ title: String,
        successCondition: String? = nil,
        owner: Origin? = nil,
        dueAt: Date? = nil,
        requiredEvidence: [EvidenceRequirement] = [],
        dependsOn dependencies: [ObjectID] = [],
        in project: ObjectID? = nil,
        lifecycle: Lifecycle? = nil,
        attributes extra: [String: Attribute] = [:],
        by author: Origin
    ) throws -> TaskItem {
        if author.isAI, let lifecycle, lifecycle != .draft { throw TaskError.agentMustDraft(author) }
        let lifecycle = lifecycle ?? (author.isAI ? .draft : .active)
        return try store.batch { store in
            let now = clock.now()
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
            var attributes: [String: Attribute] = extra
            attributes.merge([
                TaskItem.Keys.status: Attribute(.string(TaskStatus.open.rawValue)),
                TaskItem.Keys.owner: Attribute((owner ?? author).value),
            ]) { _, own in own }
            if let successCondition { attributes[TaskItem.Keys.successCondition] = Attribute(.string(successCondition)) }
            if let dueAt { attributes[TaskItem.Keys.dueAt] = Attribute(.date(dueAt)) }
            if !requiredEvidence.isEmpty {
                attributes[TaskItem.Keys.requiredEvidence] = Attribute(.list(requiredEvidence.map(\.value)))
            }
            let record = try store.create(ObjectRecord(
                type: .task, title: title, attributes: attributes, lifecycle: lifecycle, provenance: provenance
            ))
            if let project {
                try store.relate(Relationship(kind: .contains, from: project, to: record.id, validFrom: now, provenance: provenance))
            }
            for dependency in dependencies {
                try addDependency(record.id, on: dependency, by: author)
            }
            return try TaskItem(record: record)
        }
    }

    /// Promotes an agent's draft to an active task. People only.
    @discardableResult
    public func approve(_ id: ObjectID, by author: Origin) throws -> TaskItem {
        guard author.isHuman else { throw TaskError.requiresHuman(author) }
        let task = try task(id)
        guard task.isDraft else { throw TaskError.notADraft(id) }
        return try TaskItem(record: store.update(id, by: author, instruction: "Approved draft task") {
            $0.lifecycle = .active
        })
    }

    /// Hands the task to a new owner.
    @discardableResult
    public func assign(_ id: ObjectID, to owner: Origin, by author: Origin) throws -> TaskItem {
        _ = try task(id)
        return try TaskItem(record: store.update(id, by: author, instruction: "Assigned") {
            $0.attributes[TaskItem.Keys.owner] = Attribute(owner.value, provenance: provenance(author))
        })
    }

    // MARK: Reading

    public func task(_ id: ObjectID) throws -> TaskItem {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        return try TaskItem(record: record)
    }

    /// Every task that is not deleted, oldest first.
    public func allTasks() throws -> [TaskItem] {
        try store.objects(ofType: .task).filter { $0.lifecycle != .deleted }.map(TaskItem.init(record:))
    }

    /// Tasks a project contains, directly or through nested containment.
    public func tasks(in project: ObjectID, transitive: Bool = true) throws -> [TaskItem] {
        let reached = try graph.traverse(from: project, kinds: [.contains], direction: .outgoing, maxDepth: transitive ? .max : 1)
        return try store.objects(reached.map(\.id).sorted())
            .filter { $0.type == .task && $0.lifecycle != .deleted }
            .map(TaskItem.init(record:))
    }

    /// Open, approved tasks whose dependencies are all done: work that can start now.
    public func ready(in project: ObjectID? = nil) throws -> [TaskItem] {
        try candidates(in: project).filter { task in
            guard task.status == .open, task.lifecycle == .active else { return false }
            return try unfinishedDependencies(of: task.id).isEmpty
        }
    }

    /// Tasks marked blocked, plus open or in-progress tasks waiting on an unfinished dependency.
    public func blocked(in project: ObjectID? = nil) throws -> [TaskItem] {
        try candidates(in: project).filter { task in
            switch task.status {
            case .blocked: true
            case .open, .inProgress: try !unfinishedDependencies(of: task.id).isEmpty
            case .done, .cancelled: false
            }
        }
    }

    /// Unclosed tasks due before `date`.
    public func overdue(at date: Date, in project: ObjectID? = nil) throws -> [TaskItem] {
        try candidates(in: project).filter { task in
            guard let due = task.dueAt else { return false }
            return !task.status.isClosed && due < date
        }
    }

    // MARK: Dependencies

    /// Makes `id` depend on `dependency`. Refuses anything that would close a cycle.
    @discardableResult
    public func addDependency(_ id: ObjectID, on dependency: ObjectID, by author: Origin) throws -> Relationship {
        try store.batch { store in
            _ = try task(id)
            _ = try task(dependency)
            if id == dependency { throw TaskError.dependencyCycle(path: [id, id]) }
            if let existing = try currentDependency(id, on: dependency) { return existing }
            // A path dependency → … → id means the new edge would close a loop.
            if let path = try graph.shortestPath(
                from: dependency, to: id, kinds: [.dependsOn], direction: .outgoing, maxDepth: .max
            ) {
                throw TaskError.dependencyCycle(path: [id, dependency] + path.map(\.neighbor))
            }
            let now = clock.now()
            return try store.relate(Relationship(
                kind: .dependsOn, from: id, to: dependency, validFrom: now, provenance: provenance(author, at: now)
            ))
        }
    }

    /// Ends the dependency. The relationship is kept as history.
    public func removeDependency(_ id: ObjectID, on dependency: ObjectID, by author: Origin) throws {
        guard let relationship = try currentDependency(id, on: dependency) else {
            throw TaskError.notADependency(task: id, dependency: dependency)
        }
        try store.end(relationship.id, at: clock.now(), by: author)
    }

    /// Tasks `id` currently depends on directly.
    public func dependencies(of id: ObjectID) throws -> [TaskItem] {
        let ids = try graph.edges(of: id, kinds: [.dependsOn], direction: .outgoing).map(\.neighbor)
        return try store.objects(ids).map(TaskItem.init(record:))
    }

    /// Tasks that currently depend on `id` directly.
    public func dependents(of id: ObjectID) throws -> [TaskItem] {
        let ids = try graph.edges(of: id, kinds: [.dependsOn], direction: .incoming).map(\.neighbor)
        return try store.objects(ids).map(TaskItem.init(record:))
    }

    // MARK: Evidence and gates

    /// Links an object (a measurement, a report, a photo) as evidence for the task.
    @discardableResult
    public func attachEvidence(_ evidence: ObjectID, to id: ObjectID, by author: Origin) throws -> Relationship {
        _ = try task(id)
        let now = clock.now()
        return try store.relate(Relationship(
            kind: .evidencedBy, from: id, to: evidence, validFrom: now, provenance: provenance(author, at: now)
        ))
    }

    /// What must still happen before the task may be marked done.
    public func gate(for id: ObjectID) throws -> TaskGate {
        let task = try task(id)
        var missing: [EvidenceRequirement] = []
        var attachedTypes: Set<ObjectType>?
        for requirement in task.requiredEvidence {
            switch requirement {
            case .object(let evidence):
                if try store.object(evidence).map({ $0.lifecycle == .deleted }) ?? true { missing.append(requirement) }
            case .attached(let type):
                if attachedTypes == nil {
                    let ids = try graph.edges(of: id, kinds: [.evidencedBy], direction: .outgoing).map(\.neighbor)
                    attachedTypes = Set(try store.objects(ids).filter { $0.lifecycle != .deleted }.map(\.type))
                }
                if !(attachedTypes?.contains(type) ?? false) { missing.append(requirement) }
            }
        }
        return TaskGate(unfinishedDependencies: try unfinishedDependencies(of: id), missingEvidence: missing)
    }

    // MARK: Status

    /// Moves a task to `status`, as a new revision plus a `taskStatusChanged` event.
    ///
    /// Throws for transitions `TaskStatus` does not allow, for agents marking
    /// work done, for any start on an unapproved draft, and for completion
    /// while the gate is closed.
    @discardableResult
    public func setStatus(_ status: TaskStatus, of id: ObjectID, reason: String? = nil, by author: Origin) throws -> TaskItem {
        try store.batch { store in
            let task = try task(id)
            let from = task.status
            guard from.canMove(to: status) else { throw TaskError.invalidTransition(id, from: from, to: status) }
            if status == .done, !author.isHuman { throw TaskError.requiresHuman(author) }
            switch task.lifecycle {
            case .active: break
            case .draft: if status != .cancelled { throw TaskError.draftNotApproved(id) }
            case .archived, .deleted: throw TaskError.notActive(id, task.lifecycle)
            }
            if status == .done {
                let gate = try gate(for: id)
                guard gate.isOpen else {
                    throw TaskError.gateClosed(
                        id, unfinishedDependencies: gate.unfinishedDependencies, missingEvidence: gate.missingEvidence
                    )
                }
            }

            let now = clock.now()
            let stamp = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "task status transition")
            var instruction = "Status \(from.rawValue) → \(status.rawValue)"
            if let reason { instruction += ": \(reason)" }
            let updated = try store.update(id, by: author, instruction: instruction) {
                $0.attributes[TaskItem.Keys.status] = Attribute(.string(status.rawValue), provenance: stamp)
                if status == .done {
                    $0.attributes[TaskItem.Keys.completedAt] = Attribute(.date(now), provenance: stamp)
                } else {
                    $0.attributes[TaskItem.Keys.completedAt] = nil
                }
            }
            var payload: [String: Value] = ["from": .string(from.rawValue), "to": .string(status.rawValue)]
            if let reason { payload["reason"] = .string(reason) }
            var eventProvenance = stamp
            eventProvenance.revision = updated.revision
            try store.record(Event(
                at: now, kind: .taskStatusChanged, subjects: [id], summary: "\(task.title): \(instruction)",
                payload: payload, provenance: eventProvenance
            ))
            return try TaskItem(record: updated)
        }
    }

    // MARK: Private

    private func candidates(in project: ObjectID?) throws -> [TaskItem] {
        if let project { return try tasks(in: project) }
        return try allTasks()
    }

    private func unfinishedDependencies(of id: ObjectID) throws -> [ObjectID] {
        try dependencies(of: id).filter { $0.status != .done }.map(\.id)
    }

    private func currentDependency(_ id: ObjectID, on dependency: ObjectID) throws -> Relationship? {
        try graph.edges(of: id, kinds: [.dependsOn], direction: .outgoing).first { $0.neighbor == dependency }?.relationship
    }

    private func provenance(_ author: Origin, at date: Date? = nil) -> Provenance {
        Provenance(origin: author, truth: author.defaultTruth, timestamp: date ?? clock.now())
    }
}
