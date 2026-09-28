import Foundation
import NexusPersistence

/// An opaque position in a transport's feed of change sets. A CloudKit
/// transport would keep a server change token here; the in-memory one an index.
public struct SyncCursor: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Change sets pushed by other replicas, and where to continue from.
public struct SyncPull: Sendable {
    public var changeSets: [ChangeSet]
    public var cursor: SyncCursor?

    public init(changeSets: [ChangeSet], cursor: SyncCursor?) {
        self.changeSets = changeSets
        self.cursor = cursor
    }
}

/// Moves change sets and blob bytes between replicas. Knows nothing about
/// merging: `SyncEngine` and `NexusStore.apply` do that. Implementations
/// may be CloudKit, a file share, or anything else (decision 0001).
public protocol SyncTransport: Sendable {
    func push(_ changeSet: ChangeSet) async throws
    /// Change sets after `cursor` (from the start when nil), except those
    /// pushed by `replica` itself.
    func pull(after cursor: SyncCursor?, excluding replica: ReplicaID) async throws -> SyncPull
    /// The bytes stored under a SHA-256 digest, or nil if none were put yet.
    func fetchBlob(sha256: String) async throws -> Data?
    func putBlob(_ data: Data, sha256: String) async throws
}

/// A transport held in memory, for tests and previews. Change sets are kept
/// encoded, and sealed when a cipher is given, so everything crosses the same
/// serialisation and encryption boundary a real transport would.
public actor InMemorySyncTransport: SyncTransport {
    private var log: [(replica: ReplicaID, payload: Data)] = []
    private var blobs: [String: Data] = [:]
    private let cipher: PayloadCipher?

    public init(cipher: PayloadCipher? = nil) {
        self.cipher = cipher
    }

    /// Number of change sets pushed so far.
    public var changeSetCount: Int { log.count }

    /// The bytes as stored: ciphertext when a cipher is set.
    public func storedPayloads() -> [Data] { log.map(\.payload) }

    public func storedBlob(sha256: String) -> Data? { blobs[sha256] }

    public func push(_ changeSet: ChangeSet) async throws {
        let data = try changeSet.encoded()
        log.append((changeSet.replica, try cipher?.seal(data, associatedData: Data(changeSet.replica.rawValue.utf8)) ?? data))
    }

    public func pull(after cursor: SyncCursor?, excluding replica: ReplicaID) async throws -> SyncPull {
        let start = cursor.flatMap { Int($0.rawValue) } ?? 0
        var sets: [ChangeSet] = []
        for entry in log.dropFirst(start) where entry.replica != replica {
            let data = try cipher?.open(entry.payload, associatedData: Data(entry.replica.rawValue.utf8)) ?? entry.payload
            sets.append(try ChangeSet.decode(data))
        }
        return SyncPull(changeSets: sets, cursor: SyncCursor(rawValue: String(log.count)))
    }

    public func fetchBlob(sha256: String) async throws -> Data? {
        guard let stored = blobs[sha256] else { return nil }
        return try cipher?.open(stored, associatedData: Data(sha256.utf8)) ?? stored
    }

    public func putBlob(_ data: Data, sha256: String) async throws {
        guard ContentHash.sha256(data) == sha256 else { throw SyncError.digestMismatch(sha256) }
        blobs[sha256] = try cipher?.seal(data, associatedData: Data(sha256.utf8)) ?? data
    }
}
