import Foundation
import NexusCore
import NexusModel
import NexusPersistence

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

    /// Stores the meeting and its promoted items. Decisions, tasks and
    /// questions are records of what was said (recorded, by the note's
    /// author); statements of fact are claims attributed to the speaker, never
    /// facts. Everything links back to the meeting.
    @discardableResult
    public static func promote(
        transcript: String,
        title: String,
        in store: NexusStore,
        by author: Origin,
        at date: Date,
        about subjects: [ObjectID] = []
    ) throws -> (meeting: ObjectID, items: [ObjectID]) {
        try store.batch { store in
            let recorded = Provenance(origin: author, truth: .recorded, timestamp: date, method: "meeting notes")
            let meeting = try store.create(ObjectRecord(
                type: .meeting, title: title, attributes: ["transcript": Attribute(.string(transcript))], provenance: recorded
            )).id
            for subject in subjects {
                try store.relate(Relationship(kind: .dependsOn, from: meeting, to: subject, provenance: recorded))
            }
            var created: [ObjectID] = []
            for item in extract(from: transcript) {
                let id: ObjectID
                var attributes: [String: Attribute] = ["line": Attribute(.int(Int64(item.line)))]
                if let speaker = item.speaker { attributes["speaker"] = Attribute(.string(speaker)) }
                switch item.kind {
                case .decision:
                    id = try store.create(ObjectRecord(type: .decision, title: item.text, attributes: attributes, provenance: recorded)).id
                case .task:
                    attributes["status"] = Attribute(.string("open"))
                    id = try store.create(ObjectRecord(type: .task, title: item.text, attributes: attributes, provenance: recorded)).id
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
            return (meeting, created)
        }
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
