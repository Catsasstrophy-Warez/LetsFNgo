import Foundation
import NexusActions
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusProjects
import NexusTasks
import Testing

@testable import NexusAutomation

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let planner = Origin.agent(id: "planner", run: nil)

/// A sensor LT-101 with its terminal test point, a store-backed permission
/// engine and a runtime, all on one manual clock.
private struct Bench {
    let clock: ManualClock
    let store: NexusStore
    let permissions: PermissionEngine
    let runtime: AutomationRuntime
    let sensor: ObjectID
    let terminal: ObjectID

    init(location: NexusStore.Location = .inMemory, clock: ManualClock = ManualClock(t0), existing: (sensor: ObjectID, terminal: ObjectID)? = nil)
        throws
    {
        self.clock = clock
        store = try NexusStore(location, clock: clock)
        permissions = try PermissionEngine(store: store)
        runtime = AutomationRuntime(store: store, permissions: permissions, clock: clock)
        if let existing {
            sensor = existing.sensor
            terminal = existing.terminal
        } else {
            let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)
            sensor = try store.create(ObjectRecord(type: .sensor, title: "LT-101", provenance: recorded)).id
            terminal = try store.create(ObjectRecord(type: .testPoint, title: "TB-4", provenance: recorded)).id
            try store.relate(Relationship(kind: .contains, from: sensor, to: terminal, provenance: recorded))
        }
    }

    /// A voltage reading at the terminal, one second after the last.
    @discardableResult
    func reading(_ volts: Double, _ truth: TruthClass = .observed) throws -> ObjectID {
        clock.advance(by: 1)
        let origin: Origin = truth == .modeled ? .simulation(run: .make()) : tech
        let record = MeasurementRecord(
            quantityName: "voltage", value: Quantity(volts, "V"), testPoint: terminal, sampledAt: clock.now(),
            provenance: Provenance(origin: origin, truth: truth, timestamp: clock.now())
        )
        try store.add(record)
        return record.id
    }

    func threshold(below volts: Double, hysteresis: Double = 0.5, truths: [TruthClass] = observedOrRecorded) -> AutomationTrigger {
        .measurementThreshold(
            MeasurementThreshold(testPoint: terminal, quantity: "voltage", .below, Quantity(volts, "V"), hysteresis: hysteresis, truths: truths))
    }

    func notifications() throws -> [Event] {
        try store.timeline().filter { $0.kind == .notification }
    }

    func grant(_ rule: AutomationRule, _ action: String, level: PermissionLevel? = nil) throws {
        try permissions.add(PolicyRule(agent: rule.agentID, action: action, level: level, grant: .always), by: tech)
    }
}

