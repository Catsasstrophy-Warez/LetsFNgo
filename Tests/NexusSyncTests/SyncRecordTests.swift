import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusSync
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

private func prov(_ truth: TruthClass) -> Provenance {
    Provenance(origin: tech, truth: truth, timestamp: t0)
}

private func sampleChangeSet(objects: Int = 2, notes: Int = 0) throws -> ChangeSet {
    let store = try NexusStore(.inMemory, clock: ManualClock(t0))
    for index in 0..<objects {
        var attributes: [String: Attribute] = ["speed": Attribute(.double(1450 + Double(index)))]
        if notes > 0 { attributes["notes"] = Attribute(.string(String(repeating: "Pump P-\(index) notes. ", count: notes))) }
        _ = try store.create(ObjectRecord(type: .equipment, title: "Pump P-\(index)", attributes: attributes, provenance: prov(.recorded)))
    }
    return try store.changeSet()
}

private func cipher() throws -> PayloadCipher {
    try PayloadCipher(keyData: PayloadCipher.generateKeyData())
}

@Suite struct SyncRecordTests {
    @Test func changeSetBecomesASealedInlineRecordAndBack() throws {
        let changeSet = try sampleChangeSet()
        let codec = SyncRecordCodec(cipher: try cipher())
        let record = try codec.record(for: changeSet)

        #expect(record.type == SyncRecordCodec.changeSetType)
        #expect(record.id == SyncRecordID(zone: SyncRecordCodec.changeSetZone, name: "cs-\(changeSet.id)"))
        #expect(record[string: "replica"] == changeSet.replica.rawValue)
        #expect(record[int: "since"] == changeSet.since)
        #expect(record[int: "through"] == changeSet.through)
        #expect(record[date: "createdAt"] == changeSet.createdAt)
        #expect(record[string: "keyID"] == codec.cipher.keyID)
        #expect(record.fields["parts"] == nil)
        guard case .bytes(let sealed)? = record.fields["payload"] else {
            Issue.record("expected an inline payload")
            return
        }
        #expect(sealed.range(of: Data("Pump".utf8)) == nil, "Only ciphertext leaves the device")
        #expect(record.inlineByteCount < SyncRecordCodec.recordSizeLimit)
        #expect(SyncRecordCodec.replica(of: record) == changeSet.replica)
        #expect(try codec.changeSet(from: record) == changeSet)
    }

