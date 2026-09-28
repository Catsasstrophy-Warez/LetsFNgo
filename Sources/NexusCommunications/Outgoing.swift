import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A message the person is composing, prefilled from an object.
public struct OutgoingCommunication: Sendable, Hashable {
    public var channel: CommunicationChannel
    /// Email addresses, or phone numbers for text messages.
    public var recipients: [String]
    public var subject: String
    public var body: String
    /// Objects the message is about; the sent message is linked to each.
    public var about: [ObjectID]

    public init(channel: CommunicationChannel, recipients: [String] = [], subject: String = "", body: String = "", about: [ObjectID] = []) {
        self.channel = channel
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.about = about
    }
}

/// Prefills outgoing email and text messages from objects, and records a
/// message once the system reports it sent.
///
/// Nexus hands the message to the system composer (Mail's compose sheet,
/// Messages' compose sheet, the macOS sharing service). A message is
/// recorded only when that composer reports it sent: never on "cancelled",
/// "saved as draft" or "failed", and never for a `mailto:` hand-off, which
/// reports nothing back.
public enum CommunicationComposer {
    /// Attribute keys left out of a prefilled summary: long or internal.
    static let skippedKeys: Set<String> = ["transcript", "body", "notes", "embedding", CommsKey.blob, CommsKey.htmlBlob]

    /// A draft about `subject`: its title as the subject line; the body of
    /// a report (or the newest report an investigation produced), else a
    /// short summary of the object; and the email addresses or phone numbers
    /// of people related to it.
    public static func draft(about subjectID: ObjectID, channel: CommunicationChannel, in store: NexusStore) throws -> OutgoingCommunication {
        guard let subject = try store.object(subjectID) else { throw CommunicationError.notFound(subjectID) }
        var lines: [String] = []
        if let body = try reportBody(for: subject, in: store) {
            lines.append(body)
        } else {
            lines.append("\(subject.title) (\(subject.type))")
            if let notes = subject.string("notes"), !notes.isEmpty { lines += ["", notes] }
            let details = subject.attributes.keys.sorted().filter { !skippedKeys.contains($0) }.compactMap { key -> String? in
                guard let text = describe(subject.attributes[key]!.value) else { return nil }
                return "- \(key): \(text)"
            }
            if !details.isEmpty { lines += [""] + details.prefix(12) }
            let related = try (store.relationships(from: subjectID) + store.relationships(to: subjectID))
                .filter { $0.validTo == nil }
                .compactMap { try store.object($0.from == subjectID ? $0.to : $0.from) }
                .filter { ![.person, .thread, .message].contains($0.type) && $0.lifecycle != .deleted }
            if !related.isEmpty {
                lines += ["", "Related:"] + related.prefix(8).map { "- \($0.title) (\($0.type))" }
            }
        }
        lines += ["", "Nexus: nexus://object/\(subjectID)"]
        var body = lines.joined(separator: "\n")
        if channel == .textMessage, body.count > 600 { body = String(body.prefix(597)) + "…" }
        let recipients = try people(relatedTo: subjectID, in: store).compactMap { person in
            channel == .email ? person.string(CommsKey.email) : person.string(CommsKey.phone)
        }
        return OutgoingCommunication(
            channel: channel, recipients: Array(Set(recipients)).sorted(), subject: subject.title, body: body, about: [subjectID]
        )
    }

