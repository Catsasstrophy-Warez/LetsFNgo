import NexusCore

public enum ModelError: Error, Equatable, Sendable {
    case emptyTitle(ObjectID)
    case confidenceOutOfRange(Double)
    case invalidInterval(ObjectID)
    case invalidTruth(ObjectID, allowed: Set<TruthClass>, got: TruthClass)
    case nonFiniteValue(ObjectID)
}

enum Validation {
    static func check(_ provenance: Provenance) throws {
        if !provenance.isConfidenceValid, let confidence = provenance.confidence {
            throw ModelError.confidenceOutOfRange(confidence)
        }
    }
}
