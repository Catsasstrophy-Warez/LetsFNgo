#if canImport(CloudKit)
import CloudKit
import Foundation
import NexusPersistence

/// `SyncRecordDatabase` over a CloudKit private database. Apple-only; the
/// mapping and sync logic it serves are in `RecordSyncTransport` and
/// `SyncRecordCodec`, tested on Linux against `InMemoryRecordDatabase`.
///
/// Uses `CKDatabase` directly (zone change feeds with server change tokens)
/// rather than `CKSyncEngine`: `SyncEngine` already owns scheduling, state and
/// merging, and a token maps one-to-one onto `SyncCursor`, so the whole
/// transport stays a pull/push pair that the in-memory fake can mimic.
///
/// Creating a `CKContainer` without the iCloud entitlement traps, so the app
/// builds this only when compiled with `NEXUS_CLOUDKIT` (docs/DEVICE.md).
public final class CloudKitRecordDatabase: SyncRecordDatabase, @unchecked Sendable {
    // CKContainer and CKDatabase are thread-safe; they're never mutated here.
    public let container: CKContainer
    private let database: CKDatabase

    public init(container: CKContainer) {
        self.container = container
        database = container.privateCloudDatabase
    }

    /// Throws `accountUnavailable` unless an iCloud account is signed in.
    public func checkAccount() async throws {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw Self.map(error)
        }
        switch status {
        case .available: return
        case .noAccount: throw CloudSyncError.accountUnavailable(.noAccount)
        case .restricted: throw CloudSyncError.accountUnavailable(.restricted)
        case .temporarilyUnavailable: throw CloudSyncError.accountUnavailable(.temporarilyUnavailable)
        case .couldNotDetermine: throw CloudSyncError.accountUnavailable(.couldNotDetermine)
        @unknown default: throw CloudSyncError.accountUnavailable(.couldNotDetermine)
        }
    }

    public func createZone(_ zone: String) async throws {
        let zoneID = Self.zoneID(zone)
        do {
            let (saved, _) = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            if case .failure(let error)? = saved[zoneID] { throw error }
        } catch {
            throw Self.map(error, zone: zone)
        }
    }

    public func save(_ records: [SyncRecord]) async throws {
        var temporaryFiles: [URL] = []
        defer { for url in temporaryFiles { try? FileManager.default.removeItem(at: url) } }
        do {
            let ckRecords = try records.map { try Self.ckRecord(from: $0, files: &temporaryFiles) }
            let (saved, _) = try await database.modifyRecords(
                saving: ckRecords, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            for (id, result) in saved {
                if case .failure(let error) = result { throw Self.map(error, record: id.recordName, zone: id.zoneID.zoneName) }
            }
        } catch let error as CloudSyncError {
            throw error
        } catch {
            throw Self.map(error, record: records.first?.id.name, zone: records.first?.id.zone)
        }
    }

    public func record(_ id: SyncRecordID) async throws -> SyncRecord? {
        do {
            return try Self.syncRecord(from: try await database.record(for: Self.recordID(id)))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CloudSyncError {
            throw error
        } catch {
            throw Self.map(error, record: id.name, zone: id.zone)
        }
    }

    public func exists(_ id: SyncRecordID) async throws -> Bool {
        let recordID = Self.recordID(id)
        do {
            // No keys: metadata only, so no asset is downloaded.
            let results = try await database.records(for: [recordID], desiredKeys: [])
            switch results[recordID] {
            case .success?: return true
            case .failure(let error as CKError)? where error.code == .unknownItem: return false
            case .failure(let error)?: throw error
            case nil: return false
            }
        } catch {
            throw Self.map(error, record: id.name, zone: id.zone)
        }
    }

    public func changes(in zone: String, since token: Data?) async throws -> SyncRecordChanges {
        let serverToken: CKServerChangeToken?
        if let token {
            guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
                throw CloudSyncError.changeTokenExpired
            }
            serverToken = decoded
        } else {
            serverToken = nil
        }
        do {
            let result = try await database.recordZoneChanges(
                inZoneWith: Self.zoneID(zone), since: serverToken, desiredKeys: nil, resultsLimit: nil
            )
            var changed: [SyncRecord] = []
            for (id, modification) in result.modificationResultsByID {
                switch modification {
                case .success(let modification): changed.append(try Self.syncRecord(from: modification.record))
                case .failure(let error): throw Self.map(error, record: id.recordName, zone: zone)
                }
            }
            let deleted = result.deletions.map { SyncRecordID(zone: zone, name: $0.recordID.recordName) }
            let next = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            return SyncRecordChanges(changed: changed, deleted: deleted, token: next, moreComing: result.moreComing)
        } catch let error as CloudSyncError {
            throw error
        } catch {
            throw Self.map(error, zone: zone)
        }
    }

    // MARK: Mapping CKRecord <-> SyncRecord

    static func zoneID(_ zone: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.name, zoneID: zoneID(id.zone))
    }

    /// A new `CKRecord`. Assets are written to temporary files, listed in
    /// `files` so the caller removes them after the upload.
    static func ckRecord(from record: SyncRecord, files: inout [URL]) throws -> CKRecord {
        let ck = CKRecord(recordType: record.type, recordID: recordID(record.id))
        for (key, value) in record.fields {
            switch value {
            case .string(let text): ck.setObject(text as NSString, forKey: key)
            case .int(let number): ck.setObject(NSNumber(value: number), forKey: key)
            case .date(let date): ck.setObject(date as NSDate, forKey: key)
            case .bytes(let data): ck.setObject(data as NSData, forKey: key)
            case .assets(let parts):
                var assets: [CKAsset] = []
                for part in parts {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-sync-\(UUID().uuidString)")
                    try part.write(to: url, options: .atomic)
                    files.append(url)
                    assets.append(CKAsset(fileURL: url))
                }
                ck.setObject(assets as NSArray, forKey: key)
            }
        }
        return ck
    }

    static func syncRecord(from ck: CKRecord) throws -> SyncRecord {
        var fields: [String: SyncFieldValue] = [:]
        for key in ck.allKeys() {
            let value = ck.object(forKey: key)
            if let text = value as? String {
                fields[key] = .string(text)
            } else if let date = value as? Date {
                fields[key] = .date(date)
            } else if let data = value as? Data {
                fields[key] = .bytes(data)
            } else if let assets = value as? [CKAsset] {
                fields[key] = .assets(try assets.map(read))
            } else if let asset = value as? CKAsset {
                fields[key] = .assets([try read(asset)])
            } else if let number = value as? NSNumber {
                fields[key] = .int(number.int64Value)
            }
        }
        let id = SyncRecordID(zone: ck.recordID.zoneID.zoneName, name: ck.recordID.recordName)
        return SyncRecord(type: ck.recordType, id: id, fields: fields, changeTag: ck.recordChangeTag)
    }

    private static func read(_ asset: CKAsset) throws -> Data {
        guard let url = asset.fileURL else { throw CloudSyncError.other("An iCloud asset has no downloaded file.") }
        return try Data(contentsOf: url)
    }

    // MARK: Errors

    /// Maps a CloudKit error onto `CloudSyncError`.
    static func map(_ error: Error, record: String? = nil, zone: String? = nil) -> Error {
        if error is CloudSyncError { return error }
        if error is URLError { return CloudSyncError.network(retryAfter: nil) }
        guard let ck = error as? CKError else { return error }
        switch ck.code {
        case .partialFailure:
            // The first error that isn't "failed because another item failed".
            if let entry = ck.partialErrorsByItemID?.first(where: { ($0.value as? CKError)?.code != .batchRequestFailed }) {
                return map(entry.value, record: (entry.key.base as? CKRecord.ID)?.recordName ?? record, zone: zone)
            }
            return CloudSyncError.other(ck.localizedDescription)
        case .notAuthenticated: return CloudSyncError.accountUnavailable(.noAccount)
        case .accountTemporarilyUnavailable: return CloudSyncError.accountUnavailable(.temporarilyUnavailable)
        case .quotaExceeded: return CloudSyncError.quotaExceeded
        case .networkUnavailable, .networkFailure: return CloudSyncError.network(retryAfter: ck.retryAfterSeconds)
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return CloudSyncError.rateLimited(retryAfter: ck.retryAfterSeconds)
        case .zoneNotFound, .userDeletedZone: return CloudSyncError.zoneNotFound(zone ?? "")
        case .serverRecordChanged: return CloudSyncError.serverRecordChanged(record ?? "")
        case .changeTokenExpired: return CloudSyncError.changeTokenExpired
        case .limitExceeded, .assetFileNotFound: return CloudSyncError.recordTooLarge(record ?? "", bytes: 0)
        case .missingEntitlement, .badContainer:
            return CloudSyncError.notConfigured("the iCloud container or entitlement is missing (docs/DEVICE.md).")
        case .permissionFailure: return CloudSyncError.permissionFailure
        default: return CloudSyncError.other(ck.localizedDescription)
        }
    }
}

/// Sync over the user's CloudKit private database: a `RecordSyncTransport`
/// on a `CloudKitRecordDatabase`, checking the iCloud account first so an
/// unavailable account surfaces as `CloudSyncError.accountUnavailable`.
public struct CloudKitSyncTransport: SyncTransport {
    public let database: CloudKitRecordDatabase
    private let records: RecordSyncTransport

    public init(containerIdentifier: String, cipher: PayloadCipher) {
        database = CloudKitRecordDatabase(container: CKContainer(identifier: containerIdentifier))
        records = RecordSyncTransport(database: database, codec: SyncRecordCodec(cipher: cipher))
    }

    public func push(_ changeSet: ChangeSet) async throws {
        try await database.checkAccount()
        try await records.push(changeSet)
    }

    public func pull(after cursor: SyncCursor?, excluding replica: ReplicaID) async throws -> SyncPull {
        try await database.checkAccount()
        return try await records.pull(after: cursor, excluding: replica)
    }

    public func fetchBlob(sha256: String) async throws -> Data? {
        try await records.fetchBlob(sha256: sha256)
    }

    public func putBlob(_ data: Data, sha256: String) async throws {
        try await records.putBlob(data, sha256: sha256)
    }
}
#endif
