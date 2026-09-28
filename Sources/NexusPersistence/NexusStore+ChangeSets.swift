import Foundation
import NexusCore
import NexusModel

// MARK: - Replicas and clocks

/// Identity of one copy of the store (one device, one install). Generated
/// once and kept in the store's settings; see `NexusStore.replicaID()`.
public struct ReplicaID: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func make() -> ReplicaID { ReplicaID(ObjectID.make().description) }

    public var description: String { rawValue }

    public static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// When, where and by whom a field of an object or relationship was last
/// written. Merges compare `(at, replica)`: the later time wins, and the
/// higher replica ID breaks a tie.
public struct FieldClock: Codable, Sendable, Hashable {
    public var at: Date
    public var replica: ReplicaID
    public var author: Origin

    public init(at: Date, replica: ReplicaID, author: Origin) {
        self.at = at
        self.replica = replica
        self.author = author
    }

    public func isNewer(than other: FieldClock) -> Bool {
        (at, replica) > (other.at, other.replica)
    }
}

/// The head revision an object or relationship had on the sending replica.
public struct RevisionStamp: Codable, Sendable, Hashable {
    public var id: RevisionID?
    public var sequence: Int
    public var author: Origin
    public var instruction: String?
    public var at: Date

    public init(id: RevisionID?, sequence: Int, author: Origin, instruction: String?, at: Date) {
        self.id = id
        self.sequence = sequence
        self.author = author
        self.instruction = instruction
        self.at = at
    }
}

// MARK: - Change set

/// An object's current state on the sending replica, with the clock of every
/// field ("title", "lifecycle", "provenance", "attr:<key>"). A clock for a
/// field the record lacks means that field was removed.
public struct ObjectChange: Codable, Sendable, Hashable {
    public var record: ObjectRecord
    public var head: RevisionStamp
    public var clocks: [String: FieldClock]
}

/// A relationship's current state, with field clocks ("validFrom",
/// "validTo", "provenance", "attr:<key>").
public struct RelationshipChange: Codable, Sendable, Hashable {
    public var relationship: Relationship
    public var head: RevisionStamp
    public var clocks: [String: FieldClock]
}

/// A measurement and the canonical object that registers it. Append-only.
public struct MeasurementChange: Codable, Sendable, Hashable {
    public var measurement: MeasurementRecord
    public var object: ObjectRecord
}

/// A claim and the canonical object that registers it. Append-only.
public struct ClaimChange: Codable, Sendable, Hashable {
    public var claim: Claim
    public var object: ObjectRecord
}

/// One telemetry chunk. Chunks have no ID of their own; a chunk is its
/// channel, time range, count, encoding and payload digest. The payload rides
/// along because chunks are bounded to a few thousand samples.
public struct TelemetryChunkRef: Codable, Sendable, Hashable {
    public var channel: ObjectID
    public var start: Double
    public var end: Double
    public var count: Int
    public var encoding: String
    /// Lowercase hex SHA-256 of `payload`, checked on apply.
    public var sha256: String
    public var payload: Data

    public init(_ chunk: TelemetryChunk) {
        channel = chunk.channel
        start = chunk.start
        end = chunk.end
        count = chunk.count
        encoding = chunk.encoding
        sha256 = ContentHash.sha256(chunk.payload)
        payload = chunk.payload
    }

    public var chunk: TelemetryChunk {
        TelemetryChunk(channel: channel, start: start, end: end, count: count, encoding: encoding, payload: payload)
    }
}

/// A hard delete that must not be undone by a replica still holding the rows.
public struct SyncTombstone: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case telemetryChannel
        case telemetryChunk
    }

    public var kind: Kind
    public var entity: ObjectID
    /// For a chunk: its range and count. Zero for a channel.
    public var start: Double
    public var end: Double
    public var count: Int
    public var deletedAt: Date
}

/// A value that lost a merge only because of `TruthPolicy`: an agent,
/// modeled or other unprotected value that was newer than a recorded or
/// observed one. It is kept here, with a `syncConflict` event, rather than
/// dropped. Its ID is derived from the conflict, so every replica that sees
/// the conflict records the same row.
public struct AlternateRevision: Codable, Sendable, Hashable, Identifiable {
    public enum EntityKind: String, Codable, Sendable, Hashable {
        case object
        case relationship
    }

    public var id: ObjectID
    public var entity: ObjectID
    public var entityKind: EntityKind
    /// "title", "provenance", "attr:<key>", …
    public var field: String
    /// JSON of the value that lost; nil when the losing write removed the field.
    public var valueJSON: String?
    /// Truth class of the value that lost.
    public var truth: TruthClass?
    public var clock: FieldClock
    /// The `syncConflict` event recorded with it.
    public var conflictEvent: ObjectID

    /// The losing attribute, for an "attr:<key>" field.
    public var attribute: Attribute? {
        guard field.hasPrefix("attr:"), let valueJSON else { return nil }
        return try? JSONDecoder().decode(Attribute.self, from: Data(valueJSON.utf8))
    }
}

