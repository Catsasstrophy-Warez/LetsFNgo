import Foundation
import NexusActions
import NexusCore
import NexusModel
import NexusPermissions
import NexusProjects
import NexusTasks

/// What a problem with an automation form is, per field, for the builder to show.
public enum AutomationFormError: Error, Equatable, Sendable {
    /// A required field is empty. `field` names it in words.
    case missing(String)
    /// A field's text isn't what it should be.
    case invalid(String, reason: String)
    case noActions
}

/// A number typed in a form: accepts a decimal comma.
func parseNumber(_ text: String) -> Double? {
    Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
}

/// The rule builder's state as plain values, and its conversion to an
/// `AutomationRule`. The SwiftUI sheet only binds fields to this; everything
/// that decides what the rule is lives here, where it is tested.
public struct AutomationRuleForm: Sendable, Hashable {
    public enum TriggerKind: String, Sendable, Hashable, CaseIterable, Identifiable {
        case measurement = "A reading crosses a threshold"
        case event = "Something happens"
        case schedule = "On a schedule"
        case taskStatus = "A task changes status"
        case attribute = "An attribute changes"

        public var id: String { rawValue }
    }

    public enum ScheduleMode: String, Sendable, Hashable, CaseIterable {
        case every = "Every"
        case once = "Once"
    }

    public enum IntervalUnit: String, Sendable, Hashable, CaseIterable {
        case minutes, hours, days

        public var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3_600
            case .days: 86_400
            }
        }
    }

    /// How the extra conditions combine.
    public enum Match: String, Sendable, Hashable, CaseIterable {
        case all = "All of"
        case any = "Any of"
    }

    public var title = ""
    public var trigger = TriggerKind.measurement

    // A reading crosses a threshold.
    public var testPoint: ObjectID?
    public var quantity = ""
    public var direction = MeasurementThreshold.Direction.below
    public var threshold = ""
    public var unit = ""
    public var hysteresis = ""

    // Something happens.
    /// An `EventKind` raw value, e.g. "note" or "agentRequested".
    public var eventKind = ""
    public var eventSubject: ObjectID?
    /// An `ObjectType` raw value; empty for any.
    public var eventSubjectType = ""

    // On a schedule.
    public var scheduleMode = ScheduleMode.every
    public var interval = "1"
    public var intervalUnit = IntervalUnit.hours
    public var runAt = Date()

    // A task changes status. Nil task: any task.
    public var task: ObjectID?
    public var taskStatus = TaskStatus.done

    // An attribute changes. Nil object: any object (of `objectType`, if set).
    public var attributeObject: ObjectID?
    public var attributeObjectType = ""
    public var attribute = AttributeTest()

    public var match = Match.all
    public var conditions: [ConditionForm] = []
    public var actions: [ActionForm] = [ActionForm()]

    /// Seconds between firings; empty for no limit.
    public var minimumInterval = ""

    public init() {}

    /// The rule this form describes, or the first thing wrong with it.
    public func rule(owner: Origin, project: ObjectID?) throws -> AutomationRule {
        guard !actions.isEmpty else { throw AutomationFormError.noActions }
        var interval: TimeInterval = 0
        if !minimumInterval.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let seconds = parseNumber(minimumInterval), seconds >= 0 else {
                throw AutomationFormError.invalid("minimum interval", reason: "a number of seconds")
            }
            interval = seconds
        }
        var built = conditions.isEmpty ? [] : try conditions.map { try $0.condition() }
        if match == .any, built.count > 1 { built = [.any(built)] }
        return AutomationRule(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? defaultTitle : title.trimmingCharacters(in: .whitespaces),
            trigger: try automationTrigger(), conditions: built, actions: try actions.map { try $0.action(project: project) }, owner: owner,
            minimumInterval: interval, project: project)
    }

    public func automationTrigger() throws -> AutomationTrigger {
        switch trigger {
        case .measurement:
            guard let testPoint else { throw AutomationFormError.missing("test point") }
            let quantity = try required(quantity, "quantity")
            guard let value = parseNumber(threshold) else { throw AutomationFormError.invalid("threshold", reason: "a number") }
            let unit = try required(unit, "unit")
            var band = 0.0
            if !hysteresis.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let parsed = parseNumber(hysteresis), parsed >= 0 else {
                    throw AutomationFormError.invalid("hysteresis", reason: "a number, zero or more")
                }
                band = parsed
            }
            return .measurementThreshold(MeasurementThreshold(testPoint: testPoint, quantity: quantity, direction, Quantity(value, unit), hysteresis: band))
        case .event:
            let kind = try required(eventKind, "event kind")
            let type = eventSubjectType.trimmingCharacters(in: .whitespaces)
            return .event(kind: EventKind(rawValue: kind), subject: eventSubject, subjectType: type.isEmpty ? nil : ObjectType(rawValue: type))
        case .schedule:
            switch scheduleMode {
            case .every:
                guard let count = parseNumber(interval), count > 0 else { throw AutomationFormError.invalid("interval", reason: "a number above zero") }
                let seconds = count * intervalUnit.seconds
                guard seconds >= 60 else { throw AutomationFormError.invalid("interval", reason: "at least a minute") }
                return .schedule(.every(seconds: seconds))
            case .once:
                return .schedule(.once(at: runAt))
            }
        case .taskStatus:
            return .taskStatus(task: task, status: taskStatus)
        case .attribute:
            let type = attributeObjectType.trimmingCharacters(in: .whitespaces)
            return .attribute(
                object: attributeObject, objectType: type.isEmpty ? nil : ObjectType(rawValue: type), key: try required(attribute.key, "attribute"),
                comparison: attribute.comparison, value: try attribute.parsedValue())
        }
    }

    /// A name from the trigger when the person gives none.
    public var defaultTitle: String {
        switch trigger {
        case .measurement: "\(quantity) \(direction.rawValue) \(threshold) \(unit)".trimmingCharacters(in: .whitespaces)
        case .event: "On \(eventKind)"
        case .schedule: scheduleMode == .every ? "Every \(interval) \(intervalUnit.rawValue)" : "Once"
        case .taskStatus: "Task \(taskStatus.rawValue)"
        case .attribute: "\(attribute.key) \(attribute.comparison.symbol) \(attribute.value)"
        }
    }
}

