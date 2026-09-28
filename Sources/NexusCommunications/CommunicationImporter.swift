import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusSearch

/// What one import did.
public struct CommunicationImport: Sendable, Hashable {
    /// The `document` object holding the file (its bytes are a blob).
    public var document: ObjectRecord
    public var threads: [ObjectID]
    public var messages: [ObjectID]
    /// Content keys (Message-IDs) already in the store, skipped.
    public var duplicates: [String]
    public var mentions: [Mention]
}

/// An object a message mentions by tag, serial or Nexus ID.
public struct Mention: Sendable, Hashable {
    public var message: ObjectID
    public var object: ObjectID
    /// The text that matched, e.g. "LT-101".
    public var evidence: String
    public var confidence: Double
}

/// Imports email from .eml (one RFC 5322 message) and .mbox files.
///
/// Apple doesn't let apps read Mail or Messages, so import is how mail gets
/// in: the person exports messages and imports the files (docs/COMMUNICATIONS.md).
///
/// The file is stored first, as a blob behind a `document` object. Every
/// thread, message and person the file yields is **recorded** truth whose
/// origin is `importer(source:)` naming that document, so each traces back
/// to the bytes it came from. Attachments become `document` objects of their
/// own. Links to what a message is about are **derived**: a tag or serial
/// that matches an object exactly (via `NameplateMatcher`), or a Nexus ID.
///
/// Re-importing a message (same Message-ID, or the same bytes when it has
/// none) adds nothing. Replies join their parent's thread by References /
/// In-Reply-To, else a thread with the same normalised subject.
public struct CommunicationImporter {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Imports one .eml message. `subjects` are objects the person says the
    /// message is about; its thread is linked to each.
    @discardableResult
    public func importEML(_ data: Data, named fileName: String, about subjects: [ObjectID] = [], by author: Origin) throws -> CommunicationImport {
        guard !data.isEmpty else { throw CommunicationError.empty(fileName) }
        return try importMessages([data], file: data, named: fileName, mediaType: "message/rfc822", format: "EML", about: subjects, by: author)
    }

    /// Imports every message in an mbox file.
    @discardableResult
    public func importMBox(_ data: Data, named fileName: String, about subjects: [ObjectID] = [], by author: Origin) throws -> CommunicationImport {
        let messages = MBox.messages(data)
        guard !messages.isEmpty else { throw CommunicationError.empty(fileName) }
        return try importMessages(messages, file: data, named: fileName, mediaType: "application/mbox", format: "mbox", about: subjects, by: author)
    }

