import Foundation
import NexusCore
import NexusModel

/// Filters for `NexusStore.search`. Every set field must match.
public struct SearchFilter: Sendable, Hashable {
    public var types: Set<ObjectType>?
    /// Truth class of the object itself (its provenance).
    public var truth: Set<TruthClass>?
    public var updatedFrom: Date?
    public var updatedTo: Date?
    /// Restrict results to these objects, e.g. a project's members.
    public var scope: Set<ObjectID>?

    public init(
        types: Set<ObjectType>? = nil,
        truth: Set<TruthClass>? = nil,
        updatedFrom: Date? = nil,
        updatedTo: Date? = nil,
        scope: Set<ObjectID>? = nil
    ) {
        self.types = types
        self.truth = truth
        self.updatedFrom = updatedFrom
        self.updatedTo = updatedTo
        self.scope = scope
    }
}

public struct SearchHit: Sendable, Hashable {
    public var id: ObjectID
    public var type: ObjectType
    public var title: String
    /// BM25 score; lower is more relevant.
    public var score: Double
}

/// The canonical local store: one SQLite database holding every object,
/// relationship, event, revision, claim and measurement, with FTS5 search.
///
/// All access is serialized. Every public write runs in its own savepoint, so
/// a failed write leaves the previous valid state untouched; `batch` groups
/// several writes into one all-or-nothing unit.
public final class NexusStore: @unchecked Sendable {
    public enum Location: Sendable {
        case inMemory
        case file(URL)
    }

