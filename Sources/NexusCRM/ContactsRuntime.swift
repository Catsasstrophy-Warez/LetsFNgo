import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks

/// A typed view of a person object. The canonical state stays in the store.
public struct Contact: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var name: String { record.title }
    public var emails: [String] { record.strings(ContactKey.emails) }
    public var phones: [String] { record.strings(ContactKey.phones) }
    public var jobTitle: String? { record.string(ContactKey.jobTitle) }
    public var birthday: String? { record.string(ContactKey.birthday) }
    /// The person's own cadence, in days, when they set one.
    public var cadenceDays: Int? { record.int(ContactKey.cadenceDays) }
}

/// Where a relationship stands on a date. Derived; never stored.
public struct ContactStanding: Sendable, Hashable {
    public var contact: Contact
    /// The latest recorded or observed interaction.
    public var lastContacted: Date?
    public var daysSince: Int?
    /// The contact's own cadence, or the default.
    public var cadenceDays: Int
    /// Past the cadence, or never contacted despite a cadence the person set.
    public var isOverdue: Bool
    /// Days past the cadence (0 when not overdue; the full cadence when never contacted).
    public var daysOverdue: Int
    public var truth: TruthClass { .derived }
}

/// People, organisations, interactions and follow-ups over the shared store.
///
/// Last contact counts only interactions that are recorded (imported) or
/// observed (a person logged them). An interaction an agent inferred is an
/// agent interpretation: it is kept on the timeline but never resets a cadence.
public struct ContactsRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    /// "Haven't talked in 90 days."
    public static let defaultCadenceDays = 90

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    func provenance(_ author: Origin, method: String? = nil) -> Provenance {
        Provenance(origin: author, truth: author.entryTruth, timestamp: clock.now(), method: method)
    }

    // MARK: People and organisations

    @discardableResult
    public func addPerson(_ name: String, emails: [String] = [], phones: [String] = [], organization: String? = nil, by author: Origin) throws -> Contact {
        try store.batch { store in
            let stamp = provenance(author, method: "entered")
            var attributes: [String: Attribute] = [:]
            if !emails.isEmpty { attributes[ContactKey.emails] = Attribute(.list(emails.map(Value.string))) }
            if !phones.isEmpty { attributes[ContactKey.phones] = Attribute(.list(phones.map(Value.string))) }
            let record = try store.create(ObjectRecord(type: .person, title: name, attributes: attributes, provenance: stamp))
            if let organization, !organization.isEmpty {
                try link(record.id, worksAt: try self.organization(named: organization, provenance: stamp).id, provenance: stamp)
            }
            return Contact(record: record)
        }
    }

    public func contact(_ id: ObjectID) throws -> Contact {
        guard let record = try store.object(id), record.type == .person else { throw ContactsError.notFound(id, expected: .person) }
        return Contact(record: record)
    }

    /// Every live person in the store, whoever created them, by name.
    public func contacts() throws -> [Contact] {
        try store.objects(ofType: .person).filter { $0.lifecycle != .deleted }.map(Contact.init).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The organization with this name, created when there is none.
    @discardableResult
    public func organization(named name: String, provenance: Provenance) throws -> ObjectRecord {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let existing = try store.objects(ofType: .organization).first(where: {
            $0.lifecycle != .deleted && $0.title.caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return existing
        }
        return try store.create(ObjectRecord(type: .organization, title: wanted, provenance: provenance))
    }

    func link(_ person: ObjectID, worksAt organization: ObjectID, provenance: Provenance) throws {
        let current = try store.relationships(from: person, kind: .worksAt).filter { $0.validTo == nil }
        guard !current.contains(where: { $0.to == organization }) else { return }
        try store.relate(Relationship(kind: .worksAt, from: person, to: organization, provenance: provenance))
    }

    /// Organisations the person currently works at.
    public func organizations(of person: ObjectID) throws -> [ObjectRecord] {
        try store.objects(try store.relationships(from: person, kind: .worksAt).filter { $0.validTo == nil }.map(\.to))
    }

    /// People who currently work at an organization.
    public func people(at organization: ObjectID) throws -> [Contact] {
        try store.objects(try store.relationships(to: organization, kind: .worksAt).filter { $0.validTo == nil }.map(\.from)).map(Contact.init)
    }

    /// A person sets how often they want to be in touch with a contact.
    @discardableResult
    public func setCadence(_ days: Int?, for person: ObjectID, by author: Origin) throws -> Contact {
        if let days, !(1...3_650).contains(days) { throw ContactsError.invalidCadence(days) }
        _ = try contact(person)
        let stamp = provenance(author, method: "cadence")
        return Contact(
            record: try store.update(person, by: author, instruction: days.map { "Keep in touch every \($0) days" } ?? "No cadence") {
                $0.attributes[ContactKey.cadenceDays] = days.map { Attribute(.int(Int64($0)), provenance: stamp) }
            })
    }

    // MARK: Interactions

    /// Logs a call, email, meeting or message with one or more people, as an
    /// `interaction` event on the shared timeline. A person's log is observed truth.
    @discardableResult
    public func logInteraction(
        with people: [ObjectID], channel: InteractionChannel, at date: Date? = nil, summary: String, note: String? = nil, by author: Origin
    ) throws -> Event {
        guard !people.isEmpty else { throw ContactsError.noPeople }
        for person in people { _ = try contact(person) }
        var payload: [String: Value] = [ContactKey.channel: .string(channel.rawValue)]
        if let note, !note.isEmpty { payload[ContactKey.note] = .string(note) }
        let event = Event(
            at: date ?? clock.now(), kind: .interaction, subjects: people, summary: summary, payload: payload,
            provenance: provenance(author, method: "\(channel.rawValue) logged")
        )
        try store.record(event)
        return event
    }

    /// A person's interactions, newest first.
    public func interactions(with person: ObjectID) throws -> [Event] {
        try store.events(about: person).filter { $0.kind == .interaction }.sorted { $0.at > $1.at }
    }

    /// The latest recorded or observed interaction with a person.
    public func lastContacted(_ person: ObjectID) throws -> Date? {
        try interactions(with: person).first { TruthPolicy.protected.contains($0.provenance.truth) }?.at
    }

    /// Where the relationship with a person stands on `date`.
    public func standing(of person: ObjectID, asOf date: Date, defaultCadence: Int = defaultCadenceDays) throws -> ContactStanding {
        let contact = try contact(person)
        let last = try lastContacted(person)
        let cadence = contact.cadenceDays ?? defaultCadence
        let since = last.map { ContactsCalendar.days(from: $0, to: date) }
        let overdue: Int
        if let since {
            overdue = max(0, since - cadence)
        } else {
            // Never contacted counts only when the person asked to keep in touch.
            overdue = contact.cadenceDays == nil ? 0 : cadence
        }
        let isOverdue = since.map { $0 > cadence } ?? (contact.cadenceDays != nil)
        return ContactStanding(contact: contact, lastContacted: last, daysSince: since, cadenceDays: cadence, isOverdue: isOverdue, daysOverdue: overdue)
    }

    /// Everyone past their cadence on `date`, most overdue first. People never
    /// contacted appear only when they have a cadence of their own.
    public func overdue(asOf date: Date, defaultCadence: Int = defaultCadenceDays) throws -> [ContactStanding] {
        try contacts().map { try standing(of: $0.id, asOf: date, defaultCadence: defaultCadence) }.filter(\.isOverdue).sorted {
            ($0.daysOverdue, $1.contact.name) > ($1.daysOverdue, $0.contact.name)
        }
    }

    // MARK: Follow-ups

    /// A follow-up task with a person, due on `due`. From an agent it is a draft.
    @discardableResult
    public func addFollowUp(with person: ObjectID, title: String? = nil, due: Date? = nil, by author: Origin) throws -> TaskItem {
        try store.batch { store in
            let contact = try contact(person)
            let task = try TaskRuntime(store: store, clock: clock).create(
                title ?? "Follow up with \(contact.name)", successCondition: "An interaction with \(contact.name) is logged", dueAt: due, by: author
            )
            try store.relate(Relationship(kind: .followUpFor, from: task.id, to: person, provenance: provenance(author, method: "follow-up")))
            return task
        }
    }

    /// Open follow-ups with a person (not done or cancelled).
    public func followUps(for person: ObjectID) throws -> [TaskItem] {
        let tasks = TaskRuntime(store: store, clock: clock)
        return try store.relationships(to: person, kind: .followUpFor).compactMap { try? tasks.task($0.from) }.filter {
            $0.lifecycle != .deleted && ![.done, .cancelled].contains($0.status)
        }
    }

    /// A follow-up, due on `date`, for everyone overdue who has none open.
    @discardableResult
    public func scheduleFollowUps(asOf date: Date, defaultCadence: Int = defaultCadenceDays, by author: Origin) throws -> [TaskItem] {
        try store.batch { _ in
            try overdue(asOf: date, defaultCadence: defaultCadence).filter { try followUps(for: $0.contact.id).isEmpty }.map { standing in
                let reason = standing.daysSince.map { "last contact \($0) days ago" } ?? "never contacted"
                return try addFollowUp(with: standing.contact.id, title: "Catch up with \(standing.contact.name) (\(reason))", due: date, by: author)
            }
        }
    }
}
