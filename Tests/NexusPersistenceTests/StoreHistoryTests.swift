import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusPersistence

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let agent = Origin.agent(id: "diag", run: nil)

private func prov(_ truth: TruthClass, _ origin: Origin = tech, at offset: TimeInterval = 0) -> Provenance {
    Provenance(origin: origin, truth: truth, timestamp: t0 + offset)
}

/// Collects delivered batches for inspection.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[StoreChange]] = []
    var batches: [[StoreChange]] { lock.withLock { storage } }
    func receive(_ batch: [StoreChange]) { lock.withLock { storage.append(batch) } }
}

@Suite struct StoreEventTests {
    @Test func updateAppendsAnEditEventInTheSameWrite() throws {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let pump = try store.create(
            ObjectRecord(
                type: .equipment, title: "Pump P-9", attributes: ["tag": Attribute(.string("P-9"))],
                provenance: prov(.recorded)
            )
        )
        let inbox = Inbox()
        let token = store.observeChanges(inbox.receive)
        clock.advance(by: 5)

        let updated = try store.update(pump.id, by: agent) {
            $0.attributes["suspect"] = Attribute(.string("seal wear"))
            $0.title = "Pump P-9 (suspect)"
        }

        let events = try store.events(about: pump.id)
        #expect(events.count == 1)
        let edit = try #require(events.first)
        #expect(edit.kind == .objectEdited)
        #expect(edit.subjects == [pump.id])
        #expect(edit.at == t0 + 5)
        #expect(edit.payload["changedAttributes"] == .list([.string("suspect")]))
        #expect(edit.payload["changedFields"] == .list([.string("title")]))
        #expect(edit.payload["author"] == .string("agent:diag"))
        #expect(edit.provenance.origin == agent)
        #expect(edit.provenance.revision == updated.revision)
        // One delivery holds both the revision and its event.
        #expect(inbox.batches.map { $0.map(\.kind) } == [[.updated, .event]])

        // A refused update leaves neither a revision nor an event.
        #expect(throws: StoreError.self) {
            try store.update(pump.id, by: agent) { $0.attributes["tag"] = Attribute(.string("P-10")) }
        }
        #expect(try store.events(about: pump.id).count == 1)
        #expect(inbox.batches.count == 1)
        withExtendedLifetime(token) {}
    }

    @Test func addingAMeasurementAppendsAMeasuredEvent() throws {
        let store = try NexusStore(.inMemory)
        let point = try store.create(ObjectRecord(type: .testPoint, title: "TB-4 7/8", provenance: prov(.recorded)))
        let meter = try store.create(ObjectRecord(type: .instrument, title: "Fluke 87V", provenance: prov(.recorded)))
        let reading = MeasurementRecord(
            quantityName: "terminal voltage", value: Quantity(10.8, "V"), uncertainty: 0.05, testPoint: point.id,
            instrument: meter.id, sampledAt: t0 + 60, provenance: prov(.observed, .instrument(id: meter.id), at: 60)
        )
        try store.add(reading)

        let events = try store.events(about: point.id)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .measured)
        #expect(event.at == t0 + 60)
        #expect(Set(event.subjects) == [reading.id, point.id, meter.id])
        #expect(event.provenance == reading.provenance)
        #expect(event.payload["value"] == .quantity(Quantity(10.8, "V")))
        #expect(event.payload["truth"] == .string("observed"))
        #expect(event.payload["uncertainty"] == .double(0.05))
        #expect(try store.events(about: meter.id) == [event])
        #expect(try store.events(about: reading.id) == [event])

        // A duplicate is refused without a second event.
        #expect(throws: StoreError.duplicate(reading.id)) { try store.add(reading) }
        #expect(try store.timeline().count == 1)
    }
}

@Suite struct VersioningTests {
    /// Three revisions of a transmitter: created, then edited by a technician,
    /// then annotated by an agent.
    private struct History {
        let store: NexusStore
        let clock: ManualClock
        let id: ObjectID
        let revisions: [Revision]

