import Foundation
import NexusActions
import NexusCore
import NexusModel
import NexusPermissions
import NexusProjects
import NexusTasks

extension ObjectType {
    /// A rule: trigger, conditions, actions, owner. See `AutomationRule`.
    public static let automation: ObjectType = "automation"
    /// A goal an automation hands to the agent runtime. The app runs it;
    /// automations never call models themselves.
    public static let agentRequest: ObjectType = "agentRequest"
}

extension EventKind {
    /// One firing of an automation, whatever its outcome. Subjects: the rule,
    /// the trigger's subject and what the firing produced. See `AutomationRun`.
    public static let automationRun: EventKind = "automationRun"
    /// A notice for people. Payload: `message`, `severity`, `external`, `automation`.
    public static let notification: EventKind = "notification"
    /// An automation queued an agent goal. Payload: `profile`, `goal`, `automation`.
    public static let agentRequested: EventKind = "agentRequested"
}

// MARK: Comparisons and conditions

public enum Comparison: String, Codable, Sendable, Hashable, CaseIterable {
    case lessThan = "<"
    case lessOrEqual = "<="
    case greaterThan = ">"
    case greaterOrEqual = ">="
    case equal = "=="
    case notEqual = "!="

    public var symbol: String {
        switch self {
        case .equal: "="
        case .notEqual: "≠"
        case .lessOrEqual: "≤"
        case .greaterOrEqual: "≥"
        default: rawValue
        }
    }

    public func holds(_ lhs: Double, _ rhs: Double) -> Bool {
        switch self {
        case .lessThan: lhs < rhs
        case .lessOrEqual: lhs <= rhs
        case .greaterThan: lhs > rhs
        case .greaterOrEqual: lhs >= rhs
        case .equal: lhs == rhs
        case .notEqual: lhs != rhs
        }
    }

    /// Numbers (and quantities in the same unit) compare by value; anything
    /// else only by equality. Nil when the values can't be compared.
    public func holds(_ lhs: Value, _ rhs: Value) -> Bool? {
        if case .quantity(let left) = lhs, case .quantity(let right) = rhs {
            guard left.unit == right.unit else { return nil }
            return holds(left.value, right.value)
        }
        if let left = lhs.number, let right = rhs.number { return holds(left, right) }
        switch self {
        case .equal: return lhs == rhs
        case .notEqual: return lhs != rhs
        default: return nil
        }
    }
}

extension Value {
    var number: Double? {
        switch self {
        case .double(let number): number
        case .int(let number): Double(number)
        case .quantity(let quantity): quantity.value
        default: nil
        }
    }

    var displayText: String {
        switch self {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): Self.format(number)
        case .bool(let flag): flag ? "true" : "false"
        case .date(let date): date.description
        case .quantity(let quantity): "\(Self.format(quantity.value)) \(quantity.unit)"
        case .reference(let id): id.description
        case .list(let values): values.map(\.displayText).joined(separator: ", ")
        case .map: "…"
        case .null: "none"
        }
    }

    static func format(_ number: Double) -> String { String(format: "%g", number) }
}

/// Only measured or recorded values count by default: a simulation never
/// trips an automation meant for the real plant.
public let observedOrRecorded: [TruthClass] = [.observed, .recorded]

/// A state of the world that holds or doesn't, now. Used for a rule's extra
/// conditions and for tasks that start "when …".
public indirect enum SystemCondition: Codable, Sendable, Hashable {
    /// The latest reading of `quantity` at `testPoint`, among readings of the
    /// given truth classes, compares to `value` (same unit).
    case measurement(testPoint: ObjectID, quantity: String, comparison: Comparison, value: Quantity, truths: [TruthClass] = observedOrRecorded)
    /// An object's attribute compares to `value`. `truths` limits which truth
    /// classes of the stored value count; nil accepts any.
    case attribute(object: ObjectID, key: String, comparison: Comparison, value: Value, truths: [TruthClass]? = nil)
    case taskStatus(task: ObjectID, status: TaskStatus)
    /// The clock has reached `date`.
    case after(Date)
    case all([SystemCondition])
    case any([SystemCondition])
}

