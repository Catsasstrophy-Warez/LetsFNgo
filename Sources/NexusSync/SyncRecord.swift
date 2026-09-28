import Foundation
import NexusCore
import NexusPersistence

// MARK: - Records

/// Where a record lives: a zone and a name unique within it. Mirrors
/// `CKRecord.ID` (the owner is always the current user's private database).
public struct SyncRecordID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var zone: String
    public var name: String

    public init(zone: String, name: String) {
        self.zone = zone
        self.name = name
    }

    public var description: String { "\(zone)/\(name)" }
}

/// One field value, limited to what CloudKit stores natively.
public enum SyncFieldValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case date(Date)
    /// Inline bytes. Counts toward the 1 MB record limit.
    case bytes(Data)
    /// A list of assets (`[CKAsset]`). Held in memory here; a CloudKit
    /// database writes them to files. Does not count toward the record limit.
    case assets([Data])
}

/// A CloudKit-shaped record in plain Swift, so the mapping from change sets
/// and blobs is testable on Linux. `CloudKitRecordDatabase` converts it to
/// and from `CKRecord`.
public struct SyncRecord: Hashable, Sendable {
    public var type: String
    public var id: SyncRecordID
    public var fields: [String: SyncFieldValue]
    /// The server's change tag (`recordChangeTag`); nil until saved.
    public var changeTag: String?

    public init(type: String, id: SyncRecordID, fields: [String: SyncFieldValue] = [:], changeTag: String? = nil) {
        self.type = type
        self.id = id
        self.fields = fields
        self.changeTag = changeTag
    }

    /// Bytes that count toward CloudKit's per-record limit: every field
    /// except assets, plus the key names and a little metadata.
    public var inlineByteCount: Int {
        var total = type.utf8.count + id.name.utf8.count + id.zone.utf8.count
        for (key, value) in fields {
            total += key.utf8.count
            switch value {
            case .string(let text): total += text.utf8.count
            case .int, .date: total += 8
            case .bytes(let data): total += data.count
            // Each asset reference is a small descriptor in the record.
            case .assets(let parts): total += 256 * parts.count
            }
        }
        return total
    }

    public subscript(string key: String) -> String? {
        if case .string(let value)? = fields[key] { return value }
        return nil
    }

    public subscript(int key: String) -> Int64? {
        if case .int(let value)? = fields[key] { return value }
        return nil
    }

    public subscript(date key: String) -> Date? {
        if case .date(let value)? = fields[key] { return value }
        return nil
    }
}

// MARK: - Errors

/// Why the iCloud account can't be used.
public enum CloudAccountProblem: String, Sendable, Equatable {
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

/// Typed failures of a record-based (CloudKit) transport. The CloudKit
/// adapter maps `CKError` codes onto these; the in-memory database throws
/// them directly, so the handling is tested on Linux.
public enum CloudSyncError: Error, Equatable, Sendable {
    /// No iCloud account, or it is restricted or signing in.
    case accountUnavailable(CloudAccountProblem)
    /// The user's iCloud storage is full.
    case quotaExceeded
    /// Offline or the connection failed; retry later.
    case network(retryAfter: TimeInterval?)
    /// CloudKit asked us to slow down, or is briefly unavailable.
    case rateLimited(retryAfter: TimeInterval?)
    /// The zone doesn't exist (never created, or the user deleted iCloud data).
    case zoneNotFound(String)
    /// A record with this name already exists with other contents.
    case serverRecordChanged(String)
    /// The server no longer accepts the saved change token; refetch from the start.
    case changeTokenExpired
    /// A record exceeds CloudKit's size limit.
    case recordTooLarge(String, bytes: Int)
    /// A record was sealed with a different key than this device holds.
    case keyMismatch(expected: String, found: String)
    /// A record is missing fields or its payload doesn't match its digest.
    case malformedRecord(String, reason: String)
    /// The container or entitlement isn't set up for this build.
    case notConfigured(String)
    case permissionFailure
    case other(String)

    /// Whether trying again later may succeed without the user doing anything.
    public var isRetryable: Bool {
        switch self {
        case .network, .rateLimited, .changeTokenExpired, .zoneNotFound: true
        case .accountUnavailable(let problem): problem == .temporarilyUnavailable || problem == .couldNotDetermine
        default: false
        }
    }

