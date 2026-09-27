import Foundation
import NexusCore
import NexusModel

extension RelationKind {
    /// Investigation → the object under investigation.
    public static let investigates: RelationKind = "investigates"
}

extension EventKind {
    public static let firstDivergence: EventKind = "firstDivergence"
    /// A person confirmed a hypothesis as the cause. Payload: `hypothesis`, `statement`.
    public static let hypothesisConfirmed: EventKind = "hypothesisConfirmed"
    /// A hypothesis was rejected, by a person or by contradicting evidence.
    /// Payload: `hypothesis`, `statement`, `reason`, and `measurement` when evidence did it.
    public static let hypothesisRejected: EventKind = "hypothesisRejected"
    /// The investigation was closed. Payload: `resolution`, `evidence`.
    public static let investigationClosed: EventKind = "investigationClosed"
    /// A repair's field work was verified by observed or recorded readings.
    /// Payload: `summary`, `evidence`, and `task` when a task carried the repair.
    public static let repairVerified: EventKind = "repairVerified"
}

extension ObjectType {
    public static let report: ObjectType = "report"
}

public enum HypothesisState: String, Codable, Sendable, CaseIterable {
    case candidate
    case confirmed
    case rejected
    case unknown

    /// Still in play for test selection and evidence updates.
    public var isLive: Bool { self == .candidate || self == .unknown }
}

/// What a hypothesis expects to observe at one test point, as an interval.
/// Predictions are what make a hypothesis testable: a measurement outside the
/// interval contradicts it.
public struct Prediction: Codable, Sendable, Hashable {
    public var testPoint: ObjectID
    public var quantity: String
    public var unit: String
    public var low: Double
    public var high: Double
    /// Measurement condition that must match, e.g. "under load".
    public var condition: String?

    public init(testPoint: ObjectID, quantity: String, unit: String, low: Double, high: Double, condition: String? = nil) {
        self.testPoint = testPoint
        self.quantity = quantity
        self.unit = unit
        self.low = low
        self.high = high
        self.condition = condition
    }

    public func applies(to measurement: MeasurementRecord) -> Bool {
        measurement.testPoint == testPoint
            && measurement.quantityName == quantity
            && measurement.value.unit == unit
            && (condition == nil || condition == measurement.loading)
    }

    /// Compares a reading, widened by its uncertainty, with the interval.
    /// Only a reading entirely outside the interval contradicts.
    public func judge(_ measurement: MeasurementRecord) -> EvidenceEffect {
        let spread = measurement.uncertainty ?? 0
        let lower = measurement.value.value - spread
        let upper = measurement.value.value + spread
        if lower >= low && upper <= high { return .supports }
        if upper < low || lower > high { return .contradicts }
        return .inconclusive
    }

    var value: Value {
        var map: [String: Value] = [
            "testPoint": .reference(testPoint), "quantity": .string(quantity), "unit": .string(unit),
            "low": .double(low), "high": .double(high),
        ]
        if let condition { map["condition"] = .string(condition) }
        return .map(map)
    }

    init?(_ value: Value) {
        guard case .map(let map) = value,
              case .reference(let testPoint)? = map["testPoint"],
              case .string(let quantity)? = map["quantity"],
              case .string(let unit)? = map["unit"],
              case .double(let low)? = map["low"],
              case .double(let high)? = map["high"]
        else { return nil }
        var condition: String?
        if case .string(let text)? = map["condition"] { condition = text }
        self.init(testPoint: testPoint, quantity: quantity, unit: unit, low: low, high: high, condition: condition)
    }
}

public enum EvidenceEffect: String, Sendable, Hashable {
    case supports
    case contradicts
    case inconclusive
    case notApplicable
}

/// A typed view of a hypothesis object. The canonical state lives in the
/// store as an `ObjectRecord`; this struct only reads it.
public struct Hypothesis: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord
    public var statement: String
    public var state: HypothesisState
    public var predictions: [Prediction]
    /// Relative prior weight; normalized across live hypotheses.
    public var prior: Double
    public var safetyNotes: [String]

    public var id: ObjectID { record.id }

    public init(record: ObjectRecord) throws {
        guard record.type == .hypothesis,
              case .string(let rawState)? = record.attributes["state"]?.value,
              let state = HypothesisState(rawValue: rawState),
              case .double(let prior)? = record.attributes["prior"]?.value
        else { throw InvestigationError.malformed(record.id) }
        var predictions: [Prediction] = []
        if case .list(let values)? = record.attributes["predictions"]?.value {
            predictions = try values.map { try Prediction($0).orThrow(InvestigationError.malformed(record.id)) }
        }
        var notes: [String] = []
        if case .list(let values)? = record.attributes["safetyNotes"]?.value {
            notes = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        }
        self.record = record
        self.statement = record.title
        self.state = state
        self.predictions = predictions
        self.prior = prior
        self.safetyNotes = notes
    }

    public func prediction(for measurement: MeasurementRecord) -> Prediction? {
        predictions.first { $0.applies(to: measurement) }
    }

    static func attributes(state: HypothesisState, predictions: [Prediction], prior: Double, safetyNotes: [String]) -> [String: Attribute] {
        var attributes: [String: Attribute] = [
            "state": Attribute(.string(state.rawValue)),
            "prior": Attribute(.double(prior)),
            "predictions": Attribute(.list(predictions.map(\.value))),
        ]
        if !safetyNotes.isEmpty {
            attributes["safetyNotes"] = Attribute(.list(safetyNotes.map(Value.string)))
        }
        return attributes
    }
}

public enum InvestigationError: Error, Equatable, Sendable {
    case notAnInvestigation(ObjectID)
    case malformed(ObjectID)
    case notInInvestigation(hypothesis: ObjectID, investigation: ObjectID)
    case notLive(ObjectID, HypothesisState)
    case invalidPrior(Double)
    /// Only a person (or the system acting for one) may confirm a root cause.
    case requiresHuman(Origin)
    /// Confirmation needs at least one supporting observed measurement.
    case unsupported(ObjectID)
    case divergenceNeedsObservedAndExpected
    case mismatchedMeasurements
    /// A verification needs at least one reading.
    case unverified(ObjectID)
    /// Only observed or recorded readings can verify a repair.
    case notEvidence(ObjectID, TruthClass)
}

extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