// MARK: Triggers

public struct MeasurementThreshold: Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable, Hashable {
        /// Fires when a reading drops below the threshold; re-arms at or above threshold + hysteresis.
        case below
        /// Fires when a reading rises above the threshold; re-arms at or below threshold − hysteresis.
        case above
    }

    public var testPoint: ObjectID
    public var quantity: String
    public var direction: Direction
    public var threshold: Quantity
    /// Dead band, in the threshold's unit, the reading must leave before the rule can fire again.
    public var hysteresis: Double
    /// Readings of other truth classes are ignored entirely. Default observed and recorded, never modeled.
    public var truths: [TruthClass]

    public init(
        testPoint: ObjectID,
        quantity: String,
        _ direction: Direction,
        _ threshold: Quantity,
        hysteresis: Double = 0,
        truths: [TruthClass] = observedOrRecorded
    ) {
        self.testPoint = testPoint
        self.quantity = quantity
        self.direction = direction
        self.threshold = threshold
        self.hysteresis = hysteresis
        self.truths = truths
    }
}

public enum AutomationSchedule: Codable, Sendable, Hashable {
    /// Every `seconds`, first at `startingAt` (default: creation + one interval).
    case every(seconds: TimeInterval, startingAt: Date? = nil)
    /// Once, at `date`.
    case once(at: Date)
}

public enum AutomationTrigger: Codable, Sendable, Hashable {
    /// An event of `kind`, optionally about `subject` or about an object of `subjectType`.
    case event(kind: EventKind, subject: ObjectID? = nil, subjectType: ObjectType? = nil)
    case measurementThreshold(MeasurementThreshold)
    /// A task (or any task, when nil) reaches `status`. Fires on the transition, once per task.
    case taskStatus(task: ObjectID? = nil, status: TaskStatus)
    /// An object's attribute starts to satisfy the comparison. Fires on the transition, once per object.
    case attribute(
        object: ObjectID? = nil, objectType: ObjectType? = nil, key: String, comparison: Comparison, value: Value, truths: [TruthClass]? = nil
    )
    /// Evaluated by `AutomationRuntime.tick(now:)`.
    case schedule(AutomationSchedule)
}

// MARK: Actions

/// Which object an action works on.
public enum AutomationTarget: Codable, Sendable, Hashable {
    case object(ObjectID)
    /// What the trigger was about: the test point, the task, the object, the event's first subject.
    case triggerSubject
    /// The reading that crossed a threshold.
    case triggerMeasurement
    /// The first object the previous action in this firing produced.
    case previousResult
}

public struct CommandAction: Codable, Sendable, Hashable {
    /// A `CommandID` raw value.
    public var command: String
    public var selection: [AutomationTarget]
    /// `ActionParameters` fields by name: strings, numbers, dates and object
    /// IDs only. A string "$subject", "$measurement" or "$previous" stands for
    /// that target's ID; `{subject}`, `{value}` and `{rule}` in text are filled in.
    public var presets: [String: Value]
    /// Raises the command's level, e.g. for a command wired to an outside service.
    public var minimumLevel: PermissionLevel?

    public init(_ command: CommandID, selection: [AutomationTarget] = [], presets: [String: Value] = [:], minimumLevel: PermissionLevel? = nil) {
        self.command = command.rawValue
        self.selection = selection
        self.presets = presets
        self.minimumLevel = minimumLevel
    }

    public var commandID: CommandID { CommandID(rawValue: command) }
}

public struct TaskAction: Codable, Sendable, Hashable {
    /// `{subject}`, `{value}` and `{rule}` are filled in.
    public var title: String
    public var successCondition: String?
    public var project: ObjectID?
    /// Due this long after the firing.
    public var dueIn: TimeInterval?
    /// Create as a draft for a person to approve (P2) rather than active work (P3).
    public var draft: Bool
    /// Objects the task is about, kept as the `about` attribute.
    public var about: [AutomationTarget]
    /// Make the new task wait for this condition.
    public var startsWhen: SystemCondition?

