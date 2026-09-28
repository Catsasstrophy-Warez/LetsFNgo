import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusSync
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let meter = Origin.instrument(id: ObjectID("0190b6a0-0000-7000-8000-000000000001")!)

private func prov(_ truth: TruthClass, _ origin: Origin = tech, at offset: TimeInterval = 0) -> Provenance {
    Provenance(origin: origin, truth: truth, timestamp: t0 + offset)
}

/// A device: its store and clock, and an engine over the shared fake iCloud.
private struct Device {
    let clock = ManualClock(t0)
    let store: NexusStore
    let engine: SyncEngine

    init(_ transport: any SyncTransport) throws {
        store = try NexusStore(.inMemory, clock: clock)
        engine = SyncEngine(store: store, transport: transport)
    }
}

/// A transport over the fake database with a small inline limit and small
/// pages, so tests cross the asset and paging paths.
private func transport(_ database: InMemoryRecordDatabase, key: Data) throws -> RecordSyncTransport {
    RecordSyncTransport(database: database, codec: SyncRecordCodec(cipher: try PayloadCipher(keyData: key), inlineLimit: 2_048, assetPartSize: 1_024))
}

private func changeSet(from store: NexusStore, since: Int64 = 0) throws -> ChangeSet {
    try store.changeSet(since: since)
}

@Suite struct RecordSyncTransportTests {
    @Test func cursorFollowsTheChangeFeed() async throws {
        let database = InMemoryRecordDatabase(pageSize: 2)
        let key = PayloadCipher.generateKeyData()
        let cloud = try transport(database, key: key)
        let store = try NexusStore(.inMemory, clock: ManualClock(t0))
        let me = ReplicaID.make()

        // Before anything is pushed the zone doesn't exist: an empty pull
        // creates it and keeps no cursor.
        let empty = try await cloud.pull(after: nil, excluding: me)
        #expect(empty.changeSets.isEmpty)
        #expect(empty.cursor == nil)

        var pushed: [ChangeSet] = []
        for index in 0..<5 {
            let since = store.syncSequence
            _ = try store.create(ObjectRecord(type: .equipment, title: "Pump P-\(index)", provenance: prov(.recorded)))
            let set = try changeSet(from: store, since: since)
            try await cloud.push(set)
            pushed.append(set)
        }
        #expect(await database.records(in: SyncRecordCodec.changeSetZone).count == 5)

        // Five records over pages of two: the transport follows `moreComing`.
        let first = try await cloud.pull(after: nil, excluding: me)
        #expect(Set(first.changeSets.map(\.id)) == Set(pushed.map(\.id)))
        let cursor = try #require(first.cursor)
        #expect(Data(base64Encoded: cursor.rawValue) != nil, "The cursor is the server change token")

        // From the cursor, only what came after.
        #expect(try await cloud.pull(after: cursor, excluding: me).changeSets.isEmpty)
        let since = store.syncSequence
        _ = try store.create(ObjectRecord(type: .testPoint, title: "TP9", provenance: prov(.recorded)))
        let later = try changeSet(from: store, since: since)
        try await cloud.push(later)
        let next = try await cloud.pull(after: cursor, excluding: me)
        #expect(next.changeSets.map(\.id) == [later.id])

        // A replica never pulls its own change sets back.
        #expect(try await cloud.pull(after: nil, excluding: try store.replicaID()).changeSets.isEmpty)
        // A cursor from another transport starts over.
        #expect(try await cloud.pull(after: SyncCursor(rawValue: "3"), excluding: me).changeSets.count == 6)
    }