    /// .mbox by extension or by a leading "From " line; anything else as .eml.
    @discardableResult
    public func importFile(_ data: Data, named fileName: String, about subjects: [ObjectID] = [], by author: Origin) throws -> CommunicationImport {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".mbox") || lower.hasSuffix(".mbx") || data.starts(with: Array("From ".utf8)) {
            return try importMBox(data, named: fileName, about: subjects, by: author)
        }
        return try importEML(data, named: fileName, about: subjects, by: author)
    }

    private func importMessages(
        _ raw: [Data], file: Data, named fileName: String, mediaType: String, format: String, about subjects: [ObjectID], by author: Origin
    ) throws -> CommunicationImport {
        try store.batch { store in
            let now = clock.now()
            let document = try storeDocument(file, named: fileName, mediaType: mediaType, format: format, by: author)
            let importer = Origin.importer(source: document.id)
            var index = try ThreadIndex(store: store)
            var people = PersonDirectory(store: store)
            var threads: [ObjectID] = []
            var messages: [ObjectID] = []
            var duplicates: [String] = []
            var mentions: [Mention] = []
            let linker = MentionLinker(store: store)
            var ownObjects: Set<ObjectID> = [document.id]

            for (position, data) in raw.enumerated() {
                let email = EmailMessage(data)
                let key = email.messageID ?? "sha256:" + ContentHash.sha256(data)
                if index.threadOfMessage[key] != nil {
                    duplicates.append(key)
                    continue
                }
                let locator = raw.count > 1 ? "\(format) message \(position + 1)" : format
                let recorded = Provenance(
                    origin: importer, truth: .recorded, timestamp: now, method: "\(locator), imported by \(author.commsLabel)", dependencies: [document.id]
                )

                // Thread: a known parent's, else one with the same subject, else a new one.
                let parents = ([email.inReplyTo].compactMap { $0 } + email.references.reversed())
                var thread = parents.lazy.compactMap { index.threadOfMessage[$0] }.first
                if thread == nil, !email.threadSubject.isEmpty { thread = index.threadOfSubject[email.threadSubject] }
                if thread == nil {
                    let title = email.subject.isEmpty ? "(no subject)" : email.subject
                    thread = try store.create(
                        ObjectRecord(
                            type: .thread, title: title,
                            attributes: [
                                CommsKey.channel: Attribute(.string(CommunicationChannel.email.rawValue)),
                                CommsKey.threadSubject: Attribute(.string(email.threadSubject)),
                            ],
                            provenance: recorded
                        )
                    ).id
                    if !email.threadSubject.isEmpty { index.threadOfSubject[email.threadSubject] = thread }
                }
                guard let thread else { continue }
                if !threads.contains(thread) { threads.append(thread) }
                ownObjects.insert(thread)

                var attributes: [String: Attribute] = [
                    CommsKey.channel: Attribute(.string(CommunicationChannel.email.rawValue)),
                    CommsKey.direction: Attribute(.string("incoming")),
                    CommsKey.contentKey: Attribute(.string(key)),
                    CommsKey.subject: Attribute(.string(email.subject)),
                    CommsKey.body: Attribute(.string(email.text)),
                    CommsKey.from: Attribute(.list(email.from.map { .string($0.description) })),
                    CommsKey.to: Attribute(.list(email.to.map { .string($0.description) })),
                    CommsKey.cc: Attribute(.list(email.cc.map { .string($0.description) })),
                    CommsKey.references: Attribute(.list(email.references.map { .string($0) })),
                ]
                if let messageID = email.messageID { attributes[CommsKey.messageID] = Attribute(.string(messageID)) }
                if let reply = email.inReplyTo { attributes[CommsKey.inReplyTo] = Attribute(.string(reply)) }
                if let date = email.date { attributes[CommsKey.sentAt] = Attribute(.date(date)) }
                if let html = email.html {
                    attributes[CommsKey.htmlBlob] = Attribute(.string(try store.putBlob(Data(html.utf8), mediaType: "text/html").sha256))
                }
                let message = try store.create(
                    ObjectRecord(
                        type: .message, title: email.subject.isEmpty ? "(no subject)" : email.subject, attributes: attributes, provenance: recorded
                    ))
                try store.relate(Relationship(kind: .inThread, from: message.id, to: thread, provenance: recorded))
                index.threadOfMessage[key] = thread
                messages.append(message.id)
                ownObjects.insert(message.id)

                for sender in email.from {
                    let person = try people.person(for: sender, provenance: recorded)
                    ownObjects.insert(person)
                    try store.relate(Relationship(kind: .sent, from: person, to: message.id, provenance: recorded))
                }
                for recipient in email.to + email.cc {
                    let person = try people.person(for: recipient, provenance: recorded)
                    ownObjects.insert(person)
                    try store.relate(Relationship(kind: .addressedTo, from: message.id, to: person, provenance: recorded))
                }
                for attachment in email.attachments {
                    let file = try storeDocument(
                        attachment.data, named: attachment.filename, mediaType: attachment.mediaType, format: "email attachment", by: importer
                    )
                    ownObjects.insert(file.id)
                    try store.relate(Relationship(kind: .attachedTo, from: file.id, to: message.id, provenance: recorded))
                }

                // Derived links to what the message mentions.
                let found = try linker.mentions(in: [email.subject, email.text], excluding: ownObjects)
                for mention in found {
                    let derived = Provenance(
                        origin: importer, truth: .derived, timestamp: now, method: "mentions \(mention.evidence)", confidence: mention.confidence,
                        dependencies: [message.id]
                    )
                    try store.relate(Relationship(kind: .about, from: message.id, to: mention.object, provenance: derived))
                    try relateOnce(thread, to: mention.object, provenance: derived, in: store)
                    mentions.append(Mention(message: message.id, object: mention.object, evidence: mention.evidence, confidence: mention.confidence))
                }
            }

            let stated = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "imported for this object")
            for subject in subjects {
                for thread in threads { try relateOnce(thread, to: subject, provenance: stated, in: store) }
            }
            try store.record(
                Event(
                    at: now, kind: .communicationImported, subjects: [document.id] + threads,
                    summary: "Imported \(messages.count) message(s) from \(fileName)",
                    payload: ["messages": .int(Int64(messages.count)), "duplicates": .int(Int64(duplicates.count)), "threads": .int(Int64(threads.count))],
                    provenance: Provenance(origin: author, truth: .recorded, timestamp: now, method: "\(format) import")
                ))
            return CommunicationImport(document: document, threads: threads, messages: messages, duplicates: duplicates, mentions: mentions)
        }
    }

    /// Stores bytes as a blob behind a `document` object, reusing the
    /// document when the same bytes were stored before.
    func storeDocument(_ data: Data, named fileName: String, mediaType: String, format: String, by author: Origin) throws -> ObjectRecord {
        let blob = try store.putBlob(data, mediaType: mediaType)
        if let existing = try store.objects(ofType: .document).first(where: { $0.string(CommsKey.blob) == blob.sha256 }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .document, title: fileName.isEmpty ? "Untitled" : fileName,
                attributes: [
                    CommsKey.blob: Attribute(.string(blob.sha256)),
                    CommsKey.mediaType: Attribute(.string(mediaType)),
                    CommsKey.format: Attribute(.string(format)),
                    CommsKey.byteCount: Attribute(.int(Int64(blob.byteCount))),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "\(format) import")
            ))
    }
}