@Suite struct AutomationTriggerTests {
    @Test func thresholdCrossingWithHysteresisFiresOnce() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(
                title: "Low terminal voltage", trigger: bench.threshold(below: 12), actions: [.notify(NotifyAction("TB-4 at {value}"))], owner: tech),
            by: tech)
        try bench.runtime.start()

        for volts in [13.0, 11.9, 11.8, 12.2, 11.7, 12.4] { try bench.reading(volts) }
        #expect(try bench.runtime.runs(of: rule.id).map(\.status) == [.completed])
        #expect(try bench.notifications().map(\.summary) == ["TB-4 at 11.9 V"])

        // Leaving the dead band (≥ 12.5 V) re-arms; the next drop fires again.
        try bench.reading(12.6)
        try bench.reading(11.5)
        #expect(try bench.runtime.runs(of: rule.id).count == 2)
        let last = try #require(try bench.runtime.runs(of: rule.id).last)
        #expect(last.inputs["value"] == .quantity(Quantity(11.5, "V")))
        #expect(last.inputs["truth"] == .string("observed"))
    }

    @Test func modeledReadingsDoNotFireAnObservedOnlyRule() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(title: "Low voltage", trigger: bench.threshold(below: 12), actions: [.notify(NotifyAction("low"))], owner: tech), by: tech)
        try bench.runtime.start()

        try bench.reading(9, .modeled)
        try bench.reading(8, .modeled)
        #expect(try bench.runtime.runs(of: rule.id).isEmpty)
        #expect(try bench.notifications().isEmpty)

        try bench.reading(11, .observed)
        #expect(try bench.runtime.runs(of: rule.id).count == 1)
    }

    @Test func replayAfterReloadDoesNotDoubleFire() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nexus.sqlite")
        let clock = ManualClock(t0)

        var ids: (sensor: ObjectID, terminal: ObjectID)
        let ruleID: ObjectID
        do {
            let bench = try Bench(location: .file(url), clock: clock)
            ids = (bench.sensor, bench.terminal)
            ruleID = try bench.runtime.create(
                AutomationRule(title: "Low voltage", trigger: bench.threshold(below: 12), actions: [.notify(NotifyAction("low"))], owner: tech), by: tech
            ).id
            try bench.runtime.start()
            try bench.reading(11)
            #expect(try bench.runtime.runs(of: ruleID).count == 1)
            bench.runtime.stop()
        }

        // A new process over the same file replays the feed from each rule's cursor.
        let reloaded = try Bench(location: .file(url), clock: clock, existing: ids)
        try reloaded.runtime.start()
        try reloaded.runtime.process()
        #expect(try reloaded.runtime.runs(of: ruleID).count == 1)
        #expect(try reloaded.notifications().count == 1)

        // The rule is still disarmed after the reload: a lower reading doesn't fire…
        try reloaded.reading(10)
        #expect(try reloaded.runtime.runs(of: ruleID).count == 1)
        // …until the voltage recovers past the dead band.
        try reloaded.reading(13)
        try reloaded.reading(11)
        #expect(try reloaded.runtime.runs(of: ruleID).count == 2)
    }

    @Test func selfTriggeringRuleStopsAtMaxDepth() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(
                title: "Echo", trigger: .event(kind: .notification, subject: bench.sensor),
                actions: [.notify(NotifyAction("echo", subjects: [.triggerSubject]))], owner: tech, maxDepth: 3),
            by: tech)
        try bench.runtime.start()

        try bench.store.record(
            Event(
                at: t0, kind: .notification, subjects: [bench.sensor], summary: "kick",
                provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)))

        let runs = try bench.runtime.runs(of: rule.id)
        #expect(runs.map(\.status) == [.completed, .completed, .completed, .loopLimit])
        #expect(runs.map(\.depth) == [1, 2, 3, 4])
        #expect(try bench.notifications().count == 4)
    }

    @Test func taskStatusTriggerFiresOncePerTransition() throws {
        let bench = try Bench()
        let task = try bench.runtime.tasks.create("Replace terminal", by: tech)
        let rule = try bench.runtime.create(
            AutomationRule(title: "Started", trigger: .taskStatus(status: .inProgress), actions: [.notify(NotifyAction("{subject} started"))], owner: tech),
            by: tech)
        try bench.runtime.start()
        try bench.runtime.tasks.setStatus(.inProgress, of: task.id, by: tech)
        try bench.runtime.tasks.assign(task.id, to: .user(id: "lead"), by: tech)
        #expect(try bench.notifications().map(\.summary) == ["Replace terminal started"])
        try bench.runtime.tasks.setStatus(.blocked, of: task.id, by: tech)
        try bench.runtime.tasks.setStatus(.inProgress, of: task.id, by: tech)
        #expect(try bench.runtime.runs(of: rule.id).count == 2)
    }
}