    /// One sentence for Settings.
    public var message: String {
        switch self {
        case .accountUnavailable(.noAccount): "Sign in to iCloud in Settings to sync."
        case .accountUnavailable(.restricted): "iCloud is restricted on this device (Screen Time or a device profile)."
        case .accountUnavailable: "iCloud isn't available right now. Nexus will try again."
        case .quotaExceeded: "Your iCloud storage is full. Free up space or upgrade to keep syncing."
        case .network: "Offline. Nexus will sync when the connection is back."
        case .rateLimited: "iCloud asked Nexus to wait. It will try again shortly."
        case .zoneNotFound: "The sync data in iCloud was reset. Nexus will recreate it."
        case .serverRecordChanged(let name): "iCloud already holds a different record \(name)."
        case .changeTokenExpired: "iCloud asked for a full refresh. Nexus will fetch everything again."
        case .recordTooLarge(let name, let bytes): "Record \(name) is too large for iCloud (\(bytes) bytes)."
        case .keyMismatch:
            "Another device synced with a different key. Wait for iCloud Keychain to bring this device the same key, then sync again."
        case .malformedRecord(let name, let reason): "Record \(name) couldn't be read: \(reason)."
        case .notConfigured(let detail): "iCloud isn't set up for this build: \(detail)"
        case .permissionFailure: "iCloud refused access to the sync container."
        case .other(let detail): detail
        }
    }
}

// MARK: - Mapping

/// How change sets and blobs become records, and back.
///
/// - Change sets live in zone `NexusChangeSets` as `NexusChangeSet` records
///   named by the change set's ID. Plain fields carry what a reader needs
///   before decrypting: the sender, the sequence range, the key ID and the
///   payload's length and SHA-256. The sealed JSON goes inline in `payload`
///   when it fits `inlineLimit` (well under CloudKit's 1 MB per record), and
///   otherwise as assets in `parts`, split every `assetPartSize` bytes.
/// - Blobs live in their own zone, `NexusBlobs`, so fetching change sets
///   never downloads blob bytes. A `NexusBlob` record is named by the blob's
///   SHA-256 (so putting the same bytes twice is harmless) and always
///   carries its sealed bytes as assets.
///
/// Every payload is sealed with `PayloadCipher`. The associated data binds it
/// to its record name and plain fields, so a payload moved to another record,
/// or a record whose sender or range was edited, fails to open.
public struct SyncRecordCodec: Sendable {
    public static let changeSetZone = "NexusChangeSets"
    public static let blobZone = "NexusBlobs"
    public static let changeSetType = "NexusChangeSet"
    public static let blobType = "NexusBlob"
    /// CloudKit's limit on a record's non-asset data.
    public static let recordSizeLimit = 1_000_000
    /// Version of this record layout, stored in every record.
    public static let layoutVersion: Int64 = 1

    public let cipher: PayloadCipher
    /// Largest sealed payload stored inline.
    public let inlineLimit: Int
    /// Largest single asset.
    public let assetPartSize: Int

    public init(cipher: PayloadCipher, inlineLimit: Int = 700_000, assetPartSize: Int = 32 * 1024 * 1024) {
        precondition(inlineLimit > 0 && inlineLimit < Self.recordSizeLimit && assetPartSize > 0)
        self.cipher = cipher
        self.inlineLimit = inlineLimit
        self.assetPartSize = assetPartSize
    }

    // MARK: Names

    public static func changeSetRecordID(_ id: ObjectID) -> SyncRecordID {
        SyncRecordID(zone: changeSetZone, name: "cs-\(id)")
    }

    public static func blobRecordID(sha256: String) -> SyncRecordID {
        SyncRecordID(zone: blobZone, name: "blob-\(sha256)")
    }

    /// The replica that pushed a change set record, readable without the key.
    public static func replica(of record: SyncRecord) -> ReplicaID? {
        record[string: "replica"].map(ReplicaID.init(rawValue:))
    }

    // MARK: Change sets

    public func record(for changeSet: ChangeSet) throws -> SyncRecord {
        let id = Self.changeSetRecordID(changeSet.id)
        let plain = try changeSet.encoded()
        let sealed = try cipher.seal(plain, associatedData: changeSetAD(id, replica: changeSet.replica, since: changeSet.since, through: changeSet.through))
        var fields: [String: SyncFieldValue] = [
            "layout": .int(Self.layoutVersion),
            "version": .int(Int64(changeSet.version)),
            "replica": .string(changeSet.replica.rawValue),
            "since": .int(changeSet.since),
            "through": .int(changeSet.through),
            "createdAt": .date(changeSet.createdAt),
        ]
        fields.merge(payloadFields(sealed)) { $1 }
        let record = SyncRecord(type: Self.changeSetType, id: id, fields: fields)
        try Self.checkSize(record)
        return record
    }

