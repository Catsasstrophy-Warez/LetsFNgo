import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusPersistence

@Suite struct TelemetryMigrationTests {
    @Test func aVersionFourDatabaseUpgradesToTelemetry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-v4-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        // Build a database as version 4 shipped it.
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at REAL NOT NULL);")
            for migration in Migrations.all where migration.version <= 4 {
                try connection.execute(migration.sql)
                try connection.run(
                    "INSERT INTO schema_migrations VALUES (?, ?, 0)", [.int(Int64(migration.version)), .text(migration.name)]
                )
            }
        }

        let store = try NexusStore(.file(url))
        #expect(store.schemaVersion == 5)
        let channel = TelemetryChannel(
            object: .make(), quantity: "voltage", unit: "V",
            provenance: Provenance(origin: .instrument(id: .make()), truth: .observed, timestamp: Date(timeIntervalSinceReferenceDate: 0))
        )
        try store.createTelemetryChannel(channel)
        let chunk = TelemetryChunk(channel: channel.id, start: 0, end: 1, count: 2, encoding: "test", payload: Data([1, 2, 3]))
        try store.appendTelemetryChunks([chunk], truth: .observed)
        #expect(try store.telemetryChunks(channel: channel.id) == [chunk])
        #expect(throws: StoreError.truthConflict(object: channel.id, attribute: "voltage", existing: .observed, incoming: .modeled)) {
            try store.appendTelemetryChunks([chunk], truth: .modeled)
        }
        let foreign = TelemetryChunk(channel: .make(), start: 0, end: 0, count: 0, encoding: "", payload: Data())
        #expect(throws: StoreError.notFound(foreign.channel)) {
            try store.pruneTelemetry(channel: channel.id, before: 10, replacements: [foreign], by: .system)
        }
        #expect(try store.telemetryChunks(channel: channel.id).count == 1, "A failed prune changes nothing")
    }
}
