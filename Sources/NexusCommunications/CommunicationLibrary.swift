import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// One message, read for display.
public struct CommunicationMessage: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord
    public var id: ObjectID { record.id }
    public var channel: CommunicationChannel { record.string(CommsKey.channel).flatMap(CommunicationChannel.init) ?? .email }
    public var isOutgoing: Bool { record.string(CommsKey.direction) == "outgoing" }
    public var subject: String { record.string(CommsKey.subject) ?? record.title }
    public var from: [String] { record.strings(CommsKey.from) }
    public var to: [String] { record.strings(CommsKey.to) }
    public var cc: [String] { record.strings(CommsKey.cc) }
    public var sentAt: Date? { record.date(CommsKey.sentAt) }
    public var body: String { record.string(CommsKey.body) ?? "" }
    public var htmlBlob: String? { record.string(CommsKey.htmlBlob) }
    /// Attachment `document` objects.
    public var attachments: [ObjectRecord]

    public init(record: ObjectRecord, attachments: [ObjectRecord] = []) {
        self.record = record
        self.attachments = attachments
    }
}

/// A thread with what a list row needs.
public struct CommunicationThread: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord
    public var id: ObjectID { record.id }
    public var messageCount: Int
    public var lastMessageAt: Date?
    /// Person objects who sent or received its messages.
    public var participants: [ObjectID]
}

/// Reads threads and messages from the store. Everything is computed from
/// objects and relationships; nothing is cached here.
public struct CommunicationLibrary {
    public let store: NexusStore

    public init(store: NexusStore) {
        self.store = store
    }

    /// Threads about `object`: linked to it directly, or holding a message
    /// that is. Most recent first.
    public func threads(about object: ObjectID) throws -> [CommunicationThread] {
        var ids: [ObjectID] = []
        for edge in try store.relationships(to: object, kind: .about) where edge.validTo == nil {
            guard let source = try store.object(edge.from), source.lifecycle != .deleted else { continue }
            switch source.type {
            case .thread: ids.append(source.id)
            case .message: ids += try store.relationships(from: source.id, kind: .inThread).map(\.to)
            default: continue
            }
        }
        var seen: Set<ObjectID> = []
        return try ids.filter { seen.insert($0).inserted }.compactMap(thread).sorted {
            ($0.lastMessageAt ?? .distantPast, $0.id) > ($1.lastMessageAt ?? .distantPast, $1.id)
        }
    }

    /// Every thread, most recent first.
    public func allThreads() throws -> [CommunicationThread] {
        try store.objects(ofType: .thread).filter { $0.lifecycle != .deleted }.compactMap { try thread($0.id) }.sorted {
            ($0.lastMessageAt ?? .distantPast, $0.id) > ($1.lastMessageAt ?? .distantPast, $1.id)
        }
    }

    public func thread(_ id: ObjectID) throws -> CommunicationThread? {
        guard let record = try store.object(id), record.type == .thread else { return nil }
        let messages = try self.messages(in: id)
        var participants: [ObjectID] = []
        for message in messages {
            participants += try store.relationships(to: message.id, kind: .sent).map(\.from)
            participants += try store.relationships(from: message.id, kind: .addressedTo).map(\.to)
        }
        var seen: Set<ObjectID> = []
        return CommunicationThread(
            record: record, messageCount: messages.count, lastMessageAt: messages.compactMap(\.sentAt).max() ?? messages.last?.record.createdAt,
            participants: participants.filter { seen.insert($0).inserted }
        )
    }

    /// A thread's messages, oldest first.
    public func messages(in thread: ObjectID) throws -> [CommunicationMessage] {
        let ids = try store.relationships(to: thread, kind: .inThread).map(\.from)
        return try store.objects(ids).filter { $0.lifecycle != .deleted }.map { record in
            let files = try store.objects(store.relationships(to: record.id, kind: .attachedTo).map(\.from))
            return CommunicationMessage(record: record, attachments: files)
        }
        .sorted { ($0.sentAt ?? $0.record.createdAt, $0.id) < ($1.sentAt ?? $1.record.createdAt, $1.id) }
    }

    /// Objects a thread is about (not people or other communications).
    public func subjects(of thread: ObjectID) throws -> [ObjectID] {
        var ids = try store.relationships(from: thread, kind: .about).filter { $0.validTo == nil }.map(\.to)
        for message in try messages(in: thread) {
            ids += try store.relationships(from: message.id, kind: .about).filter { $0.validTo == nil }.map(\.to)
        }
        var seen: Set<ObjectID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
