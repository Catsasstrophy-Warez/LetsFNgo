import Foundation

/// Scores from one evaluation run on held-out scenarios (docs/BUILD_PLAN.md §F3).
///
/// Every metric is optional: `nil` means the run did not measure it (for
/// example, no prediction carried tool calls). The JSON form is the metrics
/// report printed by `NexusDatasetGen evaluate`; extra keys are ignored when
/// decoding, so a full report can be read back as metrics.
public struct EvalMetrics: Codable, Sendable, Hashable {
    /// Fraction of examples whose predicted cause matches the true cause. Higher is better.
    public var rootCauseAccuracy: Double?
    /// Fraction of examples whose predicted next test is the one `TestSelector` ranks first. Higher is better.
    public var nextTestAgreement: Double?
    /// Fraction of answers containing at least one number not traceable to the
    /// example's observations or tool results. Lower is better.
    public var hallucinatedValueRate: Double?
    /// Fraction of grounded values in answers that carry a correct truth-class label. Higher is better.
    public var truthClassDiscipline: Double?
    /// Fraction of predicted tool calls naming a known tool with its required arguments. Higher is better.
    public var toolCallValidity: Double?

    public init(
        rootCauseAccuracy: Double? = nil,
        nextTestAgreement: Double? = nil,
        hallucinatedValueRate: Double? = nil,
        truthClassDiscipline: Double? = nil,
        toolCallValidity: Double? = nil
    ) {
        self.rootCauseAccuracy = rootCauseAccuracy
        self.nextTestAgreement = nextTestAgreement
        self.hallucinatedValueRate = hallucinatedValueRate
        self.truthClassDiscipline = truthClassDiscipline
        self.toolCallValidity = toolCallValidity
    }

    /// One metric's name, value and direction.
    public struct Metric: Sendable, Hashable {
        public var name: String
        public var value: Double?
        public var higherIsBetter: Bool
    }

    /// All metrics in a fixed order, with the direction the gate compares them in.
    public var all: [Metric] {
        [
            Metric(name: "rootCauseAccuracy", value: rootCauseAccuracy, higherIsBetter: true),
            Metric(name: "nextTestAgreement", value: nextTestAgreement, higherIsBetter: true),
            Metric(name: "hallucinatedValueRate", value: hallucinatedValueRate, higherIsBetter: false),
            Metric(name: "truthClassDiscipline", value: truthClassDiscipline, higherIsBetter: true),
            Metric(name: "toolCallValidity", value: toolCallValidity, higherIsBetter: true),
        ]
    }
}
