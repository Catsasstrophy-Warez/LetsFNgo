import Foundation
import NexusCore

/// Which held-out partition an example belongs to. Splits draw scenario seeds
/// from disjoint ranges, so no scenario can appear in both.
public enum DatasetSplit: String, Codable, Sendable, CaseIterable {
    case train
    case eval

    /// First scenario seed of the split's range. Each range is 2^40 wide.
    var seedBase: UInt64 {
        switch self {
        case .train: 0
        case .eval: 1 << 40
        }
    }

    public static let seedRangeWidth: UInt64 = 1 << 40
    /// Examples one `--seed` value can address before its range would touch the next seed's.
    public static let maximumCount = 1 << 20

    /// The scenario seed for example `index` of a run started with `seed`.
    /// Always inside this split's range, whatever the inputs.
    public func scenarioSeed(runSeed seed: UInt64, index: Int) -> UInt64 {
        let offset = ((seed << 20) &+ UInt64(index)) % Self.seedRangeWidth
        return seedBase + offset
    }

    /// The split whose range contains `scenarioSeed`.
    public static func containing(_ scenarioSeed: UInt64) -> DatasetSplit? {
        allCases.first { scenarioSeed >= $0.seedBase && scenarioSeed < $0.seedBase + seedRangeWidth }
    }
}

public enum ExampleKind: String, Codable, Sendable, CaseIterable {
    /// Instrument-loop symptom → hypotheses, next test, cause, first divergence.
    case diagnosis
    /// A user goal answered through WorldTools calls, ending in a cited answer.
    case toolTranscript
    /// "Why isn't X on?" over a generated ladder permissive chain, answered with the causal trail.
    case ladderWhy
    /// Automotive "cranks slowly / battery light on" → hypotheses, next test, cause, first divergence.
    case chargingDiagnosis
}

/// Which simulators a run draws from. `loop` is the original rotation and
/// stays byte-identical; `automotive` makes only charging-system cases;
/// `mixed` adds one charging case after every loop rotation.
public enum DatasetDomain: String, Codable, Sendable, CaseIterable {
    case loop
    case automotive
    case mixed
}

/// One value the model may see, with its truth class and where it came from.
public struct ObservationExample: Codable, Sendable, Hashable {
    public var name: String
    /// Human title of the object it belongs to.
    public var object: String
    public var value: Double
    public var unit: String
    public var truth: TruthClass
    /// Instrument, system or model that produced it.
    public var source: String

    public init(name: String, object: String, value: Double, unit: String, truth: TruthClass, source: String) {
        self.name = name
        self.object = object
        self.value = value
        self.unit = unit
        self.truth = truth
        self.source = source
    }
}

/// A candidate measurement, as offered to `TestSelector`.
public struct TestExample: Codable, Sendable, Hashable {
    public var title: String
    public var object: String
    public var quantity: String
    public var unit: String
    public var cost: Double
    public var safety: String
}

public struct PredictionExample: Codable, Sendable, Hashable {
    public var test: String
    public var quantity: String
    public var unit: String
    public var low: Double
    public var high: Double
}

/// One candidate cause with the interval it predicts for every test.
public struct HypothesisExample: Codable, Sendable, Hashable {
    /// Stable cause label; for loop scenarios a `LoopFaultKind` raw value.
    public var cause: String
    public var statement: String
    public var predictions: [PredictionExample]
}

public struct RankedTestExample: Codable, Sendable, Hashable {
    public var title: String
    /// Expected reduction in uncertainty, in bits.
    public var informationGain: Double
    /// Gain per minute after the safety factor.
    public var score: Double
    /// Causes grouped by the outcome they predict.
    public var outcomes: [[String]]
}

/// One step of the expert path: the test run, the field's answer, and what survived.
public struct ExpertStepExample: Codable, Sendable, Hashable {
    public var test: String
    public var value: Double
    public var unit: String
    public var truth: TruthClass
    public var remaining: [String]
}

public struct DivergenceExample: Codable, Sendable, Hashable {
    public var object: String
    public var quantity: String
    public var unit: String
    public var tick: Int
    public var seconds: Double
    /// Healthy-twin value (modeled truth).
    public var expected: Double
    /// Field value (observed truth under the training-world convention).
    public var actual: Double
}

public struct TrailStepExample: Codable, Sendable, Hashable {
    public var kind: String
    public var target: String
    public var headline: String
}

/// Everything the grader knows.
public struct AnswerKey: Codable, Sendable, Hashable {
    /// The true cause label.
    public var cause: String
    /// Title of the test `TestSelector` ranks first, when the example has tests.
    public var nextTest: String?
    /// A reference answer: every figure in it is labeled with its truth class.
    public var text: String
    public var ranking: [RankedTestExample]?
    public var expertPath: [ExpertStepExample]?
    public var firstDivergence: DivergenceExample?
    /// Ladder examples: the causal trail from `CausalJournal`.
    public var trail: [TrailStepExample]?
    /// Ladder examples: every unsatisfied permissive, primary first.
    public var blockers: [String]?
}

public struct ParameterOverrideExample: Codable, Sendable, Hashable {
    public var object: String
    public var parameter: String
    public var value: Double
}

/// The hidden setup of a loop scenario.
public struct LoopScenarioExample: Codable, Sendable, Hashable {
    public var fault: String
    public var severity: Double
    public var overrides: [ParameterOverrideExample]
    public var setpoint: Double
    public var initialLevel: Double
    public var runSeconds: Double
}

public struct ToolCallExample: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One chat turn. Tool turns carry the result of the call named by `toolCallID`.
public struct MessageExample: Codable, Sendable, Hashable {
    public var role: String
    public var content: String
    public var toolCalls: [ToolCallExample]?
    public var toolCallID: String?
}

public struct LadderRungExample: Codable, Sendable, Hashable {
    public var number: Int
    /// Rung text, e.g. `XIC(GuardDoor_Closed) XIO(Fault) OTE(Safety_OK)`.
    public var text: String
}

public struct LadderContextExample: Codable, Sendable, Hashable {
    public var routine: String
    public var rungs: [LadderRungExample]
    public var target: String
}

/// One line of the JSONL dataset. Sections that do not apply to a kind are omitted.
public struct TrainingExample: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ExampleKind
    public var split: DatasetSplit
    public var seed: UInt64
    /// What the model is asked: a symptom, a goal or a question.
    public var prompt: String
    /// Values available before any test, each with its truth class.
    public var observations: [ObservationExample]
    public var tests: [TestExample]?
    public var hypotheses: [HypothesisExample]?
    public var scenario: LoopScenarioExample?
    public var messages: [MessageExample]?
    public var ladder: LadderContextExample?
    public var answer: AnswerKey
    /// Automotive examples: the hidden vehicle setup.
    public var vehicle: VehicleScenarioExample? = nil
}