    public func changeSet(from record: SyncRecord) throws -> ChangeSet {
        guard record.type == Self.changeSetType else { throw malformed(record, "not a change set record") }
        try checkLayout(record)
        guard let replica = Self.replica(of: record), let since = record[int: "since"], let through = record[int: "through"] else {
            throw malformed(record, "missing replica or range")
        }
        let sealed = try payload(of: record)
        let plain: Data
        do {
            plain = try cipher.open(sealed, associatedData: changeSetAD(record.id, replica: replica, since: since, through: through))
        } catch {
            throw malformed(record, "payload failed authentication")
        }
        let changeSet = try ChangeSet.decode(plain)
        guard Self.changeSetRecordID(changeSet.id) == record.id, changeSet.replica == replica else {
            throw malformed(record, "payload doesn't match its record")
        }
        return changeSet
    }

    private func changeSetAD(_ id: SyncRecordID, replica: ReplicaID, since: Int64, through: Int64) -> Data {
        Data("nexus.changeset|\(Self.layoutVersion)|\(id)|\(replica)|\(since)|\(through)".utf8)
    }

    // MARK: Blobs

    public func blobRecord(_ data: Data, sha256: String) throws -> SyncRecord {
        guard ContentHash.sha256(data) == sha256 else { throw SyncError.digestMismatch(sha256) }
        let id = Self.blobRecordID(sha256: sha256)
        let sealed = try cipher.seal(data, associatedData: Data(sha256.utf8))
        var fields: [String: SyncFieldValue] = [
            "layout": .int(Self.layoutVersion),
            "sha256": .string(sha256),
        ]
        fields.merge(payloadFields(sealed, forceAssets: true)) { $1 }
        let record = SyncRecord(type: Self.blobType, id: id, fields: fields)
        try Self.checkSize(record)
        return record
    }

    public func blobData(from record: SyncRecord) throws -> Data {
        guard record.type == Self.blobType, let sha256 = record[string: "sha256"], Self.blobRecordID(sha256: sha256) == record.id else {
            throw malformed(record, "not a blob record")
        }
        try checkLayout(record)
        let sealed = try payload(of: record)
        let data: Data
        do {
            data = try cipher.open(sealed, associatedData: Data(sha256.utf8))
        } catch {
            throw malformed(record, "payload failed authentication")
        }
        guard ContentHash.sha256(data) == sha256 else { throw SyncError.digestMismatch(sha256) }
        return data
    }

    // MARK: Payloads and chunking

    /// Splits `data` into consecutive parts of at most `size` bytes.
    public static func split(_ data: Data, partSize size: Int) -> [Data] {
        guard !data.isEmpty else { return [Data()] }
        return stride(from: 0, to: data.count, by: size).map { offset in
            let start = data.startIndex + offset
            return Data(data[start..<min(start + size, data.endIndex)])
        }
    }

    private func payloadFields(_ sealed: Data, forceAssets: Bool = false) -> [String: SyncFieldValue] {
        var fields: [String: SyncFieldValue] = [
            "keyID": .string(cipher.keyID),
            "byteCount": .int(Int64(sealed.count)),
            "digest": .string(ContentHash.sha256(sealed)),
        ]
        if !forceAssets && sealed.count <= inlineLimit {
            fields["payload"] = .bytes(sealed)
        } else {
            fields["parts"] = .assets(Self.split(sealed, partSize: assetPartSize))
        }
        return fields
    }

    /// Reassembles and checks a sealed payload, before any decryption.
    private func payload(of record: SyncRecord) throws -> Data {
        guard let keyID = record[string: "keyID"] else { throw malformed(record, "missing key ID") }
        guard keyID == cipher.keyID else { throw CloudSyncError.keyMismatch(expected: cipher.keyID, found: keyID) }
        let sealed: Data
        switch (record.fields["payload"], record.fields["parts"]) {
        case (.bytes(let inline)?, nil): sealed = inline
        case (nil, .assets(let parts)?): sealed = parts.reduce(into: Data()) { $0.append($1) }
        default: throw malformed(record, "missing payload")
        }
        guard Int64(sealed.count) == record[int: "byteCount"], ContentHash.sha256(sealed) == record[string: "digest"] else {
            throw malformed(record, "payload is incomplete or altered")
        }
        return sealed
    }

    private func checkLayout(_ record: SyncRecord) throws {
        guard let layout = record[int: "layout"] else { throw malformed(record, "missing layout version") }
        guard layout <= Self.layoutVersion else { throw malformed(record, "layout \(layout) is newer than this build") }
    }

    static func checkSize(_ record: SyncRecord) throws {
        let size = record.inlineByteCount
        guard size <= recordSizeLimit else { throw CloudSyncError.recordTooLarge(record.id.name, bytes: size) }
    }

    private func malformed(_ record: SyncRecord, _ reason: String) -> CloudSyncError {
        .malformedRecord(record.id.name, reason: reason)
    }
}