    @Test func deletedZoneIsRecreatedAndExpiredTokensRestart() async throws {
        let database = InMemoryRecordDatabase()
        let cloud = try transport(database, key: PayloadCipher.generateKeyData())
        let store = try NexusStore(.inMemory, clock: ManualClock(t0))
        let me = ReplicaID.make()
        _ = try store.create(ObjectRecord(type: .equipment, title: "Pump P-1", provenance: prov(.recorded)))
        try await cloud.push(try changeSet(from: store))
        let cursor = try #require(try await cloud.pull(after: nil, excluding: me).cursor)

        // The user deletes the app's iCloud data; the next push recreates the zone.
        await database.deleteZone(SyncRecordCodec.changeSetZone)
        let since = store.syncSequence
        _ = try store.create(ObjectRecord(type: .equipment, title: "Pump P-2", provenance: prov(.recorded)))
        let after = try changeSet(from: store, since: since)
        try await cloud.push(after)

        // The old token is refused; the transport refetches from the start.
        let pulled = try await cloud.pull(after: cursor, excluding: me)
        #expect(pulled.changeSets.map(\.id) == [after.id])
        #expect(pulled.cursor != nil && pulled.cursor != cursor)
        #expect(await database.calls["changes", default: 0] == 3)
    }

    @Test func blobsAreContentAddressedAndUploadedOnce() async throws {
        let database = InMemoryRecordDatabase()
        let cloud = try transport(database, key: PayloadCipher.generateKeyData())
        let data = Data(repeating: 0x5A, count: 5_000)
        let sha = ContentHash.sha256(data)

        #expect(try await cloud.fetchBlob(sha256: sha) == nil, "No zone yet reads as no blob")
        try await cloud.putBlob(data, sha256: sha)
        try await cloud.putBlob(data, sha256: sha)
        #expect(await database.calls["save"] == 1, "The second put finds the record and uploads nothing")
        #expect(try await cloud.fetchBlob(sha256: sha) == data)
        let stored = try #require(await database.records(in: SyncRecordCodec.blobZone).first)
        guard case .assets(let parts)? = stored.fields["parts"] else {
            Issue.record("expected asset parts")
            return
        }
        #expect(parts.count == 5)
        await #expect(throws: SyncError.digestMismatch(sha)) { try await cloud.putBlob(Data("x".utf8), sha256: sha) }
    }

