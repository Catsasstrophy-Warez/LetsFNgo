import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import Testing
@testable import NexusTasks

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let lead = Origin.user(id: "lead-1")
private let agent = Origin.agent(id: "planner", run: nil)

private struct Bench {
    let clock = ManualClock(t0)
    let store: NexusStore
    let runtime: TaskRuntime

    init() throws {
        store = try NexusStore(.inMemory, clock: clock)
        runtime = TaskRuntime(store: store, clock: clock)
    }

    func project(_ title: String = "LT-101 repair") throws -> ObjectID {
        try store.create(ObjectRecord(
            type: .project, title: title, provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now())
        )).id
    }
}

@Suite struct TaskStatusTests {
    @Test func transitionTableMatchesTheLifecycle() {
        #expect(TaskStatus.open.canMove(to: .inProgress))
        #expect(TaskStatus.inProgress.canMove(to: .done))
        #expect(TaskStatus.blocked.canMove(to: .open))
        #expect(!TaskStatus.blocked.canMove(to: .done))
        #expect(TaskStatus.done.allowedNext == [.open])
        #expect(TaskStatus.cancelled.allowedNext == [.open])
        for status in TaskStatus.allCases {
            #expect(!status.canMove(to: status))
        }
    }

    @Test func ownerRoundTripsThroughAttributes() {
        let origins: [Origin] = [
            .user(id: "a"), .agent(id: "b", run: .make()), .agent(id: "c", run: nil), .importer(source: .make()),
            .simulation(run: .make()), .instrument(id: .make()), .system,
            .model(ModelRef(provider: "apple", modelID: "fm", adapterID: "nexus", adapterVersion: "1", promptHash: "abc")),
        ]
        for origin in origins {
            #expect(Origin(value: origin.value) == origin)
        }
    }
}

@Suite struct TaskRuntimeTests {
    @Test func createStoresATaskObjectWithItsFields() throws {
        let bench = try Bench()
        let due = t0 + 86_400
        let task = try bench.runtime.create(
            "Replace TB-4 terminal", successCondition: "Loop reads 12 mA at 50 %", owner: lead, dueAt: due, by: tech
        )
        let stored = try #require(try bench.store.object(task.id))
        #expect(stored.type == .task)
        #expect(stored.lifecycle == .active)
        #expect(task.status == .open)
        #expect(task.owner == lead)
        #expect(task.dueAt == due)
        #expect(task.successCondition == "Loop reads 12 mA at 50 %")
        #expect(stored.provenance.truth == .recorded)
    }

    @Test func extraAttributesCannotOverrideTaskFields() throws {
        let bench = try Bench()
        let task = try bench.runtime.create(
            "Pull a work order", owner: lead,
            attributes: ["line": Attribute(.int(3)), "status": Attribute(.string("done")), "owner": Attribute(.string("nobody"))],
            by: tech
        )
        #expect(task.record.attributes["line"]?.value == .int(3))
        #expect(task.status == .open)
        #expect(task.owner == lead)
        #expect(RelationKind.follows.rawValue == "follows")
    }

    @Test func statusChangesAreRevisionsWithEvents() throws {
        let bench = try Bench()
        let task = try bench.runtime.create("Check loop supply", by: tech)
        bench.clock.advance(by: 60)
        try bench.runtime.setStatus(.inProgress, of: task.id, by: tech)
        bench.clock.advance(by: 60)
        let done = try bench.runtime.setStatus(.done, of: task.id, reason: "24.1 V measured", by: tech)

        #expect(done.status == .done)
        #expect(done.record.attributes["completedAt"]?.value == .date(t0 + 120))
        let revisions = try bench.store.revisions(of: task.id)
        #expect(revisions.count == 3)
        #expect(revisions.last?.instruction == "Status inProgress → done: 24.1 V measured")

        let events = try bench.store.events(about: task.id).filter { $0.kind == .taskStatusChanged }
        #expect(events.map { $0.payload["to"] } == [.string("inProgress"), .string("done")])
        #expect(events.last?.payload["from"] == .string("inProgress"))
        #expect(events.last?.payload["reason"] == .string("24.1 V measured"))
        #expect(events.last?.provenance.revision == done.record.revision)
        #expect(events.last?.provenance.truth == .recorded)
    }

