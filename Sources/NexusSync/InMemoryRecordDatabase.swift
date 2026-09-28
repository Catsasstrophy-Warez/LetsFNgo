import Foundation

/// A record database held in memory that behaves like a CloudKit private
/// database where it matters to sync, for tests and previews:
///
/// - Records live in zones that must be created first (`zoneNotFound`).
/// - Saves are atomic, stamp a new change tag, and refuse a new record whose
///   name is taken or an update with a stale tag (`serverRecordChanged`).
/// - A record's non-asset data is limited to 1 MB (`recordTooLarge`).
/// - Each zone has a change feed. Tokens are opaque; a page holds at most
///   `pageSize` records and says whether more are coming; a record changed
///   twice appears once, in its latest version. Deleting a zone invalidates
///   its tokens (`changeTokenExpired`), as CloudKit does.
/// - `failNext(_:)` injects an error (quota, network, account) into the next call.
public actor InMemoryRecordDatabase: SyncRecordDatabase {
    private struct Zone {
        var generation: Int
        var records: [String: SyncRecord] = [:]
        /// Name of the record changed at each sequence number, oldest first.
        var feed: [(seq: Int, name: String, deleted: Bool)] = []
    }

    private struct Token: Codable {
        var zone: String
        var generation: Int
        var seq: Int
    }

    private var zones: [String: Zone] = [:]
    private var nextSeq = 1
    private var generations = 0
    private var injected: [CloudSyncError] = []
    public let pageSize: Int

    /// Number of calls made, by operation, for tests.
    public private(set) var calls: [String: Int] = [:]

    public init(pageSize: Int = 400) {
        self.pageSize = max(1, pageSize)
    }

    /// The next call (of any kind) throws `error`.
    public func failNext(_ error: CloudSyncError) {
        injected.append(error)
    }

    /// What the user does in Settings → Apple Account → iCloud → Manage
    /// Storage → Delete: the zone and its records disappear.
    public func deleteZone(_ zone: String) {
        zones[zone] = nil
    }

    public func records(in zone: String) -> [SyncRecord] {
        (zones[zone]?.records.values).map { $0.sorted { $0.id.name < $1.id.name } } ?? []
    }

    public func createZone(_ zone: String) async throws {
        try begin("createZone")
        guard zones[zone] == nil else { return }
        generations += 1
        zones[zone] = Zone(generation: generations)
    }

    public func save(_ records: [SyncRecord]) async throws {
        try begin("save")
        // Validate everything first: all or none.
        for record in records {
            guard let zone = zones[record.id.zone] else { throw CloudSyncError.zoneNotFound(record.id.zone) }
            try SyncRecordCodec.checkSize(record)
            if zone.records[record.id.name]?.changeTag != record.changeTag {
                throw CloudSyncError.serverRecordChanged(record.id.name)
            }
        }
        for var record in records {
            record.changeTag = UUID().uuidString
            zones[record.id.zone]?.records[record.id.name] = record
            zones[record.id.zone]?.feed.append((nextSeq, record.id.name, false))
            nextSeq += 1
        }
    }

    public func delete(_ id: SyncRecordID) throws {
        guard zones[id.zone] != nil else { throw CloudSyncError.zoneNotFound(id.zone) }
        zones[id.zone]?.records[id.name] = nil
        zones[id.zone]?.feed.append((nextSeq, id.name, true))
        nextSeq += 1
    }

    public func record(_ id: SyncRecordID) async throws -> SyncRecord? {
        try begin("record")
        guard let zone = zones[id.zone] else { throw CloudSyncError.zoneNotFound(id.zone) }
        return zone.records[id.name]
    }

    public func exists(_ id: SyncRecordID) async throws -> Bool {
        try begin("exists")
        guard let zone = zones[id.zone] else { throw CloudSyncError.zoneNotFound(id.zone) }
        return zone.records[id.name] != nil
    }

    public func changes(in zoneName: String, since token: Data?) async throws -> SyncRecordChanges {
        try begin("changes")
        guard let zone = zones[zoneName] else { throw CloudSyncError.zoneNotFound(zoneName) }
        var after = 0
        if let token {
            guard let decoded = try? JSONDecoder().decode(Token.self, from: token), decoded.zone == zoneName,
                decoded.generation == zone.generation
            else { throw CloudSyncError.changeTokenExpired }
            after = decoded.seq
        }
        // The latest entry per record, in feed order.
        var latest: [String: (seq: Int, deleted: Bool)] = [:]
        for entry in zone.feed where entry.seq > after { latest[entry.name] = (entry.seq, entry.deleted) }
        let ordered = latest.sorted { $0.value.seq < $1.value.seq }
        let page = ordered.prefix(pageSize)
        let through = page.last?.value.seq ?? max(after, zone.feed.last?.seq ?? 0)
        var changed: [SyncRecord] = []
        var deleted: [SyncRecordID] = []
        for (name, entry) in page {
            if entry.deleted {
                deleted.append(SyncRecordID(zone: zoneName, name: name))
            } else if let record = zone.records[name] {
                changed.append(record)
            }
        }
        let next = try JSONEncoder().encode(Token(zone: zoneName, generation: zone.generation, seq: through))
        return SyncRecordChanges(changed: changed, deleted: deleted, token: next, moreComing: ordered.count > page.count)
    }

    private func begin(_ operation: String) throws {
        calls[operation, default: 0] += 1
        if !injected.isEmpty { throw injected.removeFirst() }
    }
}
