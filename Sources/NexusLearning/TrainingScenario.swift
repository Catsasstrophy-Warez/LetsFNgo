import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

extension ObjectType {
    public static let trainingScenario: ObjectType = "trainingScenario"
    public static let scenarioAttempt: ObjectType = "scenarioAttempt"
}

public enum LearningError: Error, Equatable, Sendable {
    case investigationNotResolved(ObjectID)
    case notAScenario(ObjectID)
    case malformed(ObjectID)
    case unknownTest(String)
    /// No simulator could be found to replay the investigation.
    case noSimulator(ObjectID)
}

/// What a test reads, as an interval.
public struct ReadingRange: Sendable, Hashable {
    public var low: Double
    public var high: Double
    public var unit: String

    public init(low: Double, high: Double, unit: String) {
        self.low = low
        self.high = high
        self.unit = unit
    }

    public func contains(_ value: Double) -> Bool { (low...high).contains(value) }
}

/// A replayable exercise distilled from a resolved investigation.
///
/// The learner sees only the briefing, the candidate causes and the tests
/// they may run; the answer key (cause, expert path, first divergence) stays
/// in the scenario for scoring. The fault is replayed by a
/// `ScenarioSimulator` (instrument loop, charging system or a generic
/// solver set), so the field can be rebuilt and measured again.
public struct TrainingScenario: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var briefing: String
    public var simulator: any ScenarioSimulator
    public var choices: [String]
    public var tests: [TestOption]
    public var cause: String
    /// Test titles in the order the resolving technician ran them.
    public var expertPath: [String]
    public var firstDivergence: String?
    /// Per candidate cause, what each test (by title) was predicted to read.
    /// Taken from the investigation's hypotheses.
    public var candidateReadings: [String: [String: ReadingRange]]
    /// What the learner practises, for the learner record. Defaults to the simulator kind.
    public var topic: String

    public init(
        id: ObjectID,
        briefing: String,
        simulator: any ScenarioSimulator,
        choices: [String],
        tests: [TestOption],
        cause: String,
        expertPath: [String],
        firstDivergence: String?,
        candidateReadings: [String: [String: ReadingRange]] = [:],
        topic: String? = nil
    ) {
        self.id = id
        self.briefing = briefing
        self.simulator = simulator
        self.choices = choices
        self.tests = tests
        self.cause = cause
        self.expertPath = expertPath
        self.firstDivergence = firstDivergence
        self.candidateReadings = candidateReadings
        self.topic = topic ?? simulator.kind
    }

    /// An instrument-loop scenario with one fault.
    public init(
        id: ObjectID,
        briefing: String,
        loop: InstrumentLoop,
        fault: SimulatedFault,
        choices: [String],
        tests: [TestOption],
        cause: String,
        expertPath: [String],
        firstDivergence: String?,
        candidateReadings: [String: [String: ReadingRange]] = [:]
    ) {
        self.init(
            id: id, briefing: briefing, simulator: LoopScenarioSimulator(loop: loop, faults: [fault]), choices: choices, tests: tests,
            cause: cause, expertPath: expertPath, firstDivergence: firstDivergence, candidateReadings: candidateReadings
        )
    }

    /// The loop, when the scenario replays one.
    public var loop: InstrumentLoop? { (simulator as? LoopScenarioSimulator)?.loop }
    /// The first fault the simulator injects.
    public var fault: SimulatedFault? { simulator.faults.first }

    /// A fresh field simulation with the case's fault, run to the operating
    /// point where the symptom appeared.
    public func makeField() throws -> SimulationRuntime {
        try simulator.makeField()
    }

    /// The same simulation without the fault.
    public func makeTwin() throws -> SimulationRuntime {
        try simulator.makeTwin()
    }

    public static func == (lhs: TrainingScenario, rhs: TrainingScenario) -> Bool {
        lhs.id == rhs.id && lhs.briefing == rhs.briefing && lhs.choices == rhs.choices && lhs.tests == rhs.tests && lhs.cause == rhs.cause
            && lhs.expertPath == rhs.expertPath && lhs.firstDivergence == rhs.firstDivergence && lhs.candidateReadings == rhs.candidateReadings
            && lhs.topic == rhs.topic && ScenarioSimulators.encode(lhs.simulator) == ScenarioSimulators.encode(rhs.simulator)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(cause)
        hasher.combine(ScenarioSimulators.encode(simulator))
    }
}

public struct ScenarioAttemptResult: Sendable, Hashable {
    public var attempt: ObjectID
    public var correctDiagnosis: Bool
    /// Cost of the expert-path tests the learner ran ÷ the learner's total cost.
    /// 1 means no wasted tests; 0 means none of the discriminating tests were run.
    public var efficiency: Double
    public var hazardousTests: [String]
    /// Chose a cause without running any test that splits the candidates.
    public var jumpedToConclusion: Bool
    /// 0–100.
    public var score: Int
}

extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