    public init(
        title: String,
        successCondition: String? = nil,
        project: ObjectID? = nil,
        dueIn: TimeInterval? = nil,
        draft: Bool = false,
        about: [AutomationTarget] = [.triggerSubject],
        startsWhen: SystemCondition? = nil
    ) {
        self.title = title
        self.successCondition = successCondition
        self.project = project
        self.dueIn = dueIn
        self.draft = draft
        self.about = about
        self.startsWhen = startsWhen
    }
}

public struct AgentGoalAction: Codable, Sendable, Hashable {
    /// Agent profile id, e.g. "diagnostic".
    public var profile: String
    public var goal: String
    public var subjects: [AutomationTarget]

    public init(profile: String, goal: String, subjects: [AutomationTarget] = [.triggerSubject]) {
        self.profile = profile
        self.goal = goal
        self.subjects = subjects
    }
}

public struct NotifyAction: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable, Hashable { case info, warning, critical }

    public var message: String
    public var severity: Severity
    /// Leaves the app (push, mail, a pager): an external action, P4.
    public var external: Bool
    public var subjects: [AutomationTarget]

    public init(_ message: String, severity: Severity = .info, external: Bool = false, subjects: [AutomationTarget] = [.triggerSubject]) {
        self.message = message
        self.severity = severity
        self.external = external
        self.subjects = subjects
    }
}

public enum AutomationAction: Codable, Sendable, Hashable {
    case command(CommandAction)
    case createTask(TaskAction)
    case startAgent(AgentGoalAction)
    case notify(NotifyAction)

    /// The permission level this action needs.
    public var level: PermissionLevel {
        switch self {
        case .command(let action): max(action.commandID.defaultPermission, action.minimumLevel ?? .observe)
        case .createTask(let action): action.draft ? .createDraft : .modifyInternalState
        case .startAgent: .createDraft
        case .notify(let action): action.external ? .externalAction : .analyze
        }
    }

    /// The action name permission policy matches on.
    public var permissionAction: String {
        switch self {
        case .command(let action): "command.\(action.command)"
        case .createTask: "createTask"
        case .startAgent: "startAgent"
        case .notify(let action): action.external ? "notify.external" : "notify"
        }
    }

    public var kind: String {
        switch self {
        case .command: "command"
        case .createTask: "createTask"
        case .startAgent: "startAgent"
        case .notify: "notify"
        }
    }
}

// MARK: Rule

public enum AutomationError: Error, Equatable, Sendable {
    case notAnAutomation(ObjectID)
    case corruptRule(ObjectID, field: String)
    case noActions
    case commandNeedsInput(String, fields: [String])
    case commandUnsupported(String, reason: String)
    case unresolvedTarget(AutomationTarget)
    /// Only a person or the system may enable a rule or approve a blocked run.
    case requiresHuman(Origin)
    case notAwaitingApproval(ObjectID)
}

