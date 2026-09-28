import Foundation
import ControlsPLC

public enum EvidenceKind: String, Codable, Sendable, CaseIterable {
    case fact
    case measurement
    case assumption
    case inference

    public var displayName: String { rawValue.capitalized }
}

public enum EvidenceConfidence: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case verified = 3

    public static func < (lhs: EvidenceConfidence, rhs: EvidenceConfidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .verified: return "Verified"
        }
    }

    public var supportsHardPruning: Bool { self >= .high }
}

public enum MeasurementCondition: String, Codable, Sendable, CaseIterable {
    case unspecified
    case unloaded
    case underLoad
    case simulated

    public var displayName: String {
        switch self {
        case .unspecified: return "Unspecified"
        case .unloaded: return "Unloaded"
        case .underLoad: return "Under load"
        case .simulated: return "Simulated"
        }
    }
}

public enum ContradictionSeverity: Int, Codable, Sendable, CaseIterable, Comparable {
    case advisory = 0
    case meaningful = 1
    case strong = 2

    public static func < (lhs: ContradictionSeverity, rhs: ContradictionSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct EvidenceContradiction: Identifiable, Equatable, Sendable {
    public let id: String
    public let upstreamTarget: String
    public let downstreamTarget: String
    public let upstreamObservation: TroubleshootingObservation
    public let downstreamObservation: TroubleshootingObservation
    public let severity: ContradictionSeverity
    public let explanation: String
    public let resolutionTarget: String
    public let resolutionInstruction: String

    public init(
        upstreamTarget: String,
        downstreamTarget: String,
        upstreamObservation: TroubleshootingObservation,
        downstreamObservation: TroubleshootingObservation,
        severity: ContradictionSeverity,
        explanation: String,
        resolutionTarget: String,
        resolutionInstruction: String
    ) {
        self.id = "\(upstreamTarget)->\(downstreamTarget)#\(upstreamObservation.sequence)-\(downstreamObservation.sequence)"
        self.upstreamTarget = upstreamTarget
        self.downstreamTarget = downstreamTarget
        self.upstreamObservation = upstreamObservation
        self.downstreamObservation = downstreamObservation
        self.severity = severity
        self.explanation = explanation
        self.resolutionTarget = resolutionTarget
        self.resolutionInstruction = resolutionInstruction
    }
}

public struct EvidenceSummary: Equatable, Sendable {
    public let facts: Int
    public let measurements: Int
    public let assumptions: Int
    public let inferences: Int
    public let lowConfidenceMeasurements: Int
    public let contradictions: Int

    public init(observations: [TroubleshootingObservation], contradictions: [EvidenceContradiction]) {
        facts = observations.filter { $0.kind == .fact }.count
        measurements = observations.filter { $0.kind == .measurement }.count
        assumptions = observations.filter { $0.kind == .assumption }.count
        inferences = observations.filter { $0.kind == .inference }.count
        lowConfidenceMeasurements = observations.filter { $0.kind == .measurement && !$0.confidence.supportsHardPruning }.count
        self.contradictions = contradictions.count
    }
}
