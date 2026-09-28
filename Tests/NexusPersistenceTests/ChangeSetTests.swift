import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusPersistence

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let agent = Origin.agent(id: "diag", run: nil)
private let meter = Origin.instrument(id: ObjectID("0190b6a0-0000-7000-8000-000000000001")!)

private func prov(_ truth: TruthClass, _ origin: Origin = tech, at offset: TimeInterval = 0) -> Provenance {
    Provenance(origin: origin, truth: truth, timestamp: t0 + offset)
}

/// Two in-memory replicas with their own clocks.
private struct Pair {
    let clockA = ManualClock(t0)
    let clockB = ManualClock(t0)
    let a: NexusStore
    let b: NexusStore

    init() throws {
        a = try NexusStore(.inMemory, clock: clockA)
        b = try NexusStore(.inMemory, clock: clockB)
    }

    /// Sends everything each side has to the other, both ways.
    @discardableResult
    func exchange() throws -> (toB: SyncApplyResult, toA: SyncApplyResult) {
        let fromA = try a.changeSet()
        let fromB = try b.changeSet()
        let toB = try b.apply(fromA, from: fromA.replica)
        let toA = try a.apply(fromB, from: fromB.replica)
        return (toB, toA)
    }
}

/// Replica-independent content: the change set since 0, minus local revision IDs.
private func content(_ store: NexusStore) throws -> [String] {
    let set = try store.changeSet()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    var lines: [String] = []
    for change in set.objects {
        var record = change.record
        record.revision = nil
        lines.append("object " + (try json(record)) + (try json(change.clocks)))
    }
    for change in set.relationships { lines.append("relationship " + (try json(change.relationship)) + (try json(change.clocks))) }
    for event in set.events { lines.append("event " + (try json(event))) }
    for change in set.measurements {
        var object = change.object
        object.revision = nil
        lines.append("measurement " + (try json(change.measurement)) + (try json(object)))
    }
    for change in set.claims { lines.append("claim " + (try json(change.claim))) }
    for blob in set.blobs { lines.append("blob " + blob.sha256) }
    for alternate in set.alternates { lines.append("alternate " + (try json(alternate))) }
    return lines.sorted()
}

@Suite struct ChangeSetTests {
    @Test func changeSetsCarryEveryKindSinceASequence() throws {
        let store = try NexusStore(.inMemory, clock: ManualClock(t0))
        let pump = try store.create(ObjectRecord(type: .equipment, title: "Pump", provenance: prov(.recorded)))
        let point = try store.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        let mark = store.syncSequence
        try store.relate(Relationship(kind: .contains, from: pump.id, to: point.id, provenance: prov(.recorded)))
        try store.add(
            MeasurementRecord(
                quantityName: "voltage", value: Quantity(24, "V"), testPoint: point.id, sampledAt: t0,
                provenance: prov(.observed, meter)
            )
        )
        let blob = try store.putBlob(Data("manual".utf8), mediaType: "text/plain")

        let all = try store.changeSet()
        #expect(all.objects.count == 2)
        #expect(all.measurements.count == 1)
        #expect(all.blobs == [blob])

        let recent = try store.changeSet(since: mark)
        #expect(recent.replica == (try store.replicaID()))
        #expect(recent.since == mark)
        #expect(recent.through == store.syncSequence)
        #expect(recent.objects.isEmpty, "Objects unchanged since the mark are left out")
        #expect(recent.relationships.count == 1)
        #expect(recent.measurements.count == 1)
        #expect(recent.events.map(\.kind) == [.measured])
        #expect(try store.changeSet(since: store.syncSequence).isEmpty)

        // Versioned and Codable.
        let decoded = try ChangeSet.decode(try recent.encoded())
        #expect(decoded == recent)
        var future = recent
        future.version = ChangeSet.currentVersion + 1
        #expect(throws: SyncError.unsupportedVersion(ChangeSet.currentVersion + 1)) { try ChangeSet.decode(try future.encoded()) }
    }