/// Adds `thread → about → object` unless it is already there.
func relateOnce(_ from: ObjectID, to: ObjectID, provenance: Provenance, in store: NexusStore) throws {
    guard from != to, try !store.relationships(from: from, kind: .about).contains(where: { $0.to == to && $0.validTo == nil }) else { return }
    try store.relate(Relationship(kind: .about, from: from, to: to, provenance: provenance))
}

/// Messages and threads already stored, by content key and by subject.
struct ThreadIndex {
    var threadOfMessage: [String: ObjectID] = [:]
    var threadOfSubject: [String: ObjectID] = [:]

    init(store: NexusStore) throws {
        for thread in try store.objects(ofType: .thread) where thread.lifecycle != .deleted {
            if let subject = thread.string(CommsKey.threadSubject), !subject.isEmpty, threadOfSubject[subject] == nil {
                threadOfSubject[subject] = thread.id
            }
        }
        for message in try store.objects(ofType: .message) where message.lifecycle != .deleted {
            guard let thread = try store.relationships(from: message.id, kind: .inThread).first?.to else { continue }
            if let key = message.string(CommsKey.contentKey) { threadOfMessage[key] = thread }
            if let id = message.string(CommsKey.messageID) { threadOfMessage[id] = thread }
        }
    }
}

/// Person objects by email address or phone number, reusing an existing
/// person with that address, or else with the same name and no address.
struct PersonDirectory {
    let store: NexusStore
    private var cache: [String: ObjectID] = [:]

    init(store: NexusStore) { self.store = store }