    /// A `mailto:` URL (RFC 6068) for platforms without a compose sheet.
    public static func mailtoURL(_ draft: OutgoingCommunication) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var allowedAddress = allowed
        allowedAddress.insert(charactersIn: "@+")
        let to = draft.recipients.map { $0.addingPercentEncoding(withAllowedCharacters: allowedAddress) ?? "" }.joined(separator: ",")
        let body = draft.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return URL(string: "mailto:\(to)?subject=\(encode(draft.subject))&body=\(encode(body))")
    }

    /// Records a message the system reported sent: an outgoing `message` in
    /// a thread (a new one unless `thread` is given), linked to what it is
    /// about and to the people it went to, plus a `communicationSent` event.
    /// Recorded truth by the person; `method` names the composer that
    /// reported it, e.g. "MFMailComposeViewController reported sent".
    @discardableResult
    public static func recordSent(
        _ draft: OutgoingCommunication, method: String, thread existing: ObjectID? = nil, in store: NexusStore, by author: Origin, at date: Date
    ) throws -> (thread: ObjectID, message: ObjectID) {
        try store.batch { store in
            let recorded = Provenance(origin: author, truth: .recorded, timestamp: date, method: method)
            let title = draft.subject.isEmpty ? (draft.channel == .email ? "(no subject)" : "Message") : draft.subject
            let thread =
                try existing
                ?? store.create(
                    ObjectRecord(
                        type: .thread, title: title,
                        attributes: [
                            CommsKey.channel: Attribute(.string(draft.channel.rawValue)),
                            CommsKey.threadSubject: Attribute(.string(EmailMessage.normalizedSubject(draft.subject))),
                        ],
                        provenance: recorded
                    )
                ).id
            let message = try store.create(
                ObjectRecord(
                    type: .message, title: title,
                    attributes: [
                        CommsKey.channel: Attribute(.string(draft.channel.rawValue)),
                        CommsKey.direction: Attribute(.string("outgoing")),
                        CommsKey.subject: Attribute(.string(draft.subject)),
                        CommsKey.body: Attribute(.string(draft.body)),
                        CommsKey.to: Attribute(.list(draft.recipients.map { .string($0) })),
                        CommsKey.sentAt: Attribute(.date(date)),
                    ],
                    provenance: recorded
                ))
            try store.relate(Relationship(kind: .inThread, from: message.id, to: thread, provenance: recorded))
            var people = PersonDirectory(store: store)
            for recipient in draft.recipients {
                let person =
                    draft.channel == .email
                    ? try people.person(for: EmailAddress.list(recipient).first ?? EmailAddress(address: recipient), provenance: recorded)
                    : try people.person(phone: recipient, provenance: recorded)
                try store.relate(Relationship(kind: .addressedTo, from: message.id, to: person, provenance: recorded))
            }
            for subject in draft.about {
                try relateOnce(thread, to: subject, provenance: recorded, in: store)
                try store.relate(Relationship(kind: .about, from: message.id, to: subject, provenance: recorded))
            }
            let channel = draft.channel == .email ? "Email" : "Message"
            try store.record(
                Event(
                    at: date, kind: .communicationSent, subjects: [message.id, thread] + draft.about,
                    summary: "\(channel) sent: \(title)",
                    payload: ["channel": .string(draft.channel.rawValue), "recipients": .list(draft.recipients.map { .string($0) })],
                    provenance: recorded
                ))
            return (thread, message.id)
        }
    }

    /// People linked to the object in either direction.
    static func people(relatedTo id: ObjectID, in store: NexusStore) throws -> [ObjectRecord] {
        let edges = try store.relationships(from: id) + store.relationships(to: id)
        return try store.objects(edges.filter { $0.validTo == nil }.map { $0.from == id ? $0.to : $0.from }).filter { $0.type == .person }
    }

    static func reportBody(for subject: ObjectRecord, in store: NexusStore) throws -> String? {
        if let body = subject.string("body"), !body.isEmpty { return body }
        let produced = try store.objects(store.relationships(from: subject.id, kind: .produced).map(\.to))
        return produced.filter { $0.type == "report" && $0.lifecycle != .deleted }.max { $0.createdAt < $1.createdAt }?.string("body")
    }

    static func describe(_ value: Value) -> String? {
        switch value {
        case .string(let text): text.count <= 200 && !text.isEmpty ? text : nil
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .bool(let flag): flag ? "yes" : "no"
        case .date(let date): RFC5322Date.format(date)
        case .quantity(let quantity): "\(quantity.value) \(quantity.unit)"
        default: nil
        }
    }
}