    private let db: SQLiteConnection
    private let clock: NexusClock
    private let lock = NSRecursiveLock()
    private var savepointDepth = 0

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(_ location: Location, clock: NexusClock = SystemClock()) throws {
        switch location {
        case .inMemory:
            db = try SQLiteConnection(path: ":memory:")
        case .file(let url):
            db = try SQLiteConnection(path: url.path)
            try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        }
        self.clock = clock
        try db.execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    // MARK: Schema

    public var schemaVersion: Int {
        locked { (try? currentSchemaVersion()) ?? 0 }
    }

    private func currentSchemaVersion() throws -> Int {
        try db.query("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") { Int($0.int(0)) }.first ?? 0
    }

    private func migrate() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at REAL NOT NULL
            );
            """)
        let current = try currentSchemaVersion()
        guard current <= Migrations.latestVersion else {
            throw StoreError.schemaTooNew(found: current, supported: Migrations.latestVersion)
        }
        for migration in Migrations.all where migration.version > current {
            try transaction {
                try db.execute(migration.sql)
                try db.run(
                    "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
                    [.int(Int64(migration.version)), .text(migration.name), .real(clock.now().timeIntervalSinceReferenceDate)]
                )
            }
        }
    }

    // MARK: Transactions

    /// Runs `body` as one atomic unit. Nested batches become nested savepoints.
    public func batch<T>(_ body: (NexusStore) throws -> T) throws -> T {
        try locked { try transaction { try body(self) } }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        let name = "nexus_sp_\(savepointDepth)"
        try db.execute("SAVEPOINT \(name)")
        savepointDepth += 1
        do {
            let result = try body()
            savepointDepth -= 1
            try db.execute("RELEASE \(name)")
            return result
        } catch {
            savepointDepth -= 1
            try? db.execute("ROLLBACK TO \(name)")
            try? db.execute("RELEASE \(name)")
            throw error
        }
    }

    // MARK: Objects

    /// Inserts a new object and its first revision.
    @discardableResult
    public func create(_ record: ObjectRecord, instruction: String? = nil) throws -> ObjectRecord {
        try locked {
            try transaction {
                try record.validate()
                guard try !exists(record.id) else { throw StoreError.duplicate(record.id) }
                return try insertObject(record, instruction: instruction)
            }
        }
    }

    /// Applies `mutate` to an object and stores the result as a new revision.
    ///
    /// Throws `truthConflict` if the change would replace a recorded or
    /// observed value with a weaker truth class.
    @discardableResult
    public func update(
        _ id: ObjectID,
        by author: Origin,
        instruction: String? = nil,
        _ mutate: (inout ObjectRecord) throws -> Void
    ) throws -> ObjectRecord {
        try locked {
            try transaction {
                guard let old = try fetchObject(id) else { throw StoreError.notFound(id) }
                if old.type == .measurement || old.type == .claim {
                    throw StoreError.immutableRecord(id, old.type)
                }
                var new = old
                try mutate(&new)
                stampChangedAttributes(from: old, to: &new, by: author)
                try checkUpdate(from: old, to: new, by: author)
                try new.validate()
                new.updatedAt = clock.now()
                return try writeRevision(of: new, parent: old.revision, author: author, instruction: instruction)
            }
        }
    }

    public func object(_ id: ObjectID) throws -> ObjectRecord? {
        try locked { try fetchObject(id) }
    }

    public func objects(ofType type: ObjectType) throws -> [ObjectRecord] {
        try locked {
            try db.query("SELECT record FROM objects WHERE type = ? ORDER BY id", [.text(type.rawValue)]) {
                try decode(ObjectRecord.self, $0, table: "objects")
            }
        }
    }

    /// Fetches several objects at once, in the order of `ids`. Unknown IDs are skipped.
    public func objects(_ ids: [ObjectID]) throws -> [ObjectRecord] {
        guard !ids.isEmpty else { return [] }
        return try locked {
            var byID: [ObjectID: ObjectRecord] = [:]
            // Stay well under SQLite's bound-parameter limit.
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ ids[$0..<min($0 + 500, ids.count)] }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let records = try db.query(
                    "SELECT record FROM objects WHERE id IN (\(placeholders))", chunk.map { .text($0.description) }
                ) { try decode(ObjectRecord.self, $0, table: "objects") }
                for record in records {
                    byID[record.id] = record
                }
            }
            return ids.compactMap { byID[$0] }
        }
    }

    /// Objects whose title equals `title`, ignoring case. Deleted objects are excluded.
    public func objects(titled title: String) throws -> [ObjectRecord] {
        try locked {
            try db.query(
                "SELECT record FROM objects WHERE title = ? COLLATE NOCASE AND lifecycle != 'deleted' ORDER BY id",
                [.text(title)]
            ) { try decode(ObjectRecord.self, $0, table: "objects") }
        }
    }

    /// All revisions of an object, oldest first.
    public func revisions(of id: ObjectID) throws -> [Revision] {
        try locked {
            try db.query("SELECT record FROM revisions WHERE object_id = ? ORDER BY seq", [.text(id.description)]) {
                try decode(Revision.self, $0, table: "revisions")
            }
        }
    }

    private func exists(_ id: ObjectID) throws -> Bool {
        try !db.query("SELECT 1 FROM objects WHERE id = ?", [.text(id.description)]) { _ in true }.isEmpty
    }

    private func requireExists(_ id: ObjectID) throws {
        guard try exists(id) else { throw StoreError.notFound(id) }
    }

    private func fetchObject(_ id: ObjectID) throws -> ObjectRecord? {
        try db.query("SELECT record FROM objects WHERE id = ?", [.text(id.description)]) {
            try decode(ObjectRecord.self, $0, table: "objects")
        }.first
    }

    private func insertObject(_ record: ObjectRecord, instruction: String?) throws -> ObjectRecord {
        var record = record
        let revision = RevisionID.make()
        record.revision = revision
        try db.run(
            """
            INSERT INTO objects (id, type, title, lifecycle, truth, created_at, updated_at, head_revision, record)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(record.id.description), .text(record.type.rawValue), .text(record.title),
                .text(record.lifecycle.rawValue), .text(record.provenance.truth.rawValue),
                .real(record.createdAt.timeIntervalSinceReferenceDate),
                .real(record.updatedAt.timeIntervalSinceReferenceDate),
                .text(revision.description), .text(try encode(record)),
            ]
        )
        try insertRevision(
            Revision(
                id: revision, objectID: record.id, parent: nil, sequence: 1,
                author: record.provenance.origin, instruction: instruction,
                at: record.createdAt, snapshot: record
            )
        )
        try reindex(record.id, title: record.title, body: record.searchableText)
        return record
    }

    private func writeRevision(of record: ObjectRecord, parent: RevisionID?, author: Origin, instruction: String?) throws -> ObjectRecord {
        var record = record
        let revision = RevisionID.make()
        record.revision = revision
        let sequence = try db.query(
            "SELECT COALESCE(MAX(seq), 0) + 1 FROM revisions WHERE object_id = ?", [.text(record.id.description)]
        ) { Int($0.int(0)) }.first ?? 1
        try db.run(
            """
            UPDATE objects SET title = ?, lifecycle = ?, truth = ?, updated_at = ?, head_revision = ?, record = ?
            WHERE id = ?
            """,
            [
                .text(record.title), .text(record.lifecycle.rawValue), .text(record.provenance.truth.rawValue),
                .real(record.updatedAt.timeIntervalSinceReferenceDate), .text(revision.description),
                .text(try encode(record)), .text(record.id.description),
            ]
        )
        try insertRevision(
            Revision(
                id: revision, objectID: record.id, parent: parent, sequence: sequence,
                author: author, instruction: instruction, at: record.updatedAt, snapshot: record
            )
        )
        try reindex(record.id, title: record.title, body: record.searchableText)
        return record
    }

    private func insertRevision(_ revision: Revision) throws {
        try db.run(
            "INSERT INTO revisions (id, object_id, parent_id, seq, at, record) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(revision.id.description), .text(revision.objectID.description),
                (revision.parent?.description).sql, .int(Int64(revision.sequence)),
                .real(revision.at.timeIntervalSinceReferenceDate), .text(try encode(revision)),
            ]
        )
    }

    /// A changed attribute with no provenance of its own would otherwise inherit
    /// the object's, letting an agent write "recorded" values. Stamp it with
    /// its actual author instead.
    private func stampChangedAttributes(from old: ObjectRecord, to new: inout ObjectRecord, by author: Origin) {
        let now = clock.now()
        for (key, attribute) in new.attributes where attribute.provenance == nil && attribute != old.attributes[key] {
            new.attributes[key]?.provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
        }
    }

    private func checkUpdate(from old: ObjectRecord, to new: ObjectRecord, by author: Origin) throws {
        if new.id != old.id { throw StoreError.immutableField(object: old.id, field: "id") }
        if new.type != old.type { throw StoreError.immutableField(object: old.id, field: "type") }
        if new.createdAt != old.createdAt { throw StoreError.immutableField(object: old.id, field: "createdAt") }

        if new.provenance != old.provenance,
           !TruthPolicy.canReplace(existing: old.provenance.truth, with: new.provenance.truth) {
            throw StoreError.truthConflict(
                object: old.id, attribute: nil, existing: old.provenance.truth, incoming: new.provenance.truth
            )
        }

        for key in Set(old.attributes.keys).union(new.attributes.keys).sorted() {
            guard let existing = old.truth(of: key), TruthPolicy.protected.contains(existing) else { continue }
            guard new.attributes[key] != nil else {
                switch author {
                case .user, .system: continue
                default: throw StoreError.protectedRemoval(object: old.id, attribute: key, by: author)
                }
            }
            guard new.attributes[key] != old.attributes[key], let incoming = new.truth(of: key) else { continue }
            if !TruthPolicy.canReplace(existing: existing, with: incoming) {
                throw StoreError.truthConflict(object: old.id, attribute: key, existing: existing, incoming: incoming)
            }
        }
    }

    // MARK: Relationships

    @discardableResult
    public func relate(_ relationship: Relationship) throws -> Relationship {
        try locked {
            try transaction {
                try relationship.validate()
                try requireExists(relationship.from)
                try requireExists(relationship.to)
                try db.run(
                    """
                    INSERT INTO relationships (id, kind, from_id, to_id, truth, valid_from, valid_to, record)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(relationship.id.description), .text(relationship.kind.rawValue),
                        .text(relationship.from.description), .text(relationship.to.description),
                        .text(relationship.provenance.truth.rawValue),
                        (relationship.validFrom?.timeIntervalSinceReferenceDate).sql,
                        (relationship.validTo?.timeIntervalSinceReferenceDate).sql,
                        .text(try encode(relationship)),
                    ]
                )
                return relationship
            }
        }
    }

    public func relationship(_ id: ObjectID) throws -> Relationship? {
        try locked { try fetchRelationship(id) }
    }

    /// Closes a relationship's validity interval at `date`. The relationship is
    /// kept, so history ("was in this project until…") stays queryable.
    ///
    /// Ending a recorded or observed relationship is limited to users and the
    /// system, the same rule as removing a protected attribute.
    @discardableResult
    public func end(_ id: ObjectID, at date: Date, by author: Origin) throws -> Relationship {
        try locked {
            try transaction {
                guard var relationship = try fetchRelationship(id) else { throw StoreError.notFound(id) }
                if relationship.validTo != nil {
                    throw StoreError.immutableField(object: id, field: "validTo")
                }
                if TruthPolicy.protected.contains(relationship.provenance.truth) {
                    switch author {
                    case .user, .system: break
                    default: throw StoreError.protectedRemoval(object: id, attribute: "validTo", by: author)
                    }
                }
                relationship.validTo = date
                try relationship.validate()
                try db.run(
                    "UPDATE relationships SET valid_to = ?, record = ? WHERE id = ?",
                    [.real(date.timeIntervalSinceReferenceDate), .text(try encode(relationship)), .text(id.description)]
                )
                return relationship
            }
        }
    }

    private func fetchRelationship(_ id: ObjectID) throws -> Relationship? {
        try db.query("SELECT record FROM relationships WHERE id = ?", [.text(id.description)]) {
            try decode(Relationship.self, $0, table: "relationships")
        }.first
    }

    public func relationships(from id: ObjectID, kind: RelationKind? = nil) throws -> [Relationship] {
        try relationships(column: "from_id", id: id, kind: kind)
    }

    public func relationships(to id: ObjectID, kind: RelationKind? = nil) throws -> [Relationship] {
        try relationships(column: "to_id", id: id, kind: kind)
    }

    private func relationships(column: String, id: ObjectID, kind: RelationKind?) throws -> [Relationship] {
        try locked {
            var sql = "SELECT record FROM relationships WHERE \(column) = ?"
            var values: [SQLValue] = [.text(id.description)]
            if let kind {
                sql += " AND kind = ?"
                values.append(.text(kind.rawValue))
            }
            return try db.query(sql + " ORDER BY id", values) { try decode(Relationship.self, $0, table: "relationships") }
        }
    }

    // MARK: Events

    public func record(_ event: Event) throws {
        try locked {
            try transaction {
                try event.validate()
                for subject in event.subjects {
                    try requireExists(subject)
                }
                try db.run(
                    "INSERT INTO events (id, at, kind, truth, record) VALUES (?, ?, ?, ?, ?)",
                    [
                        .text(event.id.description), .real(event.at.timeIntervalSinceReferenceDate),
                        .text(event.kind.rawValue), .text(event.provenance.truth.rawValue), .text(try encode(event)),
                    ]
                )
                for subject in Set(event.subjects) {
                    try db.run(
                        "INSERT INTO event_subjects (event_id, object_id) VALUES (?, ?)",
                        [.text(event.id.description), .text(subject.description)]
                    )
                }
            }
        }
    }

    /// Events involving an object, in time order.
    public func events(about id: ObjectID) throws -> [Event] {
        try locked {
            try db.query(
                """
                SELECT e.record FROM events e JOIN event_subjects s ON s.event_id = e.id
                WHERE s.object_id = ? ORDER BY e.at, e.id
                """,
                [.text(id.description)]
            ) { try decode(Event.self, $0, table: "events") }
        }
    }

    /// The shared timeline, optionally bounded (inclusive).
    public func timeline(from start: Date? = nil, to end: Date? = nil) throws -> [Event] {
        try locked {
            try db.query(
                "SELECT record FROM events WHERE at >= ? AND at <= ? ORDER BY at, id",
                [
                    .real(start?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude),
                    .real(end?.timeIntervalSinceReferenceDate ?? Double.greatestFiniteMagnitude),
                ]
            ) { try decode(Event.self, $0, table: "events") }
        }
    }

    // MARK: Claims

    /// Stores a claim, registering it as a canonical object of type `claim`.
    public func add(_ claim: Claim) throws {
        try locked {
            try transaction {
                try claim.validate()
                guard try !exists(claim.id) else { throw StoreError.duplicate(claim.id) }
                for source in claim.sources + claim.counterevidence {
                    try requireExists(source)
                }
                var body = claim.passages
                if let applicability = claim.applicability { body.append(applicability) }
                var object = ObjectRecord(
                    id: claim.id, type: .claim, title: claim.statement,
                    attributes: ["sourceClass": Attribute(.string(claim.sourceClass.rawValue))],
                    provenance: claim.provenance
                )
                object.attributes["passages"] = Attribute(.list(body.map(Value.string)))
                _ = try insertObject(object, instruction: nil)
                try db.run(
                    "INSERT INTO claims (id, source_class, confidence, record) VALUES (?, ?, ?, ?)",
                    [
                        .text(claim.id.description), .text(claim.sourceClass.rawValue),
                        claim.provenance.confidence.sql, .text(try encode(claim)),
                    ]
                )
                for source in Set(claim.sources) {
                    try db.run(
                        "INSERT INTO claim_sources (claim_id, source_id) VALUES (?, ?)",
                        [.text(claim.id.description), .text(source.description)]
                    )
                }
            }
        }
    }

    public func claim(_ id: ObjectID) throws -> Claim? {
        try locked {
            try db.query("SELECT record FROM claims WHERE id = ?", [.text(id.description)]) {
                try decode(Claim.self, $0, table: "claims")
            }.first
        }
    }

    /// Claims that cite a given source.
    public func claims(citing source: ObjectID) throws -> [Claim] {
        try locked {
            try db.query(
                """
                SELECT c.record FROM claims c JOIN claim_sources s ON s.claim_id = c.id
                WHERE s.source_id = ? ORDER BY c.id
                """,
                [.text(source.description)]
            ) { try decode(Claim.self, $0, table: "claims") }
        }
    }

    // MARK: Measurements

    /// Appends a measurement. Measurements are never updated in place, so a
    /// modeled value can sit beside an observed one but never replace it.
    public func add(_ measurement: MeasurementRecord) throws {
        try locked {
            try transaction {
                try measurement.validate()
                guard try !exists(measurement.id) else { throw StoreError.duplicate(measurement.id) }
                try requireExists(measurement.testPoint)
                if let instrument = measurement.instrument {
                    try requireExists(instrument)
                }
                let title = "\(measurement.quantityName) \(String(format: "%.6g", measurement.value.value)) \(measurement.value.unit)"
                let object = ObjectRecord(
                    id: measurement.id, type: .measurement, title: title,
                    attributes: ["quantity": Attribute(.string(measurement.quantityName))],
                    provenance: measurement.provenance
                )
                _ = try insertObject(object, instruction: nil)
                try db.run(
                    """
                    INSERT INTO measurements (id, test_point, quantity, value, unit, truth, sampled_at, record)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(measurement.id.description), .text(measurement.testPoint.description),
                        .text(measurement.quantityName), .real(measurement.value.value), .text(measurement.value.unit),
                        .text(measurement.truth.rawValue), .real(measurement.sampledAt.timeIntervalSinceReferenceDate),
                        .text(try encode(measurement)),
                    ]
                )
            }
        }
    }

    public func measurement(_ id: ObjectID) throws -> MeasurementRecord? {
        try locked {
            try db.query("SELECT record FROM measurements WHERE id = ?", [.text(id.description)]) {
                try decode(MeasurementRecord.self, $0, table: "measurements")
            }.first
        }
    }

    /// Measurements at a test point in sample order, optionally of one truth class.
    public func measurements(at testPoint: ObjectID, truth: TruthClass? = nil) throws -> [MeasurementRecord] {
        try locked {
            var sql = "SELECT record FROM measurements WHERE test_point = ?"
            var values: [SQLValue] = [.text(testPoint.description)]
            if let truth {
                sql += " AND truth = ?"
                values.append(.text(truth.rawValue))
            }
            return try db.query(sql + " ORDER BY sampled_at, id", values) {
                try decode(MeasurementRecord.self, $0, table: "measurements")
            }
        }
    }

    // MARK: Search

    /// Full-text search over titles and string attributes. Every word in
    /// `text` must match, as a prefix.
    public func search(_ text: String, types: Set<ObjectType>? = nil, limit: Int = 50) throws -> [SearchHit] {
        try search(text, filter: SearchFilter(types: types), limit: limit)
    }

    /// Full-text search with structured, temporal and scope filters applied in
    /// SQL, so `limit` counts only results that pass every filter.
    public func search(_ text: String, filter: SearchFilter, limit: Int = 50) throws -> [SearchHit] {
        let tokens = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"*" }
        guard !tokens.isEmpty, limit > 0 else { return [] }
        if let scope = filter.scope, scope.isEmpty { return [] }

        return try locked {
            try transaction {
                var sql = """
                    SELECT o.id, o.type, o.title, bm25(search_index) AS score
                    FROM search_index JOIN objects o ON o.rowid = search_index.rowid
                    WHERE search_index MATCH ? AND o.lifecycle != 'deleted'
                    """
                var values: [SQLValue] = [.text(tokens.joined(separator: " "))]
                if let types = filter.types, !types.isEmpty {
                    sql += " AND o.type IN (\(placeholders(types.count)))"
                    values += types.map(\.rawValue).sorted().map(SQLValue.text)
                }
                if let truth = filter.truth, !truth.isEmpty {
                    sql += " AND o.truth IN (\(placeholders(truth.count)))"
                    values += truth.map(\.rawValue).sorted().map(SQLValue.text)
                }
                if let from = filter.updatedFrom {
                    sql += " AND o.updated_at >= ?"
                    values.append(.real(from.timeIntervalSinceReferenceDate))
                }
                if let to = filter.updatedTo {
                    sql += " AND o.updated_at <= ?"
                    values.append(.real(to.timeIntervalSinceReferenceDate))
                }
                if let scope = filter.scope {
                    try db.execute("CREATE TEMP TABLE IF NOT EXISTS search_scope (id TEXT PRIMARY KEY); DELETE FROM search_scope;")
                    for id in scope {
                        try db.run("INSERT INTO search_scope (id) VALUES (?)", [.text(id.description)])
                    }
                    sql += " AND o.id IN (SELECT id FROM search_scope)"
                }
                sql += " ORDER BY score, o.id LIMIT ?"
                values.append(.int(Int64(limit)))
                let hits = try db.query(sql, values) { row in
                    guard let idText = row.text(0), let id = ObjectID(idText) else {
                        throw StoreError.corruptRecord(table: "objects", id: row.text(0) ?? "?")
                    }
                    return SearchHit(
                        id: id, type: ObjectType(rawValue: row.text(1) ?? ""), title: row.text(2) ?? "", score: row.real(3)
                    )
                }
                if filter.scope != nil {
                    try db.execute("DELETE FROM search_scope;")
                }
                return hits
            }
        }
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// The FTS row shares the object's rowid, so updates replace it directly.
    private func reindex(_ id: ObjectID, title: String, body: String) throws {
        let rowid = try db.query("SELECT rowid FROM objects WHERE id = ?", [.text(id.description)]) { $0.int(0) }.first
        guard let rowid else { throw StoreError.notFound(id) }
        try db.run("DELETE FROM search_index WHERE rowid = ?", [.int(rowid)])
        try db.run(
            "INSERT INTO search_index (rowid, object_id, title, body) VALUES (?, ?, ?, ?)",
            [.int(rowid), .text(id.description), .text(title), .text(body)]
        )
    }

    // MARK: Coding

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ row: SQLiteConnection.Statement, table: String) throws -> T {
        guard let text = row.text(0) else { throw StoreError.corruptRecord(table: table, id: "?") }
        return try decoder.decode(type, from: Data(text.utf8))
    }
}