        init() throws {
            clock = ManualClock(t0)
            store = try NexusStore(.inMemory, clock: clock)
            let created = try store.create(
                ObjectRecord(
                    type: .sensor, title: "LT-101",
                    attributes: [
                        "tag": Attribute(.string("LT-101")),
                        "range": Attribute(.string("0-5 m")),
                        "supply": Attribute(.quantity(Quantity(24, "V")), provenance: prov(.observed)),
                    ],
                    lifecycle: .draft,
                    provenance: prov(.recorded)
                )
            )
            id = created.id
            clock.advance(by: 10)
            try store.update(id, by: tech) {
                $0.title = "LT-101 level transmitter"
                $0.lifecycle = .active
                $0.attributes["range"] = nil
                $0.attributes["supply"] = Attribute(.quantity(Quantity(23.8, "V")), provenance: prov(.observed, at: 10))
                $0.attributes["model"] = Attribute(.string("LT-3051"))
            }
            clock.advance(by: 10)
            try store.update(id, by: agent) { $0.attributes["suspect"] = Attribute(.string("terminal corrosion")) }
            revisions = try store.revisions(of: id)
        }
    }

    @Test func diffReportsAttributeTitleAndLifecycleChanges() throws {
        let history = try History()
        let diff = try history.store.diff(of: history.id, from: history.revisions[0].id, to: history.revisions[1].id)
        #expect(diff.object == history.id)
        #expect(diff.from == history.revisions[0].id)
        #expect(diff.to == history.revisions[1].id)
        #expect(diff.title == FieldChange(old: "LT-101", new: "LT-101 level transmitter"))
        #expect(diff.lifecycle == FieldChange(old: .draft, new: .active))
        #expect(diff.truth == nil)
        #expect(diff.attributes.map(\.key) == ["model", "range", "supply"])
        #expect(diff.attributes.map(\.kind) == [.added, .removed, .changed])

        let model = diff.attributes[0]
        #expect(model.old == nil && model.oldTruth == nil)
        #expect(model.new?.value == .string("LT-3051"))
        #expect(model.newTruth == .recorded, "Stamped with the technician's default truth")
        let range = diff.attributes[1]
        #expect(range.oldTruth == .recorded, "Inherited from the object")
        #expect(range.new == nil && range.newTruth == nil)
        let supply = diff.attributes[2]
        #expect(supply.old?.value == .quantity(Quantity(24, "V")))
        #expect(supply.new?.value == .quantity(Quantity(23.8, "V")))
        #expect(supply.oldTruth == .observed && supply.newTruth == .observed)

        let agentDiff = try history.store.diff(of: history.id, from: history.revisions[1].id, to: history.revisions[2].id)
        #expect(agentDiff.title == nil && agentDiff.lifecycle == nil)
        #expect(agentDiff.attributes.map(\.key) == ["suspect"])
        #expect(agentDiff.attributes.first?.newTruth == .agentInterpretation)

        // Backwards reads the other way; a revision against itself is empty.
        let backwards = try history.store.diff(of: history.id, from: history.revisions[1].id, to: history.revisions[0].id)
        #expect(backwards.attributes.map(\.kind) == [.removed, .added, .changed])
        #expect(backwards.lifecycle == FieldChange(old: .active, new: .draft))
        #expect(try history.store.diff(of: history.id, from: history.revisions[2].id, to: history.revisions[2].id).isEmpty)
    }

