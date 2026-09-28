import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// "Start this task when …": a task tied to a future system state.
///
/// The condition itself is a structured value this module stores but does not
/// interpret; `NexusAutomation.SystemCondition` writes and evaluates it. The
/// text is kept beside it so any screen (the Calendar, a task list) can say
/// "starts when TB-4 voltage > 20 V" without knowing the condition model.
public struct TaskStartCondition: Sendable, Hashable {
    public var task: ObjectID
    /// The structured condition, as stored.
    public var condition: Value
    /// The condition in words, e.g. "TB-4 voltage > 20 V".
    public var text: String
    /// Where the task goes when the condition holds: `open` (ready) or `inProgress`.
    public var startAs: TaskStatus
    /// When the condition was met and the task started; nil while it waits.
    public var metAt: Date?
    /// Why it started, e.g. the reading that satisfied the condition.
    public var metReason: String?

    public var isWaiting: Bool { metAt == nil }

    /// "starts when TB-4 voltage > 20 V", or "started: …" once met.
    public var label: String {
        guard metAt != nil else { return "starts when \(text)" }
        return "started: \(metReason ?? text)"
    }
}

extension TaskRuntime {
    enum ConditionKeys {
        static let startsWhen = "startsWhen"
        static let startsWhenText = "startsWhenText"
        static let startsAs = "startsAs"
        static let startsWhenMetAt = "startsWhenMetAt"
        static let startsWhenReason = "startsWhenReason"
    }

    /// Makes the task wait for `condition`. An open or in-progress task is
    /// moved to `blocked` with the condition as the reason; the automation
    /// runtime moves it to `startAs` when the condition holds.
    ///
    /// Throws for closed tasks and drafts, and when `startAs` is neither
    /// `open` nor `inProgress`.
    @discardableResult
    public func setStartCondition(
        _ condition: Value,
        text: String,
        startAs: TaskStatus = .open,
        on id: ObjectID,
        by author: Origin
    ) throws -> TaskItem {
        try store.batch { store in
            let task = try task(id)
            guard startAs == .open || startAs == .inProgress else {
                throw TaskError.invalidTransition(id, from: .blocked, to: startAs)
            }
            guard task.lifecycle == .active else {
                if task.isDraft { throw TaskError.draftNotApproved(id) }
                throw TaskError.notActive(id, task.lifecycle)
            }
            guard !task.status.isClosed else { throw TaskError.invalidTransition(id, from: task.status, to: .blocked) }
            let stamp = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "start condition")
            try store.update(id, by: author, instruction: "Starts when \(text)") {
                $0.attributes[ConditionKeys.startsWhen] = Attribute(condition, provenance: stamp)
                $0.attributes[ConditionKeys.startsWhenText] = Attribute(.string(text), provenance: stamp)
                $0.attributes[ConditionKeys.startsAs] = Attribute(.string(startAs.rawValue), provenance: stamp)
                $0.attributes[ConditionKeys.startsWhenMetAt] = nil
                $0.attributes[ConditionKeys.startsWhenReason] = nil
            }
            if task.status != .blocked {
                return try setStatus(.blocked, of: id, reason: "Waiting until \(text)", by: author)
            }
            return try self.task(id)
        }
    }

    /// Removes the start condition. The task's status is left as it is.
    @discardableResult
    public func clearStartCondition(on id: ObjectID, by author: Origin) throws -> TaskItem {
        _ = try task(id)
        return try TaskItem(
            record: store.update(id, by: author, instruction: "Removed start condition") {
                for key in [
                    ConditionKeys.startsWhen, ConditionKeys.startsWhenText, ConditionKeys.startsAs, ConditionKeys.startsWhenMetAt,
                    ConditionKeys.startsWhenReason,
                ] {
                    $0.attributes[key] = nil
                }
            })
    }

    /// The conditions a task starts on: empty for an ordinary task.
    public func conditions(for id: ObjectID) throws -> [TaskStartCondition] {
        let task = try task(id)
        return Self.startCondition(of: task).map { [$0] } ?? []
    }

    /// Active tasks still waiting on a start condition.
    public func waitingOnConditions() throws -> [TaskItem] {
        try allTasks().filter { task in
            guard task.lifecycle == .active, !task.status.isClosed else { return false }
            return Self.startCondition(of: task)?.isWaiting ?? false
        }
    }

    /// Marks the task's condition as met and moves it to its `startAs`
    /// status, logging `reason` on the status change. A task someone already
    /// started by hand keeps its status. Throws if it isn't waiting.
    @discardableResult
    public func activate(_ id: ObjectID, reason: String, by author: Origin) throws -> TaskItem {
        try store.batch { store in
            let task = try task(id)
            guard let condition = Self.startCondition(of: task), condition.isWaiting else {
                throw TaskError.corruptTask(id, field: ConditionKeys.startsWhen)
            }
            let now = clock.now()
            let stamp = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "start condition met")
            try store.update(id, by: author, instruction: "Condition met: \(reason)") {
                $0.attributes[ConditionKeys.startsWhenMetAt] = Attribute(.date(now), provenance: stamp)
                $0.attributes[ConditionKeys.startsWhenReason] = Attribute(.string(reason), provenance: stamp)
            }
            let target = condition.startAs
            let current = try self.task(id).status
            if current != target, current == .blocked || (current == .open && target == .inProgress) {
                return try setStatus(target, of: id, reason: "Started: \(reason)", by: author)
            }
            return try self.task(id)
        }
    }

    static func startCondition(of task: TaskItem) -> TaskStartCondition? {
        let attributes = task.record.attributes
        guard let condition = attributes[ConditionKeys.startsWhen]?.value else { return nil }
        var text = ""
        if case .string(let stored)? = attributes[ConditionKeys.startsWhenText]?.value { text = stored }
        var startAs = TaskStatus.open
        if case .string(let raw)? = attributes[ConditionKeys.startsAs]?.value, let status = TaskStatus(rawValue: raw) { startAs = status }
        var metAt: Date?
        if case .date(let date)? = attributes[ConditionKeys.startsWhenMetAt]?.value { metAt = date }
        var reason: String?
        if case .string(let stored)? = attributes[ConditionKeys.startsWhenReason]?.value { reason = stored }
        return TaskStartCondition(task: task.id, condition: condition, text: text, startAs: startAs, metAt: metAt, metReason: reason)
    }
}