/// Everything a replica changed after one sequence number of its sync feed,
/// in a transport-independent, versioned form.
///
/// Objects and relationships travel as their current state plus per-field
/// clocks; events, measurements and claims are append-only; blobs travel as
/// SHA-256 references whose bytes the transport moves separately.
public struct ChangeSet: Codable, Sendable, Hashable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    public var id: ObjectID
    /// The replica whose store produced this change set.
    public var replica: ReplicaID
    /// Exclusive lower and inclusive upper bound in the producer's sync feed.
    public var since: Int64
    public var through: Int64
    public var createdAt: Date
    public var objects: [ObjectChange] = []
    public var relationships: [RelationshipChange] = []
    public var events: [Event] = []
    public var measurements: [MeasurementChange] = []
    public var claims: [ClaimChange] = []
    /// Blob metadata. Fetch the bytes of any blob `apply` reports missing.
    public var blobs: [BlobRef] = []
    public var telemetryChannels: [TelemetryChannel] = []
    public var telemetryChunks: [TelemetryChunkRef] = []
    public var tombstones: [SyncTombstone] = []
    public var alternates: [AlternateRevision] = []

    public init(replica: ReplicaID, since: Int64, through: Int64, createdAt: Date) {
        version = Self.currentVersion
        id = .make()
        self.replica = replica
        self.since = since
        self.through = through
        self.createdAt = createdAt
    }

    public var isEmpty: Bool {
        objects.isEmpty && relationships.isEmpty && events.isEmpty && measurements.isEmpty && claims.isEmpty && blobs.isEmpty
            && telemetryChannels.isEmpty && telemetryChunks.isEmpty && tombstones.isEmpty && alternates.isEmpty
    }

    /// SHA-256 digests of every blob referenced.
    public var blobDigests: [String] { blobs.map(\.sha256) }

    /// Stable JSON (sorted keys) for a transport.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a change set, refusing a version newer than this build knows.
    public static func decode(_ data: Data) throws -> ChangeSet {
        struct Header: Decodable { var version: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.version <= currentVersion else { throw SyncError.unsupportedVersion(header.version) }
        return try decoder.decode(ChangeSet.self, from: data)
    }
}

/// What one `apply` did.
public struct SyncApplyResult: Sendable, Hashable {
    public var objectsInserted = 0
    public var objectsMerged = 0
    public var relationshipsInserted = 0
    public var relationshipsMerged = 0
    public var eventsInserted = 0
    public var measurementsInserted = 0
    public var claimsInserted = 0
    public var telemetryChannelsInserted = 0
    public var telemetryChunksInserted = 0
    public var tombstonesApplied = 0
    /// TruthPolicy conflicts first recorded by this apply.
    public var conflicts: [AlternateRevision] = []
    /// Blobs referenced by the change set whose bytes this store lacks.
    /// Fetch them and hand them to `receiveBlob(_:)`.
    public var missingBlobs: [BlobRef] = []

    public init() {}

    /// Whether the apply changed anything (a replay changes nothing).
    public var changedStore: Bool {
        objectsInserted + objectsMerged + relationshipsInserted + relationshipsMerged + eventsInserted + measurementsInserted
            + claimsInserted + telemetryChannelsInserted + telemetryChunksInserted + tombstonesApplied + conflicts.count > 0
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    /// `apply(_:from:)` was told a different sender than the change set names.
    case replicaMismatch(expected: ReplicaID, got: ReplicaID)
    /// The same ID names different kinds of thing on the two replicas.
    case incompatible(ObjectID)
    /// Bytes do not hash to the digest they were sent under.
    case digestMismatch(String)
    /// Bytes arrived for a blob no change set referenced.
    case unexpectedBlob(String)
}

extension EventKind {
    /// Written by sync when `TruthPolicy` kept a protected value over a newer
    /// unprotected one. The payload names the field and the preserved alternate.
    public static let syncConflict: EventKind = "syncConflict"
}

// MARK: - Store API

/// Change sets for sync (migration 7).
///
/// The sync feed (`sync_log`) is kept by triggers on every synced table, so
/// no write path can skip it. `changeSet(since:)` reads it; `apply(_:from:)`
/// merges another replica's change set:
///
/// - Events, measurements and claims are append-only: union by ID.
/// - Objects and relationships merge per field. The field whose clock is later
///   wins, and the higher replica ID breaks a tie.
/// - `TruthPolicy` comes first: a recorded or observed value is never replaced
///   by an unprotected one, whatever the clocks say. When the unprotected value
///   was the newer one, the conflict is kept as a `syncConflict` event and an
///   `AlternateRevision`, on every replica.
/// - Deletes are tombstones. A `deleted` lifecycle and a closed validity
///   interval always win a merge; deleted telemetry leaves `SyncTombstone`s.
/// - Blobs are referenced by SHA-256; the bytes travel separately.
///
/// The merge is commutative and idempotent, so replicas that have seen the
/// same change sets hold the same content, and replaying a change set
/// changes nothing. Revision IDs and local history stay per replica.
extension NexusStore {
    /// Settings namespace for the replica ID and sync progress.
    public static let syncSettingsNamespace = "nexus.sync"

    /// This store's replica ID, created on first use.
    public func replicaID() throws -> ReplicaID {
        try locked { try transaction { try localReplica() } }
    }

    /// The newest sequence number in the sync feed, or 0.
    public var syncSequence: Int64 {
        locked { (try? db.query("SELECT COALESCE(MAX(seq), 0) FROM sync_log") { $0.int(0) }.first) ?? 0 }
    }

    /// Everything changed after `seq` in the sync feed.
    public func changeSet(since seq: Int64 = 0) throws -> ChangeSet {
        try locked {
            try transaction {
                let local = try localReplica()
                let rows = try db.query("SELECT seq, entity, entity_id FROM sync_log WHERE seq > ? ORDER BY seq", [.int(seq)]) {
                    ($0.int(0), $0.text(1) ?? "", $0.text(2) ?? "")
                }
                var set = ChangeSet(replica: local, since: seq, through: rows.last?.0 ?? seq, createdAt: clock.now())
                for (_, entity, key) in rows {
                    try addToChangeSet(&set, entity: entity, key: key, local: local)
                }
                return set
            }
        }
    }

