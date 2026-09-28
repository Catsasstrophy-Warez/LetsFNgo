import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence

extension ObjectType {
    /// A spaced-repetition flashcard derived from canonical objects.
    public static let reviewCard: ObjectType = "reviewCard"
}

extension EventKind {
    /// A learner graded their recall of a card. Payload: `learner`, `grade`
    /// (0–5), `intervalBefore`, `intervalAfter` (days), `easiness`, `due`.
    public static let cardReviewed: EventKind = "cardReviewed"
}

public enum ReviewError: Error, Equatable, Sendable {
    case invalidGrade(Int)
    case notACard(ObjectID)
    case malformed(ObjectID)
}

/// What a card asks about.
public enum ReviewCardKind: String, Sendable, Hashable, CaseIterable {
    /// The confirmed cause of a resolved investigation.
    case cause
    /// A reading that supported the confirmed cause.
    case evidence
    /// A claim, with its citation.
    case claim
    /// One step of a procedure.
    case procedureStep
    /// What a diagnostic trouble code means.
    case dtcMeaning
}

/// SuperMemo-2 scheduling state.
public struct SM2State: Sendable, Hashable {
    /// Successful reviews in a row.
    public var repetitions: Int
    /// Easiness factor, never below 1.3.
    public var easiness: Double
    /// Days until the next review.
    public var intervalDays: Int
    public var due: Date
    /// Reviews graded below 3.
    public var lapses: Int

    public static let initialEasiness = 2.5
    public static let minimumEasiness = 1.3

    public init(repetitions: Int = 0, easiness: Double = SM2State.initialEasiness, intervalDays: Int = 0, due: Date, lapses: Int = 0) {
        self.repetitions = repetitions
        self.easiness = easiness
        self.intervalDays = intervalDays
        self.due = due
        self.lapses = lapses
    }

    /// The state after a review graded `grade` (0–5) at `date`.
    ///
    /// SM-2 (Woźniak, 1990): a grade of 3 or more is a success, and the
    /// interval goes 1 day, 6 days, then the previous interval × EF, rounded.
    /// A grade below 3 restarts the repetitions at a 1-day interval. After
    /// every review EF ← EF + 0.1 − (5 − q)(0.08 + (5 − q) 0.02), floored at 1.3.
    public func reviewed(grade: Int, at date: Date) throws -> SM2State {
        guard (0...5).contains(grade) else { throw ReviewError.invalidGrade(grade) }
        var next = self
        if grade >= 3 {
            switch repetitions {
            case 0: next.intervalDays = 1
            case 1: next.intervalDays = 6
            default: next.intervalDays = Int((Double(intervalDays) * easiness).rounded())
            }
            next.repetitions += 1
        } else {
            next.repetitions = 0
            next.intervalDays = 1
            next.lapses += 1
        }
        let q = Double(5 - grade)
        next.easiness = max(Self.minimumEasiness, easiness + 0.1 - q * (0.08 + q * 0.02))
        next.due = date.addingTimeInterval(Double(next.intervalDays) * 86_400)
        return next
    }
}

/// A flashcard. `sources` are the canonical objects it was made from; the
/// card links to each with `cites`, so its provenance survives.
public struct ReviewCard: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var kind: ReviewCardKind
    /// Identifies what the card is about, so it is made only once.
    public var key: String
    public var front: String
    public var back: String
    public var sources: [ObjectID]
    public var schedule: SM2State
    public var provenance: Provenance

    /// The learner-record topic a review of this card scores.
    public var topic: String { "cards/\(kind.rawValue)" }
}

