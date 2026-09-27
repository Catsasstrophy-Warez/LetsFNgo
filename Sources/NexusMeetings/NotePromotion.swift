import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks

extension ObjectType {
    public static let meeting: ObjectType = "meeting"
    public static let question: ObjectType = "question"
}

/// One structured item found in a transcript or note.
public struct PromotedItem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case decision
        case task
        case claim
        case question
    }

    public var kind: Kind
    public var text: String
    /// Who said it, when the transcript names the speaker.
    public var speaker: String?
    /// Zero-based line in the transcript, for citation.
    public var line: Int
}

/// Turns meeting or field-note transcripts into structured objects instead of
/// leaving decisions and commitments trapped in prose.
///
/// Extraction here is rule-based and conservative, so it runs offline and
/// deterministically; an agent can propose more (as interpretations) later.
/// Lines look like "Speaker: text" or plain text.
public enum NotePromotion {
    public static func extract(from transcript: String) -> [PromotedItem] {
        var items: [PromotedItem] = []
        for (index, raw) in transcript.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let (speaker, text) = split(String(raw))
            let lower = text.lowercased()
            guard !text.isEmpty else { continue }
            let kind: PromotedItem.Kind?
            if lower.hasPrefix("decision:") || lower.contains("we decided") || lower.contains("we agreed") || lower.hasPrefix("agreed:") {
                kind = .decision
            } else if lower.hasPrefix("action:") || lower.hasPrefix("todo:") || lower.hasPrefix("task:")
                        || lower.range(of: #"^(i|we|[a-z]+) will "#, options: .regularExpression) != nil
                        || lower.contains("i'll ") {
                kind = .task
            } else if lower.hasPrefix("according to") || lower.contains("the manual says") || lower.contains("spec says") || lower.contains("datasheet says") {
                kind = .claim
            } else if text.hasSuffix("?") {
                kind = .question
            } else {
                kind = nil
            }
            if let kind {
                items.append(PromotedItem(kind: kind, text: strip(text), speaker: speaker, line: index))
            }
        }
        return items
    }

    /// What `promote` stored.
    public struct Promotion: Sendable, Hashable {
        public var meeting: ObjectID
        /// Promoted items in transcript order.
        public var items: [ObjectID]
        /// Person objects that `attended` the meeting, by name.
        public var participants: [String: ObjectID]
        /// Tasks someone took on in their own words ("I will …"), owned by them.
        public var commitments: [ObjectID]
    }

    /// Stores the meeting and its promoted items. Decisions, tasks and
    /// questions are records of what was said (recorded, by the note's
    /// author); statements of fact are claims attributed to the speaker, never
    /// facts. Everything links back to the meeting.
    ///
    /// Tasks go through `TaskRuntime`, so they get a status, an owner and a
    /// timeline like any other task. A speaker who says "I will …" or "I'll
    /// …" makes a commitment: a task owned by that speaker (`.user(id:)`
    /// with their name) and linked to their person object. Every speaker and
    /// every listed participant becomes a person object that `attended` the
    /// meeting, reusing an existing person with the same name.
    @discardableResult
    public static func promote(
        transcript: String,
        title: String,
        in store: NexusStore,
        by author: Origin,
        at date: Date,
        about subjects: [ObjectID] = []
    ) throws -> (meeting: ObjectID, items: [ObjectID]) {
        let promotion = try promote(transcript: transcript, title: title, participants: [], in: store, by: author, at: date, about: subjects)
        return (promotion.meeting, promotion.items)
    }

