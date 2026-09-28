import Foundation
import NexusActions
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusProjects
import NexusTasks
import Testing

@testable import NexusAutomation

private let owner = Origin.user(id: "tech-1")

@Suite struct AutomationRuleFormTests {
    @Test func thresholdFormBuildsAThresholdRule() throws {
        var form = AutomationRuleForm()
        let point = ObjectID.make()
        form.testPoint = point
        form.quantity = "voltage"
        form.threshold = "11,5"
        form.unit = "V"
        form.hysteresis = "0.5"
        let project = ObjectID.make()
        let rule = try form.rule(owner: owner, project: project)
        #expect(rule.title == "voltage below 11,5 V")
        #expect(
            rule.trigger
                == .measurementThreshold(MeasurementThreshold(testPoint: point, quantity: "voltage", .below, Quantity(11.5, "V"), hysteresis: 0.5)))
        #expect(rule.actions == [.createTask(TaskAction(title: "Check {subject}: {value}", project: project))])
        #expect(rule.owner == owner && rule.project == project && rule.conditions.isEmpty)
    }

    @Test func everyTriggerKind() throws {
        var form = AutomationRuleForm()
        form.trigger = .event
        form.eventKind = "note"
        form.eventSubjectType = "sensor"
        #expect(try form.automationTrigger() == .event(kind: .note, subject: nil, subjectType: .sensor))

        form.trigger = .schedule
        form.interval = "15"
        form.intervalUnit = .minutes
        #expect(try form.automationTrigger() == .schedule(.every(seconds: 900)))
        form.interval = "0.5"
        #expect(throws: AutomationFormError.invalid("interval", reason: "at least a minute")) { try form.automationTrigger() }
        form.scheduleMode = .once
        let at = Date(timeIntervalSinceReferenceDate: 900_000_000)
        form.runAt = at
        #expect(try form.automationTrigger() == .schedule(.once(at: at)))

        form.trigger = .taskStatus
        let task = ObjectID.make()
        form.task = task
        form.taskStatus = .blocked
        #expect(try form.automationTrigger() == .taskStatus(task: task, status: .blocked))

        form.trigger = .attribute
        form.attributeObjectType = "sensor"
        form.attribute = AttributeTest(key: "state", comparison: .equal, value: "tripped")
        #expect(try form.automationTrigger() == .attribute(object: nil, objectType: .sensor, key: "state", comparison: .equal, value: .string("tripped")))
        form.attribute = AttributeTest(key: "level", comparison: .greaterThan, value: "80", unit: "%")
        #expect(
            try form.automationTrigger()
                == .attribute(object: nil, objectType: .sensor, key: "level", comparison: .greaterThan, value: .quantity(Quantity(80, "%"))))
        form.attribute = AttributeTest(key: "state", comparison: .greaterThan, value: "tripped")
        #expect(throws: AutomationFormError.invalid("value", reason: "a number, to compare with >")) { try form.automationTrigger() }
    }

    @Test func attributeValuesAreTyped() throws {
        #expect(try AttributeTest(value: "3").parsedValue() == .int(3))
        #expect(try AttributeTest(value: "2,5").parsedValue() == .double(2.5))
        #expect(try AttributeTest(value: "yes").parsedValue() == .bool(true))
        #expect(throws: AutomationFormError.missing("value")) { try AttributeTest(value: " ").parsedValue() }
        #expect(throws: AutomationFormError.invalid("value", reason: "a number, since it has a unit")) {
            try AttributeTest(value: "high", unit: "V").parsedValue()
        }
    }

    @Test func conditionsCombineAllOrAny() throws {
        var form = AutomationRuleForm()
        form.trigger = .event
        form.eventKind = "note"
        let point = ObjectID.make()
        let task = ObjectID.make()
        var reading = ConditionForm(kind: .measurement)
        reading.object = point
        reading.quantity = "current"
        reading.comparison = .greaterOrEqual
        reading.value = "4"
        reading.unit = "mA"
        var status = ConditionForm(kind: .taskStatus)
        status.object = task
        status.taskStatus = .open
        form.conditions = [reading, status]

        let expected: [SystemCondition] = [
            .measurement(testPoint: point, quantity: "current", comparison: .greaterOrEqual, value: Quantity(4, "mA")),
            .taskStatus(task: task, status: .open),
        ]
        #expect(try form.rule(owner: owner, project: nil).conditions == expected)
        form.match = .any
        #expect(try form.rule(owner: owner, project: nil).conditions == [.any(expected)])

        var missing = ConditionForm(kind: .attribute)
        missing.attribute = AttributeTest(key: "k", value: "1")
        form.conditions = [missing]
        #expect(throws: AutomationFormError.missing("object")) { try form.rule(owner: owner, project: nil) }
    }

    @Test func everyActionKind() throws {
        let project = ObjectID.make()
        var task = ActionForm(kind: .createTask)
        task.taskTitle = "Swap {subject}"
        task.dueInHours = "2"
        task.draft = true
        task.successCondition = "Reads 4 mA"
        #expect(
            try task.action(project: project)
                == .createTask(TaskAction(title: "Swap {subject}", successCondition: "Reads 4 mA", project: project, dueIn: 7_200, draft: true)))

        var command = ActionForm(kind: .command)
        command.command = "investigate"
        command.presets = "symptom = Low voltage at {subject}\n\n"
        #expect(
            try command.action(project: nil)
                == .command(CommandAction(.investigate, selection: [.triggerSubject], presets: ["symptom": .string("Low voltage at {subject}")])))
        command.command = "recordMeasurement"
        command.selection = .none
        command.presets = "testPoint=$subject\nquantity=voltage\nvalue=12\nunit=V"
        #expect(
            try command.action(project: nil)
                == .command(
                    CommandAction(
                        .recordMeasurement,
                        presets: ["testPoint": .string("$subject"), "quantity": .string("voltage"), "value": .double(12), "unit": .string("V")])))
        command.presets = "loop=x"
        #expect(throws: AutomationFormError.invalid("presets", reason: "\"loop\" is not a field a preset can fill")) { try command.action(project: nil) }
        command.presets = "symptom"
        #expect(throws: AutomationFormError.invalid("presets", reason: "\"symptom\" is not field=value")) { try command.action(project: nil) }
        command.presets = ""
        command.command = "launchRockets"
        #expect(throws: AutomationFormError.invalid("command", reason: "not a known command")) { try command.action(project: nil) }
        command.command = "open"
        command.selection = .object
        #expect(throws: AutomationFormError.missing("object")) { try command.action(project: nil) }

        var agent = ActionForm(kind: .agentGoal)
        agent.profile = "research"
        agent.goal = "What do the manuals say about {subject}?"
        #expect(try agent.action(project: nil) == .startAgent(AgentGoalAction(profile: "research", goal: "What do the manuals say about {subject}?")))

        var notify = ActionForm(kind: .notify)
        notify.message = "Low at {subject}"
        notify.severity = .critical
        notify.external = true
        let action = try notify.action(project: nil)
        #expect(action == .notify(NotifyAction("Low at {subject}", severity: .critical, external: true)))
        #expect(action.level == .externalAction)
    }

    @Test func formRulesRunInTheRuntime() throws {
        let clock = ManualClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let store = try NexusStore(.inMemory, clock: clock)
        let runtime = AutomationRuntime(store: store, permissions: try PermissionEngine(store: store), clock: clock)
        let recorded = Provenance(origin: owner, truth: .recorded, timestamp: clock.now())
        let pump = try store.create(ObjectRecord(type: .equipment, title: "P-1", provenance: recorded))

        var form = AutomationRuleForm()
        form.title = "Pump tripped"
        form.trigger = .attribute
        form.attributeObject = pump.id
        form.attribute = AttributeTest(key: "state", value: "tripped")
        var notify = ActionForm(kind: .notify)
        notify.message = "{subject} tripped"
        var agent = ActionForm(kind: .agentGoal)
        agent.goal = "Why did {subject} trip?"
        form.actions = [notify, agent]
        _ = try runtime.create(try form.rule(owner: owner, project: nil), by: owner)
        try runtime.start()

        try store.update(pump.id, by: owner) { $0.attributes["state"] = Attribute(.string("tripped")) }
        #expect(try store.timeline().filter { $0.kind == .notification }.map(\.summary) == ["P-1 tripped"])
        #expect(try store.objects(ofType: .agentRequest).map(\.title) == ["Why did P-1 trip?"])
    }

    @Test func emptyFormsSayWhatIsMissing() throws {
        var form = AutomationRuleForm()
        #expect(throws: AutomationFormError.missing("test point")) { try form.rule(owner: owner, project: nil) }
        form.trigger = .event
        #expect(throws: AutomationFormError.missing("event kind")) { try form.rule(owner: owner, project: nil) }
        form.eventKind = "note"
        form.actions = []
        #expect(throws: AutomationFormError.noActions) { try form.rule(owner: owner, project: nil) }
        form.actions = [ActionForm(kind: .notify)]
        form.minimumInterval = "soon"
        #expect(throws: AutomationFormError.invalid("minimum interval", reason: "a number of seconds")) { try form.rule(owner: owner, project: nil) }
        form.minimumInterval = "30"
        #expect(try form.rule(owner: owner, project: nil).minimumInterval == 30)
    }
}