@Suite struct AutomationSafetyTests {
    @Test func externalActionIsBlockedWithoutAGrant() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(
                title: "Page on-call", trigger: bench.threshold(below: 12),
                actions: [.notify(NotifyAction("TB-4 low", severity: .critical, external: true))], owner: tech),
            by: tech)
        #expect(rule.permissionLevel == .externalAction)
        // A blanket P4 grant is not enough: it must name this automation and action.
        try bench.permissions.add(PolicyRule(level: .externalAction, grant: .always), by: tech)
        try bench.runtime.start()

        try bench.reading(11)
        let blocked = try #require(try bench.runtime.runs(of: rule.id).last)
        #expect(blocked.status == .awaitingApproval)
        #expect(blocked.actions.map(\.status) == ["blocked"])
        #expect(try bench.notifications().isEmpty)

        // Agents can't approve; a person can, once.
        #expect(throws: AutomationError.requiresHuman(planner)) { try bench.runtime.approve(blocked, by: planner) }
        let approved = try bench.runtime.approve(blocked, by: tech)
        #expect(approved.status == .completed && approved.approves == blocked.id)
        #expect(throws: AutomationError.notAwaitingApproval(blocked.id)) { try bench.runtime.approve(blocked, by: tech) }
        #expect(try bench.notifications().count == 1)

        // With an explicit grant the next crossing runs by itself.
        try bench.grant(rule, "notify.external")
        try bench.reading(13)
        try bench.reading(11)
        #expect(try bench.runtime.runs(of: rule.id).last?.status == .completed)
        #expect(try bench.notifications().count == 2)
    }

    @Test func sensitiveCommandNeedsAnExplicitGrant() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(
                title: "Open", trigger: bench.threshold(below: 12),
                actions: [.command(CommandAction(.open, selection: [.triggerSubject], minimumLevel: .sensitive))], owner: tech),
            by: tech)
        try bench.runtime.start()
        try bench.reading(11)
        #expect(try bench.runtime.runs(of: rule.id).last?.status == .awaitingApproval)

        try bench.grant(rule, "command.open")
        try bench.reading(13)
        try bench.reading(11)
        #expect(try bench.runtime.runs(of: rule.id).last?.status == .completed)
    }

    @Test func modifyingStateNeedsAGrantOrApproval() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(title: "Task", trigger: bench.threshold(below: 12), actions: [.createTask(TaskAction(title: "Check TB-4"))], owner: tech),
            by: tech)
        try bench.runtime.start()
        try bench.reading(11)
        #expect(try bench.runtime.runs(of: rule.id).last?.status == .awaitingApproval)
        #expect(try bench.runtime.tasks.allTasks().isEmpty)
    }

    @Test func failedActionLeavesNoPartialWrites() throws {
        let bench = try Bench()
        let missing = ObjectID.make()
        let rule = try bench.runtime.create(
            AutomationRule(
                title: "Broken", trigger: bench.threshold(below: 12),
                actions: [
                    .notify(NotifyAction("low")),
                    .createTask(TaskAction(title: "Check TB-4")),
                    .command(CommandAction(.open, selection: [.object(missing)])),
                ],
                owner: tech),
            by: tech)
        try bench.grant(rule, "createTask")
        try bench.runtime.start()
        let before = try bench.store.objects(ofType: .task).count

        try bench.reading(11)
        let run = try #require(try bench.runtime.runs(of: rule.id).last)
        #expect(run.status == .failed)
        #expect(run.actions.map(\.status) == ["rolledBack", "rolledBack", "failed"])
        #expect(run.error != nil)
        #expect(run.produced.isEmpty)
        #expect(try bench.store.objects(ofType: .task).count == before)
        #expect(try bench.notifications().isEmpty)
    }

    @Test func agentRulesAreDisabledDraftsUntilAPersonEnablesThem() throws {
        let bench = try Bench()
        let proposed = try bench.runtime.create(
            AutomationRule(title: "Proposed", trigger: bench.threshold(below: 12), actions: [.notify(NotifyAction("low"))], owner: planner), by: planner)
        #expect(!proposed.enabled && proposed.record?.lifecycle == .draft)
        try bench.runtime.start()
        try bench.reading(11)
        #expect(try bench.runtime.runs(of: proposed.id).isEmpty)
        #expect(throws: AutomationError.requiresHuman(planner)) { try bench.runtime.setEnabled(true, rule: proposed.id, by: planner) }

        try bench.runtime.setEnabled(true, rule: proposed.id, by: tech)
        try bench.reading(13)
        try bench.reading(11)
        #expect(try bench.runtime.runs(of: proposed.id).count == 1)
    }
}

