import Foundation
import NexusCore

/// The canonical object. Domain modules extend meaning through `type` and
/// `attributes`; they never keep a second copy of this state.
public struct ObjectRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var type: ObjectType
    public var title: String
    public var attributes: [String: Attribute]
    public var lifecycle: Lifecycle
    public var createdAt: Date
    public var updatedAt: Date
    public var provenance: Provenance
    /// Head revision. Assigned by the store on every write.
    public var revision: RevisionID?

    public init(
        id: ObjectID = .make(),
        type: ObjectType,
        title: String,
        attributes: [String: Attribute] = [:],
        lifecycle: Lifecycle = .active,
        provenance: Provenance
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.attributes = attributes
        self.lifecycle = lifecycle
        self.createdAt = provenance.timestamp
        self.updatedAt = provenance.timestamp
        self.provenance = provenance
        self.revision = nil
    }

    /// Truth class of an attribute, falling back to the object's own.
    public func truth(of key: String) -> TruthClass? {
        guard let attribute = attributes[key] else { return nil }
        return attribute.provenance?.truth ?? provenance.truth
    }

    public var searchableText: String {
        attributes.keys.sorted().flatMap { attributes[$0]!.value.searchableText }.joined(separator: " ")
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelError.emptyTitle(id)
        }
        try Validation.check(provenance)
        for attribute in attributes.values {
            if let provenance = attribute.provenance {
                try Validation.check(provenance)
            }
        }
    }
}

/// A first-class, directed relationship with its own provenance, validity
/// interval and confidence.
public struct Relationship: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var kind: RelationKind
    public var from: ObjectID
    public var to: ObjectID
    public var validFrom: Date?
    public var validTo: Date?
    public var attributes: [String: Attribute]
    public var provenance: Provenance

    public init(
        id: ObjectID = .make(),
        kind: RelationKind,
        from: ObjectID,
        to: ObjectID,
        validFrom: Date? = nil,
        validTo: Date? = nil,
        attributes: [String: Attribute] = [:],
        provenance: Provenance
    ) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.validFrom = validFrom
        self.validTo = validTo
        self.attributes = attributes
        self.provenance = provenance
    }

    public func validate() throws {
        try Validation.check(provenance)
        if let validFrom, let validTo, validTo < validFrom {
            throw ModelError.invalidInterval(id)
        }
    }
}

/// Something that happened, on one shared timeline.
public struct Event: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var at: Date
    public var kind: EventKind
    public var subjects: [ObjectID]
    public var summary: String
    public var payload: [String: Value]
    public var provenance: Provenance

    public init(
        id: ObjectID = .make(),
        at: Date,
        kind: EventKind,
        subjects: [ObjectID],
        summary: String,
        payload: [String: Value] = [:],
        provenance: Provenance
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.subjects = subjects
        self.summary = summary
        self.payload = payload
        self.provenance = provenance
    }

    public func validate() throws {
        try Validation.check(provenance)
    }
}

/// One immutable snapshot in an object's history.
public struct Revision: Codable, Sendable, Hashable, Identifiable {
    public var id: RevisionID
    public var objectID: ObjectID
    public var parent: RevisionID?
    public var sequence: Int
    public var author: Origin
    public var instruction: String?
    public var at: Date
    public var snapshot: ObjectRecord

    public init(
        id: RevisionID,
        objectID: ObjectID,
        parent: RevisionID?,
        sequence: Int,
        author: Origin,
        instruction: String?,
        at: Date,
        snapshot: ObjectRecord
    ) {
        self.id = id
        self.objectID = objectID
        self.parent = parent
        self.sequence = sequence
        self.author = author
        self.instruction = instruction
        self.at = at
        self.snapshot = snapshot
    }
}
