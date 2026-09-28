import Foundation
import NexusCore
import NexusModel

// Communications on NexusModel's open vocabularies. Threads, messages and
// the people in them are ordinary objects in the shared store; imported
// files are `document` objects whose bytes are a blob, and so are
// attachments. Nothing here keeps state of its own.

extension ObjectType {
    /// A conversation: messages that reply to each other.
    public static let thread: ObjectType = "thread"
    /// One email or text message.
    public static let message: ObjectType = "message"
}

extension RelationKind {
    /// Message → the thread it belongs to.
    public static let inThread: RelationKind = "inThread"
    /// Person → a message they sent.
    public static let sent: RelationKind = "sent"
    /// Message → a person it was sent to (To or Cc).
    public static let addressedTo: RelationKind = "addressedTo"
    /// Thread or message → an object it is about.
    public static let about: RelationKind = "about"
    /// Document → the message that carried it.
    public static let attachedTo: RelationKind = "attachedTo"
}

extension EventKind {
    /// An .eml or .mbox file was imported. Payload: counts.
    public static let communicationImported: EventKind = "communicationImported"
    /// The system reported that a message the person composed in Nexus was sent.
    public static let communicationSent: EventKind = "communicationSent"
}

/// Attribute keys on threads, messages, people and documents.
public enum CommsKey {
    public static let channel = "channel"
    /// "incoming" (imported) or "outgoing" (sent from Nexus).
    public static let direction = "direction"
    public static let messageID = "messageID"
    public static let inReplyTo = "inReplyTo"
    public static let references = "references"
    public static let subject = "subject"
    /// A thread's normalised subject, for grouping replies without headers.
    public static let threadSubject = "threadSubject"
    public static let from = "from"
    public static let to = "to"
    public static let cc = "cc"
    public static let sentAt = "sentAt"
    public static let body = "body"
    /// SHA-256 of the HTML body's blob, when the message had one.
    public static let htmlBlob = "htmlBlob"
    /// Dedup key: the Message-ID, or a hash of the message when it has none.
    public static let contentKey = "contentKey"
    public static let lastMessageAt = "lastMessageAt"
    public static let messageCount = "messageCount"
    /// On a person.
    public static let email = "email"
    public static let phone = "phone"
    public static let blob = "blob"
    public static let mediaType = "mediaType"
    public static let format = "format"
    public static let byteCount = "byteCount"
}

public enum CommunicationChannel: String, Codable, Sendable, CaseIterable {
    case email
    /// SMS or iMessage.
    case textMessage
}

public enum CommunicationError: Error, Equatable, Sendable {
    case notFound(ObjectID)
    /// The file held no message.
    case empty(String)
    /// No recipient to address.
    case noRecipients
}

extension ObjectRecord {
    func string(_ key: String) -> String? {
        if case .string(let text)? = attributes[key]?.value { return text }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let date)? = attributes[key]?.value { return date }
        return nil
    }

    func strings(_ key: String) -> [String] {
        guard case .list(let values)? = attributes[key]?.value else { return [] }
        return values.compactMap {
            if case .string(let text) = $0 { return text }
            return nil
        }
    }
}