    @Test func largeChangeSetIsChunkedIntoAssets() throws {
        let changeSet = try sampleChangeSet(objects: 20, notes: 40)
        let plainSize = try changeSet.encoded().count
        let codec = SyncRecordCodec(cipher: try cipher(), inlineLimit: 1_000, assetPartSize: 4_096)
        let record = try codec.record(for: changeSet)

        #expect(record.fields["payload"] == nil)
        guard case .assets(let parts)? = record.fields["parts"] else {
            Issue.record("expected asset parts")
            return
        }
        let sealedSize = plainSize + 29
        #expect(record[int: "byteCount"] == Int64(sealedSize))
        #expect(parts.count == (sealedSize + 4_095) / 4_096)
        #expect(parts.dropLast().allSatisfy { $0.count == 4_096 })
        #expect(parts.reduce(0) { $0 + $1.count } == sealedSize)
        #expect(record.inlineByteCount < 2_000 + parts.count * 256, "Assets don't count toward the record limit")
        #expect(try codec.changeSet(from: record) == changeSet)

        // A missing or reordered part is caught before decryption.
        var truncated = record
        truncated.fields["parts"] = .assets(Array(parts.dropLast()))
        #expect(throws: CloudSyncError.self) { try codec.changeSet(from: truncated) }
        var reordered = record
        reordered.fields["parts"] = .assets(parts.reversed())
        #expect(throws: CloudSyncError.malformedRecord(record.id.name, reason: "payload is incomplete or altered")) {
            try codec.changeSet(from: reordered)
        }
    }

    @Test func splitCoversEveryByteOnce() {
        let data = Data((0..<10).map { UInt8($0) })
        #expect(SyncRecordCodec.split(data, partSize: 3).map(\.count) == [3, 3, 3, 1])
        #expect(SyncRecordCodec.split(data, partSize: 5).map(\.count) == [5, 5])
        #expect(SyncRecordCodec.split(data, partSize: 20) == [data])
        #expect(SyncRecordCodec.split(Data(), partSize: 4) == [Data()])
        #expect(SyncRecordCodec.split(data.dropFirst(2), partSize: 4).reduce(Data(), +) == data.dropFirst(2))
    }

    @Test func blobsAlwaysTravelAsSealedAssets() throws {
        let codec = SyncRecordCodec(cipher: try cipher(), assetPartSize: 16)
        let data = Data("wiring diagram for the LT-101 loop".utf8)
        let sha = ContentHash.sha256(data)
        let record = try codec.blobRecord(data, sha256: sha)

        #expect(record.type == SyncRecordCodec.blobType)
        #expect(record.id == SyncRecordCodec.blobRecordID(sha256: sha))
        #expect(record.id.zone == SyncRecordCodec.blobZone)
        guard case .assets(let parts)? = record.fields["parts"] else {
            Issue.record("expected asset parts")
            return
        }
        #expect(parts.count == (data.count + 29 + 15) / 16)
        #expect(parts.reduce(Data(), +).range(of: Data("LT-101".utf8)) == nil)
        #expect(try codec.blobData(from: record) == data)

        #expect(throws: SyncError.digestMismatch(sha)) { try codec.blobRecord(Data("other".utf8), sha256: sha) }

        // The sealed bytes are bound to their digest: moving them onto another
        // blob's record fails to open.
        let other = Data("another file".utf8)
        let otherSHA = ContentHash.sha256(other)
        var moved = record
        moved.id = SyncRecordCodec.blobRecordID(sha256: otherSHA)
        moved.fields["sha256"] = .string(otherSHA)
        #expect(throws: CloudSyncError.malformedRecord(moved.id.name, reason: "payload failed authentication")) {
            try codec.blobData(from: moved)
        }
    }

    @Test func plainFieldsAreAuthenticatedWithThePayload() throws {
        let codec = SyncRecordCodec(cipher: try cipher())
        let record = try codec.record(for: try sampleChangeSet())
        var forged = record
        forged.fields["replica"] = .string(ReplicaID.make().rawValue)
        #expect(throws: CloudSyncError.malformedRecord(record.id.name, reason: "payload failed authentication")) {
            try codec.changeSet(from: forged)
        }
        var widened = record
        widened.fields["through"] = .int(999)
        #expect(throws: CloudSyncError.self) { try codec.changeSet(from: widened) }
        var newer = record
        newer.fields["layout"] = .int(SyncRecordCodec.layoutVersion + 1)
        #expect(throws: CloudSyncError.malformedRecord(record.id.name, reason: "layout 2 is newer than this build")) {
            try codec.changeSet(from: newer)
        }
    }

    @Test func anotherKeyIsReportedAsAKeyMismatch() throws {
        let mine = try cipher()
        let theirs = try cipher()
        #expect(mine.keyID != theirs.keyID)
        #expect(mine.keyID.count == 16)
        #expect(try PayloadCipher(keyData: Data(repeating: 7, count: 32)).keyID == (try PayloadCipher(keyData: Data(repeating: 7, count: 32)).keyID))
        let record = try SyncRecordCodec(cipher: theirs).record(for: try sampleChangeSet())
        #expect(throws: CloudSyncError.keyMismatch(expected: mine.keyID, found: theirs.keyID)) {
            try SyncRecordCodec(cipher: mine).changeSet(from: record)
        }
    }

    @Test func fakeDatabaseEnforcesCloudKitRules() async throws {
        let database = InMemoryRecordDatabase()
        let big = SyncRecord(type: "X", id: SyncRecordID(zone: "Z", name: "big"), fields: ["b": .bytes(Data(count: 1_100_000))])
        let small = SyncRecord(type: "X", id: SyncRecordID(zone: "Z", name: "small"), fields: ["s": .string("hi")])
        await #expect(throws: CloudSyncError.zoneNotFound("Z")) { try await database.save([small]) }
        try await database.createZone("Z")
        try await database.createZone("Z")
        await #expect(throws: CloudSyncError.recordTooLarge("big", bytes: big.inlineByteCount)) { try await database.save([small, big]) }
        #expect(await database.records(in: "Z").isEmpty, "Saves are atomic")
        try await database.save([small])
        await #expect(throws: CloudSyncError.serverRecordChanged("small")) { try await database.save([small]) }
        var update = try #require(try await database.record(small.id))
        #expect(update.changeTag != nil)
        update.fields["s"] = .string("hello")
        try await database.save([update])
        await #expect(throws: CloudSyncError.serverRecordChanged("small")) { try await database.save([update]) }

        // The change feed holds each record once, in its latest version.
        let feed = try await database.changes(in: "Z", since: nil)
        #expect(feed.changed.count == 1)
        #expect(feed.changed.first?[string: "s"] == "hello")
        #expect(!feed.moreComing)
        #expect(try await database.changes(in: "Z", since: feed.token).changed.isEmpty)

        await database.deleteZone("Z")
        try await database.createZone("Z")
        await #expect(throws: CloudSyncError.changeTokenExpired) { try await database.changes(in: "Z", since: feed.token) }
    }
}
