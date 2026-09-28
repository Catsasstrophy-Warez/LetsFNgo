import Foundation
import NexusCore
import NexusModel
import NexusPersistence

extension ObjectType {
    /// One learner's record: mastery per topic as derived attributes.
    public static let learnerRecord: ObjectType = "learnerRecord"
}

extension EventKind {
    /// A graded piece of practice (a scenario attempt or a card review).
    /// Payload: `learner`, `scores` (topic → 0…1), `source`.
    public static let practiceRecorded: EventKind = "practiceRecorded"
}

/// Mastery of one topic or skill.
public struct TopicMastery: Sendable, Hashable {
    public var topic: String
    /// 0…1, an exponential moving average of scores.
    public var mastery: Double
    public var attempts: Int
    public var lastScore: Double
    public var lastPractised: Date
}

/// What to practise next.
public enum PracticeRecommendation: Sendable, Hashable {
    /// Cards are due: retrieval now keeps them from lapsing.
    case review(cards: [ObjectID], reason: String)
    /// The scenario on the weakest topic.
    case scenario(ObjectID, topic: String, mastery: Double, reason: String)
    /// Nothing is due and every topic is mastered.
    case upToDate(nextDue: Date?, reason: String)
}

/// Learner records on the canonical store.
///
/// Each practice writes a `practiceRecorded` event (the scores, derived by
/// the grader) and updates the learner's `mastery` attribute, a derived
/// value: per topic, `m ← m + α (score − m)` with `α = learningRate`,
/// starting from 0, so a topic is only mastered after repeated good work.
///
/// A scenario attempt scores four topics: `<topic>` (score ÷ 100),
/// `<topic>/diagnosis` (1 if correct), `<topic>/testSelection`
/// (efficiency) and `<topic>/safety` (0 if a hazardous test was run). A
/// card review scores `cards/<kind>` as grade ÷ 5.
public struct LearnerRecords: Sendable {
    public let store: NexusStore
    let clock: NexusClock
    public static let learningRate = 0.35
    /// Mastery at or above this counts as mastered.
    public static let masteredAt = 0.8

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// The learner's record, created on first use.
    @discardableResult
    public func record(for learner: Origin) throws -> ObjectRecord {
        let label = LearnerKey.label(learner)
        if let existing = try store.objects(ofType: .learnerRecord).first(where: { $0.attributes["learner"]?.value == .string(label) }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .learnerRecord, title: "Learner record: \(label)",
                attributes: ["learner": Attribute(.string(label))],
                provenance: Provenance(origin: .system, truth: .derived, timestamp: clock.now(), method: "learner record")
            ))
    }

    /// Mastery per topic, from the stored record.
    public func mastery(of learner: Origin) throws -> [String: TopicMastery] {
        Self.decode(try record(for: learner))
    }

    /// Records a scenario attempt.
    @discardableResult
    public func record(_ result: ScenarioAttemptResult, on scenario: TrainingScenario, learner: Origin) throws -> [String: TopicMastery] {
        let topic = scenario.topic
        return try recordPractice(
            [
                topic: Double(result.score) / 100,
                "\(topic)/diagnosis": result.correctDiagnosis ? 1 : 0,
                "\(topic)/testSelection": result.efficiency,
                "\(topic)/safety": result.hazardousTests.isEmpty ? 1 : 0,
            ],
            source: result.attempt, learner: learner, method: "scenario grade", summary: "Scenario attempt: \(result.score)/100"
        )
    }

    /// Records scores (0…1 per topic) earned on `source` and updates mastery.
    @discardableResult
    public func recordPractice(
        _ scores: [String: Double],
        source: ObjectID,
        learner: Origin,
        method: String,
        summary: String
    ) throws -> [String: TopicMastery] {
        try store.batch { store in
            let record = try record(for: learner)
            let now = clock.now()
            let event = Event(
                at: now, kind: .practiceRecorded, subjects: [record.id, source], summary: summary,
                payload: [
                    "learner": .string(LearnerKey.label(learner)), "source": .reference(source),
                    "scores": .map(scores.mapValues { .double(min(1, max(0, $0))) }),
                ],
                provenance: Provenance(origin: .system, truth: .derived, timestamp: now, method: method, dependencies: [source])
            )
            try store.record(event)

            var mastery = Self.decode(record)
            for (topic, raw) in scores {
                let score = min(1, max(0, raw))
                var entry = mastery[topic] ?? TopicMastery(topic: topic, mastery: 0, attempts: 0, lastScore: 0, lastPractised: now)
                entry.mastery += Self.learningRate * (score - entry.mastery)
                entry.attempts += 1
                entry.lastScore = score
                entry.lastPractised = now
                mastery[topic] = entry
            }
            let provenance = Provenance(
                origin: .system, truth: .derived, timestamp: now,
                method: "exponential moving average of practice scores (α = \(Self.learningRate))", dependencies: [event.id]
            )
            try store.update(record.id, by: .system, instruction: "Practice recorded") {
                $0.attributes["mastery"] = Attribute(Self.encode(mastery), provenance: provenance)
            }
            return mastery
        }
    }

    /// The next best thing to practise: due cards first (retrieval is cheap
    /// and they decay), then the scenario on the weakest unmastered topic
    /// (unpractised topics count as 0; ties go to fewer attempts, then the
    /// oldest scenario), else nothing until the next card is due.
    ///
    /// With a project, only its cards and the scenarios made from its
    /// investigations (or placed in it) count.
    public func nextBestThing(for learner: Origin, in project: ObjectID? = nil, at date: Date? = nil) throws -> PracticeRecommendation {
        let now = date ?? clock.now()
        let reviews = ReviewRuntime(store: store, clock: clock)
        let due = try reviews.dueCards(in: project, at: now)
        if !due.isEmpty {
            return .review(cards: due.map(\.id), reason: "\(due.count) card\(due.count == 1 ? " is" : "s are") due for review")
        }

        let mastery = try mastery(of: learner)
        var scenarios = try LearningRuntime(store: store, clock: clock).scenarios()
        if let project {
            let members = Set(try store.relationships(from: project, kind: .contains).filter { $0.validTo == nil }.map(\.to))
            scenarios = try scenarios.filter { scenario in
                if members.contains(scenario.id) { return true }
                return try store.relationships(from: scenario.id, kind: .derivedFrom).contains { members.contains($0.to) }
            }
        }
        let weakest =
            scenarios
            .map { (scenario: $0, entry: mastery[$0.topic]) }
            .filter { ($0.entry?.mastery ?? 0) < Self.masteredAt }
            .min { lhs, rhs in
                let left = (lhs.entry?.mastery ?? 0, lhs.entry?.attempts ?? 0)
                let right = (rhs.entry?.mastery ?? 0, rhs.entry?.attempts ?? 0)
                return left != right ? left < right : lhs.scenario.id < rhs.scenario.id
            }
        if let weakest {
            let level = weakest.entry?.mastery ?? 0
            return .scenario(
                weakest.scenario.id, topic: weakest.scenario.topic, mastery: level,
                reason: weakest.entry == nil
                    ? "\(weakest.scenario.topic) has not been practised yet"
                    : "\(weakest.scenario.topic) is the weakest topic (mastery \(Int((level * 100).rounded())) %)"
            )
        }
        let next = try reviews.cards(in: project).map(\.schedule.due).min()
        return .upToDate(nextDue: next, reason: "Every topic is mastered and no card is due")
    }

    // MARK: Encoding

    static func encode(_ mastery: [String: TopicMastery]) -> Value {
        .map(
            mastery.mapValues { entry in
                .map([
                    "mastery": .double(entry.mastery), "attempts": .int(Int64(entry.attempts)), "lastScore": .double(entry.lastScore),
                    "lastPractised": .date(entry.lastPractised),
                ])
            })
    }

    static func decode(_ record: ObjectRecord) -> [String: TopicMastery] {
        guard case .map(let topics)? = record.attributes["mastery"]?.value else { return [:] }
        var result: [String: TopicMastery] = [:]
        for (topic, value) in topics {
            guard case .map(let map) = value, case .double(let mastery)? = map["mastery"], case .int(let attempts)? = map["attempts"],
                case .double(let last)? = map["lastScore"], case .date(let at)? = map["lastPractised"]
            else { continue }
            result[topic] = TopicMastery(topic: topic, mastery: mastery, attempts: Int(attempts), lastScore: last, lastPractised: at)
        }
        return result
    }
}