/// "key comparison value", typed as text. The value becomes a quantity when
/// a unit is given, else a number, a flag or text.
public struct AttributeTest: Sendable, Hashable {
    public var key = ""
    public var comparison = Comparison.equal
    public var value = ""
    public var unit = ""

    public init(key: String = "", comparison: Comparison = .equal, value: String = "", unit: String = "") {
        self.key = key
        self.comparison = comparison
        self.value = value
        self.unit = unit
    }

    public func parsedValue() throws -> Value {
        let text = value.trimmingCharacters(in: .whitespaces)
        let unit = unit.trimmingCharacters(in: .whitespaces)
        if !unit.isEmpty {
            guard let number = parseNumber(text) else { throw AutomationFormError.invalid("value", reason: "a number, since it has a unit") }
            return .quantity(Quantity(number, unit))
        }
        if let number = Int64(text) { return .int(number) }
        if let number = parseNumber(text) { return .double(number) }
        switch text.lowercased() {
        case "true", "yes": return .bool(true)
        case "false", "no": return .bool(false)
        default: break
        }
        guard !text.isEmpty else { throw AutomationFormError.missing("value") }
        guard comparison == .equal || comparison == .notEqual else {
            throw AutomationFormError.invalid("value", reason: "a number, to compare with \(comparison.symbol)")
        }
        return .string(text)
    }
}

/// One extra condition in the builder.
public struct ConditionForm: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case measurement = "Latest reading"
        case attribute = "Attribute"
        case taskStatus = "Task status"
        case after = "After a time"
    }

    public var id = UUID()
    public var kind = Kind.measurement
    public var object: ObjectID?
    // Latest reading.
    public var quantity = ""
    public var comparison = Comparison.lessThan
    public var value = ""
    public var unit = ""
    // Attribute.
    public var attribute = AttributeTest()
    // Task status.
    public var taskStatus = TaskStatus.done
    // After.
    public var date = Date()

    public init(kind: Kind = .measurement) {
        self.kind = kind
    }

    public func condition() throws -> SystemCondition {
        switch kind {
        case .measurement:
            guard let object else { throw AutomationFormError.missing("test point") }
            guard let number = parseNumber(value) else { throw AutomationFormError.invalid("value", reason: "a number") }
            return .measurement(
                testPoint: object, quantity: try required(quantity, "quantity"), comparison: comparison, value: Quantity(number, try required(unit, "unit"))
            )
        case .attribute:
            guard let object else { throw AutomationFormError.missing("object") }
            return .attribute(
                object: object, key: try required(attribute.key, "attribute"), comparison: attribute.comparison, value: try attribute.parsedValue())
        case .taskStatus:
            guard let object else { throw AutomationFormError.missing("task") }
            return .taskStatus(task: object, status: taskStatus)
        case .after:
            return .after(date)
        }
    }
}

