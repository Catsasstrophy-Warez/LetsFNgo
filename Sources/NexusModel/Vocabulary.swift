/// Open vocabularies. Each is a string-backed struct rather than an enum so
/// domain modules can add types without editing the core model, while common
/// values stay discoverable as static constants.

public struct ObjectType: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let project: ObjectType = "project"
    public static let person: ObjectType = "person"
    public static let organization: ObjectType = "organization"
    public static let task: ObjectType = "task"
    public static let event: ObjectType = "event"
    public static let document: ObjectType = "document"
    public static let source: ObjectType = "source"
    public static let claim: ObjectType = "claim"
    public static let decision: ObjectType = "decision"
    public static let artifact: ObjectType = "artifact"
    public static let equipment: ObjectType = "equipment"
    public static let component: ObjectType = "component"
    public static let sensor: ObjectType = "sensor"
    public static let signal: ObjectType = "signal"
    public static let testPoint: ObjectType = "testPoint"
    public static let instrument: ObjectType = "instrument"
    public static let measurement: ObjectType = "measurement"
    public static let fault: ObjectType = "fault"
    public static let procedure: ObjectType = "procedure"
    public static let investigation: ObjectType = "investigation"
    public static let hypothesis: ObjectType = "hypothesis"
    public static let simulation: ObjectType = "simulation"
    public static let agent: ObjectType = "agent"
    public static let workflow: ObjectType = "workflow"
}

public struct RelationKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let contains: RelationKind = "contains"
    public static let belongsTo: RelationKind = "belongsTo"
    public static let connectedTo: RelationKind = "connectedTo"
    public static let produced: RelationKind = "produced"
    public static let supports: RelationKind = "supports"
    public static let contradicts: RelationKind = "contradicts"
    public static let testedBy: RelationKind = "testedBy"
    public static let confirms: RelationKind = "confirms"
    public static let attended: RelationKind = "attended"
    public static let created: RelationKind = "created"
    public static let blocks: RelationKind = "blocks"
    public static let dependsOn: RelationKind = "dependsOn"
    public static let measuredAt: RelationKind = "measuredAt"
    public static let derivedFrom: RelationKind = "derivedFrom"
    public static let represents: RelationKind = "represents"
    public static let cites: RelationKind = "cites"
}

public struct EventKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let stateChanged: EventKind = "stateChanged"
    public static let measured: EventKind = "measured"
    public static let simulated: EventKind = "simulated"
    public static let faultInjected: EventKind = "faultInjected"
    public static let agentAction: EventKind = "agentAction"
    public static let userEdit: EventKind = "userEdit"
    public static let repair: EventKind = "repair"
    public static let approval: EventKind = "approval"
    public static let message: EventKind = "message"
    public static let note: EventKind = "note"
    /// Written by the store for every `update` of an object, by any author.
    /// Measurements use `measured`.
    public static let objectEdited: EventKind = "objectEdited"
    /// Written by the store when an object's lifecycle moves.
    public static let lifecycleChanged: EventKind = "lifecycleChanged"
    /// Written by the store when an object is restored to an earlier revision.
    public static let revisionRestored: EventKind = "revisionRestored"
}

public enum Lifecycle: String, Codable, Sendable, CaseIterable {
    case draft
    case active
    case archived
    case deleted
}

/// Credibility class of a source, from the claim/evidence ledger.
public enum SourceClass: String, Codable, Sendable, CaseIterable {
    case primary
    case secondary
    case tertiary
    case community
    case unknown
}