@Suite struct ConditionalTaskAndScheduleTests {
    @Test func conditionalTaskStartsWhenTheConditionHolds() throws {
        let bench = try Bench()
        try bench.runtime.start()
        let task = try bench.runtime.tasks.create("Calibrate LT-101", by: tech)
        let condition = SystemCondition.measurement(testPoint: bench.terminal, quantity: "voltage", comparison: .greaterThan, value: Quantity(20, "V"))
        try bench.runtime.startTask(task.id, when: condition, startAs: .inProgress, by: tech)

        #expect(try bench.runtime.tasks.task(task.id).status == .blocked)
        let waiting = try #require(try bench.runtime.tasks.conditions(for: task.id).first)
        #expect(waiting.label == "starts when TB-4 voltage > 20 V")
        #expect(waiting.isWaiting)
        #expect(try bench.runtime.startCondition(of: task.id) == condition)

        try bench.reading(25, .modeled)
        try bench.reading(18)
        #expect(try bench.runtime.tasks.task(task.id).status == .blocked)

        try bench.reading(21.3)
        #expect(try bench.runtime.tasks.task(task.id).status == .inProgress)
        let met = try #require(try bench.runtime.tasks.conditions(for: task.id).first)
        #expect(!met.isWaiting)
        #expect(met.metReason?.contains("voltage 21.3 V observed") == true)
        let change = try #require(try bench.store.events(about: task.id).last { $0.kind == .taskStatusChanged })
        #expect(change.payload["to"] == .string("inProgress"))
        guard case .string(let reason)? = change.payload["reason"] else {
            Issue.record("no reason")
            return
        }
        #expect(reason.contains("TB-4 voltage > 20 V"))

        // Met conditions stay met: the task is not moved again.
        try bench.reading(22)
        #expect(try bench.store.events(about: task.id).filter { $0.kind == .taskStatusChanged }.count == 2)
    }

    @Test func scheduleTicksFireOncePerDueTime() throws {
        let bench = try Bench()
        let hourly = try bench.runtime.create(
            AutomationRule(
                title: "Hourly check", trigger: .schedule(.every(seconds: 3600, startingAt: t0 + 3600)), actions: [.notify(NotifyAction("check"))],
                owner: tech),
            by: tech)
        let once = try bench.runtime.create(
            AutomationRule(title: "Reminder", trigger: .schedule(.once(at: t0 + 5000)), actions: [.notify(NotifyAction("remind"))], owner: tech), by: tech)

        #expect(try bench.runtime.tick(now: t0 + 100).isEmpty)
        #expect(try bench.runtime.tick(now: t0 + 3600).map(\.rule) == [hourly.id])
        #expect(try bench.runtime.tick(now: t0 + 3600).isEmpty)
        // Missed periods are coalesced into one firing.
        let late = try bench.runtime.tick(now: t0 + 3 * 3600 + 5)
        #expect(Set(late.map(\.rule)) == [hourly.id, once.id])
        #expect(late.first { $0.rule == hourly.id }?.inputs["periods"] == .int(2))
        #expect(try bench.runtime.tick(now: t0 + 10 * 3600).map(\.rule) == [hourly.id])
        #expect(try bench.runtime.runs(of: once.id).count == 1)
    }

    @Test func tickStartsTasksWaitingForATime() throws {
        let bench = try Bench()
        let task = try bench.runtime.tasks.create("Quarterly inspection", by: tech)
        try bench.runtime.startTask(task.id, when: .after(t0 + 86_400), by: tech)
        try bench.runtime.tick(now: t0 + 3600)
        #expect(try bench.runtime.tasks.task(task.id).status == .blocked)
        try bench.runtime.tick(now: t0 + 86_400)
        #expect(try bench.runtime.tasks.task(task.id).status == .open)
        #expect(try bench.runtime.tasks.ready().map(\.id) == [task.id])
    }
}

