import Foundation
import NexusCore
import NexusModel
import Testing
@testable import NexusPersistence

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)

/// Collects delivered batches for inspection.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[StoreChange]] = []
    var batches: [[StoreChange]] { lock.withLock { storage } }
    func receive(_ batch: [StoreChange]) { lock.withLock { storage.append(batch) } }
}

@Suite struct ChangeFeedTests {
    @Test func everyKindOfWriteIsLoggedInOrder() throws {
        let store = try NexusStore(.inMemory)
        let a = try store.create(ObjectRecord(type: .component, title: "A", provenance: recorded)).id
        let b = try store.create(ObjectRecord(type: .component, title: "B", provenance: recorded)).id
        try store.update(a, by: tech) { $0.title = "A2" }
        let link = try store.relate(Relationship(kind: .connectedTo, from: a, to: b, provenance: recorded))
        try store.end(link.id, at: t0 + 1, by: tech)
        try store.record(Event(at: t0, kind: .note, subjects: [b], summary: "n", provenance: recorded))

        // The update also appends its objectEdited event in the same write.
        let changes = try store.changes()
        #expect(changes.map(\.kind) == [.created, .created, .updated, .event, .related, .related, .related, .related, .event])
        #expect(changes.map(\.seq) == Array(1...9).map(Int64.init))
        #expect(changes[3].object == a)
        #expect(changes.last?.object == b)
        #expect(try store.changes(after: 7).count == 2)
        #expect(store.latestChangeSequence == 9)
    }

    @Test func observersSeeOnlyCommittedWorkOncePerOutermostWrite() throws {
        let store = try NexusStore(.inMemory)
        let inbox = Inbox()
        let token = store.observeChanges(inbox.receive)

        try store.batch { store in
            try store.create(ObjectRecord(type: .component, title: "one", provenance: recorded))
            try store.create(ObjectRecord(type: .component, title: "two", provenance: recorded))
        }
        #expect(inbox.batches.map(\.count) == [2], "One delivery for the whole batch")

        // A failing batch leaves no rows and no notification.
        #expect(throws: StoreError.self) {
            try store.batch { store in
                try store.create(ObjectRecord(type: .component, title: "ghost", provenance: recorded))
                try store.relate(Relationship(kind: .contains, from: .make(), to: .make(), provenance: recorded))
            }
        }
        #expect(inbox.batches.count == 1)
        #expect(try store.changes().count == 2)

        // A nested failure that the outer batch catches keeps only the outer work.
        try store.batch { store in
            try store.create(ObjectRecord(type: .component, title: "kept", provenance: recorded))
            _ = try? store.batch { store in
                try store.create(ObjectRecord(type: .component, title: "dropped", provenance: recorded))
                throw StoreError.notFound(.make())
            }
        }
        #expect(inbox.batches.last?.count == 1)
        #expect(try store.search("dropped").isEmpty)

        token.cancel()
        try store.create(ObjectRecord(type: .component, title: "unseen", provenance: recorded))
        #expect(inbox.batches.count == 2)
    }

    @Test func observersMayReadTheStoreWhenCalled() throws {
        let store = try NexusStore(.inMemory)
        let seen = Inbox()
        let token = store.observeChanges { batch in
            // Delivered after unlock, so reading back is safe and sees the commit.
            let titles = batch.compactMap { try? store.object($0.object)?.title }
            seen.receive(titles.isEmpty ? [] : batch)
        }
        try store.create(ObjectRecord(type: .component, title: "visible", provenance: recorded))
        #expect(seen.batches.first?.count == 1)
        withExtendedLifetime(token) {}
    }

    @Test func settingsUpsertAndDelete() throws {
        let store = try NexusStore(.inMemory)
        try store.putSetting("ns", "k", "1")
        try store.putSetting("ns", "k", "2")
        try store.putSetting("ns", "other", "x")
        #expect(try store.setting("ns", "k") == "2")
        #expect(try store.settings("ns") == ["k": "2", "other": "x"])
        try store.putSetting("ns", "k", nil)
        #expect(try store.setting("ns", "k") == nil)
        #expect(try store.settings("elsewhere").isEmpty)
    }
}

@Suite struct BackupTests {
    @Test func backupIsAConsistentOpenableCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NexusStore(.file(directory.appendingPathComponent("live.sqlite")))
        let pump = try store.create(ObjectRecord(type: .equipment, title: "Pump P-9", provenance: recorded))
        try store.putSetting("ns", "k", "v")

        let copyURL = directory.appendingPathComponent("copy.sqlite")
        try store.backup(to: copyURL)
        try store.update(pump.id, by: tech) { $0.title = "Pump P-9 (after backup)" }

        let copy = try NexusStore(.file(copyURL))
        #expect(try copy.object(pump.id)?.title == "Pump P-9")
        #expect(try copy.search("pump").map(\.id) == [pump.id])
        #expect(try copy.setting("ns", "k") == "v")
        #expect(copy.latestChangeSequence == 1)
        #expect(throws: StoreError.self) { try store.backup(to: copyURL) }
    }
}
