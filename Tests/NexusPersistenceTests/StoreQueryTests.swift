import Foundation
import NexusCore
import NexusModel
import Testing
@testable import NexusPersistence

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

private func prov(_ truth: TruthClass, _ origin: Origin = tech, at offset: TimeInterval = 0) -> Provenance {
    Provenance(origin: origin, truth: truth, timestamp: t0 + offset)
}

@Suite struct StoreQueryTests {
    @Test func upgradesAVersion1DatabaseToLatest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id: ObjectID
        do {
            let store = try NexusStore(.file(url))
            id = try store.create(ObjectRecord(type: .equipment, title: "Pump P-2", provenance: prov(.recorded))).id
        }
        // Roll the file back to exactly what migration 1 produced.
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute("DROP INDEX objects_title_nocase; DELETE FROM schema_migrations WHERE version > 1;")
        }
        let store = try NexusStore(.file(url))
        #expect(store.schemaVersion == Migrations.latestVersion)
        #expect(try store.objects(titled: "pump p-2").map(\.id) == [id])
    }

    @Test func batchFetchPreservesRequestedOrderAndSkipsUnknownIDs() throws {
        let store = try NexusStore(.inMemory)
        let a = try store.create(ObjectRecord(type: .component, title: "A", provenance: prov(.recorded)))
        let b = try store.create(ObjectRecord(type: .component, title: "B", provenance: prov(.recorded)))
        #expect(try store.objects([b.id, .make(), a.id]).map(\.id) == [b.id, a.id])
        #expect(try store.objects([]).isEmpty)
    }

    @Test func exactTitleLookupIgnoresCaseAndDeletedObjects() throws {
        let store = try NexusStore(.inMemory)
        let live = try store.create(ObjectRecord(type: .sensor, title: "LT-101", provenance: prov(.recorded)))
        let gone = try store.create(ObjectRecord(type: .sensor, title: "lt-101", provenance: prov(.recorded)))
        try store.update(gone.id, by: tech) { $0.lifecycle = .deleted }
        #expect(try store.objects(titled: "Lt-101").map(\.id) == [live.id])
    }

    @Test func endingARelationshipKeepsItsHistory() throws {
        let store = try NexusStore(.inMemory)
        let project = try store.create(ObjectRecord(type: .project, title: "P", provenance: prov(.recorded)))
        let pump = try store.create(ObjectRecord(type: .equipment, title: "Pump", provenance: prov(.recorded)))
        let link = try store.relate(Relationship(kind: .contains, from: project.id, to: pump.id, validFrom: t0, provenance: prov(.recorded)))

        #expect(throws: StoreError.protectedRemoval(object: link.id, attribute: "validTo", by: .agent(id: "a", run: nil))) {
            try store.end(link.id, at: t0 + 10, by: .agent(id: "a", run: nil))
        }
        #expect(throws: ModelError.invalidInterval(link.id)) {
            try store.end(link.id, at: t0 - 10, by: tech)
        }

        let ended = try store.end(link.id, at: t0 + 10, by: tech)
        #expect(ended.validTo == t0 + 10)
        #expect(try store.relationship(link.id) == ended)
        #expect(try store.relationships(from: project.id) == [ended])
        #expect(throws: StoreError.immutableField(object: link.id, field: "validTo")) {
            try store.end(link.id, at: t0 + 20, by: tech)
        }
    }

    @Test func searchFiltersByTruthTimeAndScope() throws {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let recorded = try store.create(ObjectRecord(type: .note, title: "valve stiction note", provenance: prov(.recorded)))
        let agent = try store.create(ObjectRecord(
            type: .note, title: "valve stiction suspected", provenance: prov(.agentInterpretation, .agent(id: "diag", run: nil))
        ))
        clock.advance(by: 3600)
        try store.update(recorded.id, by: tech) { $0.title = "valve stiction note (checked)" }

        #expect(try store.search("stiction", filter: SearchFilter(truth: [.agentInterpretation])).map(\.id) == [agent.id])
        #expect(try store.search("stiction", filter: SearchFilter(updatedFrom: t0 + 60)).map(\.id) == [recorded.id])
        #expect(try store.search("stiction", filter: SearchFilter(updatedTo: t0 + 60)).map(\.id) == [agent.id])
        #expect(try store.search("stiction", filter: SearchFilter(scope: [agent.id])).map(\.id) == [agent.id])
        #expect(try store.search("stiction", filter: SearchFilter(scope: [])).isEmpty)
        // The scope table is cleared, so a later unscoped search sees everything.
        #expect(try Set(store.search("stiction").map(\.id)) == [recorded.id, agent.id])
    }
}

private extension ObjectType {
    static let note: ObjectType = "note"
}