    /// Merges a change set produced by `replica`. Atomic and idempotent. A
    /// change set from this store itself is ignored.
    @discardableResult
    public func apply(_ changeSet: ChangeSet, from replica: ReplicaID) throws -> SyncApplyResult {
        guard changeSet.version <= ChangeSet.currentVersion else { throw SyncError.unsupportedVersion(changeSet.version) }
        guard changeSet.replica == replica else { throw SyncError.replicaMismatch(expected: replica, got: changeSet.replica) }
        return try locked {
            try transaction {
                var result = SyncApplyResult()
                let local = try localReplica()
                guard replica != local else { return result }
                for tombstone in changeSet.tombstones {
                    try applyTombstone(tombstone, into: &result)
                }
                for change in changeSet.objects {
                    try mergeObject(change, from: replica, local: local, into: &result)
                }
                for change in changeSet.measurements {
                    try insertSyncedMeasurement(change, from: replica, into: &result)
                }
                for change in changeSet.claims {
                    try insertSyncedClaim(change, from: replica, into: &result)
                }
                for change in changeSet.relationships {
                    try mergeRelationship(change, from: replica, local: local, into: &result)
                }
                for channel in changeSet.telemetryChannels {
                    try insertSyncedChannel(channel, into: &result)
                }
                for chunk in changeSet.telemetryChunks {
                    try insertSyncedChunk(chunk, into: &result)
                }
                for blob in changeSet.blobs {
                    try noteSyncedBlob(blob, into: &result)
                }
                for event in changeSet.events where !(try eventExists(event.id)) {
                    try insertEvent(event)
                    result.eventsInserted += 1
                }
                for alternate in changeSet.alternates where !(try alternateExists(alternate.id)) {
                    try insertAlternate(alternate)
                }
                return result
            }
        }
    }

    /// Values preserved by TruthPolicy conflicts on an object or relationship.
    public func alternateRevisions(of id: ObjectID) throws -> [AlternateRevision] {
        try locked {
            try db.query("SELECT record FROM sync_alternates WHERE entity_id = ? ORDER BY at, id", [.text(id.description)]) {
                try decode(AlternateRevision.self, $0, table: "sync_alternates")
            }
        }
    }

    /// Blobs referenced by applied change sets whose bytes have not arrived.
    public func pendingBlobs() throws -> [BlobRef] {
        try locked {
            try db.query("SELECT sha256, byte_count, media_type FROM sync_pending_blobs ORDER BY sha256") { row in
                BlobRef(
                    id: .derived(from: "blob|" + (row.text(0) ?? "")), sha256: row.text(0) ?? "", byteCount: Int(row.int(1)),
                    mediaType: row.text(2) ?? "", createdAt: Date(timeIntervalSinceReferenceDate: 0)
                )
            }
        }
    }

    /// Stores the bytes of a pending blob. Throws `unexpectedBlob` for bytes
    /// no change set referenced.
    @discardableResult
    public func receiveBlob(_ data: Data) throws -> BlobRef {
        let digest = ContentHash.sha256(data)
        return try locked {
            try transaction {
                let pending = try db.query(
                    "SELECT media_type FROM sync_pending_blobs WHERE sha256 = ?", [.text(digest)], row: { $0.text(0) }
                )
                guard let mediaType = pending.first else {
                    if let existing = try blob(sha256: digest) { return existing }
                    throw SyncError.unexpectedBlob(digest)
                }
                let blob = try putBlob(data, mediaType: mediaType ?? "application/octet-stream")
                try db.run("DELETE FROM sync_pending_blobs WHERE sha256 = ?", [.text(digest)])
                return blob
            }
        }
    }

    // MARK: Field clocks (hooks for local writes)

    /// Stamps every field that differs between two versions of an object with
    /// this replica's clock.
    func stampFieldClocks(from old: ObjectRecord, to new: ObjectRecord, by author: Origin) throws {
        for field in try changedSyncFields(from: syncFields(of: old), to: syncFields(of: new)) {
            try stampFieldClock(entity: new.id, field: field, at: new.updatedAt, by: author)
        }
    }

    /// Stamps one field with this replica's clock. The time never goes
    /// backwards from the clock it replaces, so a later local edit wins over
    /// the value it edited even when the other replica's clock ran ahead.
    func stampFieldClock(entity: ObjectID, field: String, at: Date, by author: Origin) throws {
        let previous = try db.query(
            "SELECT at FROM sync_field_clocks WHERE entity_id = ? AND field = ?", [.text(entity.description), .text(field)]
        ) { $0.real(0) }.first
        var time = at.timeIntervalSinceReferenceDate
        if let previous, previous >= time { time = previous.nextUp }
        try db.run(
            """
            INSERT INTO sync_field_clocks (entity_id, field, at, replica, author) VALUES (?, ?, ?, NULL, ?)
            ON CONFLICT (entity_id, field) DO UPDATE SET at = excluded.at, replica = NULL, author = excluded.author
            """,
            [.text(entity.description), .text(field), .real(time), .text(try encode(author))]
        )
    }

    /// Mergeable fields of an object as JSON, with the truth class that
    /// protects each (nil where TruthPolicy does not apply).
    func syncFields(of record: ObjectRecord) throws -> [String: SyncFieldState] {
        var fields: [String: SyncFieldState] = [
            "title": SyncFieldState(json: try encode(record.title), truth: nil),
            "lifecycle": SyncFieldState(json: try encode(record.lifecycle), truth: nil),
            "provenance": SyncFieldState(json: try encode(record.provenance), truth: record.provenance.truth),
        ]
        for (key, attribute) in record.attributes {
            fields["attr:" + key] = SyncFieldState(json: try encode(attribute), truth: record.truth(of: key))
        }
        return fields
    }

    func syncFields(of relationship: Relationship) throws -> [String: SyncFieldState] {
        var fields: [String: SyncFieldState] = [
            "validFrom": SyncFieldState(json: try relationship.validFrom.map { try encode($0) }, truth: nil),
            "validTo": SyncFieldState(json: try relationship.validTo.map { try encode($0) }, truth: nil),
            "provenance": SyncFieldState(json: try encode(relationship.provenance), truth: relationship.provenance.truth),
        ]
        for (key, attribute) in relationship.attributes {
            fields["attr:" + key] = SyncFieldState(json: try encode(attribute), truth: relationship.truth(of: key))
        }
        return fields
    }

