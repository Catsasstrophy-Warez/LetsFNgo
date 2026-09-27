import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusPersistence

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-ops-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite struct BackupRestoreTests {
    @Test func restoreRoundTripsABackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try NexusStore(.file(directory.appendingPathComponent("live.sqlite")))
        let pump = try live.create(ObjectRecord(type: .equipment, title: "Pump P-9", provenance: recorded))
        try live.update(pump.id, by: tech) { $0.attributes["tag"] = Attribute(.string("P-9")) }
        let manual = try live.putBlob(Data("pump manual".utf8), mediaType: "text/plain")
        try live.putSetting("ns", "k", "v")

        let backupURL = directory.appendingPathComponent("backup.sqlite")
        try live.backup(to: backupURL)
        try live.update(pump.id, by: tech) { $0.title = "Pump P-9 (after backup)" }

        let restoredURL = directory.appendingPathComponent("restored.sqlite")
        let restored = try NexusStore.restore(from: backupURL, to: restoredURL)
        #expect(restored.schemaVersion == Migrations.latestVersion)
        #expect(try restored.object(pump.id)?.title == "Pump P-9")
        #expect(try restored.object(pump.id)?.attributes["tag"]?.value == .string("P-9"))
        #expect(try restored.revisions(of: pump.id).count == 2)
        #expect(try restored.events(about: pump.id).map(\.kind) == [.objectEdited])
        #expect(try restored.search("pump").map(\.id) == [pump.id])
        #expect(try restored.setting("ns", "k") == "v")
        #expect(try restored.blobData(sha256: manual.sha256) == Data("pump manual".utf8))
        #expect(restored.latestChangeSequence == live.latestChangeSequence - 2)

        // The restored store is an ordinary, writable store.
        try restored.update(pump.id, by: tech) { $0.title = "Pump P-9 (restored)" }
        #expect(try restored.search("restored").map(\.id) == [pump.id])

        // Restoring never overwrites.
        #expect(throws: StoreError.destinationExists(restoredURL.path)) {
            try NexusStore.restore(from: backupURL, to: restoredURL)
        }
    }

    @Test func restoreRejectsFilesThatAreNotUsableBackups() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.sqlite")

        func expectInvalid(_ url: URL, _ comment: Comment) {
            let error = #expect(throws: StoreError.self, comment) {
                try NexusStore.restore(from: url, to: destination)
            }
            guard case .invalidBackup = error else {
                Issue.record("\(comment): expected invalidBackup, got \(String(describing: error))")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path), comment)
        }

        expectInvalid(directory.appendingPathComponent("missing.sqlite"), "missing file")

        let garbage = directory.appendingPathComponent("garbage.sqlite")
        try Data(repeating: 0x42, count: 8_192).write(to: garbage)
        expectInvalid(garbage, "not SQLite")

        let foreign = directory.appendingPathComponent("foreign.sqlite")
        try SQLiteConnection(path: foreign.path).execute("CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('x');")
        expectInvalid(foreign, "SQLite, but not a Nexus store")

        let renamed = directory.appendingPathComponent("renamed.sqlite")
        do {
            _ = try NexusStore(.file(renamed))
            try SQLiteConnection(path: renamed.path).execute("UPDATE schema_migrations SET name = 'other' WHERE version = 2;")
        }
        expectInvalid(renamed, "a different migration history")

        let future = directory.appendingPathComponent("future.sqlite")
        do {
            _ = try NexusStore(.file(future))
            try SQLiteConnection(path: future.path).execute("INSERT INTO schema_migrations VALUES (999, 'future', 0);")
        }
        #expect(throws: StoreError.schemaTooNew(found: 999, supported: Migrations.latestVersion)) {
            try NexusStore.restore(from: future, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Suite struct PerformTests {
    @Test func performRunsOnTheStoreQueueAndReturnsItsResult() async throws {
        let store = try NexusStore(.inMemory)
        let id = try await store.perform { store in
            dispatchPrecondition(condition: .onQueue(store.workQueue))
            return try store.create(ObjectRecord(type: .equipment, title: "Pump P-9", provenance: recorded)).id
        }
        let title = try await store.perform { try $0.object(id)?.title }
        #expect(title == "Pump P-9")
        // Synchronous callers still see the same store.
        #expect(try store.object(id)?.title == "Pump P-9")
    }

    @Test func performPropagatesErrorsAndRollsBack() async throws {
        let store = try NexusStore(.inMemory)
        let missing = ObjectID.make()
        await #expect(throws: StoreError.notFound(missing)) {
            try await store.perform { store in
                try store.batch { store in
                    try store.create(ObjectRecord(type: .component, title: "ghost", provenance: recorded))
                    try store.relate(Relationship(kind: .contains, from: missing, to: missing, provenance: recorded))
                }
            }
        }
        #expect(try store.search("ghost").isEmpty)
    }

    @Test func concurrentPerformsAndSyncCallsAreSerialised() async throws {
        let store = try NexusStore(.inMemory)
        let counter = try store.create(
            ObjectRecord(type: .component, title: "Counter", attributes: ["n": Attribute(.int(0))], provenance: recorded)
        )
        @Sendable func increment(_ store: NexusStore) throws {
            try store.update(counter.id, by: tech) {
                guard case .int(let n) = $0.attributes["n"]?.value else { return }
                $0.attributes["n"] = Attribute(.int(n + 1))
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask { try await store.perform(increment) }
            }
            // Meanwhile, synchronous writers on other threads.
            group.addTask {
                DispatchQueue.concurrentPerform(iterations: 10) { _ in try? increment(store) }
            }
            try await group.waitForAll()
        }
        #expect(try store.object(counter.id)?.attributes["n"]?.value == .int(50))
        #expect(try store.revisions(of: counter.id).count == 51)
        #expect(try store.events(about: counter.id).count == 50)
    }

    @Test func cancelledCallersDoNotRunWork() async throws {
        let store = try NexusStore(.inMemory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.perform { store in
                try store.create(ObjectRecord(type: .component, title: "never", provenance: recorded))
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.search("never").isEmpty)
    }
}

@Suite struct StoreOptimisationTests {
    @Test func splicedRevisionJSONMatchesEncodingTheWholeRevision() throws {
        let store = try NexusStore(.inMemory)
        let record = try store.create(
            ObjectRecord(
                type: .sensor, title: "LT-101 \"quoted\" / slash", attributes: ["a": Attribute(.list([.int(1), .null]))],
                provenance: recorded
            )
        )
        let header = RevisionHeader(
            id: .make(), objectID: record.id, parent: record.revision, sequence: 2, author: tech, instruction: nil, at: t0
        )
        let whole = Revision(
            id: header.id, objectID: header.objectID, parent: header.parent, sequence: 2, author: tech,
            instruction: nil, at: t0, snapshot: record
        )
        #expect(try store.revisionJSON(header, snapshotJSON: store.encode(record)) == store.encode(whole))
        var withInstruction = header
        withInstruction.instruction = "why"
        var wholeWithInstruction = whole
        wholeWithInstruction.instruction = "why"
        #expect(
            try store.revisionJSON(withInstruction, snapshotJSON: store.encode(record)) == store.encode(wholeWithInstruction)
        )
        // And what the store wrote decodes to the same revision it returns.
        #expect(try store.revisions(of: record.id).first?.snapshot == record)
    }

    @Test func statementsAreCachedAndBounded() throws {
        let store = try NexusStore(.inMemory)
        let a = try store.create(ObjectRecord(type: .component, title: "A", provenance: recorded))
        let warm = store.db.cachedStatementCount
        for index in 0..<50 {
            try store.create(ObjectRecord(type: .component, title: "B \(index)", provenance: recorded))
            _ = try store.object(a.id)
        }
        #expect(store.db.cachedStatementCount == warm + 1, "Only the point lookup is new")
        // Generated IN lists of every length stay within the bound.
        for count in 1...300 {
            _ = try store.objects(Array(repeating: a.id, count: count))
        }
        #expect(store.db.cachedStatementCount <= SQLiteConnection.cacheLimit)
        #expect(try store.objects([a.id]).map(\.id) == [a.id])
    }

    @Test func connectionPragmasAreSet() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NexusStore(.file(directory.appendingPathComponent("p.sqlite")))
        #expect(try store.db.query("PRAGMA temp_store") { $0.int(0) } == [2], "MEMORY")
        #expect(try store.db.query("PRAGMA cache_size") { $0.int(0) } == [-Int64(NexusStore.cacheSizeKiB)])
        #expect(try store.db.query("PRAGMA mmap_size") { $0.int(0) } == [Int64(NexusStore.mmapBytes)])
        #expect(try store.db.query("PRAGMA foreign_keys") { $0.int(0) } == [1])
    }

    /// Equal bm25 scores are common (titles of one shape), so ties must break
    /// by ID, deterministically, with `limit` counting only filtered hits.
    @Test func searchBreaksScoreTiesByIDAfterFiltering() throws {
        let store = try NexusStore(.inMemory)
        var documents: [ObjectID] = []
        try store.batch { store in
            for index in 0..<120 {
                let type: ObjectType = index.isMultiple(of: 3) ? .document : .component
                let lifecycle: Lifecycle = index.isMultiple(of: 7) ? .deleted : .active
                let record = try store.create(
                    ObjectRecord(type: type, title: "pump valve", lifecycle: lifecycle, provenance: recorded)
                )
                if type == .document, lifecycle != .deleted { documents.append(record.id) }
            }
        }
        let hits = try store.search("pump", types: [.document], limit: 10)
        #expect(Set(hits.map(\.score)).count == 1, "Identical titles tie")
        #expect(hits.map(\.id) == Array(documents.sorted { $0.description < $1.description }.prefix(10)))
        #expect(try store.search("pump", types: [.document], limit: 1_000).count == documents.count)
    }

    @Test func columnReadsMatchDecodedRecords() throws {
        let store = try NexusStore(.inMemory)
        let point = try store.create(ObjectRecord(type: .testPoint, title: "TP-1", provenance: recorded))
        try store.create(ObjectRecord(type: .testPoint, title: "TP-2", lifecycle: .draft, provenance: recorded))
        for index in 0..<5 {
            try store.add(
                MeasurementRecord(
                    quantityName: "loop current", value: Quantity(4 + Double(index), "mA"), testPoint: point.id,
                    sampledAt: t0 + Double(10 - index),
                    provenance: Provenance(origin: tech, truth: index.isMultiple(of: 2) ? .observed : .modeled, timestamp: t0)
                )
            )
        }
        let summaries = try store.summaries(ofType: .testPoint)
        let full = try store.objects(ofType: .testPoint)
        #expect(summaries.map(\.id) == full.map(\.id))
        #expect(summaries.map(\.title) == full.map(\.title))
        #expect(summaries.map(\.lifecycle) == full.map(\.lifecycle))
        #expect(summaries.map(\.truth) == full.map(\.provenance.truth))
        #expect(summaries.map(\.updatedAt) == full.map(\.updatedAt))
        #expect(summaries.map(\.revision) == full.map(\.revision))

        for truth in [nil, TruthClass.observed, .modeled] {
            let samples = try store.measurementSamples(at: point.id, truth: truth)
            let records = try store.measurements(at: point.id, truth: truth)
            #expect(samples.map(\.id) == records.map(\.id))
            #expect(samples.map(\.value) == records.map(\.value))
            #expect(samples.map(\.truth) == records.map(\.truth))
            #expect(samples.map(\.sampledAt) == records.map(\.sampledAt))
            #expect(samples.map(\.quantityName) == records.map(\.quantityName))
        }
    }
}
