import Foundation
import NexusCore
import NexusModel

// MARK: - Background work

extension NexusStore {
    /// Runs `work` against the store on the store's own serial background
    /// queue and returns its result. Use it from the main actor (SwiftUI
    /// views, view models) so that reads and writes never block the UI:
    ///
    ///     let hits = try await store.perform { try $0.search(query) }
    ///     try await store.perform { try $0.update(id, by: user) { $0.title = title } }
    ///
    /// Why a dedicated serial `DispatchQueue` rather than a Swift concurrency
    /// executor: every store call takes a lock and does synchronous SQLite
    /// I/O. Blocking a cooperative-pool thread on that lock could starve other
    /// tasks, while a Dispatch thread may block safely. The queue is serial,
    /// so `perform` calls run one at a time, in the order they were made.
    /// Synchronous calls from other threads still interleave with them
    /// safely, serialised by the store's lock.
    ///
    /// `work` runs whole: a single store call, or a `batch`, is atomic as
    /// always. If the calling task is cancelled before `work` starts, `work`
    /// does not run and `CancellationError` is thrown; once started it
    /// finishes. Change observers are still called on the thread that made
    /// the write, which here is the background queue, so hop to the main actor
    /// inside an observer before touching UI state.
    public func perform<T: Sendable>(_ work: @escaping @Sendable (NexusStore) throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                continuation.resume(with: Result { try work(self) })
            }
        }
    }
}

// MARK: - Restore from backup

extension NexusStore {
    /// Tables every Nexus store has had since migration 1.
    private static let requiredTables = ["objects", "revisions", "relationships", "events", "search_index"]

    /// Restores a backup made by `backup(to:)` into a new file and opens it.
    ///
    /// The backup is opened read-only and checked before anything is written:
    /// it must be an intact SQLite database (`quick_check`), carry a Nexus
    /// migration history that matches this build's migrations, and have a
    /// schema version this build supports. An older schema is accepted and
    /// migrated forward when the restored copy opens; a newer one throws
    /// `schemaTooNew`. The copy is written with `VACUUM INTO`, so the backup
    /// itself is never modified. Blob bytes next to the backup
    /// (`<backup>.blobs`) are copied next to the destination.
    ///
    /// `destinationURL` must not exist: a restore never overwrites a store.
    /// To replace a live store, close it, restore beside it, then swap files.
    @discardableResult
    public static func restore(
        from backupURL: URL, to destinationURL: URL, clock: NexusClock = SystemClock()
    ) throws -> NexusStore {
        let files = FileManager.default
        guard files.fileExists(atPath: backupURL.path) else {
            throw StoreError.invalidBackup(reason: "no file at \(backupURL.path)")
        }
        for suffix in ["", "-wal", ".blobs"] where files.fileExists(atPath: destinationURL.path + suffix) {
            throw StoreError.destinationExists(destinationURL.path + suffix)
        }
        let version = try validateBackup(at: backupURL)

        do {
            do {
                let source = try SQLiteConnection(path: backupURL.path, readOnly: true)
                try source.run("VACUUM INTO ?", [.text(destinationURL.path)])
            }
            let blobs = URL(fileURLWithPath: backupURL.path + ".blobs", isDirectory: true)
            if files.fileExists(atPath: blobs.path) {
                try files.copyItem(at: blobs, to: URL(fileURLWithPath: destinationURL.path + ".blobs", isDirectory: true))
            }
            let store = try NexusStore(.file(destinationURL), clock: clock)
            guard store.schemaVersion >= version else {
                throw StoreError.invalidBackup(reason: "restored copy reports an older schema than the backup")
            }
            return store
        } catch {
            for suffix in ["", "-wal", "-shm", ".blobs"] {
                try? files.removeItem(atPath: destinationURL.path + suffix)
            }
            throw error
        }
    }