    func changedSyncFields(from old: [String: SyncFieldState], to new: [String: SyncFieldState]) -> [String] {
        Set(old.keys).union(new.keys).sorted().filter { (old[$0]?.json) != (new[$0]?.json) }
    }

    // MARK: Private: building change sets

    private func localReplica() throws -> ReplicaID {
        if let text = try db.query(
            "SELECT value FROM settings WHERE namespace = ? AND key = 'replica'", [.text(Self.syncSettingsNamespace)], row: { $0.text(0) }
        ).first, let text {
            return ReplicaID(text)
        }
        let replica = ReplicaID.make()
        try db.run(
            "INSERT INTO settings (namespace, key, value, updated_at) VALUES (?, 'replica', ?, ?)",
            [.text(Self.syncSettingsNamespace), .text(replica.rawValue), .real(clock.now().timeIntervalSinceReferenceDate)]
        )
        return replica
    }

    private func addToChangeSet(_ set: inout ChangeSet, entity: String, key: String, local: ReplicaID) throws {
        switch entity {
        case "object":
            guard let id = ObjectID(key), let record = try fetchObject(id) else { return }
            switch record.type {
            case .measurement:
                if let measurement = try measurement(id) { set.measurements.append(MeasurementChange(measurement: measurement, object: record)) }
            case .claim:
                if let claim = try claim(id) { set.claims.append(ClaimChange(claim: claim, object: record)) }
            default:
                let clocks = try resolvedClocks(
                    entity: id, fields: syncFields(of: record), createdAt: record.createdAt, author: record.provenance.origin, local: local
                )
                set.objects.append(ObjectChange(record: record, head: try objectHead(record), clocks: clocks))
            }
        case "relationship":
            guard let id = ObjectID(key), let relationship = try fetchRelationship(id) else { return }
            let clocks = try resolvedClocks(
                entity: id, fields: syncFields(of: relationship), createdAt: relationshipCreatedAt(relationship),
                author: relationship.provenance.origin, local: local
            )
            set.relationships.append(RelationshipChange(relationship: relationship, head: try relationshipHead(relationship), clocks: clocks))
        case "event":
            if let event = try db.query("SELECT record FROM events WHERE id = ?", [.text(key)], row: { try decode(Event.self, $0, table: "events") }).first {
                set.events.append(event)
            }
        case "blob":
            if let blob = try blob(sha256: key) { set.blobs.append(blob) }
        case "telemetryChannel":
            if let id = ObjectID(key), let channel = try telemetryChannel(id) { set.telemetryChannels.append(channel) }
        case "telemetryChunk":
            guard let rowid = Int64(key) else { return }
            let chunk = try db.query(
                "SELECT channel_id, start_at, end_at, sample_count, encoding, payload FROM telemetry_chunks WHERE row_id = ?", [.int(rowid)]
            ) { row -> TelemetryChunk? in
                guard let channel = row.text(0).flatMap(ObjectID.init), let encoding = row.text(4),
                    let payload = row.text(5).flatMap({ Data(base64Encoded: $0) })
                else { return nil }
                return TelemetryChunk(channel: channel, start: row.real(1), end: row.real(2), count: Int(row.int(3)), encoding: encoding, payload: payload)
            }.first
            if let chunk = chunk ?? nil { set.telemetryChunks.append(TelemetryChunkRef(chunk)) }
        case "tombstone":
            guard let rowid = Int64(key) else { return }
            let tombstone = try db.query(
                "SELECT kind, entity_id, start_at, end_at, sample_count, deleted_at FROM sync_tombstones WHERE row_id = ?", [.int(rowid)]
            ) { row -> SyncTombstone? in
                guard let kind = row.text(0).flatMap(SyncTombstone.Kind.init(rawValue:)), let entity = row.text(1).flatMap(ObjectID.init) else {
                    return nil
                }
                return SyncTombstone(
                    kind: kind, entity: entity, start: row.real(2), end: row.real(3), count: Int(row.int(4)),
                    deletedAt: Date(timeIntervalSinceReferenceDate: row.real(5))
                )
            }.first
            if let tombstone = tombstone ?? nil { set.tombstones.append(tombstone) }
        case "alternate":
            set.alternates += try db.query("SELECT record FROM sync_alternates WHERE id = ?", [.text(key)]) {
                try decode(AlternateRevision.self, $0, table: "sync_alternates")
            }
        default:
            return
        }
    }

    private func objectHead(_ record: ObjectRecord) throws -> RevisionStamp {
        let row = try db.query(
            """
            SELECT id, seq, at, json_extract(record, '$.author'), json_extract(record, '$.instruction')
            FROM revisions WHERE object_id = ? ORDER BY seq DESC LIMIT 1
            """,
            [.text(record.id.description)]
        ) { row in
            RevisionStamp(
                id: row.text(0).flatMap(RevisionID.init), sequence: Int(row.int(1)),
                author: try row.data(3).map { try JSONDecoder().decode(Origin.self, from: $0) } ?? record.provenance.origin,
                instruction: row.text(4), at: Date(timeIntervalSinceReferenceDate: row.real(2))
            )
        }.first
        return row ?? RevisionStamp(id: record.revision, sequence: 1, author: record.provenance.origin, instruction: nil, at: record.updatedAt)
    }