/// One action in the builder.
public struct ActionForm: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case createTask = "Create a task"
        case command = "Run a command"
        case agentGoal = "Ask an agent"
        case notify = "Notify"
    }

    /// What a command acts on.
    public enum Selection: String, Sendable, Hashable, CaseIterable {
        case none = "Nothing"
        case subject = "What triggered it"
        case measurement = "The reading"
        case previous = "The previous action's result"
        case object = "A chosen object"

        func targets(_ object: ObjectID?) throws -> [AutomationTarget] {
            switch self {
            case .none: return []
            case .subject: return [.triggerSubject]
            case .measurement: return [.triggerMeasurement]
            case .previous: return [.previousResult]
            case .object:
                guard let object else { throw AutomationFormError.missing("object") }
                return [.object(object)]
            }
        }
    }

    public var id = UUID()
    public var kind = Kind.createTask

    // Create a task.
    public var taskTitle = "Check {subject}: {value}"
    public var successCondition = ""
    /// Hours after the firing; empty for no due date.
    public var dueInHours = ""
    /// A draft for a person to approve (P2) instead of active work (P3).
    public var draft = false

    // Run a command.
    /// A `CommandID` raw value.
    public var command = CommandID.investigate.rawValue
    public var selection = Selection.subject
    public var selectionObject: ObjectID?
    /// `field=value` per line, e.g. `symptom=Low voltage at {subject}`. Values
    /// may be `$subject`, `$measurement` or `$previous`.
    public var presets = ""

    // Ask an agent.
    public var profile = "diagnostic"
    public var goal = "Diagnose {subject}: {value}"

    // Notify.
    public var message = "{rule}: {subject} {value}"
    public var severity = NotifyAction.Severity.info
    /// Leaves the app: P4, runs only with an explicit grant.
    public var external = false

    public init(kind: Kind = .createTask) {
        self.kind = kind
    }

    public func action(project: ObjectID?) throws -> AutomationAction {
        switch kind {
        case .createTask:
            var due: TimeInterval?
            if !dueInHours.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let hours = parseNumber(dueInHours), hours > 0 else { throw AutomationFormError.invalid("due in", reason: "hours above zero") }
                due = hours * 3_600
            }
            let condition = successCondition.trimmingCharacters(in: .whitespaces)
            return .createTask(
                TaskAction(
                    title: try required(taskTitle, "task title"), successCondition: condition.isEmpty ? nil : condition, project: project, dueIn: due,
                    draft: draft))
        case .command:
            let id = CommandID(rawValue: try required(command, "command"))
            guard CommandID.all.contains(id) else { throw AutomationFormError.invalid("command", reason: "not a known command") }
            return .command(CommandAction(id, selection: try selection.targets(selectionObject), presets: try parsedPresets()))
        case .agentGoal:
            return .startAgent(AgentGoalAction(profile: try required(profile, "agent"), goal: try required(goal, "goal")))
        case .notify:
            return .notify(NotifyAction(try required(message, "message"), severity: severity, external: external))
        }
    }

    static let numericFields: Set<ActionParameters.Field> = [.value, .uncertainty, .rangeLow, .rangeHigh, .prior, .seconds, .confidence]

    /// Presets from `field=value` lines, checked against the fields a preset can fill.
    public func parsedPresets() throws -> [String: Value] {
        var presets: [String: Value] = [:]
        for line in self.presets.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else {
                throw AutomationFormError.invalid("presets", reason: "\"\(trimmed)\" is not field=value")
            }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let text = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let field = ActionParameters.Field(rawValue: key), ActionParameters.presettableFields.contains(field) else {
                throw AutomationFormError.invalid("presets", reason: "\"\(key)\" is not a field a preset can fill")
            }
            if ["$subject", "$measurement", "$previous"].contains(text) {
                presets[key] = .string(text)
            } else if let id = ObjectID(text), id.description == text {
                presets[key] = .reference(id)
            } else if Self.numericFields.contains(field), let number = parseNumber(text) {
                presets[key] = .double(number)
            } else {
                presets[key] = .string(text)
            }
        }
        // Fail here rather than at the first firing.
        do {
            let resolved = presets.mapValues { value -> Value in
                if case .string(let text) = value, text.hasPrefix("$") { return .reference(.make()) }
                return value
            }
            _ = try ActionParameters(presets: resolved)
        } catch {
            throw AutomationFormError.invalid("presets", reason: String(describing: error))
        }
        return presets
    }
}

extension AutomationFormError: ClassifiableError {
    public var classified: ClassifiedError {
        switch self {
        case .missing(let field):
            ClassifiedError(category: .userInput, whatHappened: "Fill in the \(field).", nextActions: [NextAction("Fill in the \(field)")])
        case .invalid(let field, let reason):
            ClassifiedError(category: .userInput, whatHappened: "The \(field) should be \(reason).", nextActions: [NextAction("Fix the \(field)")])
        case .noActions:
            ClassifiedError(category: .userInput, whatHappened: "An automation needs at least one action.", nextActions: [NextAction("Add an action")])
        }
    }
}

private func required(_ text: String, _ field: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw AutomationFormError.missing(field) }
    return trimmed
}