    /// Checks a backup file and returns its schema version.
    static func validateBackup(at url: URL) throws -> Int {
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: url.path, readOnly: true)
            let check = try connection.query("PRAGMA quick_check") { $0.text(0) ?? "" }
            guard check == ["ok"] else {
                throw StoreError.invalidBackup(reason: "integrity check failed: \(check.joined(separator: "; "))")
            }
        } catch let error as StoreError {
            if case .invalidBackup = error { throw error }
            throw StoreError.invalidBackup(reason: "not a readable SQLite database (\(error))")
        }
        let tables = Set(
            try connection.query("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')") { $0.text(0) ?? "" }
        )
        guard tables.contains("schema_migrations") else {
            throw StoreError.invalidBackup(reason: "not a Nexus store: no migration history")
        }
        let applied = try connection.query("SELECT version, name FROM schema_migrations ORDER BY version") {
            (Int($0.int(0)), $0.text(1) ?? "")
        }
        guard let version = applied.last?.0, version >= 1 else {
            throw StoreError.invalidBackup(reason: "not a Nexus store: empty migration history")
        }
        guard version <= Migrations.latestVersion else {
            throw StoreError.schemaTooNew(found: version, supported: Migrations.latestVersion)
        }
        let known = Dictionary(uniqueKeysWithValues: Migrations.all.map { ($0.version, $0.name) })
        for (number, name) in applied where known[number] != name {
            throw StoreError.invalidBackup(
                reason: "migration \(number) is '\(name)', expected '\(known[number] ?? "none")'"
            )
        }
        let missing = requiredTables.filter { !tables.contains($0) }
        guard missing.isEmpty else {
            throw StoreError.invalidBackup(reason: "missing tables: \(missing.joined(separator: ", "))")
        }
        return version
    }
}

// MARK: - Column-only reads

/// An object's indexed columns, read without decoding its JSON record.
public struct ObjectSummary: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var type: ObjectType
    public var title: String
    public var lifecycle: Lifecycle
    /// Truth class of the object itself (its provenance).
    public var truth: TruthClass
    public var updatedAt: Date
    public var revision: RevisionID?
}

/// One measurement's plottable fields, read without decoding its JSON record.
public struct MeasurementSample: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var quantityName: String
    public var value: Quantity
    public var truth: TruthClass
    public var sampledAt: Date
}

extension NexusStore {
    /// Lists objects of a type from their indexed columns alone. Much cheaper
    /// than `objects(ofType:)` for lists and pickers; fetch the full record
    /// with `object(_:)` when a row is opened.
    public func summaries(ofType type: ObjectType) throws -> [ObjectSummary] {
        try locked {
            try db.query(
                "SELECT id, title, lifecycle, truth, updated_at, head_revision FROM objects WHERE type = ? ORDER BY id",
                [.text(type.rawValue)]
            ) { row in
                guard let id = row.text(0).flatMap(ObjectID.init),
                    let lifecycle = row.text(2).flatMap(Lifecycle.init(rawValue:)),
                    let truth = row.text(3).flatMap(TruthClass.init(rawValue:))
                else { throw StoreError.corruptRecord(table: "objects", id: row.text(0) ?? "?") }
                return ObjectSummary(
                    id: id, type: type, title: row.text(1) ?? "", lifecycle: lifecycle, truth: truth,
                    updatedAt: Date(timeIntervalSinceReferenceDate: row.real(4)),
                    revision: row.text(5).flatMap(RevisionID.init)
                )
            }
        }
    }

    /// Measurements at a test point for plotting: value, unit, truth class and
    /// time, in sample order, without decoding the full records.
    public func measurementSamples(at testPoint: ObjectID, truth: TruthClass? = nil) throws -> [MeasurementSample] {
        try locked {
            var sql = "SELECT id, quantity, value, unit, truth, sampled_at FROM measurements WHERE test_point = ?"
            var values: [SQLValue] = [.text(testPoint.description)]
            if let truth {
                sql += " AND truth = ?"
                values.append(.text(truth.rawValue))
            }
            return try db.query(sql + " ORDER BY sampled_at, id", values) { row in
                guard let id = row.text(0).flatMap(ObjectID.init),
                    let truth = row.text(4).flatMap(TruthClass.init(rawValue:))
                else { throw StoreError.corruptRecord(table: "measurements", id: row.text(0) ?? "?") }
                return MeasurementSample(
                    id: id, quantityName: row.text(1) ?? "", value: Quantity(row.real(2), row.text(3) ?? ""),
                    truth: truth, sampledAt: Date(timeIntervalSinceReferenceDate: row.real(5))
                )
            }
        }
    }
}