    private func relationshipHead(_ relationship: Relationship) throws -> RevisionStamp {
        let row = try db.query(
            "SELECT id, seq, at, author, instruction FROM relationship_revisions WHERE relationship_id = ? ORDER BY seq DESC LIMIT 1",
            [.text(relationship.id.description)]
        ) { row in
            RevisionStamp(
                id: row.text(0).flatMap(RevisionID.init), sequence: Int(row.int(1)),
                author: try row.data(3).map { try JSONDecoder().decode(Origin.self, from: $0) } ?? relationship.provenance.origin,
                instruction: row.text(4), at: Date(timeIntervalSinceReferenceDate: row.real(2))
            )
        }.first
        return row
            ?? RevisionStamp(
                id: nil, sequence: 1, author: relationship.provenance.origin, instruction: nil, at: relationship.provenance.timestamp
            )
    }

    /// Clock of every current field, plus stored clocks of removed ones.
    /// Fields without a stored clock were set at creation on this replica.
    private func resolvedClocks(
        entity: ObjectID, fields: [String: SyncFieldState], createdAt: Date, author: Origin, local: ReplicaID
    ) throws -> [String: FieldClock] {
        var clocks: [String: FieldClock] = [:]
        let rows = try db.query(
            "SELECT field, at, replica, author FROM sync_field_clocks WHERE entity_id = ?", [.text(entity.description)]
        ) { row in
            (
                row.text(0) ?? "",
                FieldClock(
                    at: Date(timeIntervalSinceReferenceDate: row.real(1)), replica: row.text(2).map { ReplicaID($0) } ?? local,
                    author: try row.data(3).map { try JSONDecoder().decode(Origin.self, from: $0) } ?? author
                )
            )
        }
        for (field, clock) in rows { clocks[field] = clock }
        for field in fields.keys where clocks[field] == nil {
            clocks[field] = FieldClock(at: createdAt, replica: local, author: author)
        }
        return clocks
    }

    // MARK: Private: merging

    private func mergeObject(_ change: ObjectChange, from replica: ReplicaID, local: ReplicaID, into result: inout SyncApplyResult) throws {
        var incoming = change.record
        incoming.revision = nil
        guard incoming.type != .measurement, incoming.type != .claim else { return }
        let fallback = FieldClock(at: incoming.createdAt, replica: replica, author: incoming.provenance.origin)
        let row = try db.query("SELECT row_id, record FROM objects WHERE id = ?", [.text(incoming.id.description)]) {
            ($0.int(0), try decode(ObjectRecord.self, $0, column: 1, table: "objects"))
        }.first
        guard let row else {
            try incoming.validate()
            _ = try insertObject(incoming, instruction: syncInstruction(change.head, from: replica))
            try writeClocks(entity: incoming.id, clocks: completed(change.clocks, fields: syncFields(of: incoming), fallback: fallback), local: local)
            result.objectsInserted += 1
            return
        }
        let (rowid, current) = row
        guard current.type == incoming.type, current.createdAt == incoming.createdAt else { throw SyncError.incompatible(current.id) }
        let outcome = SyncMerge.merge(
            local: try syncFields(of: current),
            localClocks: try resolvedClocks(
                entity: current.id, fields: syncFields(of: current), createdAt: current.createdAt, author: current.provenance.origin, local: local
            ),
            localFallback: FieldClock(at: current.createdAt, replica: local, author: current.provenance.origin),
            incoming: try syncFields(of: incoming), incomingClocks: change.clocks, incomingFallback: fallback
        )
        var merged = current
        for (field, state) in outcome.adopted.sorted(by: { $0.key < $1.key }) {
            try Self.set(field, json: state.json, on: &merged)
        }
        merged.updatedAt = max(current.updatedAt, incoming.updatedAt)
        if merged != current {
            try merged.validate()
            _ = try writeRevision(
                of: merged, rowid: rowid, parent: current.revision, author: change.head.author,
                instruction: syncInstruction(change.head, from: replica)
            )
            result.objectsMerged += 1
        }
        try writeClocks(entity: current.id, clocks: outcome.clocks, local: local)
        for conflict in outcome.conflicts {
            try recordConflict(conflict, entity: current.id, kind: .object, subjects: [current.id], into: &result)
        }
    }

