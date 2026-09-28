import Foundation
import NexusCore
import NexusModel

/// One immutable snapshot in a relationship's history (migration 7).
///
/// `relate`, `end`, `updateRelationship` and synced merges each write one.
/// Relationships that existed before migration 7 have a synthesized first
/// revision whose ID is the relationship's own ID.
public struct RelationshipRevision: Codable, Sendable, Hashable, Identifiable {
    public var id: RevisionID
    public var relationshipID: ObjectID
    public var parent: RevisionID?
    public var sequence: Int
    public var author: Origin
    public var instruction: String?
    public var at: Date
    public var snapshot: Relationship

    public init(
        id: RevisionID, relationshipID: ObjectID, parent: RevisionID?, sequence: Int, author: Origin, instruction: String?, at: Date,
        snapshot: Relationship
    ) {
        self.id = id
        self.relationshipID = relationshipID
        self.parent = parent
        self.sequence = sequence
        self.author = author
        self.instruction = instruction
        self.at = at
        self.snapshot = snapshot
    }
}

extension EventKind {
    /// Written by the store for every `updateRelationship`, by any author.
    public static let relationshipEdited: EventKind = "relationshipEdited"
}

extension NexusStore {
    /// All revisions of a relationship, oldest first.
    public func relationshipRevisions(of id: ObjectID) throws -> [RelationshipRevision] {
        try locked {
            try db.query(
                "SELECT id, parent_id, seq, at, author, instruction, snapshot FROM relationship_revisions WHERE relationship_id = ? ORDER BY seq",
                [.text(id.description)]
            ) { row in try relationshipRevision(row, relationship: id) }
        }
    }

    /// Applies `mutate` to a relationship and stores the result as a new
    /// revision, under the same `TruthPolicy` rules as `update` on objects.
    ///
    /// Attributes, `validFrom` and the provenance may change. `id`, `kind`,
    /// `from` and `to` are immutable, and `validTo` changes only through
    /// `end`. A changed attribute without provenance of its own is stamped
    /// with `author`, so an agent cannot write a value that inherits a
    /// recorded relationship's truth. A recorded or observed attribute (or
    /// provenance) can only be replaced by another recorded or observed one,
    /// and removed only by a user or the system.
    ///
    /// In the same transaction the store appends a `relationshipEdited` event
    /// about both endpoints, listing the changed attribute keys.
    @discardableResult
    public func updateRelationship(
        _ id: ObjectID,
        by author: Origin,
        instruction: String? = nil,
        _ mutate: (inout Relationship) throws -> Void
    ) throws -> Relationship {
        try locked {
            try transaction {
                guard let old = try fetchRelationship(id) else { throw StoreError.notFound(id) }
                var new = old
                try mutate(&new)
                let now = clock.now()
                for (key, attribute) in new.attributes where attribute.provenance == nil && attribute != old.attributes[key] {
                    new.attributes[key]?.provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
                }
                try checkRelationshipUpdate(from: old, to: new, by: author)
                try new.validate()
                guard new != old else { return old }
                try writeRelationshipRow(new)
                try recordRelationshipRevision(new, author: author, instruction: instruction, at: now)
                let changedKeys = Set(old.attributes.keys).union(new.attributes.keys).sorted().filter {
                    old.attributes[$0] != new.attributes[$0]
                }
                for field in try changedSyncFields(from: syncFields(of: old), to: syncFields(of: new)) {
                    try stampFieldClock(entity: id, field: field, at: now, by: author)
                }
                try recordStoreEvent(
                    kind: .relationshipEdited, subjects: [old.from, old.to],
                    summary: "Edited \(old.kind.rawValue) relationship"
                        + (changedKeys.isEmpty ? "" : " (\(changedKeys.joined(separator: ", ")))"),
                    payload: [
                        "relationship": .reference(id),
                        "changedAttributes": .list(changedKeys.map(Value.string)),
                    ],
                    author: author, revision: nil
                )
                return new
            }
        }
    }

    // MARK: Internal