    @Test func diffRejectsRevisionsOfOtherObjects() throws {
        let history = try History()
        let other = try history.store.create(ObjectRecord(type: .component, title: "Other", provenance: prov(.recorded)))
        let foreign = try #require(other.revision)
        #expect(throws: StoreError.revisionNotFound(object: history.id, revision: foreign)) {
            try history.store.diff(of: history.id, from: history.revisions[0].id, to: foreign)
        }
        #expect(try history.store.revision(foreign, of: history.id) == nil)
        #expect(try history.store.revision(history.revisions[1].id, of: history.id) == history.revisions[1])
    }

    @Test func restoreWritesANewRevisionAndKeepsHistory() throws {
        let history = try History()
        let store = history.store
        history.clock.advance(by: 10)
        let restored = try store.restore(history.id, toRevision: history.revisions[0].id, by: tech)

        let revisions = try store.revisions(of: history.id)
        #expect(revisions.count == 4)
        #expect(Array(revisions.prefix(3)) == history.revisions, "History is never rewritten")
        let head = try #require(revisions.last)
        #expect(head.parent == history.revisions[2].id)
        #expect(head.author == tech)
        #expect(head.instruction == "Restore revision 1")
        #expect(head.id == restored.revision)
        #expect(restored.updatedAt == t0 + 30)

        // Same content as the old snapshot, including provenance.
        let old = history.revisions[0].snapshot
        #expect(restored.title == old.title)
        #expect(restored.lifecycle == old.lifecycle)
        #expect(restored.attributes == old.attributes)
        #expect(restored.provenance == old.provenance)
        #expect(try store.diff(of: history.id, from: history.revisions[0].id, to: head.id).isEmpty)
        #expect(try store.object(history.id) == restored)
        #expect(try store.search("level transmitter").isEmpty, "Search follows the restored title")

        let event = try #require(try store.events(about: history.id).last)
        #expect(event.kind == .revisionRestored)
        #expect(event.payload["restoredRevision"] == .string(history.revisions[0].id.description))
        #expect(event.payload["restoredSequence"] == .int(1))
        #expect(event.provenance.revision == head.id)
    }

    @Test func agentsCannotRestoreOverProtectedValues() throws {
        let history = try History()
        let store = history.store

        // Going back to revision 1 would drop the recorded model number.
        #expect(throws: StoreError.protectedRemoval(object: history.id, attribute: "model", by: agent)) {
            try store.restore(history.id, toRevision: history.revisions[0].id, by: agent)
        }
        let simulation = Origin.simulation(run: .make())
        #expect(throws: StoreError.protectedRemoval(object: history.id, attribute: "model", by: simulation)) {
            try store.restore(history.id, toRevision: history.revisions[0].id, by: simulation)
        }
        #expect(try store.revisions(of: history.id).count == 3)
        #expect(try store.events(about: history.id).count == 2)

        // Undoing its own interpretation touches nothing protected, so it is allowed.
        let undone = try store.restore(history.id, toRevision: history.revisions[1].id, by: agent)
        #expect(undone.attributes["suspect"] == nil)

        // A newer observation arrives. Revision 2's supply voltage is also
        // observed, so plain TruthPolicy would allow the swap, but an agent
        // may not put an old protected value back over a current one.
        try store.update(history.id, by: tech) {
            $0.attributes["supply"] = Attribute(.quantity(Quantity(25, "V")), provenance: prov(.observed, at: 40))
        }
        #expect(
            throws: StoreError.truthConflict(
                object: history.id, attribute: "supply", existing: .observed, incoming: .agentInterpretation
            )
        ) {
            try store.restore(history.id, toRevision: history.revisions[1].id, by: agent)
        }
        #expect(try store.object(history.id)?.attributes["supply"]?.value == .quantity(Quantity(25, "V")))

        // People may restore protected values.
        let byTech = try store.restore(history.id, toRevision: history.revisions[0].id, by: tech)
        #expect(byTech.attributes["model"] == nil)
        #expect(byTech.attributes["supply"] == history.revisions[0].snapshot.attributes["supply"])
    }

    @Test func measurementsCannotBeRestored() throws {
        let store = try NexusStore(.inMemory)
        let point = try store.create(ObjectRecord(type: .testPoint, title: "TP", provenance: prov(.recorded)))
        let reading = MeasurementRecord(
            quantityName: "v", value: Quantity(1, "V"), testPoint: point.id, sampledAt: t0, provenance: prov(.observed)
        )
        try store.add(reading)
        let revision = try #require(try store.object(reading.id)?.revision)
        #expect(throws: StoreError.immutableRecord(reading.id, .measurement)) {
            try store.restore(reading.id, toRevision: revision, by: tech)
        }
        #expect(throws: StoreError.revisionNotFound(object: point.id, revision: revision)) {
            try store.restore(point.id, toRevision: revision, by: tech)
        }
    }
}