    private func mergeRelationship(
        _ change: RelationshipChange, from replica: ReplicaID, local: ReplicaID, into result: inout SyncApplyResult
    ) throws {
        let incoming = change.relationship
        let fallback = FieldClock(at: incoming.provenance.timestamp, replica: replica, author: incoming.provenance.origin)
        guard let current = try fetchRelationship(incoming.id) else {
            try incoming.validate()
            try requireExists(incoming.from)
            try requireExists(incoming.to)
            try db.run(
                """
                INSERT INTO relationships (id, kind, from_id, to_id, truth, valid_from, valid_to, record)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(incoming.id.description), .text(incoming.kind.rawValue), .text(incoming.from.description),
                    .text(incoming.to.description), .text(incoming.provenance.truth.rawValue),
                    (incoming.validFrom?.timeIntervalSinceReferenceDate).sql, (incoming.validTo?.timeIntervalSinceReferenceDate).sql,
                    .text(try encode(incoming)),
                ]
            )
            try logChange(incoming.from, .related)
            try logChange(incoming.to, .related)
            try recordRelationshipRevision(
                incoming, author: change.head.author, instruction: syncInstruction(change.head, from: replica), at: incoming.provenance.timestamp
            )
            try writeClocks(
                entity: incoming.id, clocks: completed(change.clocks, fields: syncFields(of: incoming), fallback: fallback), local: local
            )
            result.relationshipsInserted += 1
            return
        }
        guard current.kind == incoming.kind, current.from == incoming.from, current.to == incoming.to else {
            throw SyncError.incompatible(current.id)
        }
        let createdAt = try relationshipCreatedAt(current)
        let outcome = SyncMerge.merge(
            local: try syncFields(of: current),
            localClocks: try resolvedClocks(
                entity: current.id, fields: syncFields(of: current), createdAt: createdAt, author: current.provenance.origin, local: local
            ),
            localFallback: FieldClock(at: createdAt, replica: local, author: current.provenance.origin),
            incoming: try syncFields(of: incoming), incomingClocks: change.clocks, incomingFallback: fallback
        )
        var merged = current
        for (field, state) in outcome.adopted.sorted(by: { $0.key < $1.key }) {
            try Self.set(field, json: state.json, on: &merged)
        }
        if merged != current {
            try merged.validate()
            try writeRelationshipRow(merged)
            try recordRelationshipRevision(
                merged, author: change.head.author, instruction: syncInstruction(change.head, from: replica), at: clock.now()
            )
            result.relationshipsMerged += 1
        }
        try writeClocks(entity: current.id, clocks: outcome.clocks, local: local)
        for conflict in outcome.conflicts {
            try recordConflict(conflict, entity: current.id, kind: .relationship, subjects: [current.from, current.to], into: &result)
        }
    }

    private func syncInstruction(_ head: RevisionStamp, from replica: ReplicaID) -> String {
        "Synced from replica \(replica)" + (head.instruction.map { ": \($0)" } ?? "")
    }

    /// Incoming clocks, with the sender's creation clock for any field it
    /// sent without one.
    private func completed(_ clocks: [String: FieldClock], fields: [String: SyncFieldState], fallback: FieldClock) -> [String: FieldClock] {
        var clocks = clocks
        for field in fields.keys where clocks[field] == nil { clocks[field] = fallback }
        return clocks
    }

    private func writeClocks(entity: ObjectID, clocks: [String: FieldClock], local: ReplicaID) throws {
        for (field, clock) in clocks.sorted(by: { $0.key < $1.key }) {
            try db.run(
                """
                INSERT INTO sync_field_clocks (entity_id, field, at, replica, author) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (entity_id, field) DO UPDATE SET at = excluded.at, replica = excluded.replica, author = excluded.author
                """,
                [
                    .text(entity.description), .text(field), .real(clock.at.timeIntervalSinceReferenceDate),
                    clock.replica == local ? .null : .text(clock.replica.rawValue), .text(try encode(clock.author)),
                ]
            )
        }
    }

    private static func set(_ field: String, json: String?, on record: inout ObjectRecord) throws {
        let decoder = JSONDecoder()
        switch field {
        case "title": record.title = try decoder.decode(String.self, from: Data((json ?? "\"\"").utf8))
        case "lifecycle": if let json { record.lifecycle = try decoder.decode(Lifecycle.self, from: Data(json.utf8)) }
        case "provenance": if let json { record.provenance = try decoder.decode(Provenance.self, from: Data(json.utf8)) }
        default:
            guard field.hasPrefix("attr:") else { return }
            let key = String(field.dropFirst(5))
            record.attributes[key] = try json.map { try decoder.decode(Attribute.self, from: Data($0.utf8)) }
        }
    }

    private static func set(_ field: String, json: String?, on relationship: inout Relationship) throws {
        let decoder = JSONDecoder()
        switch field {
        case "validFrom": relationship.validFrom = try json.map { try decoder.decode(Date.self, from: Data($0.utf8)) }
        case "validTo": relationship.validTo = try json.map { try decoder.decode(Date.self, from: Data($0.utf8)) }
        case "provenance": if let json { relationship.provenance = try decoder.decode(Provenance.self, from: Data(json.utf8)) }
        default:
            guard field.hasPrefix("attr:") else { return }
            let key = String(field.dropFirst(5))
            relationship.attributes[key] = try json.map { try decoder.decode(Attribute.self, from: Data($0.utf8)) }
        }
    }

    /// Records the alternate and its event, once: both IDs derive from the
    /// losing write, so the replica on either side of the conflict (and any
    /// replay) produces the same rows.
    private func recordConflict(
        _ conflict: SyncMerge.Conflict, entity: ObjectID, kind: AlternateRevision.EntityKind, subjects: [ObjectID],
        into result: inout SyncApplyResult
    ) throws {
        let rejected = conflict.rejected
        let key = [
            entity.description, conflict.field, String(rejected.clock.at.timeIntervalSinceReferenceDate), rejected.clock.replica.rawValue,
            rejected.state.json ?? "-",
        ].joined(separator: "|")
        let alternate = AlternateRevision(
            id: .derived(from: "alternate|" + key), entity: entity, entityKind: kind, field: conflict.field,
            valueJSON: rejected.state.json, truth: rejected.state.truth, clock: rejected.clock,
            conflictEvent: .derived(from: "syncConflict|" + key)
        )
        guard try !alternateExists(alternate.id) else { return }
        if try !eventExists(alternate.conflictEvent) {
            let truth = rejected.state.truth?.rawValue ?? "unprotected"
            try insertEvent(
                Event(
                    id: alternate.conflictEvent, at: rejected.clock.at, kind: .syncConflict, subjects: subjects,
                    summary: "Sync kept the protected \(conflict.field); preserved the newer \(truth) value from \(rejected.clock.author.label)",
                    payload: [
                        "field": .string(conflict.field),
                        "rejectedTruth": .string(truth),
                        "rejectedReplica": .string(rejected.clock.replica.rawValue),
                        "author": .string(rejected.clock.author.label),
                        "alternate": .reference(alternate.id),
                    ],
                    provenance: Provenance(origin: .system, truth: .recorded, timestamp: rejected.clock.at, method: "sync merge")
                )
            )
        }
        try insertAlternate(alternate)
        result.conflicts.append(alternate)
    }

    private func insertAlternate(_ alternate: AlternateRevision) throws {
        try db.run(
            "INSERT INTO sync_alternates (id, entity_id, entity_kind, field, at, record) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(alternate.id.description), .text(alternate.entity.description), .text(alternate.entityKind.rawValue),
                .text(alternate.field), .real(alternate.clock.at.timeIntervalSinceReferenceDate), .text(try encode(alternate)),
            ]
        )
    }

    private func alternateExists(_ id: ObjectID) throws -> Bool {
        try !db.query("SELECT 1 FROM sync_alternates WHERE id = ?", [.text(id.description)]) { _ in true }.isEmpty
    }

    private func eventExists(_ id: ObjectID) throws -> Bool {
        try !db.query("SELECT 1 FROM events WHERE id = ?", [.text(id.description)]) { _ in true }.isEmpty
    }

    // MARK: Private: append-only kinds

    private func insertSyncedMeasurement(_ change: MeasurementChange, from replica: ReplicaID, into result: inout SyncApplyResult) throws {
        let measurement = change.measurement
        guard try !exists(measurement.id) else { return }
        try measurement.validate()
        try requireExists(measurement.testPoint)
        if let instrument = measurement.instrument { try requireExists(instrument) }
        var object = change.object
        object.revision = nil
        guard object.id == measurement.id, object.type == .measurement else { throw SyncError.incompatible(measurement.id) }
        _ = try insertObject(object, instruction: "Synced from replica \(replica)")
        try db.run(
            """
            INSERT INTO measurements (id, test_point, quantity, value, unit, truth, sampled_at, record)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(measurement.id.description), .text(measurement.testPoint.description), .text(measurement.quantityName),
                .real(measurement.value.value), .text(measurement.value.unit), .text(measurement.truth.rawValue),
                .real(measurement.sampledAt.timeIntervalSinceReferenceDate), .text(try encode(measurement)),
            ]
        )
        result.measurementsInserted += 1
    }