/// A rule: an `automation` object in the canonical store, read through a
/// typed view like `TaskItem`.
///
/// Stored attributes: `trigger`, `conditions`, `actions` (structured values,
/// see `ValueCoding`), `owner`, `enabled`, `maxDepth`, `minimumInterval`,
/// optional `project`, and the derived `permissionLevel` (0–5).
public struct AutomationRule: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var title: String
    public var trigger: AutomationTrigger
    /// Extra conditions; all must hold for the rule to fire.
    public var conditions: [SystemCondition]
    public var actions: [AutomationAction]
    /// Whom the rule acts for. A person's rule writes as that person; an
    /// agent's rule writes as the agent, so its tasks are drafts.
    public var owner: Origin
    public var enabled: Bool
    /// How many firings a chain of the rule's own writes may cause.
    public var maxDepth: Int
    /// Minimum seconds between firings; closer triggers are dropped and counted.
    public var minimumInterval: TimeInterval
    /// Project for permission scoping.
    public var project: ObjectID?
    /// The store record, once stored.
    public var record: ObjectRecord?

    public init(
        id: ObjectID = .make(),
        title: String,
        trigger: AutomationTrigger,
        conditions: [SystemCondition] = [],
        actions: [AutomationAction],
        owner: Origin,
        enabled: Bool = true,
        maxDepth: Int = 3,
        minimumInterval: TimeInterval = 0,
        project: ObjectID? = nil
    ) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.conditions = conditions
        self.actions = actions
        self.owner = owner
        self.enabled = enabled
        self.maxDepth = maxDepth
        self.minimumInterval = minimumInterval
        self.project = project
    }

    /// The highest level among the actions.
    public var permissionLevel: PermissionLevel { actions.map(\.level).max() ?? .observe }

    /// The agent name the rule has in permission policy: grant it with
    /// `PolicyRule(agent: rule.agentID, action: …, grant: .always)`.
    public var agentID: String { Self.agentID(for: id) }

    public static func agentID(for id: ObjectID) -> String { "automation:\(id)" }

    enum Keys {
        static let trigger = "trigger"
        static let conditions = "conditions"
        static let actions = "actions"
        static let owner = "owner"
        static let enabled = "enabled"
        static let maxDepth = "maxDepth"
        static let minimumInterval = "minimumInterval"
        static let project = "project"
        static let permissionLevel = "permissionLevel"
    }

    var attributes: [String: Attribute] {
        get throws {
            var attributes: [String: Attribute] = [
                Keys.trigger: Attribute(try ValueCoding.encode(trigger)),
                Keys.conditions: Attribute(try ValueCoding.encode(conditions)),
                Keys.actions: Attribute(try ValueCoding.encode(actions)),
                Keys.owner: Attribute(try ValueCoding.encode(owner)),
                Keys.enabled: Attribute(.bool(enabled)),
                Keys.maxDepth: Attribute(.int(Int64(maxDepth))),
                Keys.minimumInterval: Attribute(.double(minimumInterval)),
                Keys.permissionLevel: Attribute(.int(Int64(permissionLevel.rawValue))),
            ]
            if let project { attributes[Keys.project] = Attribute(.reference(project)) }
            return attributes
        }
    }

    public init(record: ObjectRecord) throws {
        guard record.type == .automation else { throw AutomationError.notAnAutomation(record.id) }
        func field<T: Decodable>(_ key: String, _ type: T.Type) throws -> T {
            guard let value = record.attributes[key]?.value, let decoded = try? ValueCoding.decode(type, from: value) else {
                throw AutomationError.corruptRule(record.id, field: key)
            }
            return decoded
        }
        id = record.id
        title = record.title
        trigger = try field(Keys.trigger, AutomationTrigger.self)
        conditions = record.attributes[Keys.conditions] == nil ? [] : try field(Keys.conditions, [SystemCondition].self)
        actions = try field(Keys.actions, [AutomationAction].self)
        owner = try field(Keys.owner, Origin.self)
        enabled = if case .bool(let flag)? = record.attributes[Keys.enabled]?.value { flag } else { false }
        maxDepth = record.attributes[Keys.maxDepth]?.value.number.map { Int($0) } ?? 3
        minimumInterval = record.attributes[Keys.minimumInterval]?.value.number ?? 0
        project = if case .reference(let id)? = record.attributes[Keys.project]?.value { id } else { nil }
        self.record = record
    }
}

// MARK: Runs

/// How a firing ended.
public enum AutomationRunStatus: String, Codable, Sendable, Hashable {
    /// Every action ran and was committed together.
    case completed
    /// An action failed; everything the firing wrote was rolled back.
    case failed
    /// An action needs a grant the rule doesn't have. Nothing ran; a person
    /// may approve it with `AutomationRuntime.approve(_:by:)`.
    case awaitingApproval
    /// Policy forbids an action. Nothing ran.
    case denied
    /// The firing would exceed the rule's `maxDepth`. Nothing ran.
    case loopLimit
}

/// What one action in a firing did.
public struct AutomationActionResult: Codable, Sendable, Hashable {
    public var kind: String
    public var level: PermissionLevel
    public var permissionAction: String
    /// "completed", "failed", "blocked", "skipped".
    public var status: String
    public var summary: String
    public var produced: [ObjectID]
    public var error: String?
}

