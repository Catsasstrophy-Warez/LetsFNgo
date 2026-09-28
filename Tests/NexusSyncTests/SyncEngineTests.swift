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

/// A replica: a store, its clock, and an engine on the shared transport.
private struct Replica {
    let clock = ManualClock(t0)
    let store: NexusStore
    let engine: SyncEngine

    init(_ transport: any SyncTransport) throws {
        store = try NexusStore(.inMemory, clock: clock)
        engine = SyncEngine(store: store, transport: transport)
    }
}

/// Replica-independent content: everything in the store's change set since 0,
/// minus revision IDs, which are local to each replica.
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
    for blob in set.blobs { lines.append("blob " + blob.sha256 + " " + blob.mediaType) }
    for channel in set.telemetryChannels { lines.append("channel " + (try json(channel))) }
    for chunk in set.telemetryChunks { lines.append("chunk " + (try json(chunk))) }
    for alternate in set.alternates { lines.append("alternate " + (try json(alternate))) }
    return lines.sorted()
}

@Suite struct SyncEngineTests {
    @Test func editsOnBothReplicasConverge() async throws {
        let transport = InMemorySyncTransport(cipher: try PayloadCipher(keyData: PayloadCipher.generateKeyData()))
        let a = try Replica(transport)
        let b = try Replica(transport)

        let pump = try a.store.create(
            ObjectRecord(type: .equipment, title: "Pump P-1", attributes: ["speed": Attribute(.double(1450))], provenance: prov(.recorded))
        )
        let point = try a.store.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try a.store.relate(Relationship(kind: .contains, from: pump.id, to: point.id, provenance: prov(.recorded)))
        let manual = Data("pump manual".utf8)
        try a.store.putBlob(manual, mediaType: "text/plain")
        try await a.engine.sync()
        let first = try await b.engine.sync()
        #expect(first.applied.count == 1)
        #expect(first.blobsReceived == 1)
        #expect(first.blobsPending == 0)
        #expect(try b.store.blobData(sha256: ContentHash.sha256(manual)) == manual)

        // Concurrent edits on both sides, of the same and of different things.
        a.clock.advance(by: 10)
        b.clock.advance(by: 20)
        try a.store.update(pump.id, by: tech) {
            $0.title = "Pump P-1A"
            $0.attributes["speed"] = Attribute(.double(1470))
        }
        try a.store.add(
            MeasurementRecord(
                quantityName: "voltage", value: Quantity(23.8, "V"), testPoint: point.id, sampledAt: t0 + 10, provenance: prov(.observed, meter)
            )
        )
        try b.store.update(pump.id, by: tech) { $0.attributes["speed"] = Attribute(.double(1480)) }
        let motor = try b.store.create(ObjectRecord(type: .component, title: "Motor M-1", provenance: prov(.recorded, at: 20)))
        let link = try b.store.relate(Relationship(kind: .contains, from: pump.id, to: motor.id, provenance: prov(.recorded, at: 20)))
        let channel = TelemetryChannel(object: point.id, quantity: "voltage", unit: "V", provenance: prov(.observed, meter))
        try b.store.createTelemetryChannel(channel)
        try b.store.appendTelemetryChunks(
            [TelemetryChunk(channel: channel.id, start: 0, end: 1, count: 2, encoding: "test", payload: Data([1, 2]))], truth: .observed
        )

        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()

        #expect(try content(a.store) == content(b.store))
        for store in [a.store, b.store] {
            let merged = try #require(try store.object(pump.id))
            #expect(merged.title == "Pump P-1A")
            #expect(merged.attributes["speed"]?.value == .double(1480), "The later write wins the shared attribute")
            #expect(try store.relationship(link.id) != nil)
            #expect(try store.measurements(at: point.id).count == 1)
            #expect(try store.telemetryChunks(channel: channel.id).count == 1)
        }
        // The transport only ever held ciphertext.
        let payloads = await transport.storedPayloads()
        #expect(!payloads.isEmpty)
        for payload in payloads {
            #expect(payload.range(of: Data("Pump".utf8)) == nil)
        }
        #expect(await transport.storedBlob(sha256: ContentHash.sha256(manual)) != manual)
    }

    @Test func modeledVersusObservedConflictIsPreserved() async throws {
        let transport = InMemorySyncTransport()
        let a = try Replica(transport)
        let b = try Replica(transport)
        let point = try a.store.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try await a.engine.sync()
        try await b.engine.sync()

        // A technician's meter reads the node on A; later, a simulation on B writes its prediction.
        a.clock.advance(by: 5)
        try a.store.update(point.id, by: meter) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(21.9, "V")), provenance: prov(.observed, meter, at: 5))
        }
        b.clock.advance(by: 300)
        let run = Origin.simulation(run: .make())
        try b.store.update(point.id, by: run) {
            $0.attributes["voltage"] = Attribute(.quantity(Quantity(24, "V")), provenance: prov(.modeled, run, at: 300))
        }

        try await a.engine.sync()
        let atB = try await b.engine.sync()
        let atA = try await a.engine.sync()
        #expect(atB.applied.flatMap(\.conflicts).count == 1)
        #expect(atA.applied.flatMap(\.conflicts).count == 1)

        for store in [a.store, b.store] {
            let merged = try #require(try store.object(point.id))
            #expect(merged.attributes["voltage"]?.value == .quantity(Quantity(21.9, "V")), "The observed value is never overwritten")
            #expect(merged.truth(of: "voltage") == .observed)
            let alternates = try store.alternateRevisions(of: point.id)
            #expect(alternates.count == 1)
            #expect(alternates.first?.truth == .modeled)
            #expect(alternates.first?.clock.author == run)
            #expect(alternates.first?.attribute?.value == .quantity(Quantity(24, "V")))
            let events = try store.events(about: point.id).filter { $0.kind == .syncConflict }
            #expect(events.count == 1)
            #expect(events.first?.payload["rejectedTruth"] == .string("modeled"))
        }
        #expect(try content(a.store) == content(b.store))
    }

    @Test func replayIsIdempotent() async throws {
        let transport = InMemorySyncTransport()
        let a = try Replica(transport)
        let b = try Replica(transport)
        let point = try a.store.create(ObjectRecord(type: .testPoint, title: "TP1", provenance: prov(.recorded)))
        try a.store.add(
            MeasurementRecord(quantityName: "voltage", value: Quantity(24, "V"), testPoint: point.id, sampledAt: t0, provenance: prov(.observed, meter))
        )
        try a.store.update(point.id, by: tech) { $0.attributes["label"] = Attribute(.string("supply")) }
        try await a.engine.sync()
        try await b.engine.sync()
        let settled = try content(b.store)
        let sequence = b.store.syncSequence

        // Pull everything again from the start, several times.
        let replica = try b.store.replicaID()
        for _ in 0..<3 {
            for changeSet in try await transport.pull(after: nil, excluding: replica).changeSets {
                let result = try b.store.apply(changeSet, from: changeSet.replica)
                #expect(!result.changedStore)
            }
        }
        #expect(try content(b.store) == settled)
        #expect(b.store.syncSequence == sequence, "A replay writes nothing, so nothing new is queued for push")
        #expect(try b.store.events(about: point.id).count == (try a.store.events(about: point.id).count))

        // Echoes of A's own changes, relayed by B, change nothing on A either.
        let before = try content(a.store)
        try await b.engine.sync()
        try await a.engine.sync()
        #expect(try content(a.store) == before)
        #expect(try content(a.store) == content(b.store))
    }
}
