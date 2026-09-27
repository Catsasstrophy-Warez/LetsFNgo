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

private func temporaryDatabase() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nexus-\(UUID().uuidString)")
        .appendingPathExtension("sqlite")
}

/// A small slice of the Golden Slice instrument loop, used by several tests.
private struct LoopFixture {
    var project: ObjectRecord
    var transmitter: ObjectRecord
    var terminal: ObjectRecord
    var manual: ObjectRecord
    var claim: Claim
    var observed: MeasurementRecord
    var modeled: MeasurementRecord
    var display: MeasurementRecord
    var event: Event

    init() {
        project = ObjectRecord(type: .project, title: "LT-101 level loop investigation", provenance: prov(.recorded))
        transmitter = ObjectRecord(
            type: .sensor, title: "LT-101 level transmitter",
            attributes: [
                "tag": Attribute(.string("LT-101")),
                "supply": Attribute(.quantity(Quantity(24, "V")), provenance: prov(.observed)),
            ],
            provenance: prov(.recorded)
        )
        terminal = ObjectRecord(type: .testPoint, title: "TB-4 terminals 7/8", provenance: prov(.recorded))
        manual = ObjectRecord(
            type: .document, title: "Transmitter installation manual",
            attributes: ["body": Attribute(.string("Minimum lift-off voltage 12 V at the terminals"))],
            provenance: prov(.recorded)
        )
        claim = Claim(
            statement: "The transmitter needs at least 12 V at its terminals",
            sources: [manual.id], passages: ["Minimum lift-off voltage 12 V"], sourceClass: .primary,
            applicability: "firmware 2.x", provenance: prov(.claimed)
        )
        observed = MeasurementRecord(
            quantityName: "terminal voltage", value: Quantity(10.8, "V"), uncertainty: 0.05,
            testPoint: terminal.id, loading: "20 mA under load", sampledAt: t0 + 60, provenance: prov(.observed, at: 60)
        )
        modeled = MeasurementRecord(
            quantityName: "terminal voltage", value: Quantity(13.1, "V"), testPoint: terminal.id,
            sampledAt: t0 + 60, provenance: prov(.modeled, .simulation(run: .make()), at: 60)
        )
        display = MeasurementRecord(
            quantityName: "level", value: Quantity(96.2, "%"), testPoint: terminal.id,
            sampledAt: t0 + 60, provenance: prov(.display, at: 60)
        )
        event = Event(
            at: t0 + 30, kind: .faultInjected, subjects: [terminal.id, transmitter.id],
            summary: "High-resistance terminal injected", payload: ["ohms": .double(180)],
            provenance: prov(.modeled, .simulation(run: .make()), at: 30)
        )
    }

    func write(to store: NexusStore) throws {
        try store.batch { store in
            for object in [project, transmitter, terminal, manual] {
                try store.create(object)
            }
            try store.relate(Relationship(kind: .contains, from: project.id, to: transmitter.id, provenance: prov(.recorded)))
            try store.relate(Relationship(kind: .connectedTo, from: transmitter.id, to: terminal.id, provenance: prov(.recorded)))
            try store.add(claim)
            try store.relate(Relationship(kind: .cites, from: claim.id, to: manual.id, provenance: prov(.claimed)))
            try store.add(observed)
            try store.add(modeled)
            try store.add(display)
            try store.record(event)
        }
    }
}

