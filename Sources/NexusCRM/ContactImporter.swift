import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// What one contacts import did.
public struct ContactImportResult: Sendable, Hashable {
    /// The `document` (a .vcf file) or `source` (an address book) the contacts came from.
    public var source: ObjectRecord
    public var created: [Contact]
    /// Existing people who gained an address, a number or a missing field.
    public var merged: [Contact]
    public var unchanged: Int
}

/// Imports contacts into `person` objects, merging with people already in
/// the store (by card UID, then any shared email, then exact name).
///
/// Imported values are **recorded** truth from `importer(source:)`. A merge
/// only adds: new addresses and numbers join the lists, and a field is
/// filled only when the person has none, so nothing a person entered
/// (observed) is overwritten by a file.
public struct ContactImporter: Sendable {
    public let store: NexusStore
    public let contacts: ContactsRuntime
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.contacts = ContactsRuntime(store: store, clock: clock)
        self.clock = clock
    }

    /// Imports every card of a .vcf file (vCard 2.1, 3.0 or 4.0).
    @discardableResult
    public func importVCards(_ data: Data, named fileName: String, by author: Origin) throws -> ContactImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ContactsError.malformedVCard(line: 0, reason: "not text")
        }
        let cards = try VCard.parse(text)
        return try store.batch { _ in
            let document = try storeDocument(data, named: fileName, by: author)
            return try importContacts(cards, from: document, format: "vCard", by: author)
        }
    }

    /// The `source` object for an address book such as Apple Contacts,
    /// created the first time it is imported from.
    public func addressBook(named name: String, by author: Origin) throws -> ObjectRecord {
        if let existing = try store.objects(ofType: .source).first(where: { $0.title == name && $0.string(ContactKey.format) == "address book" }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .source, title: name, attributes: [ContactKey.format: Attribute(.string("address book"))],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "address book import")
            ))
    }

    /// Imports cards read from `source` (a document or an address book).
    @discardableResult
    public func importContacts(_ cards: [ContactCard], from source: ObjectRecord, format: String, by author: Origin) throws -> ContactImportResult {
        try store.batch { store in
            let provenance = Provenance(
                origin: .importer(source: source.id), truth: .recorded, timestamp: clock.now(), method: "\(format) import", dependencies: [source.id]
            )
            var created: [Contact] = []
            var merged: [Contact] = []
            var unchanged = 0
            for card in cards {
                if let existing = try match(card) {
                    if let updated = try merge(card, into: existing, provenance: provenance) {
                        merged.append(updated)
                    } else {
                        unchanged += 1
                    }
                } else {
                    created.append(try create(card, provenance: provenance))
                }
            }
            try store.record(
                Event(
                    at: clock.now(), kind: .contactsImported, subjects: [source.id],
                    summary: "Imported \(created.count) contacts (\(merged.count) merged) from \(source.title)",
                    payload: [
                        "created": .int(Int64(created.count)), "merged": .int(Int64(merged.count)), "unchanged": .int(Int64(unchanged)),
                        ContactKey.format: .string(format),
                    ],
                    provenance: Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "\(format) import")
                ))
            return ContactImportResult(source: source, created: created, merged: merged, unchanged: unchanged)
        }
    }

    // MARK: Matching and merging

    func match(_ card: ContactCard) throws -> Contact? {
        let people = try contacts.contacts()
        if let uid = card.uid, let person = people.first(where: { $0.record.string(ContactKey.cardUID) == uid }) { return person }
        let emails = Set(card.emails.map(normalizedEmail))
        if !emails.isEmpty, let person = people.first(where: { !emails.isDisjoint(with: $0.emails.map(normalizedEmail)) }) { return person }
        return people.first { $0.name.caseInsensitiveCompare(card.formattedName) == .orderedSame }
    }

    func attributes(of card: ContactCard) -> [String: Attribute] {
        var attributes: [String: Attribute] = [:]
        let strings: [(String, String?)] = [
            (ContactKey.givenName, card.givenName), (ContactKey.familyName, card.familyName), (ContactKey.jobTitle, card.title),
            (ContactKey.department, card.department), (ContactKey.birthday, card.birthday), (ContactKey.note, card.note),
            (ContactKey.cardUID, card.uid),
        ]
        for (key, value) in strings {
            if let value, !value.isEmpty { attributes[key] = Attribute(.string(value)) }
        }
        if !card.emails.isEmpty { attributes[ContactKey.emails] = Attribute(.list(card.emails.map(Value.string))) }
        if !card.phones.isEmpty { attributes[ContactKey.phones] = Attribute(.list(card.phones.map(Value.string))) }
        if !card.categories.isEmpty { attributes[ContactKey.categories] = Attribute(.list(card.categories.map(Value.string))) }
        return attributes
    }

    func create(_ card: ContactCard, provenance: Provenance) throws -> Contact {
        let record = try store.create(ObjectRecord(type: .person, title: card.formattedName, attributes: attributes(of: card), provenance: provenance))
        if let organization = card.organization {
            try contacts.link(record.id, worksAt: try contacts.organization(named: organization, provenance: provenance).id, provenance: provenance)
        }
        return Contact(record: record)
    }

    /// Adds what the card has and the person lacks. Nil when nothing changed.
    func merge(_ card: ContactCard, into contact: Contact, provenance: Provenance) throws -> Contact? {
        let incoming = attributes(of: card)
        var changes: [String: Attribute] = [:]
        for (key, attribute) in incoming {
            switch (key, attribute.value, contact.record.attributes[key]?.value) {
            case (ContactKey.emails, .list(let values), .list(let current)?), (ContactKey.phones, .list(let values), .list(let current)?),
                (ContactKey.categories, .list(let values), .list(let current)?):
                func normalize(_ text: String) -> String {
                    switch key {
                    case ContactKey.emails: normalizedEmail(text)
                    case ContactKey.phones: normalizedPhone(text)
                    default: text.lowercased()
                    }
                }
                let known = Set(current.compactMap { if case .string(let text) = $0 { normalize(text) } else { nil } })
                let added = values.filter { if case .string(let text) = $0 { !known.contains(normalize(text)) } else { false } }
                if !added.isEmpty { changes[key] = Attribute(.list(current + added), provenance: provenance) }
            case (_, _, nil):
                changes[key] = Attribute(attribute.value, provenance: provenance)
            default:
                continue
            }
        }
        let organization = try card.organization.map { try contacts.organization(named: $0, provenance: provenance) }
        let newEmployer = try organization.map { org in try !contacts.organizations(of: contact.id).contains { $0.id == org.id } } ?? false
        guard !changes.isEmpty || newEmployer else { return nil }
        if let organization, newEmployer { try contacts.link(contact.id, worksAt: organization.id, provenance: provenance) }
        guard !changes.isEmpty else { return try contacts.contact(contact.id) }
        let record = try store.update(contact.id, by: provenance.origin, instruction: "Merged from \(provenance.method ?? "import")") {
            for (key, attribute) in changes { $0.attributes[key] = attribute }
        }
        return Contact(record: record)
    }

    /// Stores the file's bytes as a blob and returns its document object,
    /// reusing the document when the same bytes were imported before.
    func storeDocument(_ data: Data, named fileName: String, by author: Origin) throws -> ObjectRecord {
        let blob = try store.putBlob(data, mediaType: "text/vcard")
        if let existing = try store.objects(ofType: .document).first(where: { $0.string(ContactKey.blob) == blob.sha256 }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .document, title: fileName,
                attributes: [
                    ContactKey.blob: Attribute(.string(blob.sha256)),
                    ContactKey.mediaType: Attribute(.string("text/vcard")),
                    ContactKey.format: Attribute(.string("vCard")),
                    "byteCount": Attribute(.int(Int64(blob.byteCount))),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "vCard import")
            ))
    }
}