/// One `automationRun` event, read back.
public struct AutomationRun: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var rule: ObjectID
    public var at: Date
    public var status: AutomationRunStatus
    public var depth: Int
    /// What triggered it: `trigger` kind, `subject`, `value`, `event`, `scheduledFor`, `changeSeq`…
    public var inputs: [String: Value]
    public var actions: [AutomationActionResult]
    public var error: String?
    /// For a run a person approved: the blocked run it carried out.
    public var approves: ObjectID?
    public var event: Event

    public var produced: [ObjectID] { actions.flatMap(\.produced) }

    init?(event: Event) {
        guard event.kind == .automationRun, case .reference(let rule)? = event.payload["automation"],
            case .string(let raw)? = event.payload["status"], let status = AutomationRunStatus(rawValue: raw)
        else { return nil }
        id = event.id
        self.rule = rule
        at = event.at
        self.status = status
        depth = event.payload["depth"]?.number.map { Int($0) } ?? 0
        if case .map(let inputs)? = event.payload["inputs"] { self.inputs = inputs } else { inputs = [:] }
        actions = event.payload["actions"].flatMap { try? ValueCoding.decode([AutomationActionResult].self, from: $0) } ?? []
        if case .string(let error)? = event.payload["error"] { self.error = error } else { error = nil }
        if case .reference(let approved)? = event.payload["approves"] { approves = approved } else { approves = nil }
        self.event = event
    }
}

// MARK: Value coding

/// Stores Codable rule parts as structured `Value`s rather than opaque JSON,
/// so they stay readable and searchable in the object's attributes.
///
/// The mapping is JSON's: objects become `.map`, arrays `.list`, numbers
/// `.int` or `.double`, and strings that are object IDs become `.reference`.
/// Dates are seconds since 2001-01-01 (Foundation's reference date). Enums
/// with associated values use Swift's keyed form: `{"notify": {"_0": {...}}}`.
public enum ValueCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(JSONNode.self, from: encoder.encode(value)).value
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(JSONNode(value)))
    }

    private enum JSONNode: Codable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([JSONNode])
        case object([String: JSONNode])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let flag = try? container.decode(Bool.self) {
                self = .bool(flag)
            } else if let number = try? container.decode(Int64.self) {
                self = .int(number)
            } else if let number = try? container.decode(Double.self) {
                self = .double(number)
            } else if let text = try? container.decode(String.self) {
                self = .string(text)
            } else if let array = try? container.decode([JSONNode].self) {
                self = .array(array)
            } else {
                self = .object(try container.decode([String: JSONNode].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let flag): try container.encode(flag)
            case .int(let number): try container.encode(number)
            case .double(let number): try container.encode(number)
            case .string(let text): try container.encode(text)
            case .array(let array): try container.encode(array)
            case .object(let object): try container.encode(object)
            }
        }

        var value: Value {
            switch self {
            case .null: .null
            case .bool(let flag): .bool(flag)
            case .int(let number): .int(number)
            case .double(let number): .double(number)
            case .string(let text): ObjectID(text).flatMap { $0.description == text ? Value.reference($0) : nil } ?? .string(text)
            case .array(let array): .list(array.map(\.value))
            case .object(let object): .map(object.mapValues(\.value))
            }
        }

        init(_ value: Value) {
            switch value {
            case .null: self = .null
            case .bool(let flag): self = .bool(flag)
            case .int(let number): self = .int(number)
            case .double(let number): self = .double(number)
            case .string(let text): self = .string(text)
            case .reference(let id): self = .string(id.description)
            case .date(let date): self = .double(date.timeIntervalSinceReferenceDate)
            case .quantity(let quantity): self = .object(["value": .double(quantity.value), "unit": .string(quantity.unit)])
            case .list(let values): self = .array(values.map(JSONNode.init))
            case .map(let values): self = .object(values.mapValues(JSONNode.init))
            }
        }
    }
}
