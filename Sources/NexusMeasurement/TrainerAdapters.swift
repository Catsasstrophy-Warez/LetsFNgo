import ControlsPLC
import ControlsReasoning
import Foundation
import NexusCore
import NexusModel

/// Adapters from the Controls Tech Trainer's evidence types to Nexus
/// measurements. They map only what maps cleanly:
///
/// - `EvidenceConfidence` is an ordinal credibility grade, not a numeric
///   spread, so it becomes `Provenance.confidence`, never an uncertainty.
///   The trainer's hard-pruning threshold (`high` and above) corresponds to
///   `confidence >= hardPruningThreshold`.
/// - `MeasurementCondition` becomes the measurement's loading label; a
///   simulated condition makes the reading modeled.
/// - Boolean tag values become 1 / 0 in unit `bool`; DINT and REAL values
///   become numbers in the caller's unit. Timer and counter values have no
///   single scalar and are skipped.
/// - The trainer records no instrument spec, so uncertainty stays nil
///   (unknown) rather than being invented.
public enum TrainerEvidenceAdapter {
    /// Nexus confidence at and above which the trainer allowed hard pruning.
    public static let hardPruningThreshold = 0.8

    public static func confidence(_ level: EvidenceConfidence) -> Double {
        switch level {
        case .low: 0.25
        case .medium: 0.5
        case .high: 0.8
        case .verified: 0.95
        }
    }

    /// The highest trainer grade whose mapped confidence does not exceed `value`.
    public static func level(forConfidence value: Double) -> EvidenceConfidence {
        EvidenceConfidence.allCases.sorted().last { confidence($0) <= value } ?? .low
    }

    /// Loading label used by `MeasurementRecord.loading` and `Prediction.condition`.
    public static func loading(_ condition: MeasurementCondition) -> String? {
        switch condition {
        case .unloaded: "unloaded"
        case .underLoad: "under load"
        case .unspecified, .simulated: nil
        }
    }

    /// Truth class of a trainer reading: simulated readings are modeled,
    /// instructor-supplied values recorded, learner meter readings observed.
    public static func truth(source: ObservationSource, condition: MeasurementCondition) -> TruthClass {
        if source == .simulator || condition == .simulated { return .modeled }
        return source == .instructor ? .recorded : .observed
    }

    /// A numeric view of a tag value: (value, unit), or nil for timers and counters.
    public static func scalar(_ value: TagValue, unit: String) -> Quantity? {
        if let bool = value.boolValue { return Quantity(bool ? 1 : 0, "bool") }
        return value.numericValue.map { Quantity($0, unit) }
    }

    /// One troubleshooting observation as a measurement.
    ///
    /// Only `measurement` and `fact` observations are readings; assumptions and
    /// inferences are reasoning, not data, and return nil. A fact is recorded
    /// truth whatever its source.
    public static func measurement(
        _ observation: TroubleshootingObservation,
        at testPoint: ObjectID,
        unit: String = "value",
        sampledAt: Date,
        origin: Origin
    ) throws -> MeasurementRecord? {
        guard observation.kind == .measurement || observation.kind == .fact,
              let value = scalar(observation.value, unit: unit)
        else { return nil }
        _ = try MeasurementUnit(value.unit)
        let truth = observation.kind == .fact ? .recorded : truth(source: observation.source, condition: observation.condition)
        let record = MeasurementRecord(
            quantityName: observation.target, value: value, testPoint: testPoint,
            loading: loading(observation.condition), sampledAt: sampledAt,
            provenance: Provenance(
                origin: origin, truth: truth, timestamp: sampledAt, method: "trainer observation #\(observation.sequence)",
                confidence: confidence(observation.confidence), transformation: observation.note
            )
        )
        try record.validate()
        return record
    }

    /// A timed trace as one measurement per sample, `start` being the trace's
    /// millisecond zero. `sampleRateHz` is set only when samples are evenly
    /// spaced, since an uneven trace has no single rate.
    public static func measurements(
        _ observation: TemporalObservation,
        at testPoint: ObjectID,
        unit: String = "value",
        start: Date,
        origin: Origin
    ) throws -> [MeasurementRecord] {
        _ = try MeasurementUnit(unit)
        let intervals = zip(observation.samples.dropFirst(), observation.samples).map { $0.milliseconds - $1.milliseconds }
        let rate: Double? = if let first = intervals.first, first > 0, intervals.allSatisfy({ $0 == first }) {
            1_000 / Double(first)
        } else {
            nil
        }
        return try observation.samples.compactMap { sample in
            guard let value = scalar(sample.value, unit: unit) else { return nil }
            let at = start.addingTimeInterval(Double(sample.milliseconds) / 1_000)
            let record = MeasurementRecord(
                quantityName: observation.target, value: value, testPoint: testPoint,
                loading: loading(sample.condition), sampleRateHz: rate, sampledAt: at,
                provenance: Provenance(
                    origin: origin, truth: truth(source: observation.source, condition: sample.condition), timestamp: at,
                    method: "trainer temporal trace", confidence: confidence(sample.confidence), transformation: observation.note
                )
            )
            try record.validate()
            return record
        }
    }
}