    private func insertSyncedClaim(_ change: ClaimChange, from replica: ReplicaID, into result: inout SyncApplyResult) throws {
        let claim = change.claim
        guard try !exists(claim.id) else { return }
        try claim.validate()
        for source in claim.sources + claim.counterevidence { try requireExists(source) }
        var object = change.object
        object.revision = nil
        guard object.id == claim.id, object.type == .claim else { throw SyncError.incompatible(claim.id) }
        _ = try insertObject(object, instruction: "Synced from replica \(replica)")
        try db.run(
            "INSERT INTO claims (id, source_class, confidence, record) VALUES (?, ?, ?, ?)",
            [.text(claim.id.description), .text(claim.sourceClass.rawValue), claim.provenance.confidence.sql, .text(try encode(claim))]
        )
        for source in Set(claim.sources).sorted() {
            try db.run(
                "INSERT INTO claim_sources (claim_id, source_id) VALUES (?, ?)", [.text(claim.id.description), .text(source.description)]
            )
        }
        result.claimsInserted += 1
    }

    private func insertSyncedChannel(_ channel: TelemetryChannel, into result: inout SyncApplyResult) throws {
        guard try telemetryChannel(channel.id) == nil else { return }
        guard try !isTombstoned(channel: channel.id) else { return }
        try createTelemetryChannel(channel)
        result.telemetryChannelsInserted += 1
    }

    private func insertSyncedChunk(_ ref: TelemetryChunkRef, into result: inout SyncApplyResult) throws {
        guard ContentHash.sha256(ref.payload) == ref.sha256 else { throw SyncError.digestMismatch(ref.sha256) }
        guard try telemetryChannel(ref.channel) != nil else { return }
        guard try !isTombstoned(channel: ref.channel, start: ref.start, end: ref.end, count: ref.count) else { return }
        let payload = ref.payload.base64EncodedString()
        let present = try !db.query(
            """
            SELECT 1 FROM telemetry_chunks WHERE channel_id = ? AND start_at = ? AND end_at = ? AND sample_count = ?
            AND encoding = ? AND payload = ?
            """,
            [.text(ref.channel.description), .real(ref.start), .real(ref.end), .int(Int64(ref.count)), .text(ref.encoding), .text(payload)]
        ) { _ in true }.isEmpty
        guard !present else { return }
        try db.run(
            "INSERT INTO telemetry_chunks (channel_id, start_at, end_at, sample_count, encoding, payload) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(ref.channel.description), .real(ref.start), .real(ref.end), .int(Int64(ref.count)), .text(ref.encoding), .text(payload)]
        )
        result.telemetryChunksInserted += 1
    }

    private func isTombstoned(channel: ObjectID, start: Double? = nil, end: Double? = nil, count: Int? = nil) throws -> Bool {
        if try !db.query(
            "SELECT 1 FROM sync_tombstones WHERE kind = 'telemetryChannel' AND entity_id = ?", [.text(channel.description)], row: { _ in true }
        ).isEmpty {
            return true
        }
        guard let start, let end, let count else { return false }
        return try !db.query(
            """
            SELECT 1 FROM sync_tombstones WHERE kind = 'telemetryChunk' AND entity_id = ? AND start_at = ? AND end_at = ? AND sample_count = ?
            """,
            [.text(channel.description), .real(start), .real(end), .int(Int64(count))]
        ) { _ in true }.isEmpty
    }

    private func applyTombstone(_ tombstone: SyncTombstone, into result: inout SyncApplyResult) throws {
        let values: [SQLValue] = [
            .text(tombstone.kind.rawValue), .text(tombstone.entity.description), .real(tombstone.start), .real(tombstone.end),
            .int(Int64(tombstone.count)),
        ]
        let known = try !db.query(
            "SELECT 1 FROM sync_tombstones WHERE kind = ? AND entity_id = ? AND start_at = ? AND end_at = ? AND sample_count = ?", values
        ) { _ in true }.isEmpty
        guard !known else { return }
        // The row goes in first, so the delete triggers below find it and add nothing.
        try db.run(
            "INSERT INTO sync_tombstones (kind, entity_id, start_at, end_at, sample_count, deleted_at) VALUES (?, ?, ?, ?, ?, ?)",
            values + [.real(tombstone.deletedAt.timeIntervalSinceReferenceDate)]
        )
        switch tombstone.kind {
        case .telemetryChannel:
            try db.run("DELETE FROM telemetry_chunks WHERE channel_id = ?", [.text(tombstone.entity.description)])
            try db.run("DELETE FROM telemetry_channels WHERE id = ?", [.text(tombstone.entity.description)])
        case .telemetryChunk:
            try db.run(
                "DELETE FROM telemetry_chunks WHERE channel_id = ? AND start_at = ? AND end_at = ? AND sample_count = ?",
                [.text(tombstone.entity.description), .real(tombstone.start), .real(tombstone.end), .int(Int64(tombstone.count))]
            )
        }
        result.tombstonesApplied += 1
    }

