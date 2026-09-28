import Foundation
import NexusCore
import NexusModel

// Contact and relationship terms on NexusModel's open vocabularies. People
// and organisations are the shared `person` and `organization` types, so the
// same person can attend a meeting, own a task and appear here. Interactions
// are events on the one timeline; follow-ups are `task` objects. Last contact
// and cadence are derived on read. Nothing here keeps state of its own.

extension RelationKind {
    /// Person → the organization they work at.
    public static let worksAt: RelationKind = "worksAt"
    /// Task → the person it is a follow-up with.
    public static let followUpFor: RelationKind = "followUpFor"
}

extension EventKind {
    /// A call, email, meeting or message with one or more people.
    /// Payload: `channel`, optional `note`.
    public static let interaction: EventKind = "interaction"
    /// A contacts file or address book was imported. Payload: counts.
    public static let contactsImported: EventKind = "contactsImported"
}

/// Attribute and payload keys used on people and interactions.
public enum ContactKey {
    public static let givenName = "givenName"
    public static let familyName = "familyName"
    /// List of addresses.
    public static let emails = "emails"
    /// List of numbers.
    public static let phones = "phones"
    public static let jobTitle = "jobTitle"
    public static let department = "department"
    /// "1985-04-12", or "--04-12" when the year is unknown.
    public static let birthday = "birthday"
    public static let note = "note"
    /// The UID of the card a person was imported from, for re-import.
    public static let cardUID = "cardUID"
    public static let categories = "categories"
    /// How often, in days, the person wants to be in touch with this contact.
    public static let cadenceDays = "cadenceDays"
    public static let channel = "channel"
    public static let blob = "blob"
    public static let mediaType = "mediaType"
    public static let format = "format"
}

/// How an interaction happened.
public enum InteractionChannel: String, Codable, Sendable, CaseIterable {
    case call
    case email
    case meeting
    case message
    case video
    case other
}

public enum ContactsError: Error, Equatable, Sendable {
    case notFound(ObjectID, expected: ObjectType)
    case malformedVCard(line: Int, reason: String)
    case noPeople
    case invalidCadence(Int)
}

extension Origin {
    /// The truth class of a value this author enters: a person's entry is an
    /// observation, an importer's a record, an agent's an interpretation.
    var entryTruth: TruthClass {
        if case .user = self { return .observed }
        return defaultTruth
    }
}

extension ObjectRecord {
    func string(_ key: String) -> String? {
        if case .string(let text)? = attributes[key]?.value { return text }
        return nil
    }

    func strings(_ key: String) -> [String] {
        guard case .list(let values)? = attributes[key]?.value else { return [] }
        return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    func int(_ key: String) -> Int? {
        if case .int(let number)? = attributes[key]?.value { return Int(number) }
        return nil
    }
}

enum ContactsCalendar {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}

/// Lower-cased and trimmed, for matching addresses.
func normalizedEmail(_ email: String) -> String { email.trimmingCharacters(in: .whitespaces).lowercased() }

/// Digits only (and a leading +), for matching numbers.
func normalizedPhone(_ phone: String) -> String {
    let trimmed = phone.trimmingCharacters(in: .whitespaces)
    return (trimmed.hasPrefix("+") ? "+" : "") + trimmed.filter(\.isNumber)
}
