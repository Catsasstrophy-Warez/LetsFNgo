import Foundation
import NexusPersistence

/// What one `SyncEngine.sync()` did.
public struct SyncReport: Sendable {
    /// The change set pushed, or nil when nothing had changed locally.
    public var pushed: ChangeSet?
    /// One result per change set pulled and applied.
    public var applied: [SyncApplyResult]
    /// Blobs fetched and stored.
    public var blobsReceived: Int
    /// Blobs still waiting for their bytes.
    public var blobsPending: Int
}

/// Runs sync between one store and one transport, whatever the transport is.
///
/// Push: the local change set since the last push, plus the bytes of every
/// blob it references. Pull: other replicas' change sets since the last
/// pull, applied through `NexusStore.apply`, so `TruthPolicy` and history
/// apply to synced writes too, then the bytes of any blob still missing.
/// Progress (the last pushed sequence and the pull cursor) is kept in the
/// store's settings, so a restart resumes where it stopped; replaying is
/// harmless because `apply` is idempotent.
public final class SyncEngine: Sendable {
    public let store: NexusStore
    public let transport: any SyncTransport

    static let pushedKey = "pushedThrough"
    static let cursorKey = "pullCursor"

    public init(store: NexusStore, transport: any SyncTransport) {
        self.store = store
        self.transport = transport
    }

    /// Pushes local changes, then pulls and applies everyone else's.
    @discardableResult
    public func sync() async throws -> SyncReport {
        let pushed = try await push()
        let (applied, received, pending) = try await pull()
        return SyncReport(pushed: pushed, applied: applied, blobsReceived: received, blobsPending: pending)
    }

    /// Pushes the change set since the last push, if it holds anything.
    @discardableResult
    public func push() async throws -> ChangeSet? {
        let changeSet = try await store.perform { store -> ChangeSet in
            let since = Int64(try store.setting(NexusStore.syncSettingsNamespace, Self.pushedKey) ?? "") ?? 0
            return try store.changeSet(since: since)
        }
        guard !changeSet.isEmpty else { return nil }
        for digest in changeSet.blobDigests {
            let data = try await store.perform { store -> Data? in
                guard try !store.pendingBlobs().contains(where: { $0.sha256 == digest }) else { return nil }
                return try store.blobData(sha256: digest)
            }
            if let data { try await transport.putBlob(data, sha256: digest) }
        }
        try await transport.push(changeSet)
        let through = changeSet.through
        try await store.perform { try $0.putSetting(NexusStore.syncSettingsNamespace, Self.pushedKey, String(through)) }
        return changeSet
    }

    /// Pulls and applies other replicas' change sets, then fetches missing blobs.
    public func pull() async throws -> (applied: [SyncApplyResult], blobsReceived: Int, blobsPending: Int) {
        let (replica, cursor) = try await store.perform { store in
            (try store.replicaID(), try store.setting(NexusStore.syncSettingsNamespace, Self.cursorKey).map(SyncCursor.init(rawValue:)))
        }
        let pull = try await transport.pull(after: cursor, excluding: replica)
        var applied: [SyncApplyResult] = []
        for changeSet in pull.changeSets {
            applied.append(try await store.perform { try $0.apply(changeSet, from: changeSet.replica) })
        }
        if let next = pull.cursor {
            try await store.perform { try $0.putSetting(NexusStore.syncSettingsNamespace, Self.cursorKey, next.rawValue) }
        }
        var received = 0
        for blob in try await store.perform({ try $0.pendingBlobs() }) {
            guard let data = try await transport.fetchBlob(sha256: blob.sha256) else { continue }
            _ = try await store.perform { try $0.receiveBlob(data) }
            received += 1
        }
        let pending = try await store.perform { try $0.pendingBlobs().count }
        return (applied, received, pending)
    }
}
