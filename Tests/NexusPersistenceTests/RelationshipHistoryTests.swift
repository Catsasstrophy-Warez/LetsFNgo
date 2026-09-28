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

private func twoObjects(_ store: NexusStore) throws -> (ObjectID, ObjectID) {
    let pump = try store.create(ObjectRecord(type: .equipment, title: "Pump", provenance: prov(.recorded)))
    let motor = try store.create(ObjectRecord(type: .component, title: "Motor", provenance: prov(.recorded)))
    return (pump.id, motor.id)
}

@Suite struct RelationshipHistoryTests {
    @Test func relateEndAndUpdateEachWriteARevision() throws {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let (pump, motor) = try twoObjects(store)
        let link = try store.relate(
            Relationship(kind: .contains, from: pump, to: motor, attributes: ["torque": Attribute(.double(4))], provenance: prov(.recorded)),
            instruction: "Import BOM"
        )
        clock.advance(by: 10)
        try store.updateRelationship(link.id, by: tech, instruction: "Fix torque") {
            $0.attributes["torque"] = Attribute(.double(5))
        }
        clock.advance(by: 10)
        try store.end(link.id, at: t0 + 20, by: tech)

        let revisions = try store.relationshipRevisions(of: link.id)
        #expect(revisions.map(\.sequence) == [1, 2, 3])
        #expect(revisions.map(\.instruction) == ["Import BOM", "Fix torque", "End"])
        #expect(revisions.map(\.author) == [tech, tech, tech])
        #expect(revisions[0].parent == nil)
        #expect(revisions[1].parent == revisions[0].id)
        #expect(revisions[2].parent == revisions[1].id)
        #expect(revisions[0].snapshot.attributes["torque"]?.value == .double(4))
        #expect(revisions[1].snapshot.attributes["torque"]?.value == .double(5))
        #expect(revisions[1].at == t0 + 10)
        #expect(revisions[2].snapshot.validTo == t0 + 20)
        #expect(try store.relationship(link.id) == revisions[2].snapshot)

        let edit = try #require(try store.events(about: pump).last)
        #expect(edit.kind == .relationshipEdited)
        #expect(edit.payload["changedAttributes"] == .list([.string("torque")]))
    }

    @Test func updateRelationshipFollowsTruthPolicy() throws {
        let store = try NexusStore(.inMemory, clock: ManualClock(t0))
        let (pump, motor) = try twoObjects(store)
        let link = try store.relate(
            Relationship(
                kind: .connectedTo, from: pump, to: motor,
                attributes: ["cable": Attribute(.string("W-12")), "note": Attribute(.string("x"), provenance: prov(.modeled))],
                provenance: prov(.observed)
            )
        )

        // An agent cannot overwrite or remove an observed attribute, or weaken the provenance.
        #expect(throws: StoreError.truthConflict(object: link.id, attribute: "cable", existing: .observed, incoming: .agentInterpretation)) {
            try store.updateRelationship(link.id, by: agent) { $0.attributes["cable"] = Attribute(.string("W-13")) }
        }
        #expect(throws: StoreError.protectedRemoval(object: link.id, attribute: "cable", by: agent)) {
            try store.updateRelationship(link.id, by: agent) { $0.attributes["cable"] = nil }
        }
        #expect(throws: StoreError.truthConflict(object: link.id, attribute: nil, existing: .observed, incoming: .modeled)) {
            try store.updateRelationship(link.id, by: agent) { $0.provenance = prov(.modeled, agent) }
        }
        #expect(throws: StoreError.immutableField(object: link.id, field: "to")) {
            try store.updateRelationship(link.id, by: tech) { $0.to = pump }
        }
        #expect(throws: StoreError.immutableField(object: link.id, field: "validTo")) {
            try store.updateRelationship(link.id, by: tech) { $0.validTo = t0 }
        }
        #expect(try store.relationshipRevisions(of: link.id).count == 1, "Refused updates leave no revision")

        // An agent may change an unprotected attribute; its value is stamped as agent interpretation.
        let updated = try store.updateRelationship(link.id, by: agent) { $0.attributes["note"] = Attribute(.string("check lug")) }
        #expect(updated.truth(of: "note") == .agentInterpretation)
        #expect(updated.attributes["note"]?.provenance?.origin == agent)
        // A person may replace the observed value.
        let fixed = try store.updateRelationship(link.id, by: tech) {
            $0.attributes["cable"] = Attribute(.string("W-14"), provenance: prov(.observed, at: 5))
        }
        #expect(fixed.attributes["cable"]?.value == .string("W-14"))
        #expect(try store.relationshipRevisions(of: link.id).count == 3)
    }

    @Test func migrationSevenSynthesizesAFirstRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-v5-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let pump = ObjectID.make()
        let motor = ObjectID.make()
        let link = Relationship(kind: .contains, from: pump, to: motor, provenance: prov(.recorded, at: 42))
        // Build a database as version 5 shipped it, holding one relationship.
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at REAL NOT NULL);")
            for migration in Migrations.all where migration.version <= 5 {
                try connection.execute(migration.sql)
                try connection.run(
                    "INSERT INTO schema_migrations VALUES (?, ?, 0)", [.int(Int64(migration.version)), .text(migration.name)]
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for id in [pump, motor] {
                let object = ObjectRecord(id: id, type: .equipment, title: "Thing", provenance: prov(.recorded))
                try connection.run(
                    """
                    INSERT INTO objects (id, type, title, lifecycle, truth, created_at, updated_at, head_revision, record)
                    VALUES (?, 'equipment', 'Thing', 'active', 'recorded', 0, 0, ?, ?)
                    """,
                    [.text(id.description), .text(RevisionID.make().description), .text(String(decoding: try encoder.encode(object), as: UTF8.self))]
                )
            }
            try connection.run(
                "INSERT INTO relationships (id, kind, from_id, to_id, truth, record) VALUES (?, 'contains', ?, ?, 'recorded', ?)",
                [
                    .text(link.id.description), .text(pump.description), .text(motor.description),
                    .text(String(decoding: try encoder.encode(link), as: UTF8.self)),
                ]
            )
        }

        let store = try NexusStore(.file(url))
        #expect(store.schemaVersion == Migrations.latestVersion)
        let revisions = try store.relationshipRevisions(of: link.id)
        #expect(revisions.count == 1)
        let first = try #require(revisions.first)
        #expect(first.id == RevisionID(raw: link.id), "The synthesized revision's ID is the relationship's")
        #expect(first.sequence == 1)
        #expect(first.author == tech)
        #expect(first.at == t0 + 42)
        #expect(first.snapshot == link)

        // Pre-existing rows are in the sync feed, and new writes append to the history.
        let changeSet = try store.changeSet()
        #expect(changeSet.relationships.map(\.relationship.id) == [link.id])
        #expect(Set(changeSet.objects.map(\.record.id)) == [pump, motor])
        try store.end(link.id, at: t0 + 50, by: tech)
        #expect(try store.relationshipRevisions(of: link.id).map(\.sequence) == [1, 2])
    }
}
