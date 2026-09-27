import Foundation

/// Identifies the model that produced an AI output, so an interpretation can
/// always be traced to the exact model, adapter and prompt behind it.
public struct ModelRef: Codable, Sendable, Hashable {
    public var provider: String
    public var modelID: String
    public var adapterID: String?
    public var adapterVersion: String?
    public var promptHash: String?

    public init(
        provider: String,
        modelID: String,
        adapterID: String? = nil,
        adapterVersion: String? = nil,
        promptHash: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.promptHash = promptHash
    }
}

/// Who or what brought a value into the world model.
public enum Origin: Codable, Sendable, Hashable {
    case user(id: String)
    case agent(id: String, run: ObjectID?)
    case importer(source: ObjectID)
    case simulation(run: ObjectID)
    case instrument(id: ObjectID)
    case model(ModelRef)
    case system
}

/// Provenance for any meaningful value: origin, time, method, confidence,
/// inputs, transformation and revision.
public struct Provenance: Codable, Sendable, Hashable {
    public var origin: Origin
    public var truth: TruthClass
    public var timestamp: Date
    public var method: String?
    /// 0...1, or nil when confidence has not been assessed.
    public var confidence: Double?
    /// Objects this value was derived from or depends on.
    public var dependencies: [ObjectID]
    public var transformation: String?
    public var revision: RevisionID?

    public init(
        origin: Origin,
        truth: TruthClass,
        timestamp: Date,
        method: String? = nil,
        confidence: Double? = nil,
        dependencies: [ObjectID] = [],
        transformation: String? = nil,
        revision: RevisionID? = nil
    ) {
        self.origin = origin
        self.truth = truth
        self.timestamp = timestamp
        self.method = method
        self.confidence = confidence
        self.dependencies = dependencies
        self.transformation = transformation
        self.revision = revision
    }

    public var isConfidenceValid: Bool {
        guard let confidence else { return true }
        return (0...1).contains(confidence)
    }
}