/// Makes, schedules and reviews flashcards on the canonical store.
///
/// Cards are `reviewCard` objects (derived truth) placed in a project with
/// `contains`. Each review is a `cardReviewed` event, and the schedule
/// attributes are rewritten as derived values that depend on that event.
public struct ReviewRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Generating

    /// Cards from every current member of a project.
    @discardableResult
    public func generateCards(forProject project: ObjectID, by author: Origin) throws -> [ReviewCard] {
        let members = try store.relationships(from: project, kind: .contains).filter { $0.validTo == nil }.map(\.to)
        return try generateCards(from: members, in: project, by: author)
    }

    /// Cards from canonical objects: a resolved investigation gives its
    /// cause and the readings that supported it; a claim gives a cloze card
    /// with its citation; a procedure gives one card per step; a fault with
    /// a trouble code gives the code's meaning. Other objects give none.
    /// A card that already exists (same key) is reused and placed in the project.
    @discardableResult
    public func generateCards(from objects: [ObjectID], in project: ObjectID? = nil, by author: Origin) throws -> [ReviewCard] {
        try store.batch { store in
            var existing: [String: ReviewCard] = [:]
            for card in try allCards() {
                existing[card.key] = card
            }
            var cards: [ReviewCard] = []
            for record in try store.objects(objects) {
                for draft in try drafts(from: record) {
                    let card: ReviewCard
                    if let found = existing[draft.key] {
                        card = found
                    } else {
                        card = try create(draft, by: author)
                        existing[card.key] = card
                    }
                    if let project { try place(card.id, in: project, by: author) }
                    if !cards.contains(where: { $0.id == card.id }) { cards.append(card) }
                }
            }
            return cards
        }
    }

    struct Draft {
        var kind: ReviewCardKind
        var key: String
        var front: String
        var back: String
        var sources: [ObjectID]
    }

    func drafts(from record: ObjectRecord) throws -> [Draft] {
        switch record.type {
        case .investigation: return try investigationDrafts(record)
        case .claim:
            guard let claim = try store.claim(record.id) else { return [] }
            return [try claimDraft(claim)]
        case .procedure: return procedureDrafts(record)
        case .fault:
            guard case .string(let code)? = record.attributes[AutomotiveKey.dtc]?.value,
                case .string(let meaning)? = record.attributes[AutomotiveKey.description]?.value
            else { return [] }
            return [Draft(kind: .dtcMeaning, key: "dtc:\(code)", front: "What does trouble code \(code) mean?", back: meaning, sources: [record.id])]
        default: return []
        }
    }

    func investigationDrafts(_ record: ObjectRecord) throws -> [Draft] {
        guard case .reference(let causeID)? = record.attributes["cause"]?.value,
            let cause = try InvestigationRuntime(store: store, clock: clock).hypotheses(of: record.id).first(where: { $0.id == causeID })
        else { return [] }
        var back = cause.statement
        if case .string(let resolution)? = record.attributes["resolution"]?.value { back += "\nResolution: \(resolution)" }
        var drafts = [
            Draft(
                kind: .cause, key: "cause:\(record.id)", front: "Symptom: \(record.title). What was the confirmed cause?", back: back,
                sources: [record.id, cause.id]
            )
        ]
        let supporting = try store.relationships(to: cause.id, kind: .supports).map(\.from)
        for reading in try supporting.compactMap({ try store.measurement($0) }).sorted(by: { ($0.sampledAt, $0.id) < ($1.sampledAt, $1.id) })
        where InvestigationRuntime.evidenceTruth.contains(reading.truth) {
            let place = try store.object(reading.testPoint)?.title ?? "the test point"
            let value = String(format: "%.4g", reading.value.value)
            drafts.append(
                Draft(
                    kind: .evidence, key: "evidence:\(reading.id)",
                    front: "Investigating “\(record.title)”, \(reading.quantityName) read \(value) \(reading.value.unit) at \(place). "
                        + "Which cause did that reading support?",
                    back: cause.statement, sources: [reading.id, cause.id, record.id]
                ))
        }
        return drafts
    }

    func claimDraft(_ claim: Claim) throws -> Draft {
        let titles = try store.objects(claim.sources).map(\.title)
        let citation = titles.isEmpty ? "its source" : titles.joined(separator: "; ")
        let words = claim.statement.split(separator: " ")
        let shown = words.prefix(max(1, words.count / 2)).joined(separator: " ")
        var back = claim.statement + "\nSource: \(citation)"
        if let passage = claim.passages.first { back += " — “\(passage)”" }
        return Draft(
            kind: .claim, key: "claim:\(claim.id)", front: "According to \(citation), complete the claim: “\(shown) …”", back: back,
            sources: [claim.id] + claim.sources
        )
    }

    func procedureDrafts(_ record: ObjectRecord) -> [Draft] {
        guard case .list(let values)? = record.attributes[AutomotiveKey.steps]?.value else { return [] }
        let steps = values.compactMap { value -> String? in
            if case .string(let text) = value { return text }
            return nil
        }
        return steps.indices.map { index in
            let after = index > 0 ? ", after “\(steps[index - 1])”" : ""
            return Draft(
                kind: .procedureStep, key: "procedureStep:\(record.id):\(index)",
                front: "\(record.title): what is step \(index + 1) of \(steps.count)\(after)?", back: steps[index], sources: [record.id]
            )
        }
    }

    func create(_ draft: Draft, by author: Origin) throws -> ReviewCard {
        let now = clock.now()
        let provenance = Provenance(
            origin: author, truth: .derived, timestamp: now, method: "review card (\(draft.kind.rawValue))", dependencies: draft.sources
        )
        let card = ReviewCard(
            id: .make(), kind: draft.kind, key: draft.key, front: draft.front, back: draft.back, sources: draft.sources,
            schedule: SM2State(due: now), provenance: provenance
        )
        var attributes: [String: Attribute] = [
            "kind": Attribute(.string(draft.kind.rawValue)), "key": Attribute(.string(draft.key)), "front": Attribute(.string(draft.front)),
            "back": Attribute(.string(draft.back)), "sources": Attribute(.list(draft.sources.map(Value.reference))),
        ]
        for (key, value) in Self.encode(card.schedule) {
            attributes[key] = Attribute(value)
        }
        try store.create(ObjectRecord(id: card.id, type: .reviewCard, title: "Card: \(draft.front)", attributes: attributes, provenance: provenance))
        for source in draft.sources {
            try store.relate(Relationship(kind: .cites, from: card.id, to: source, provenance: provenance))
        }
        return card
    }

    func place(_ card: ObjectID, in project: ObjectID, by author: Origin) throws {
        let placed = try store.relationships(from: project, kind: .contains).contains { $0.to == card && $0.validTo == nil }
        guard !placed else { return }
        try store.relate(
            Relationship(
                kind: .contains, from: project, to: card, validFrom: clock.now(),
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "review card placed in project")
            ))
    }

    // MARK: Reading

    public func card(_ id: ObjectID) throws -> ReviewCard {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .reviewCard else { throw ReviewError.notACard(id) }
        return try Self.card(from: record)
    }

    /// Cards in a project (every card when `project` is nil).
    public func cards(in project: ObjectID?) throws -> [ReviewCard] {
        guard let project else { return try allCards() }
        let ids = try store.relationships(from: project, kind: .contains).filter { $0.validTo == nil }.map(\.to)
        return try store.objects(ids).filter { $0.type == .reviewCard && $0.lifecycle == .active }.map(Self.card(from:))
    }

    func allCards() throws -> [ReviewCard] {
        try store.objects(ofType: .reviewCard).filter { $0.lifecycle == .active }.map(Self.card(from:))
    }

    /// Cards due at `date`, most overdue first, then the hardest (lowest easiness).
    public func dueCards(in project: ObjectID?, at date: Date? = nil) throws -> [ReviewCard] {
        let now = date ?? clock.now()
        return try cards(in: project).filter { $0.schedule.due <= now }
            .sorted { ($0.schedule.due, $0.schedule.easiness, $0.id) < ($1.schedule.due, $1.schedule.easiness, $1.id) }
    }

    /// Due cards for every project that has any.
    public func dueQueues(at date: Date? = nil) throws -> [ObjectID: [ReviewCard]] {
        var queues: [ObjectID: [ReviewCard]] = [:]
        for project in try store.objects(ofType: .project) {
            let due = try dueCards(in: project.id, at: date)
            if !due.isEmpty { queues[project.id] = due }
        }
        return queues
    }

    // MARK: Reviewing

    /// Records a review graded 0–5 by the learner, reschedules the card
    /// with SM-2 and updates the learner record.
    @discardableResult
    public func review(_ cardID: ObjectID, grade: Int, by learner: Origin) throws -> ReviewCard {
        guard (0...5).contains(grade) else { throw ReviewError.invalidGrade(grade) }
        return try store.batch { store in
            var card = try card(cardID)
            let now = clock.now()
            let next = try card.schedule.reviewed(grade: grade, at: now)
            let event = Event(
                at: now, kind: .cardReviewed, subjects: [card.id], summary: "Reviewed (\(grade)/5): \(card.front)",
                payload: [
                    "learner": .string(LearnerKey.label(learner)), "grade": .int(Int64(grade)),
                    "intervalBefore": .int(Int64(card.schedule.intervalDays)), "intervalAfter": .int(Int64(next.intervalDays)),
                    "easiness": .double(next.easiness), "due": .date(next.due),
                ],
                provenance: Provenance(origin: learner, truth: learner.defaultTruth, timestamp: now, method: "self-graded recall (0–5)")
            )
            try store.record(event)
            let derived = Provenance(origin: .system, truth: .derived, timestamp: now, method: "SM-2", dependencies: [event.id])
            try store.update(card.id, by: learner, instruction: "Reviewed (\(grade)/5)") { record in
                for (key, value) in Self.encode(next) {
                    record.attributes[key] = Attribute(value, provenance: derived)
                }
            }
            card.schedule = next
            try LearnerRecords(store: store, clock: clock).recordPractice(
                [card.topic: Double(grade) / 5], source: card.id, learner: learner, method: "card review", summary: "Card review: \(grade)/5"
            )
            return card
        }
    }

    /// A card's reviews, oldest first.
    public func reviews(of cardID: ObjectID) throws -> [Event] {
        try store.events(about: cardID).filter { $0.kind == .cardReviewed }
    }

    // MARK: Encoding

    static func encode(_ schedule: SM2State) -> [String: Value] {
        [
            "repetitions": .int(Int64(schedule.repetitions)), "easiness": .double(schedule.easiness),
            "intervalDays": .int(Int64(schedule.intervalDays)), "due": .date(schedule.due), "lapses": .int(Int64(schedule.lapses)),
        ]
    }

    static func card(from record: ObjectRecord) throws -> ReviewCard {
        let a = record.attributes
        guard case .string(let kindText)? = a["kind"]?.value, let kind = ReviewCardKind(rawValue: kindText),
            case .string(let key)? = a["key"]?.value, case .string(let front)? = a["front"]?.value, case .string(let back)? = a["back"]?.value,
            case .list(let sourceValues)? = a["sources"]?.value, case .int(let repetitions)? = a["repetitions"]?.value,
            case .double(let easiness)? = a["easiness"]?.value, case .int(let interval)? = a["intervalDays"]?.value,
            case .date(let due)? = a["due"]?.value, case .int(let lapses)? = a["lapses"]?.value
        else { throw ReviewError.malformed(record.id) }
        let sources = try sourceValues.map { value -> ObjectID in
            guard case .reference(let id) = value else { throw ReviewError.malformed(record.id) }
            return id
        }
        return ReviewCard(
            id: record.id, kind: kind, key: key, front: front, back: back, sources: sources,
            schedule: SM2State(repetitions: Int(repetitions), easiness: easiness, intervalDays: Int(interval), due: due, lapses: Int(lapses)),
            provenance: record.provenance
        )
    }
}