    /// Appends a revision holding `relationship` as it is now.
    func recordRelationshipRevision(_ relationship: Relationship, author: Origin, instruction: String?, at: Date) throws {
        let head = try db.query(
            "SELECT id, seq FROM relationship_revisions WHERE relationship_id = ? ORDER BY seq DESC LIMIT 1",
            [.text(relationship.id.description)]
        ) { ($0.text(0), Int($0.int(1))) }.first
        try db.run(
            """
            INSERT INTO relationship_revisions (id, relationship_id, parent_id, seq, at, author, instruction, snapshot)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(RevisionID.make().description), .text(relationship.id.description), (head?.0 ?? nil).sql,
                .int(Int64((head?.1 ?? 0) + 1)), .real(at.timeIntervalSinceReferenceDate), .text(try encode(author)),
                instruction.sql, .text(try encode(relationship)),
            ]
        )
    }

    /// Rewrites a relationship's row from its record.
    func writeRelationshipRow(_ relationship: Relationship) throws {
        try db.run(
            "UPDATE relationships SET truth = ?, valid_from = ?, valid_to = ?, record = ? WHERE id = ?",
            [
                .text(relationship.provenance.truth.rawValue), (relationship.validFrom?.timeIntervalSinceReferenceDate).sql,
                (relationship.validTo?.timeIntervalSinceReferenceDate).sql, .text(try encode(relationship)),
                .text(relationship.id.description),
            ]
        )
        try logChange(relationship.from, .related)
        try logChange(relationship.to, .related)
    }

    /// Time of a relationship's first revision: the clock of every field
    /// that has not changed since it was created on this replica.
    func relationshipCreatedAt(_ relationship: Relationship) throws -> Date {
        let at = try db.query(
            "SELECT at FROM relationship_revisions WHERE relationship_id = ? ORDER BY seq LIMIT 1", [.text(relationship.id.description)]
        ) { $0.real(0) }.first
        return at.map(Date.init(timeIntervalSinceReferenceDate:)) ?? relationship.provenance.timestamp
    }

    // MARK: Private

    private func relationshipRevision(_ row: SQLiteConnection.Statement, relationship id: ObjectID) throws -> RelationshipRevision {
        let decoder = JSONDecoder()
        guard let revisionText = row.text(0), let revision = RevisionID(revisionText),
            let authorData = row.data(4), let snapshotData = row.data(6)
        else { throw StoreError.corruptRecord(table: "relationship_revisions", id: row.text(0) ?? "?") }
        do {
            return RelationshipRevision(
                id: revision, relationshipID: id, parent: row.text(1).flatMap(RevisionID.init), sequence: Int(row.int(2)),
                author: try decoder.decode(Origin.self, from: authorData), instruction: row.text(5),
                at: Date(timeIntervalSinceReferenceDate: row.real(3)),
                snapshot: try decoder.decode(Relationship.self, from: snapshotData)
            )
        } catch {
            throw StoreError.corruptRecord(table: "relationship_revisions", id: revisionText)
        }
    }

    private func checkRelationshipUpdate(from old: Relationship, to new: Relationship, by author: Origin) throws {
        if new.id != old.id { throw StoreError.immutableField(object: old.id, field: "id") }
        if new.kind != old.kind { throw StoreError.immutableField(object: old.id, field: "kind") }
        if new.from != old.from { throw StoreError.immutableField(object: old.id, field: "from") }
        if new.to != old.to { throw StoreError.immutableField(object: old.id, field: "to") }
        if new.validTo != old.validTo { throw StoreError.immutableField(object: old.id, field: "validTo") }

        if new.provenance != old.provenance,
            !TruthPolicy.canReplace(existing: old.provenance.truth, with: new.provenance.truth)
        {
            throw StoreError.truthConflict(object: old.id, attribute: nil, existing: old.provenance.truth, incoming: new.provenance.truth)
        }
        for key in Set(old.attributes.keys).union(new.attributes.keys).sorted() {
            guard let existing = old.truth(of: key), TruthPolicy.protected.contains(existing) else { continue }
            guard new.attributes[key] != nil else {
                if author.mayRemoveProtected { continue }
                throw StoreError.protectedRemoval(object: old.id, attribute: key, by: author)
            }
            guard new.attributes[key] != old.attributes[key], let incoming = new.truth(of: key) else { continue }
            if !TruthPolicy.canReplace(existing: existing, with: incoming) {
                throw StoreError.truthConflict(object: old.id, attribute: key, existing: existing, incoming: incoming)
            }
        }
    }
}

extension Relationship {
    /// Truth class of an attribute, falling back to the relationship's own.
    public func truth(of key: String) -> TruthClass? {
        guard let attribute = attributes[key] else { return nil }
        return attribute.provenance?.truth ?? provenance.truth
    }
}