    @Test func twoDevicesConvergeThroughTheFakeCloud() async throws {
        let database = InMemoryRecordDatabase(pageSize: 3)
        let key = PayloadCipher.generateKeyData()
        let a = try Device(try transport(database, key: key))
        let b = try Device(try transport(database, key: key))

        let pump = try a.store.create(
            ObjectRecord(type: .equipment, title: "Pump P-1", attributes: ["speed": Attribute(.double(1450))], provenance: prov(.recorded))
        )
        let point = try a.store.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try a.store.relate(Relationship(kind: .contains, from: pump.id, to: point.id, provenance: prov(.recorded)))
        let manual = Data(repeating: 0x42, count: 3_000) + Data("pump manual".utf8)
        try a.store.putBlob(manual, mediaType: "text/plain")
        try await a.engine.sync()
        let first = try await b.engine.sync()
        #expect(first.applied.count == 1)
        #expect(first.blobsReceived == 1)
        #expect(try b.store.blobData(sha256: ContentHash.sha256(manual)) == manual)

        // Concurrent edits: a shared attribute, an observed reading on A, and a
        // modeled value on B that must not overwrite it.
        a.clock.advance(by: 10)
        b.clock.advance(by: 20)
        try a.store.update(pump.id, by: tech) { $0.title = "Pump P-1A" }
        try a.store.update(point.id, by: meter) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(21.9, "V")), provenance: prov(.observed, meter, at: 10))
        }
        try b.store.update(pump.id, by: tech) { $0.attributes["speed"] = Attribute(.double(1480)) }
        let run = Origin.simulation(run: .make())
        try b.store.update(point.id, by: run) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(24, "V")), provenance: prov(.modeled, run, at: 20))
        }

        for _ in 0..<2 {
            try await a.engine.sync()
            try await b.engine.sync()
        }

        for store in [a.store, b.store] {
            let merged = try #require(try store.object(pump.id))
            #expect(merged.title == "Pump P-1A")
            #expect(merged.attributes["speed"]?.value == .double(1480))
            let tp = try #require(try store.object(point.id))
            #expect(tp.attributes["voltage"]?.value == .quantity(Quantity(21.9, "V")), "Observed truth wins over a newer model")
            #expect(try store.syncConflictCount() == 1)
            #expect(try store.alternateRevisions(of: point.id).count == 1)
        }
        #expect(try a.store.changeSet().objects.count == (try b.store.changeSet().objects.count))

        // Only ciphertext is in the cloud.
        for record in await database.records(in: SyncRecordCodec.changeSetZone) {
            for value in record.fields.values {
                switch value {
                case .bytes(let data): #expect(data.range(of: Data("Pump".utf8)) == nil)
                case .assets(let parts): #expect(parts.reduce(Data(), +).range(of: Data("Pump".utf8)) == nil)
                default: break
                }
            }
        }
    }

    @Test func cloudErrorsReachTheCallerAndTheCursorHolds() async throws {
        let database = InMemoryRecordDatabase()
        let key = PayloadCipher.generateKeyData()
        let a = try Device(try transport(database, key: key))
        let b = try Device(try transport(database, key: key))
        _ = try a.store.create(ObjectRecord(type: .equipment, title: "Pump P-1", provenance: prov(.recorded)))

        await database.failNext(.quotaExceeded)
        await #expect(throws: CloudSyncError.quotaExceeded) { try await a.engine.sync() }
        try await a.engine.sync()

        await database.failNext(.network(retryAfter: 30))
        await #expect(throws: CloudSyncError.network(retryAfter: 30)) { try await b.engine.pull() }
        #expect(try b.store.setting(NexusStore.syncSettingsNamespace, "pullCursor") == nil, "A failed pull keeps the old cursor")
        let pulled = try await b.engine.pull()
        #expect(pulled.applied.count == 1)
        #expect(try b.store.setting(NexusStore.syncSettingsNamespace, "pullCursor") != nil)

        // A device that made its own key can't read the others' records, and says why.
        let c = try Device(try transport(database, key: PayloadCipher.generateKeyData()))
        await #expect(throws: CloudSyncError.self) { try await c.engine.pull() }
        do {
            _ = try await c.engine.pull()
        } catch let error as CloudSyncError {
            guard case .keyMismatch = error else {
                Issue.record("expected a key mismatch, got \(error)")
                return
            }
            #expect(!error.isRetryable)
        }
    }

    @Test func syncLoopReportsStatusAndFollowsLocalChanges() async throws {
        let database = InMemoryRecordDatabase()
        let key = PayloadCipher.generateKeyData()
        let a = try Device(try transport(database, key: key))
        let b = try Device(try transport(database, key: key))
        let loop = SyncLoop(engine: a.engine, interval: .seconds(3_600), debounce: .milliseconds(20))

        await database.failNext(.accountUnavailable(.noAccount))
        var status = await loop.syncNow()
        #expect(status.lastError == CloudSyncError.accountUnavailable(.noAccount).message)
        #expect(status.lastSuccess == nil)
        #expect(!status.isSyncing)
        status = await loop.syncNow()
        #expect(status.lastError == nil)
        #expect(status.lastSuccess != nil)
        #expect(status.completedSyncs == 1)

        // Started, the loop syncs on launch and again shortly after a local change.
        await loop.start()
        _ = await loop.syncNow()
        let before = await loop.status.completedSyncs
        _ = try a.store.create(ObjectRecord(type: .equipment, title: "Pump P-7", provenance: prov(.recorded)))
        var waited = 0
        while await loop.status.completedSyncs == before, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(await loop.status.completedSyncs > before)
        await loop.stop()
        #expect(await !loop.isRunning)

        try await b.engine.sync()
        #expect(try b.store.changeSet().objects.contains { $0.record.title == "Pump P-7" })

        // Conflicts are counted from the store's syncConflict events.
        let point = try b.store.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try await b.engine.sync()
        _ = await loop.syncNow()
        a.clock.advance(by: 5)
        try a.store.update(point.id, by: meter) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(21.9, "V")), provenance: prov(.observed, meter, at: 5))
        }
        b.clock.advance(by: 50)
        let run = Origin.simulation(run: .make())
        try b.store.update(point.id, by: run) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(24, "V")), provenance: prov(.modeled, run, at: 50))
        }
        try await b.engine.sync()
        status = await loop.syncNow()
        #expect(status.conflictCount == 1)
    }
}
