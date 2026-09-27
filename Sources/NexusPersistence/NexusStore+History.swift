import Foundation
import NexusCore
import NexusModel

/// A field that differs between two revisions.
public struct FieldChange<Value: Sendable & Hashable>: Sendable, Hashable {
    public var old: Value
    public var new: Value

    public init(old: Value, new: Value) {
        self.old = old
        self.new = new
    }
}

/// One attribute that differs between two revisions.
public struct AttributeChange: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case added
        case removed
        /// The value, its provenance, or both changed.
        case changed
    }

    public var key: String
    public var kind: Kind
    public var old: Attribute?
    public var new: Attribute?
    /// Effective truth class on each side: the attribute's own, or the
    /// object's when the attribute has no provenance. Nil where absent.
    public var oldTruth: TruthClass?
    public var newTruth: TruthClass?
}

/// The attribute-level difference between two snapshots of one object.
public struct RevisionDiff: Sendable, Hashable {
    public var object: ObjectID
    public var from: RevisionID?
    public var to: RevisionID?
    public var title: FieldChange<String>?
    public var lifecycle: FieldChange<Lifecycle>?
    /// The object's own truth class, when its provenance changed class.
    public var truth: FieldChange<TruthClass>?
    /// Changed attributes, sorted by key.
    public var attributes: [AttributeChange]

    /// Compares two snapshots. Timestamps and the revision ID itself are not
    /// differences; everything a user would call content is.
    public init(from old: ObjectRecord, to new: ObjectRecord) {
        object = new.id
        from = old.revision
        to = new.revision
        title = old.title == new.title ? nil : FieldChange(old: old.title, new: new.title)
        lifecycle = old.lifecycle == new.lifecycle ? nil : FieldChange(old: old.lifecycle, new: new.lifecycle)
        truth =
            old.provenance.truth == new.provenance.truth
            ? nil : FieldChange(old: old.provenance.truth, new: new.provenance.truth)
        attributes = Set(old.attributes.keys).union(new.attributes.keys).sorted().compactMap { key in
            let before = old.attributes[key]
            let after = new.attributes[key]
            let kind: AttributeChange.Kind
            switch (before, after) {
            case (nil, nil): return nil
            case (nil, _): kind = .added
            case (_, nil): kind = .removed
            case let (before?, after?):
                // An inherited truth class can change without the attribute changing.
                guard before != after || old.truth(of: key) != new.truth(of: key) else { return nil }
                kind = .changed
            }
            return AttributeChange(
                key: key, kind: kind, old: before, new: after, oldTruth: old.truth(of: key), newTruth: new.truth(of: key)
            )
        }
    }

    public var isEmpty: Bool {
        title == nil && lifecycle == nil && truth == nil && attributes.isEmpty
    }

    /// Names of the changed top-level fields: "title", "lifecycle", "truth".
    public var changedFields: [String] {
        [title == nil ? nil : "title", lifecycle == nil ? nil : "lifecycle", truth == nil ? nil : "truth"].compactMap { $0 }
    }

    /// Event payload summarising the change, for the store's own events.
    var payload: [String: Value] {
        [
            "changedAttributes": .list(attributes.map { .string($0.key) }),
            "changedFields": .list(changedFields.map(Value.string)),
        ]
    }

    /// " (title, supply)", or "" when nothing changed.
    var summarySuffix: String {
        let names = changedFields + attributes.map(\.key)
        return names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
    }
}

/// What the store records about an edit. Kept as a separate name so the
/// update path reads as "what changed", not "a diff between revisions".
typealias ObjectChanges = RevisionDiff

/// The fields of a `Revision` other than its snapshot, encoded with the same
/// keys, so the snapshot's already-encoded JSON can be spliced in.
struct RevisionHeader: Codable {
    var id: RevisionID
    var objectID: ObjectID
    var parent: RevisionID?
    var sequence: Int
    var author: Origin
    var instruction: String?
    var at: Date
}

extension Origin {
    /// A short, stable description for event payloads, e.g. "user:tech-1".
    var label: String {
        switch self {
        case .user(let id): "user:\(id)"
        case .agent(let id, _): "agent:\(id)"
        case .importer(let source): "importer:\(source)"
        case .simulation(let run): "simulation:\(run)"
        case .instrument(let id): "instrument:\(id)"
        case .model(let ref): "model:\(ref.provider)/\(ref.modelID)"
        case .system: "system"
        }
    }

    /// People and the system may remove or retire protected values.
    var mayRemoveProtected: Bool {
        switch self {
        case .user, .system: true
        default: false
        }
    }
}

// MARK: - Versioning and lifecycle

extension NexusStore {
    /// One revision of an object, or nil if `revision` is not one of its revisions.
    public func revision(_ revision: RevisionID, of id: ObjectID) throws -> Revision? {
        try locked { try fetchRevision(revision, of: id) }
    }

    /// What changed in an object between two of its revisions: attributes
    /// added, removed or changed (with the truth class on each side), plus
    /// title, lifecycle and the object's own truth class. `from` may be newer
    /// than `to`; the diff then reads backwards.
    public func diff(of id: ObjectID, from revisionA: RevisionID, to revisionB: RevisionID) throws -> RevisionDiff {
        try locked {
            guard let a = try fetchRevision(revisionA, of: id) else {
                throw StoreError.revisionNotFound(object: id, revision: revisionA)
            }
            guard let b = try fetchRevision(revisionB, of: id) else {
                throw StoreError.revisionNotFound(object: id, revision: revisionB)
            }
            return RevisionDiff(from: a.snapshot, to: b.snapshot)
        }
    }