@Suite struct LifecycleTests {
    @Test func transitionTable() {
        let allowed: Set<[Lifecycle]> = [
            [.draft, .active], [.active, .archived], [.archived, .active],
            [.draft, .deleted], [.active, .deleted], [.archived, .deleted],
        ]
        for old in Lifecycle.allCases {
            for new in Lifecycle.allCases {
                #expect(NexusStore.canTransition(from: old, to: new) == allowed.contains([old, new]), "\(old) → \(new)")
            }
        }
    }

    @Test func transitionsAreRevisionedAndEvented() throws {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let doc = try store.create(
            ObjectRecord(type: .document, title: "Loop sheet", lifecycle: .draft, provenance: prov(.recorded))
        )

        clock.advance(by: 1)
        #expect(try store.setLifecycle(.active, of: doc.id, by: tech).lifecycle == .active)
        clock.advance(by: 1)
        try store.setLifecycle(.archived, of: doc.id, by: tech, instruction: "Superseded by rev B")
        #expect(throws: StoreError.invalidTransition(object: doc.id, from: .archived, to: .draft)) {
            try store.setLifecycle(.draft, of: doc.id, by: tech)
        }
        #expect(throws: StoreError.invalidTransition(object: doc.id, from: .archived, to: .archived)) {
            try store.setLifecycle(.archived, of: doc.id, by: tech)
        }
        clock.advance(by: 1)
        try store.setLifecycle(.active, of: doc.id, by: tech)
        let deleted = try store.setLifecycle(.deleted, of: doc.id, by: tech)
        #expect(throws: StoreError.invalidTransition(object: doc.id, from: .deleted, to: .active)) {
            try store.setLifecycle(.active, of: doc.id, by: tech)
        }

        let revisions = try store.revisions(of: doc.id)
        #expect(revisions.map(\.snapshot.lifecycle) == [.draft, .active, .archived, .active, .deleted])
        #expect(revisions[1].instruction == "Lifecycle draft → active")
        #expect(revisions[2].instruction == "Superseded by rev B")
        #expect(revisions.last?.id == deleted.revision)

        let events = try store.events(about: doc.id)
        #expect(events.map(\.kind) == Array(repeating: .lifecycleChanged, count: 4))
        #expect(events.map { $0.payload["to"] } == ["active", "archived", "active", "deleted"].map { .string($0) })
        #expect(events.first?.payload["from"] == .string("draft"))
        #expect(events.first?.at == t0 + 1)
        #expect(try store.search("loop sheet").isEmpty, "Deleted objects leave search")
    }

    @Test func onlyPeopleDeleteProtectedObjects() throws {
        let store = try NexusStore(.inMemory)
        let recorded = try store.create(ObjectRecord(type: .equipment, title: "Tank T-1", provenance: prov(.recorded)))
        let note = try store.create(
            ObjectRecord(type: .document, title: "Agent note", provenance: prov(.agentInterpretation, agent))
        )
        #expect(throws: StoreError.protectedRemoval(object: recorded.id, attribute: "lifecycle", by: agent)) {
            try store.setLifecycle(.deleted, of: recorded.id, by: agent)
        }
        #expect(try store.object(recorded.id)?.lifecycle == .active)
        #expect(try store.events(about: recorded.id).isEmpty)
        // Archiving is not removal, and agents may delete their own interpretations.
        #expect(try store.setLifecycle(.archived, of: recorded.id, by: agent).lifecycle == .archived)
        #expect(try store.setLifecycle(.deleted, of: note.id, by: agent).lifecycle == .deleted)
        #expect(try store.setLifecycle(.deleted, of: recorded.id, by: .system).lifecycle == .deleted)
    }
}