    @Test func attributesMergeByLatestClockWithReplicaTieBreak() throws {
        let pair = try Pair()
        let pump = try pair.a.create(
            ObjectRecord(type: .equipment, title: "Pump", attributes: ["note": Attribute(.string("new"))], provenance: prov(.recorded))
        )
        try pair.exchange()

        // Concurrent edits of different fields both survive; the same field goes to the later write.
        pair.clockA.advance(by: 10)
        pair.clockB.advance(by: 20)
        try pair.a.update(pump.id, by: tech) {
            $0.title = "Pump P-1"
            $0.attributes["note"] = Attribute(.string("from A"))
        }
        try pair.b.update(pump.id, by: tech) {
            $0.attributes["note"] = Attribute(.string("from B"))
            $0.attributes["speed"] = Attribute(.double(1450))
        }
        try pair.exchange()
        for store in [pair.a, pair.b] {
            let merged = try #require(try store.object(pump.id))
            #expect(merged.title == "Pump P-1")
            #expect(merged.attributes["note"]?.value == .string("from B"))
            #expect(merged.attributes["speed"]?.value == .double(1450))
        }
        #expect(try content(pair.a) == content(pair.b))

        // Same time on both replicas: the higher replica ID wins, on both.
        pair.clockA.advance(by: 100)
        pair.clockB.advance(by: 90)
        try pair.a.update(pump.id, by: tech) { $0.attributes["note"] = Attribute(.string("tie A")) }
        try pair.b.update(pump.id, by: tech) { $0.attributes["note"] = Attribute(.string("tie B")) }
        try pair.exchange()
        let expected = try pair.a.replicaID() > pair.b.replicaID() ? "tie A" : "tie B"
        #expect(try pair.a.object(pump.id)?.attributes["note"]?.value == .string(expected))
        #expect(try pair.b.object(pump.id)?.attributes["note"]?.value == .string(expected))
        #expect(try content(pair.a) == content(pair.b))
    }