@Suite struct AutomationEndToEndTests {
    /// "When LT-101 terminal voltage drops below 12 V (observed), start an
    /// investigation and create a task."
    @Test func lowTerminalVoltageStartsAnInvestigationAndATask() throws {
        let bench = try Bench()
        let rule = try bench.runtime.create(
            AutomationRule(
                title: "LT-101 low terminal voltage",
                trigger: bench.threshold(below: 12, hysteresis: 0.5),
                actions: [
                    .command(
                        CommandAction(
                            .investigate, selection: [.object(bench.sensor)], presets: ["symptom": .string("{subject} voltage {value}, below 12 V")])),
                    .createTask(TaskAction(title: "Check LT-101 loop supply ({value})", dueIn: 3600, about: [.previousResult, .triggerSubject])),
                    .startAgent(AgentGoalAction(profile: "diagnostic", goal: "Diagnose low voltage at {subject}")),
                ],
                owner: tech),
            by: tech)
        #expect(rule.permissionLevel == .modifyInternalState)
        try bench.grant(rule, "createTask")
        try bench.runtime.start()

        // A simulation dipping below 12 V is not evidence of a real fault.
        try bench.reading(9, .modeled)
        #expect(try bench.store.objects(ofType: .investigation).isEmpty)

        try bench.reading(12.8)
        let reading = try bench.reading(11.4)

        let investigation = try #require(try bench.store.objects(ofType: .investigation).first)
        #expect(investigation.title == "TB-4 voltage 11.4 V, below 12 V")
        let task = try #require(try bench.runtime.tasks.allTasks().first)
        #expect(task.title == "Check LT-101 loop supply (11.4 V)")
        #expect(task.status == .open && task.lifecycle == .active)
        #expect(task.dueAt == bench.clock.now() + 3600)
        #expect(task.record.attributes["about"]?.value == .list([.reference(investigation.id), .reference(bench.terminal)]))
        #expect(task.record.attributes["automation"]?.value == .reference(rule.id))
        let request = try #require(try bench.store.objects(ofType: .agentRequest).first)
        #expect(request.title == "Diagnose low voltage at TB-4")
        #expect(request.attributes["status"]?.value == .string("pending"))

        let runs = try bench.runtime.runs(of: rule.id)
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.status == .completed)
        #expect(run.inputs["measurement"] == .reference(reading))
        #expect(Set(run.produced) == [investigation.id, task.id, request.id])
        #expect(run.event.subjects.contains(bench.terminal))

        // More low readings in the same excursion don't open more investigations.
        try bench.reading(11.0)
        try bench.reading(10.5)
        #expect(try bench.store.objects(ofType: .investigation).count == 1)
        #expect(try bench.runtime.runs(of: rule.id).count == 1)
    }
}

@Suite struct AutomationModelTests {
    @Test func ruleRoundTripsThroughTheStore() throws {
        let bench = try Bench()
        let rule = AutomationRule(
            title: "Everything", trigger: bench.threshold(below: 12),
            conditions: [.all([.after(t0), .attribute(object: bench.sensor, key: "mode", comparison: .equal, value: .string("auto"))])],
            actions: [
                .command(CommandAction(.investigate, selection: [.triggerSubject], presets: ["symptom": .string("x"), "prior": .double(0.4)])),
                .createTask(TaskAction(title: "t", startsWhen: .taskStatus(task: bench.sensor, status: .done))),
                .startAgent(AgentGoalAction(profile: "diagnostic", goal: "g")),
                .notify(NotifyAction("n", severity: .warning)),
            ],
            owner: tech, maxDepth: 2, minimumInterval: 60, project: bench.sensor)
        let stored = try bench.runtime.create(rule, by: tech)
        let read = try bench.runtime.rule(stored.id)
        #expect(read.trigger == rule.trigger)
        #expect(read.conditions == rule.conditions)
        #expect(read.actions == rule.actions)
        #expect(read.owner == tech && read.enabled && read.maxDepth == 2 && read.minimumInterval == 60 && read.project == bench.sensor)
        let record = try #require(read.record)
        #expect(record.type == .automation)
        #expect(record.attributes["permissionLevel"]?.value == .int(3))
        #expect(record.provenance.origin == tech && record.provenance.truth == .recorded)
    }

    @Test func presetsFillActionParameters() throws {
        let id = ObjectID.make()
        let parameters = try ActionParameters(presets: [
            "symptom": .string("low"), "value": .int(12), "unit": .string("V"), "testPoint": .reference(id), "truth": .string("observed"),
            "evidence": .list([.string(id.description)]),
        ])
        #expect(parameters.symptom == "low" && parameters.value == 12 && parameters.unit == "V")
        #expect(parameters.testPoint == id && parameters.truth == .observed && parameters.evidence == [id])
        #expect(throws: PresetError.unknownField("nope")) { try ActionParameters(presets: ["nope": .null]) }
        #expect(throws: PresetError.unsupportedField(.faults)) { try ActionParameters(presets: ["faults": .list([])]) }
        #expect(throws: PresetError.wrongType(.value, expected: "number")) { try ActionParameters(presets: ["value": .string("x")]) }
        #expect(CommandID.open.defaultPermission == .observe)
        #expect(CommandID(rawValue: "wipeEverything").defaultPermission == .sensitive)
    }
}