    /// Writes a new head revision whose content equals an earlier snapshot.
    /// History is never rewritten: the restored state is a new revision whose
    /// parent is the current head, and a `revisionRestored` event records it.
    ///
    /// Restored values keep the provenance they had in that snapshot. The
    /// usual `TruthPolicy` checks apply, and on top of them an author whose
    /// own output is not protected (an agent, a model or a simulation) may
    /// not restore over, or remove, any recorded or observed value that is
    /// current, even with an older recorded one. Measurements and claims
    /// cannot be restored because they cannot be updated.
    @discardableResult
    public func restore(
        _ id: ObjectID, toRevision revision: RevisionID, by origin: Origin, instruction: String? = nil
    ) throws -> ObjectRecord {
        try locked {
            try transaction {
                let (rowid, current) = try fetchMutable(id)
                guard let target = try fetchRevision(revision, of: id) else {
                    throw StoreError.revisionNotFound(object: id, revision: revision)
                }
                var restored = target.snapshot
                restored.revision = current.revision
                try checkRestore(from: current, to: restored, by: origin)
                try checkLifecycleAuthority(current, to: restored.lifecycle, by: origin)
                try restored.validate()
                restored.updatedAt = clock.now()
                let written = try writeRevision(
                    of: restored, rowid: rowid, parent: current.revision, author: origin,
                    instruction: instruction ?? "Restore revision \(target.sequence)"
                )
                let changes = RevisionDiff(from: current, to: written)
                var payload = changes.payload
                payload["restoredRevision"] = .string(target.id.description)
                payload["restoredSequence"] = .int(Int64(target.sequence))
                try recordStoreEvent(
                    kind: .revisionRestored, subjects: [id],
                    summary: "Restored \(written.title) to revision \(target.sequence)\(changes.summarySuffix)",
                    payload: payload, author: origin, revision: written.revision
                )
                return written
            }
        }
    }

    /// Lifecycle moves the store accepts: draft → active → archived,
    /// archived → active, and anything not yet deleted → deleted. Deletion
    /// is final here; `restore` can bring back an earlier revision.
    public static func canTransition(from old: Lifecycle, to new: Lifecycle) -> Bool {
        switch (old, new) {
        case (.draft, .active), (.active, .archived), (.archived, .active): true
        case (.deleted, _): false
        case (_, .deleted): true
        default: false
        }
    }

    /// Moves an object through its lifecycle, as a new revision plus a
    /// `lifecycleChanged` event. Throws `invalidTransition` for a move that
    /// `canTransition` rejects (including a move to the current state).
    /// Deleting an object whose own truth is recorded or observed is limited
    /// to users and the system, like removing a protected attribute.
    @discardableResult
    public func setLifecycle(
        _ lifecycle: Lifecycle, of id: ObjectID, by origin: Origin, instruction: String? = nil
    ) throws -> ObjectRecord {
        try locked {
            try transaction {
                let (rowid, current) = try fetchMutable(id)
                guard Self.canTransition(from: current.lifecycle, to: lifecycle) else {
                    throw StoreError.invalidTransition(object: id, from: current.lifecycle, to: lifecycle)
                }
                try checkLifecycleAuthority(current, to: lifecycle, by: origin)
                var new = current
                new.lifecycle = lifecycle
                new.updatedAt = clock.now()
                let move = "\(current.lifecycle.rawValue) → \(lifecycle.rawValue)"
                let written = try writeRevision(
                    of: new, rowid: rowid, parent: current.revision, author: origin,
                    instruction: instruction ?? "Lifecycle \(move)"
                )
                try recordStoreEvent(
                    kind: .lifecycleChanged, subjects: [id], summary: "\(written.title): \(move)",
                    payload: ["from": .string(current.lifecycle.rawValue), "to": .string(lifecycle.rawValue)],
                    author: origin, revision: written.revision
                )
                return written
            }
        }
    }

    // MARK: Private

    private func fetchRevision(_ revision: RevisionID, of id: ObjectID) throws -> Revision? {
        try db.query(
            "SELECT record FROM revisions WHERE id = ? AND object_id = ?", [.text(revision.description), .text(id.description)]
        ) { try decode(Revision.self, $0, table: "revisions") }.first
    }

    private func checkRestore(from current: ObjectRecord, to restored: ObjectRecord, by origin: Origin) throws {
        try checkUpdate(from: current, to: restored, by: origin)
        guard !TruthPolicy.protected.contains(origin.defaultTruth) else { return }
        let incoming = origin.defaultTruth
        if TruthPolicy.protected.contains(current.provenance.truth), restored.provenance != current.provenance {
            throw StoreError.truthConflict(
                object: current.id, attribute: nil, existing: current.provenance.truth, incoming: incoming
            )
        }
        for key in Set(current.attributes.keys).union(restored.attributes.keys).sorted() {
            guard let existing = current.truth(of: key), TruthPolicy.protected.contains(existing) else { continue }
            guard restored.attributes[key] != nil else {
                throw StoreError.protectedRemoval(object: current.id, attribute: key, by: origin)
            }
            if restored.attributes[key] != current.attributes[key] || restored.truth(of: key) != existing {
                throw StoreError.truthConflict(object: current.id, attribute: key, existing: existing, incoming: incoming)
            }
        }
    }

    private func checkLifecycleAuthority(_ current: ObjectRecord, to lifecycle: Lifecycle, by origin: Origin) throws {
        guard lifecycle == .deleted, current.lifecycle != .deleted,
            TruthPolicy.protected.contains(current.provenance.truth), !origin.mayRemoveProtected
        else { return }
        throw StoreError.protectedRemoval(object: current.id, attribute: "lifecycle", by: origin)
    }
}