    @Test func truthPolicyConflictIsPreservedOnBothReplicas() throws {
        let pair = try Pair()
        let point = try pair.a.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try pair.exchange()

        // A records an observed reading; later, B's simulation writes a modeled value to the same attribute.
        pair.clockA.advance(by: 5)
        try pair.a.update(point.id, by: meter) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(23.1, "V")), provenance: prov(.observed, meter, at: 5))
        }
        pair.clockB.advance(by: 60)
        let run = Origin.simulation(run: .make())
        try pair.b.update(point.id, by: run) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(24, "V")), provenance: prov(.modeled, run, at: 60))
        }

        let (toB, toA) = try pair.exchange()
        #expect(toA.conflicts.count == 1)
        #expect(toB.conflicts.count == 1)
        #expect(toA.conflicts == toB.conflicts, "Both replicas derive the same alternate")
        for store in [pair.a, pair.b] {
            let merged = try #require(try store.object(point.id))
            #expect(merged.attributes["voltage"]?.value == .quantity(Quantity(23.1, "V")))
            #expect(merged.truth(of: "voltage") == .observed)
            let alternate = try #require(try store.alternateRevisions(of: point.id).first)
            #expect(alternate.field == "attr:voltage")
            #expect(alternate.truth == .modeled)
            #expect(alternate.attribute?.value == .quantity(Quantity(24, "V")))
            let conflicts = try store.events(about: point.id).filter { $0.kind == .syncConflict }
            #expect(conflicts.map(\.id) == [alternate.conflictEvent])
        }
        #expect(try content(pair.a) == content(pair.b))

        // Replays change nothing.
        let replay = try pair.exchange()
        #expect(!replay.toA.changedStore && !replay.toB.changedStore)
        #expect(try content(pair.a) == content(pair.b))
    }

    @Test func deletesAreStickyTombstones() throws {
        let pair = try Pair()
        let pump = try pair.a.create(ObjectRecord(type: .equipment, title: "Pump", provenance: prov(.claimed)))
        let motor = try pair.a.create(ObjectRecord(type: .equipment, title: "Motor", provenance: prov(.claimed)))
        let link = try pair.a.relate(Relationship(kind: .contains, from: pump.id, to: motor.id, provenance: prov(.claimed)))
        try pair.exchange()

        pair.clockA.advance(by: 1)
        try pair.a.setLifecycle(.deleted, of: pump.id, by: tech)
        try pair.a.end(link.id, at: t0 + 1, by: tech)
        // B edits later, without having seen the delete.
        pair.clockB.advance(by: 50)
        try pair.b.update(pump.id, by: tech) { $0.title = "Pump (renamed)" }
        try pair.b.updateRelationship(link.id, by: tech) { $0.attributes["note"] = Attribute(.string("still here")) }
        try pair.exchange()

        for store in [pair.a, pair.b] {
            let merged = try #require(try store.object(pump.id))
            #expect(merged.lifecycle == .deleted)
            #expect(merged.title == "Pump (renamed)")
            let relationship = try #require(try store.relationship(link.id))
            #expect(relationship.validTo == t0 + 1)
            #expect(relationship.attributes["note"]?.value == .string("still here"))
        }
        #expect(try content(pair.a) == content(pair.b))
        #expect(try pair.b.relationshipRevisions(of: link.id).count == 3, "relate, local edit, merged end")
    }

    @Test func appendOnlyKindsUnionAndReplayIsIdempotent() throws {
        let pair = try Pair()
        let point = try pair.a.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try pair.exchange()
        try pair.a.add(
            MeasurementRecord(
                quantityName: "voltage", value: Quantity(23.1, "V"), testPoint: point.id, sampledAt: t0,
                provenance: prov(.observed, meter)
            )
        )
        try pair.b.add(
            MeasurementRecord(
                quantityName: "voltage", value: Quantity(24, "V"), testPoint: point.id, sampledAt: t0,
                provenance: prov(.modeled, .simulation(run: .make()))
            )
        )
        try pair.b.add(Claim(statement: "Rated 24 V", sources: [point.id], sourceClass: .primary, provenance: prov(.claimed)))
        try pair.b.record(Event(at: t0, kind: .note, subjects: [point.id], summary: "Checked", provenance: prov(.observed)))

        let fromB = try pair.b.changeSet()
        let first = try pair.a.apply(fromB, from: fromB.replica)
        #expect(first.measurementsInserted == 1)
        #expect(first.claimsInserted == 1)
        #expect(first.eventsInserted == 2, "The note and B's measured event")
        let second = try pair.a.apply(fromB, from: fromB.replica)
        #expect(!second.changedStore)
        try pair.exchange()

        for store in [pair.a, pair.b] {
            #expect(try store.measurements(at: point.id).map(\.truth).sorted { $0.rawValue < $1.rawValue } == [.modeled, .observed])
            #expect(try store.events(about: point.id).filter { $0.kind == .measured }.count == 2)
            #expect(try store.claims(citing: point.id).count == 1)
        }
        #expect(try content(pair.a) == content(pair.b))

        // A change set from the store itself is ignored; a mismatched sender is refused.
        let own = try pair.a.changeSet()
        #expect(!(try pair.a.apply(own, from: own.replica).changedStore))
        #expect(throws: SyncError.replicaMismatch(expected: ReplicaID("other"), got: own.replica)) {
            try pair.b.apply(own, from: ReplicaID("other"))
        }
    }

    @Test func blobsTravelByDigestAndMissingOnesAreListed() throws {
        let pair = try Pair()
        let bytes = Data("wiring diagram".utf8)
        let blob = try pair.a.putBlob(bytes, mediaType: "text/plain")
        let (toB, _) = try pair.exchange()
        #expect(toB.missingBlobs.map(\.sha256) == [blob.sha256])
        #expect(try pair.b.pendingBlobs().map(\.sha256) == [blob.sha256])
        #expect(try pair.b.blob(sha256: blob.sha256) == nil)

        #expect(throws: SyncError.unexpectedBlob(ContentHash.sha256(Data("other".utf8)))) { try pair.b.receiveBlob(Data("other".utf8)) }
        let received = try pair.b.receiveBlob(bytes)
        #expect(received.sha256 == blob.sha256)
        #expect(received.mediaType == "text/plain")
        #expect(try pair.b.blobData(sha256: blob.sha256) == bytes)
        #expect(try pair.b.pendingBlobs().isEmpty)
        #expect(try pair.exchange().toB.missingBlobs.isEmpty)
    }

    @Test func telemetryChunksSyncAndDeletesLeaveTombstones() throws {
        let pair = try Pair()
        let channel = TelemetryChannel(object: .make(), quantity: "voltage", unit: "V", provenance: prov(.observed, meter))
        try pair.a.createTelemetryChannel(channel)
        let early = TelemetryChunk(channel: channel.id, start: 0, end: 1, count: 2, encoding: "test", payload: Data([1, 2]))
        let late = TelemetryChunk(channel: channel.id, start: 2, end: 3, count: 2, encoding: "test", payload: Data([3, 4]))
        try pair.a.appendTelemetryChunks([early, late], truth: .observed)
        try pair.exchange()
        #expect(try pair.b.telemetryChunks(channel: channel.id) == [early, late])

        try pair.a.pruneTelemetry(channel: channel.id, before: 2, by: tech)
        let fromB = try pair.b.changeSet()  // still holds the early chunk
        try pair.exchange()
        try pair.a.apply(fromB, from: fromB.replica)
        #expect(try pair.a.telemetryChunks(channel: channel.id) == [late], "A stale replica cannot resurrect a pruned chunk")
        #expect(try pair.b.telemetryChunks(channel: channel.id) == [late])

        try pair.b.deleteTelemetryChannel(channel.id, by: tech)
        try pair.exchange()
        #expect(try pair.a.telemetryChannel(channel.id) == nil)
        #expect(try pair.a.telemetryChunks(channel: channel.id).isEmpty)
    }

    @Test func resolveIsSymmetric() {
        let observed = SyncFieldState(json: "1", truth: .observed)
        let modeled = SyncFieldState(json: "2", truth: .modeled)
        let removed = SyncFieldState(json: nil, truth: nil)
        let older = FieldClock(at: t0, replica: ReplicaID("a"), author: meter)
        let newer = FieldClock(at: t0 + 1, replica: ReplicaID("b"), author: agent)
        let byUser = FieldClock(at: t0 + 1, replica: ReplicaID("b"), author: tech)
        let cases: [(SyncMerge.Side, SyncMerge.Side)] = [
            (.init(state: observed, clock: older), .init(state: modeled, clock: newer)),
            (.init(state: observed, clock: older), .init(state: removed, clock: newer)),
            (.init(state: observed, clock: older), .init(state: removed, clock: byUser)),
            (.init(state: modeled, clock: older), .init(state: SyncFieldState(json: "3", truth: .modeled), clock: newer)),
        ]
        for (x, y) in cases {
            let one = SyncMerge.resolve(field: "attr:v", x, y)
            let two = SyncMerge.resolve(field: "attr:v", y, x)
            #expect(one.winner == two.winner)
            #expect(one.rejected == two.rejected)
        }
        #expect(SyncMerge.resolve(field: "attr:v", cases[0].0, cases[0].1).rejected == cases[0].1)
        #expect(SyncMerge.resolve(field: "attr:v", cases[1].0, cases[1].1).winner == cases[1].0, "An agent cannot remove observed truth")
        #expect(SyncMerge.resolve(field: "attr:v", cases[2].0, cases[2].1).winner == cases[2].1, "A person can")
    }
}