@Suite struct NexusStoreTests {
    @Test func migrationsApplyOnceAndRecordVersion() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try NexusStore(.file(url)).schemaVersion == Migrations.latestVersion)
        // Reopening must not re-run migrations (the CREATE TABLEs would fail).
        #expect(try NexusStore(.file(url)).schemaVersion == Migrations.latestVersion)
    }

    /// Acceptance gate: the graph, events, claims, measurements, revisions and
    /// timeline survive a save and reload with truth classes intact.
    @Test func everythingSurvivesSaveAndReload() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = LoopFixture()
        let clock = ManualClock(t0 + 120)

        do {
            let store = try NexusStore(.file(url), clock: clock)
            try fixture.write(to: store)
            try store.update(fixture.transmitter.id, by: tech, instruction: "Record nameplate") {
                $0.attributes["model"] = Attribute(.string("LT-3051"), provenance: prov(.observed, at: 120))
            }
        }

        let store = try NexusStore(.file(url), clock: clock)

        let transmitter = try #require(try store.object(fixture.transmitter.id))
        #expect(transmitter.attributes["model"]?.value == .string("LT-3051"))
        #expect(transmitter.truth(of: "supply") == .observed)
        #expect(transmitter.provenance == fixture.transmitter.provenance)

        let revisions = try store.revisions(of: fixture.transmitter.id)
        #expect(revisions.map(\.sequence) == [1, 2])
        #expect(revisions[1].parent == revisions[0].id)
        #expect(revisions[1].instruction == "Record nameplate")
        #expect(revisions[1].id == transmitter.revision)

        let contained = try store.relationships(from: fixture.project.id, kind: .contains)
        #expect(contained.map(\.to) == [fixture.transmitter.id])
        #expect(try store.relationships(to: fixture.terminal.id).map(\.from) == [fixture.transmitter.id])

        #expect(try store.claim(fixture.claim.id) == fixture.claim)
        #expect(try store.claims(citing: fixture.manual.id) == [fixture.claim])
        #expect(try store.object(fixture.claim.id)?.type == .claim)

        let atTerminal = try store.measurements(at: fixture.terminal.id)
        #expect(Set(atTerminal) == [fixture.observed, fixture.modeled, fixture.display])
        #expect(try store.measurements(at: fixture.terminal.id, truth: .observed) == [fixture.observed])
        #expect(try store.measurements(at: fixture.terminal.id, truth: .modeled) == [fixture.modeled])
        #expect(try store.measurements(at: fixture.terminal.id, truth: .display) == [fixture.display])

        #expect(try store.timeline() == [fixture.event])
        #expect(try store.events(about: fixture.transmitter.id) == [fixture.event])
        #expect(try store.timeline(from: t0 + 31).isEmpty)
    }

    @Test func simulationCannotOverwriteObservedTruth() throws {
        let store = try NexusStore(.inMemory)
        let fixture = LoopFixture()
        try fixture.write(to: store)
        let simulation = Origin.simulation(run: .make())

        #expect(throws: StoreError.truthConflict(
            object: fixture.transmitter.id, attribute: "supply", existing: .observed, incoming: .modeled
        )) {
            try store.update(fixture.transmitter.id, by: simulation) {
                $0.attributes["supply"] = Attribute(.quantity(Quantity(22, "V")), provenance: prov(.modeled, simulation))
            }
        }

        // An attribute without its own provenance inherits the object's; the
        // agent cannot sneak a value in that way either.
        #expect(throws: StoreError.self) {
            try store.update(fixture.transmitter.id, by: .agent(id: "diag", run: nil)) {
                $0.attributes["tag"] = Attribute(.string("LT-102"))
                $0.provenance = prov(.agentInterpretation)
            }
        }

        #expect(throws: StoreError.protectedRemoval(object: fixture.transmitter.id, attribute: "supply", by: simulation)) {
            try store.update(fixture.transmitter.id, by: simulation) { $0.attributes["supply"] = nil }
        }

        // Nothing changed, and no revision was written.
        #expect(try store.object(fixture.transmitter.id) == store.revisions(of: fixture.transmitter.id).last?.snapshot)
        #expect(try store.revisions(of: fixture.transmitter.id).count == 1)

        // A new observation may supersede an old one, and the modeled value may
        // sit beside it under its own key.
        let updated = try store.update(fixture.transmitter.id, by: tech) {
            $0.attributes["supply"] = Attribute(.quantity(Quantity(23.8, "V")), provenance: prov(.observed, at: 200))
            $0.attributes["supply.modeled"] = Attribute(.quantity(Quantity(22, "V")), provenance: prov(.modeled, simulation))
        }
        #expect(updated.truth(of: "supply") == .observed)
        #expect(updated.truth(of: "supply.modeled") == .modeled)
    }

    @Test func measurementsAndClaimsAreNotEditableThroughUpdate() throws {
        let store = try NexusStore(.inMemory)
        let fixture = LoopFixture()
        try fixture.write(to: store)
        #expect(throws: StoreError.immutableRecord(fixture.observed.id, .measurement)) {
            try store.update(fixture.observed.id, by: tech) { $0.title = "edited" }
        }
        #expect(throws: StoreError.immutableRecord(fixture.claim.id, .claim)) {
            try store.update(fixture.claim.id, by: tech) { $0.title = "edited" }
        }
    }

    @Test func identityFieldsAreImmutable() throws {
        let store = try NexusStore(.inMemory)
        let record = try store.create(ObjectRecord(type: .task, title: "Check TB-4", provenance: prov(.recorded)))
        #expect(throws: StoreError.immutableField(object: record.id, field: "type")) {
            try store.update(record.id, by: tech) { $0.type = .procedure }
        }
        #expect(throws: StoreError.duplicate(record.id)) { try store.create(record) }
    }

    @Test func failedBatchLeavesPriorStateIntact() throws {
        let store = try NexusStore(.inMemory)
        let kept = try store.create(ObjectRecord(type: .equipment, title: "Tank T-1", provenance: prov(.recorded)))
        let orphan = ObjectRecord(type: .component, title: "Level valve LV-101", provenance: prov(.recorded))

        #expect(throws: StoreError.notFound(orphan.id)) {
            try store.batch { store in
                try store.update(kept.id, by: tech) { $0.title = "Tank T-1 (renamed)" }
                // Fails: the target object does not exist.
                try store.relate(Relationship(kind: .contains, from: kept.id, to: orphan.id, provenance: prov(.recorded)))
            }
        }
        #expect(try store.object(kept.id) == kept)
        #expect(try store.revisions(of: kept.id).count == 1)
        #expect(try store.search("renamed").isEmpty)

        // The store remains usable after the rollback.
        try store.create(orphan)
        try store.relate(Relationship(kind: .contains, from: kept.id, to: orphan.id, provenance: prov(.recorded)))
        #expect(try store.relationships(from: kept.id).count == 1)
    }

    @Test func referencesMustPointAtExistingObjects() throws {
        let store = try NexusStore(.inMemory)
        let missing = ObjectID.make()
        #expect(throws: StoreError.notFound(missing)) {
            try store.add(MeasurementRecord(
                quantityName: "loop current", value: Quantity(4, "mA"), testPoint: missing, sampledAt: t0,
                provenance: prov(.observed)
            ))
        }
        #expect(throws: StoreError.notFound(missing)) {
            try store.record(Event(at: t0, kind: .note, subjects: [missing], summary: "x", provenance: prov(.observed)))
        }
        #expect(throws: StoreError.notFound(missing)) {
            try store.add(Claim(statement: "x", sources: [missing], sourceClass: .unknown, provenance: prov(.claimed)))
        }
    }

    @Test func fullTextSearchFindsObjectsClaimsAndMeasurements() throws {
        let store = try NexusStore(.inMemory)
        let fixture = LoopFixture()
        try fixture.write(to: store)

        let liftOff = try store.search("lift-off")
        #expect(Set(liftOff.map(\.id)) == [fixture.manual.id, fixture.claim.id])
        #expect(try store.search("lift", types: [.claim]).map(\.id) == [fixture.claim.id])
        #expect(try store.search("LT-101 transmitter").map(\.id) == [fixture.transmitter.id])
        #expect(try store.search("terminal voltage", types: [.measurement]).count == 2)
        // FTS syntax in user input is treated as plain words, not operators.
        #expect(try store.search("\"NEAR( OR *").isEmpty)
        #expect(try store.search("   ").isEmpty)

        // Updates re-index, and deleted objects drop out of results.
        try store.update(fixture.project.id, by: tech) { $0.title = "Compressor C-7 vibration" }
        #expect(try store.search("compressor").map(\.id) == [fixture.project.id])
        #expect(try store.search("investigation").isEmpty)
        try store.update(fixture.project.id, by: tech) { $0.lifecycle = .deleted }
        #expect(try store.search("compressor").isEmpty)
    }

    @Test func newerSchemaIsRejected() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let connection = try SQLiteConnection(path: url.path)
        try connection.execute("""
            CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at REAL NOT NULL);
            INSERT INTO schema_migrations VALUES (999, 'future', 0);
            """)
        #expect(throws: StoreError.schemaTooNew(found: 999, supported: Migrations.latestVersion)) {
            _ = try NexusStore(.file(url))
        }
    }
}