    @Test func invalidTransitionsAreRefused() throws {
        let bench = try Bench()
        let task = try bench.runtime.create("Tighten terminal", by: tech)
        try bench.runtime.setStatus(.blocked, of: task.id, by: tech)
        #expect(throws: TaskError.invalidTransition(task.id, from: .blocked, to: .done)) {
            try bench.runtime.setStatus(.done, of: task.id, by: tech)
        }
        #expect(throws: TaskError.invalidTransition(task.id, from: .blocked, to: .blocked)) {
            try bench.runtime.setStatus(.blocked, of: task.id, by: tech)
        }
        try bench.runtime.setStatus(.cancelled, of: task.id, by: tech)
        #expect(throws: TaskError.invalidTransition(task.id, from: .cancelled, to: .inProgress)) {
            try bench.runtime.setStatus(.inProgress, of: task.id, by: tech)
        }
        // Reopening is the one way out of a closed status.
        #expect(try bench.runtime.setStatus(.open, of: task.id, by: tech).status == .open)
        // A refused change leaves no revision or event behind.
        #expect(try bench.store.events(about: task.id).count == 3)
    }

    @Test func agentsOnlyDraftAndNeverComplete() throws {
        let bench = try Bench()
        #expect(throws: TaskError.agentMustDraft(agent)) {
            try bench.runtime.create("Swap transmitter", lifecycle: .active, by: agent)
        }
        let draft = try bench.runtime.create("Swap transmitter", by: agent)
        #expect(draft.isDraft)
        #expect(draft.record.provenance.truth == .agentInterpretation)

        // A draft cannot be worked until a person approves it.
        #expect(throws: TaskError.draftNotApproved(draft.id)) {
            try bench.runtime.setStatus(.inProgress, of: draft.id, by: tech)
        }
        #expect(throws: TaskError.requiresHuman(agent)) {
            try bench.runtime.approve(draft.id, by: agent)
        }
        #expect(try bench.runtime.approve(draft.id, by: lead).lifecycle == .active)
        #expect(throws: TaskError.notADraft(draft.id)) { try bench.runtime.approve(draft.id, by: lead) }

        // The agent may progress its own task, but not declare it done.
        try bench.runtime.setStatus(.inProgress, of: draft.id, by: agent)
        #expect(throws: TaskError.requiresHuman(agent)) {
            try bench.runtime.setStatus(.done, of: draft.id, by: agent)
        }
        #expect(try bench.runtime.setStatus(.done, of: draft.id, by: tech).status == .done)
    }

    @Test func agentsCannotOverwriteAPersonsStatus() throws {
        let bench = try Bench()
        let task = try bench.runtime.create("Verify loop", by: tech)
        #expect(throws: StoreError.truthConflict(object: task.id, attribute: "status", existing: .recorded, incoming: .agentInterpretation)) {
            try bench.runtime.setStatus(.inProgress, of: task.id, by: agent)
        }
        #expect(try bench.runtime.task(task.id).status == .open)
    }

    @Test func dependenciesGateCompletionAndReadiness() throws {
        let bench = try Bench()
        let isolate = try bench.runtime.create("Isolate loop", by: tech)
        let repair = try bench.runtime.create("Repair terminal", dependsOn: [isolate.id], by: tech)
        let verify = try bench.runtime.create("Verify loop", dependsOn: [repair.id], by: tech)

        #expect(try bench.runtime.ready().map(\.id) == [isolate.id])
        #expect(try bench.runtime.blocked().map(\.id) == [repair.id, verify.id])
        #expect(try bench.runtime.gate(for: repair.id).unfinishedDependencies == [isolate.id])
        #expect(throws: TaskError.gateClosed(repair.id, unfinishedDependencies: [isolate.id], missingEvidence: [])) {
            try bench.runtime.setStatus(.done, of: repair.id, by: tech)
        }

        try bench.runtime.setStatus(.done, of: isolate.id, by: tech)
        #expect(try bench.runtime.ready().map(\.id) == [repair.id])
        #expect(try bench.runtime.blocked().map(\.id) == [verify.id])
        try bench.runtime.setStatus(.done, of: repair.id, by: tech)
        #expect(try bench.runtime.ready().map(\.id) == [verify.id])
        #expect(try bench.runtime.dependents(of: repair.id).map(\.id) == [verify.id])
    }

    @Test func cyclesAreRejected() throws {
        let bench = try Bench()
        let a = try bench.runtime.create("A", by: tech)
        let b = try bench.runtime.create("B", dependsOn: [a.id], by: tech)
        let c = try bench.runtime.create("C", dependsOn: [b.id], by: tech)
        #expect(throws: TaskError.dependencyCycle(path: [a.id, c.id, b.id, a.id])) {
            try bench.runtime.addDependency(a.id, on: c.id, by: tech)
        }
        #expect(throws: TaskError.dependencyCycle(path: [a.id, a.id])) {
            try bench.runtime.addDependency(a.id, on: a.id, by: tech)
        }
        // Adding an existing dependency again is a no-op, not a second edge.
        try bench.runtime.addDependency(c.id, on: b.id, by: tech)
        #expect(try bench.store.relationships(from: c.id, kind: .dependsOn).count == 1)

        // Once B no longer depends on A, the edge that closed the loop is fine.
        try bench.runtime.removeDependency(b.id, on: a.id, by: tech)
        try bench.runtime.addDependency(a.id, on: c.id, by: tech)
        #expect(try bench.runtime.dependencies(of: a.id).map(\.id) == [c.id])
        // The ended dependency is kept as history.
        #expect(try bench.store.relationships(from: b.id, kind: .dependsOn).first?.validTo != nil)
    }

    @Test func requiredEvidenceMustExistBeforeDone() throws {
        let bench = try Bench()
        let point = try bench.store.create(ObjectRecord(
            type: .testPoint, title: "TB-4 7/8", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        ))
        let reading = MeasurementRecord(
            quantityName: "loop current", value: Quantity(12, "mA"), testPoint: point.id, sampledAt: t0,
            provenance: Provenance(origin: .instrument(id: point.id), truth: .observed, timestamp: t0)
        )
        let task = try bench.runtime.create(
            "Verify loop current", requiredEvidence: [.object(reading.id), .attached(.measurement)], by: tech
        )
        #expect(try bench.runtime.gate(for: task.id).missingEvidence == [.object(reading.id), .attached(.measurement)])
        #expect(throws: TaskError.gateClosed(task.id, unfinishedDependencies: [], missingEvidence: [.object(reading.id), .attached(.measurement)])) {
            try bench.runtime.setStatus(.done, of: task.id, by: tech)
        }

        try bench.store.add(reading)
        #expect(try bench.runtime.gate(for: task.id).missingEvidence == [.attached(.measurement)])
        try bench.runtime.attachEvidence(reading.id, to: task.id, by: tech)
        #expect(try bench.runtime.gate(for: task.id).isOpen)
        #expect(try bench.runtime.setStatus(.done, of: task.id, by: tech).status == .done)
    }

    @Test func projectQueriesFollowContainment() throws {
        let bench = try Bench()
        let project = try bench.project()
        let phase = try bench.store.create(ObjectRecord(
            type: .project, title: "Phase 2", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        ))
        try bench.store.relate(Relationship(
            kind: .contains, from: project, to: phase.id, provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        ))
        let direct = try bench.runtime.create("Direct", in: project, by: tech)
        let nested = try bench.runtime.create("Nested", in: phase.id, by: tech)
        _ = try bench.runtime.create("Elsewhere", by: tech)

        #expect(Set(try bench.runtime.tasks(in: project).map(\.id)) == [direct.id, nested.id])
        #expect(try bench.runtime.tasks(in: project, transitive: false).map(\.id) == [direct.id])
        #expect(Set(try bench.runtime.ready(in: project).map(\.id)) == [direct.id, nested.id])
        #expect(try bench.runtime.allTasks().count == 3)
    }

    @Test func overdueSkipsClosedTasks() throws {
        let bench = try Bench()
        let late = try bench.runtime.create("Late", dueAt: t0 + 10, by: tech)
        let finished = try bench.runtime.create("Finished", dueAt: t0 + 10, by: tech)
        _ = try bench.runtime.create("Future", dueAt: t0 + 1_000, by: tech)
        try bench.runtime.setStatus(.done, of: finished.id, by: tech)
        #expect(try bench.runtime.overdue(at: t0 + 100).map(\.id) == [late.id])
    }

    @Test func tasksSurviveReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ManualClock(t0)
        let (first, second): (ObjectID, ObjectID)
        do {
            let runtime = TaskRuntime(store: try NexusStore(.file(url), clock: clock), clock: clock)
            first = try runtime.create("First", by: tech).id
            second = try runtime.create("Second", dependsOn: [first], by: tech).id
            try runtime.setStatus(.inProgress, of: first, by: tech)
        }
        let runtime = TaskRuntime(store: try NexusStore(.file(url), clock: clock), clock: clock)
        #expect(try runtime.task(first).status == .inProgress)
        #expect(try runtime.blocked().map(\.id) == [second])
        #expect(throws: TaskError.dependencyCycle(path: [first, second, first])) {
            try runtime.addDependency(first, on: second, by: tech)
        }
    }
}
