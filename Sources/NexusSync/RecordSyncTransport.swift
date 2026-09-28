import Foundation
import NexusCore
import NexusPersistence

/// One page of a zone's change feed.
public struct SyncRecordChanges: Sendable {
    /// The latest version of each record changed since the token.
    public var changed: [SyncRecord]
    public var deleted: [SyncRecordID]
    /// Where the next fetch continues (a serialized `CKServerChangeToken`).
    public var token: Data
    /// More changes are waiting; fetch again from `token`.
    public var moreComing: Bool

    public init(changed: [SyncRecord], deleted: [SyncRecordID], token: Data, moreComing: Bool) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

/// The few operations a record transport needs from a CloudKit-like
/// database. `CloudKitRecordDatabase` implements it over a `CKDatabase`;
/// `InMemoryRecordDatabase` mimics CloudKit's semantics for tests.
///
/// Implementations throw `CloudSyncError`.
public protocol SyncRecordDatabase: Sendable {
    /// Creates a zone; succeeds if it already exists.
    func createZone(_ zone: String) async throws
    /// Saves records atomically (all or none), with CloudKit's
    /// `ifServerRecordUnchanged` policy: a record with no change tag whose
    /// name is already taken fails with `serverRecordChanged`.
    func save(_ records: [SyncRecord]) async throws
    /// A record with its fields and assets, or nil if there is none.
    func record(_ id: SyncRecordID) async throws -> SyncRecord?
    /// Whether a record exists, without downloading its assets.
    func exists(_ id: SyncRecordID) async throws -> Bool
    /// Changes in a zone after `token` (from the start when nil).
    func changes(in zone: String, since token: Data?) async throws -> SyncRecordChanges
}

/// A `SyncTransport` over any record database: the whole CloudKit transport
/// except the `CKDatabase` calls, so it runs on Linux.
///
/// - Push saves one sealed `NexusChangeSet` record per change set.
/// - Pull follows the change-set zone's change feed. The `SyncCursor` is the
///   server change token, base64-encoded. An expired token restarts the
///   feed from the beginning, which is safe because `apply` is idempotent.
/// - Blobs are content-addressed records in their own zone, fetched by name.
/// - A missing zone is created on first use, and again if the user deleted
///   the app's iCloud data.
public struct RecordSyncTransport: SyncTransport {
    public let database: any SyncRecordDatabase
    public let codec: SyncRecordCodec

    public init(database: any SyncRecordDatabase, codec: SyncRecordCodec) {
        self.database = database
        self.codec = codec
    }

    public func push(_ changeSet: ChangeSet) async throws {
        let record = try codec.record(for: changeSet)
        try await inZone(SyncRecordCodec.changeSetZone) { try await database.save([record]) }
    }

    public func pull(after cursor: SyncCursor?, excluding replica: ReplicaID) async throws -> SyncPull {
        // A cursor that isn't a token (another transport's) starts from the beginning.
        var token = cursor.flatMap { Data(base64Encoded: $0.rawValue) }
        var records: [SyncRecordID: SyncRecord] = [:]
        var restarted = false
        while true {
            let page: SyncRecordChanges
            do {
                page = try await database.changes(in: SyncRecordCodec.changeSetZone, since: token)
            } catch CloudSyncError.changeTokenExpired where !restarted {
                (token, records, restarted) = (nil, [:], true)
                continue
            } catch CloudSyncError.zoneNotFound {
                // Nothing was ever pushed, or the user deleted the app's iCloud
                // data: recreate the zone, and start over next time.
                try await database.createZone(SyncRecordCodec.changeSetZone)
                return SyncPull(changeSets: [], cursor: nil)
            }
            for record in page.changed where record.type == SyncRecordCodec.changeSetType {
                records[record.id] = record
            }
            for id in page.deleted { records[id] = nil }
            token = page.token
            if !page.moreComing { break }
        }
        var changeSets: [ChangeSet] = []
        for record in records.values where SyncRecordCodec.replica(of: record) != replica {
            changeSets.append(try codec.changeSet(from: record))
        }
        // `apply` is commutative; a stable order keeps runs reproducible.
        changeSets.sort { ($0.createdAt, $0.replica, $0.through) < ($1.createdAt, $1.replica, $1.through) }
        return SyncPull(changeSets: changeSets, cursor: token.map { SyncCursor(rawValue: $0.base64EncodedString()) })
    }

    public func fetchBlob(sha256: String) async throws -> Data? {
        do {
            guard let record = try await database.record(SyncRecordCodec.blobRecordID(sha256: sha256)) else { return nil }
            return try codec.blobData(from: record)
        } catch CloudSyncError.zoneNotFound {
            return nil
        }
    }

    public func putBlob(_ data: Data, sha256: String) async throws {
        let id = SyncRecordCodec.blobRecordID(sha256: sha256)
        guard ContentHash.sha256(data) == sha256 else { throw SyncError.digestMismatch(sha256) }
        try await inZone(SyncRecordCodec.blobZone) {
            // Content-addressed: if it's there, it holds these bytes already.
            guard try await !database.exists(id) else { return }
            do {
                try await database.save([try codec.blobRecord(data, sha256: sha256)])
            } catch CloudSyncError.serverRecordChanged {
                // Another device saved the same blob first.
            }
        }
    }

    /// Runs `work`, creating the zone and retrying once if it's missing.
    private func inZone(_ zone: String, _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch CloudSyncError.zoneNotFound {
            try await database.createZone(zone)
            try await work()
        }
    }
}