    private func noteSyncedBlob(_ blob: BlobRef, into result: inout SyncApplyResult) throws {
        guard ContentHash.isDigest(blob.sha256) else { throw BlobError.invalidDigest(blob.sha256) }
        guard try self.blob(sha256: blob.sha256) == nil else { return }
        try db.run(
            """
            INSERT INTO sync_pending_blobs (sha256, byte_count, media_type) VALUES (?, ?, ?)
            ON CONFLICT (sha256) DO NOTHING
            """,
            [.text(blob.sha256), .int(Int64(blob.byteCount)), .text(blob.mediaType)]
        )
        result.missingBlobs.append(blob)
    }
}

// MARK: - The merge rule

/// A mergeable field: its value as JSON (nil when absent) and the truth class
/// that protects it (nil where `TruthPolicy` does not apply, e.g. a title).
struct SyncFieldState: Hashable, Sendable {
    var json: String?
    var truth: TruthClass?

    var isProtected: Bool {
        json != nil && truth.map(TruthPolicy.protected.contains) == true
    }
}

/// The per-field merge. `resolve` is symmetric in its two sides, so both
/// replicas pick the same winner whichever of them is "local".
enum SyncMerge {
    struct Side: Hashable {
        var state: SyncFieldState
        var clock: FieldClock
    }

    struct Conflict: Hashable {
        var field: String
        var kept: Side
        /// Newer than `kept`, but unprotected where `kept` is protected.
        var rejected: Side
    }

    struct Outcome {
        /// Fields whose value changes to the incoming one.
        var adopted: [String: SyncFieldState] = [:]
        /// Fields whose clock changes to the incoming one.
        var clocks: [String: FieldClock] = [:]
        var conflicts: [Conflict] = []
    }

    static func merge(
        local: [String: SyncFieldState], localClocks: [String: FieldClock], localFallback: FieldClock,
        incoming: [String: SyncFieldState], incomingClocks: [String: FieldClock], incomingFallback: FieldClock
    ) -> Outcome {
        var outcome = Outcome()
        let absent = SyncFieldState(json: nil, truth: nil)
        let keys = Set(local.keys).union(localClocks.keys).union(incoming.keys).union(incomingClocks.keys)
        for field in keys.sorted() {
            // A field with no clock on one side has been as it is since creation there.
            let mine = Side(state: local[field] ?? absent, clock: localClocks[field] ?? localFallback)
            let theirs = Side(state: incoming[field] ?? absent, clock: incomingClocks[field] ?? incomingFallback)
            if mine == theirs { continue }
            let (winner, rejected) = resolve(field: field, mine, theirs)
            if winner == theirs {
                if theirs.state != mine.state { outcome.adopted[field] = theirs.state }
                outcome.clocks[field] = theirs.clock
            }
            if let rejected {
                outcome.conflicts.append(Conflict(field: field, kept: winner, rejected: rejected))
            }
        }
        return outcome
    }

    /// The winning side, and the side that lost only because of TruthPolicy.
    static func resolve(field: String, _ a: Side, _ b: Side) -> (winner: Side, rejected: Side?) {
        if a.state == b.state { return (newer(a, b), nil) }
        // Tombstones: a deleted object and an ended relationship stay so.
        if field == "lifecycle" {
            let deleted = "\"\(Lifecycle.deleted.rawValue)\""
            let aDeleted = a.state.json == deleted
            if aDeleted != (b.state.json == deleted) { return (aDeleted ? a : b, nil) }
        }
        if field == "validTo", (a.state.json == nil) != (b.state.json == nil) {
            return (a.state.json != nil ? a : b, nil)
        }
        if a.state.isProtected != b.state.isProtected {
            let (kept, other) = a.state.isProtected ? (a, b) : (b, a)
            let otherIsNewer = other.clock.isNewer(than: kept.clock)
            // People and the system may remove a protected value.
            if other.state.json == nil, otherIsNewer, other.clock.author.mayRemoveProtected { return (other, nil) }
            return (kept, otherIsNewer ? other : nil)
        }
        return (newer(a, b), nil)
    }

    private static func newer(_ a: Side, _ b: Side) -> Side {
        if a.clock.isNewer(than: b.clock) { return a }
        if b.clock.isNewer(than: a.clock) { return b }
        // Same time and replica: fall back to the value, so the pick is still deterministic.
        return (a.state.json ?? "") >= (b.state.json ?? "") ? a : b
    }
}

extension ObjectID {
    /// A stable ID derived from `text` (a SHA-256-based UUIDv8), so replicas
    /// that derive from the same text get the same ID.
    static func derived(from text: String) -> ObjectID {
        var hex = Array(ContentHash.sha256(text).prefix(32))
        hex[12] = "8"
        let variant = Array("89ab")
        hex[16] = variant[Int(String(hex[16]), radix: 16)! % 4]
        let string = String(hex)
        let parts = [string.prefix(8), string.dropFirst(8).prefix(4), string.dropFirst(12).prefix(4), string.dropFirst(16).prefix(4), string.dropFirst(20)]
        return ObjectID(parts.joined(separator: "-"))!
    }
}