    /// `promote`, with named participants and the full result.
    @discardableResult
    public static func promote(
        transcript: String,
        title: String,
        participants named: [String],
        in store: NexusStore,
        by author: Origin,
        at date: Date,
        about subjects: [ObjectID] = []
    ) throws -> Promotion {
        try store.batch { store in
            let recorded = Provenance(origin: author, truth: .recorded, timestamp: date, method: "meeting notes")
            let tasks = TaskRuntime(store: store, clock: FixedClock(date))
            let meeting = try store.create(ObjectRecord(
                type: .meeting, title: title, attributes: ["transcript": Attribute(.string(transcript))], provenance: recorded
            )).id
            for subject in subjects {
                try store.relate(Relationship(kind: .dependsOn, from: meeting, to: subject, provenance: recorded))
            }

            let items = extract(from: transcript)
            var people: [String: ObjectID] = [:]
            for name in named + speakers(in: transcript) {
                let name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, people[name] == nil else { continue }
                let person = try store.objects(ofType: .person).first { $0.title == name && $0.lifecycle != .deleted }?.id
                    ?? store.create(ObjectRecord(type: .person, title: name, provenance: recorded)).id
                try store.relate(Relationship(kind: .attended, from: person, to: meeting, provenance: recorded))
                people[name] = person
            }

            var created: [ObjectID] = []
            var commitments: [ObjectID] = []
            for item in items {
                let id: ObjectID
                var attributes: [String: Attribute] = ["line": Attribute(.int(Int64(item.line)))]
                if let speaker = item.speaker { attributes["speaker"] = Attribute(.string(speaker)) }
                switch item.kind {
                case .decision:
                    id = try store.create(ObjectRecord(type: .decision, title: item.text, attributes: attributes, provenance: recorded)).id
                case .task:
                    let speaker = item.speaker.flatMap { people[$0] != nil ? $0 : nil }
                    let isCommitment = speaker != nil && isFirstPerson(item.text)
                    if isCommitment, let speaker, let person = people[speaker] {
                        attributes["commitment"] = Attribute(.bool(true))
                        attributes["ownerPerson"] = Attribute(.reference(person))
                    }
                    id = try tasks.create(
                        item.text, owner: isCommitment ? speaker.map { Origin.user(id: $0) } : nil,
                        attributes: attributes, by: author
                    ).id
                    if isCommitment, let speaker, let person = people[speaker] {
                        try store.relate(Relationship(kind: .created, from: person, to: id, provenance: recorded))
                        commitments.append(id)
                    }
                case .question:
                    id = try store.create(ObjectRecord(type: .question, title: item.text, attributes: attributes, provenance: recorded)).id
                case .claim:
                    let claim = Claim(
                        statement: item.text, sources: [meeting], passages: [item.text], sourceClass: .community,
                        provenance: Provenance(origin: author, truth: .claimed, timestamp: date, method: "said in meeting by \(item.speaker ?? "unknown")")
                    )
                    try store.add(claim)
                    id = claim.id
                }
                try store.relate(Relationship(kind: .produced, from: meeting, to: id, provenance: recorded))
                created.append(id)
            }
            return Promotion(meeting: meeting, items: created, participants: people, commitments: commitments)
        }
    }

    /// Everyone who speaks in the transcript, in order of first appearance.
    public static func speakers(in transcript: String) -> [String] {
        var seen: Set<String> = []
        return transcript.split(separator: "\n").compactMap { split(String($0)).0 }.filter { seen.insert($0).inserted }
    }

    /// "I will …", "I'll …": the speaker is taking the work on.
    static func isFirstPerson(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("i will ") || lower.hasPrefix("i'll ") || lower.contains(" i'll ") || lower.contains(" i will ")
    }

    private static func split(_ line: String) -> (String?, String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":") {
            let head = trimmed[..<colon]
            let lowered = head.lowercased()
            let keywords = ["decision", "action", "todo", "task", "agreed"]
            if !keywords.contains(lowered), head.count <= 30, head.split(separator: " ").count <= 3, head.first?.isUppercase == true {
                return (String(head), trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return (nil, trimmed)
    }

    private static func strip(_ text: String) -> String {
        for prefix in ["decision:", "action:", "todo:", "task:", "agreed:"] where text.lowercased().hasPrefix(prefix) {
            return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// Stamps everything a promotion writes with the meeting's time.
private struct FixedClock: NexusClock {
    let date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date { date }
}
