import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

extension EventKind {
    /// The tutor gave a learner a hint on a scenario. Payload: `learner`,
    /// `level`, `text`, optional `test`. Agent interpretation.
    public static let tutorHint: EventKind = "tutorHint"
}

/// Fixed rules of the tutor.
public enum TutorPolicy {
    /// Score deducted from the next graded attempt per hint taken.
    public static let pointsPerHint = 5.0
    /// Wrong attempts before the tutor will state the answer.
    public static let revealAfterAttempts = 3
    /// The tutor's identity on everything it writes.
    public static let agent = Origin.agent(id: "nexus-tutor", run: nil)
}

/// How much a hint gives away, in the order they are handed out.
public enum HintLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// A Socratic question: what would tell the candidates apart?
    case question = 1
    /// Points at the next discriminating test on the expert path.
    case pointer = 2
    /// The readings to expect at that test: the healthy twin's value and
    /// the candidates' predicted bands, without saying which band is whose.
    case readings = 3

    public static func < (lhs: HintLevel, rhs: HintLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One hint. Always agent interpretation: it is the tutor's reading of the
/// scenario, not a fact about the plant.
public struct TutorHint: Sendable, Hashable {
    public var level: HintLevel
    public var text: String
    /// The test pointed at (levels 2 and 3).
    public var test: String?
    /// What the healthy twin reads at that test (level 3).
    public var healthyReading: ReadingRange?
    /// The distinct bands the candidates predict at that test, low to high (level 3).
    public var candidateBands: [ReadingRange]
    public var provenance: Provenance
    /// The `tutorHint` event on the timeline.
    public var event: ObjectID
}

/// How far a learner's tests follow the expert path.
public struct ExpertPathProgress: Sendable, Hashable {
    /// Expert-path tests the learner has run, in expert order.
    public var covered: [String]
    /// Expert-path tests not yet run, in expert order.
    public var remaining: [String]
    /// Tests the learner ran that are not on the expert path.
    public var offPath: [String]
    /// Covered ÷ expert-path length (1 when the path is empty).
    public var fraction: Double

    public var next: String? { remaining.first }
}

/// The answer key, released only after the attempt threshold or a correct attempt.
public struct TutorAnswer: Sendable, Hashable {
    public var cause: String
    public var expertPath: [String]
    public var firstDivergence: String?
    public var provenance: Provenance
}

public enum TutorError: Error, Equatable, Sendable {
    /// The answer stays hidden until `required` attempts (or a correct one).
    case answerLocked(attempts: Int, required: Int)
}

/// A Socratic tutor over one training scenario for one learner.
///
/// Hints reveal progressively: a question, then a pointer to the next
/// discriminating test on the expert path, then the readings to expect
/// there. No hint names the cause, and `revealAnswer()` refuses until the
/// learner has made `revealAfterAttempts` attempts or got it right. Hints are
/// stored as `tutorHint` events (agent interpretation), and each one costs
/// `TutorPolicy.pointsPerHint` on the next graded attempt.
///
/// This follows the rule of the trainer's `PowerReasoner`
/// (ControlsReasoning): say only what captured evidence supports. Here the
/// evidence is the investigation's predictions and the simulator's replay,
/// not a guess at the cause.
public struct Tutor: Sendable {
    public let learning: LearningRuntime
    public let scenario: TrainingScenario
    public let learner: Origin
    public let revealAfterAttempts: Int
    let clock: NexusClock

    public init(
        learning: LearningRuntime,
        scenario: ObjectID,
        learner: Origin,
        revealAfterAttempts: Int = TutorPolicy.revealAfterAttempts
    ) throws {
        self.learning = learning
        self.scenario = try learning.scenario(scenario)
        self.learner = learner
        self.revealAfterAttempts = max(1, revealAfterAttempts)
        self.clock = learning.clock
    }

    var store: NexusStore { learning.store }

    /// Grades the learner's tests against the expert path.
    public func progress(testsRun: [String]) -> ExpertPathProgress {
        let covered = scenario.expertPath.filter(testsRun.contains)
        let remaining = scenario.expertPath.filter { !testsRun.contains($0) }
        var offPath: [String] = []
        for test in testsRun where !scenario.expertPath.contains(test) && !offPath.contains(test) {
            offPath.append(test)
        }
        let fraction = scenario.expertPath.isEmpty ? 1 : Double(covered.count) / Double(scenario.expertPath.count)
        return ExpertPathProgress(covered: covered, remaining: remaining, offPath: offPath, fraction: fraction)
    }

    /// Hint events this learner has had on the scenario, oldest first.
    public func hints() throws -> [Event] {
        let label = LearnerKey.label(learner)
        return try store.events(about: scenario.id).filter { $0.kind == .tutorHint && $0.payload["learner"] == .string(label) }
    }

    /// The learner's graded attempts.
    public func attempts() throws -> [ObjectRecord] {
        try learning.attempts(at: scenario.id, by: learner)
    }

    /// Whether the answer may be shown: enough attempts, or a correct one.
    public func canReveal() throws -> Bool {
        let attempts = try attempts()
        return attempts.count >= revealAfterAttempts || attempts.contains { $0.attributes["correct"]?.value == .bool(true) }
    }

    /// The next hint, one level deeper than the last (capped at `.readings`).
    @discardableResult
    public func hint(testsRun: [String]) throws -> TutorHint {
        let given = try hints().count
        let level = HintLevel(rawValue: min(HintLevel.readings.rawValue, given + 1)) ?? .readings
        let progress = progress(testsRun: testsRun)
        var hint = TutorHint(
            level: level, text: "", test: nil, healthyReading: nil, candidateBands: [],
            provenance: Provenance(
                origin: TutorPolicy.agent, truth: .agentInterpretation, timestamp: clock.now(), method: "Socratic tutor, level \(level.rawValue)",
                dependencies: [scenario.id]
            ),
            event: .make()
        )

        switch level {
        case .question:
            if testsRun.isEmpty {
                hint.text =
                    "There are \(scenario.choices.count) candidate causes. Before you measure anything: which reading would come out "
                    + "differently depending on which one is true? Look for the cheapest safe test whose predictions do not overlap."
            } else {
                hint.text =
                    "You have run \(testsRun.count) test\(testsRun.count == 1 ? "" : "s"). Which candidates can your readings still "
                    + "not tell apart, and what would split them?"
            }
        case .pointer, .readings:
            guard let next = progress.next else {
                hint.text =
                    "You already have the readings that decide this case. Compare each one with what every candidate predicts: "
                    + "which candidate is not contradicted by any of them?"
                break
            }
            hint.test = next
            if level == .pointer {
                hint.text = "Consider this test next: \(next). What would each candidate predict it reads?"
                break
            }
            let bands = Self.bands(for: next, in: scenario)
            hint.candidateBands = bands
            let unit = bands.first?.unit ?? ""
            if let test = scenario.tests.first(where: { $0.title == next }),
                let healthy = try scenario.simulator.readings(for: [test], faulted: false)[next]
            {
                hint.healthyReading = ReadingRange(low: healthy, high: healthy, unit: unit)
            }
            var parts = ["At \(next):"]
            if let healthy = hint.healthyReading {
                parts.append("a healthy system reads about \(Self.format(healthy.low)) \(unit).")
            }
            if !bands.isEmpty {
                let listed = bands.map { "\(Self.format($0.low))–\(Self.format($0.high)) \($0.unit)" }.joined(separator: "; ")
                parts.append("The candidates predict \(bands.count) distinct band\(bands.count == 1 ? "" : "s"): \(listed).")
            }
            parts.append("Which band does your reading fall in, and which candidates does that leave?")
            hint.text = parts.joined(separator: " ")
        }

        var payload: [String: Value] = [
            "learner": .string(LearnerKey.label(learner)), "level": .int(Int64(level.rawValue)), "text": .string(hint.text),
        ]
        if let test = hint.test { payload["test"] = .string(test) }
        try store.record(
            Event(
                id: hint.event, at: hint.provenance.timestamp, kind: .tutorHint, subjects: [scenario.id],
                summary: "Hint (\(level)) on \(scenario.briefing)", payload: payload, provenance: hint.provenance
            ))
        return hint
    }

    /// Grades an attempt, charging the hints taken since the last one, and
    /// updates the learner record.
    @discardableResult
    public func submit(testsRun: [String], diagnosis: String) throws -> ScenarioAttemptResult {
        let charged = try attempts().reduce(0) { total, attempt in
            if case .int(let used)? = attempt.attributes["hintsUsed"]?.value { return total + Int(used) }
            return total
        }
        let unpaid = max(0, try hints().count - charged)
        let result = try learning.grade(scenario.id, learner: learner, testsRun: testsRun, diagnosis: diagnosis, hintsUsed: unpaid)
        try LearnerRecords(store: store, clock: clock).record(result, on: scenario, learner: learner)
        return result
    }

    /// The answer key. Throws `answerLocked` until the threshold is met.
    public func revealAnswer() throws -> TutorAnswer {
        guard try canReveal() else {
            throw TutorError.answerLocked(attempts: try attempts().count, required: revealAfterAttempts)
        }
        return TutorAnswer(
            cause: scenario.cause, expertPath: scenario.expertPath, firstDivergence: scenario.firstDivergence,
            provenance: Provenance(
                origin: TutorPolicy.agent, truth: .agentInterpretation, timestamp: clock.now(), method: "answer key after attempts",
                dependencies: [scenario.id]
            )
        )
    }

    /// Distinct predicted bands at a test, merged where they are equal, low first.
    static func bands(for test: String, in scenario: TrainingScenario) -> [ReadingRange] {
        var bands: [ReadingRange] = []
        for choice in scenario.choices {
            guard let range = scenario.candidateReadings[choice]?[test], !bands.contains(range) else { continue }
            bands.append(range)
        }
        return bands.sorted { ($0.low, $0.high) < ($1.low, $1.high) }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3g", value)
    }
}

/// A stable text key for a learner.
enum LearnerKey {
    static func label(_ origin: Origin) -> String {
        switch origin {
        case .user(let id): "user:\(id)"
        case .agent(let id, _): "agent:\(id)"
        case .importer(let source): "importer:\(source)"
        case .simulation(let run): "simulation:\(run)"
        case .instrument(let id): "instrument:\(id)"
        case .model(let ref): "model:\(ref.provider)/\(ref.modelID)"
        case .system: "system"
        }
    }
}