    mutating func person(for address: EmailAddress, provenance: Provenance) throws -> ObjectID {
        try person(key: CommsKey.email, value: address.address, name: address.name, provenance: provenance)
    }

    mutating func person(phone: String, provenance: Provenance) throws -> ObjectID {
        try person(key: CommsKey.phone, value: phone, name: nil, provenance: provenance)
    }

    private mutating func person(key: String, value: String, name: String?, provenance: Provenance) throws -> ObjectID {
        let cacheKey = "\(key):\(value)"
        if let known = cache[cacheKey] { return known }
        let people = try store.objects(ofType: .person).filter { $0.lifecycle != .deleted }
        if let match = people.first(where: { $0.string(key)?.lowercased() == value }) {
            cache[cacheKey] = match.id
            return match.id
        }
        if let name, let match = people.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.string(key) == nil }) {
            try store.update(match.id, by: provenance.origin, instruction: "Added \(key) from a message") {
                $0.attributes[key] = Attribute(.string(value), provenance: provenance)
            }
            cache[cacheKey] = match.id
            return match.id
        }
        let created = try store.create(
            ObjectRecord(
                type: .person, title: name ?? value, attributes: [key: Attribute(.string(value))], provenance: provenance
            ))
        cache[cacheKey] = created.id
        return created.id
    }
}

/// Finds objects a message mentions: Nexus object IDs (bare or as
/// `nexus://object/<id>`), and instrument tags or serials that match an
/// object's `tag`, `serial` or title exactly, using `NameplateMatcher`.
/// Loose full-text hits are not links.
public struct MentionLinker {
    public let store: NexusStore
    let matcher: NameplateMatcher

    public init(store: NexusStore) {
        self.store = store
        matcher = NameplateMatcher(engine: SearchEngine(store: store, graph: ObjectGraph(store: store)))
    }

    /// Objects mentioned in `texts`, best first, leaving out `excluded` and
    /// other communications (threads, messages, people).
    public func mentions(in texts: [String], excluding excluded: Set<ObjectID> = []) throws -> [(object: ObjectID, evidence: String, confidence: Double)] {
        var found: [(object: ObjectID, evidence: String, confidence: Double)] = []
        var seen = excluded
        let skipped: Set<ObjectType> = [.thread, .message, .person]
        for text in texts {
            for token in Self.objectIDs(in: text) where !seen.contains(token) {
                guard let record = try store.object(token), record.lifecycle != .deleted, !skipped.contains(record.type) else { continue }
                seen.insert(token)
                found.append((token, token.description, 1.0))
            }
        }
        let lines = texts.flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
        for match in try matcher.match(lines: lines, limit: 10) where match.confidence >= 0.9 && !seen.contains(match.object) {
            guard let record = try store.object(match.object), !skipped.contains(record.type) else { continue }
            seen.insert(match.object)
            found.append((match.object, match.evidence, match.confidence))
        }
        return found
    }

    /// UUID-shaped tokens that parse as object IDs.
    static func objectIDs(in text: String) -> [ObjectID] {
        let hex = Set("0123456789abcdefABCDEF")
        var ids: [ObjectID] = []
        let characters = Array(text)
        var index = 0
        while index + 36 <= characters.count {
            let candidate = characters[index..<index + 36]
            let shaped = candidate.enumerated().allSatisfy { offset, character in
                [8, 13, 18, 23].contains(offset) ? character == "-" : hex.contains(character)
            }
            if shaped, let id = ObjectID(String(candidate)) {
                ids.append(id)
                index += 36
            } else {
                index += 1
            }
        }
        return ids
    }
}

extension Origin {
    var commsLabel: String {
        switch self {
        case .user(let id): "user \(id)"
        case .agent(let id, _): "agent \(id)"
        case .importer(let source): "importer \(source)"
        case .simulation: "simulation"
        case .instrument(let id): "instrument \(id)"
        case .model(let ref): ref.modelID
        case .system: "system"
        }
    }
}
