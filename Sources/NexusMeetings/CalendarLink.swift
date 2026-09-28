import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks

// Calendar events Nexus writes to the person's calendar (EventKit on Apple
// platforms) and keeps linked to the object they are about.
//
// The calendar is the external system of record for its events: what it
// reports on refresh is **recorded** truth whose origin is the `Calendar`
// source object and whose method is "calendar". Nexus never keeps a second
// calendar; it keeps the link (event identifier and external identifier) and
// the last values it saw, on an `event` object, or on the `meeting` itself
// when the event is for a meeting. EventKit stays in the Apple-only UI
// target behind `CalendarService`; everything here runs on Linux.

extension RelationKind {
    /// Calendar event → the task, meeting or object it schedules time for.
    public static let schedules: RelationKind = "schedules"
}

extension EventKind {
    /// Nexus created or edited an event in the calendar.
    public static let calendarWritten: EventKind = "calendarWritten"
    /// A refresh found the calendar event changed or removed outside Nexus.
    public static let calendarChanged: EventKind = "calendarChanged"
}

/// Attribute keys on a calendar-linked `event` or `meeting` object.
public enum CalendarKey {
    /// `EKEvent.eventIdentifier`: the event on this device.
    public static let eventID = "calendarEventID"
    /// `EKCalendarItem.calendarItemExternalIdentifier`: the event on the server, across devices.
    public static let externalID = "calendarExternalID"
    public static let calendarID = "calendarID"
    public static let calendarTitle = "calendarTitle"
    public static let title = "eventTitle"
    public static let start = "start"
    public static let end = "end"
    public static let allDay = "allDay"
    public static let location = "location"
    /// The event's notes. Distinct from an object's own free-text `notes`.
    public static let notes = "eventNotes"
    /// Alert offsets in seconds relative to the start; negative is before.
    public static let alerts = "alerts"
    public static let lastModified = "calendarLastModified"
    /// Set when a refresh no longer finds the event in the calendar.
    public static let removed = "calendarRemoved"
    /// The object the event schedules (also a `schedules` relationship).
    public static let subject = "scheduledSubject"
}

/// A calendar the person can write to.
public struct CalendarInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var isDefault: Bool

    public init(id: String, title: String, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
    }
}

/// The fields a person edits on a calendar event.
public struct CalendarEventDraft: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    /// Seconds relative to `start`; negative fires before it.
    public var alerts: [TimeInterval]
    /// The calendar to write to; nil means the default calendar.
    public var calendarID: String?

    public init(
        title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, notes: String? = nil,
        alerts: [TimeInterval] = [], calendarID: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = max(end, start)
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.alerts = alerts
        self.calendarID = calendarID
    }
}

/// What the calendar reports for one event.
public struct CalendarSnapshot: Sendable, Hashable {
    public var eventID: String
    public var externalID: String?
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var alerts: [TimeInterval]
    public var lastModified: Date?

    public init(
        eventID: String, externalID: String?, calendarID: String, calendarTitle: String, title: String, start: Date, end: Date,
        isAllDay: Bool = false, location: String? = nil, notes: String? = nil, alerts: [TimeInterval] = [], lastModified: Date? = nil
    ) {
        self.eventID = eventID
        self.externalID = externalID
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.alerts = alerts
        self.lastModified = lastModified
    }

    /// The same event as an editable draft.
    public var draft: CalendarEventDraft {
        CalendarEventDraft(
            title: title, start: start, end: end, isAllDay: isAllDay, location: location, notes: notes, alerts: alerts, calendarID: calendarID
        )
    }

    /// The stored attribute values this snapshot stands for, keyed by `CalendarKey`.
    public var values: [String: Value] {
        var values: [String: Value] = [
            CalendarKey.eventID: .string(eventID),
            CalendarKey.calendarID: .string(calendarID),
            CalendarKey.calendarTitle: .string(calendarTitle),
            CalendarKey.title: .string(title),
            CalendarKey.start: .date(start),
            CalendarKey.end: .date(end),
            CalendarKey.allDay: .bool(isAllDay),
            CalendarKey.alerts: .list(alerts.sorted().map { .double($0) }),
        ]
        if let externalID { values[CalendarKey.externalID] = .string(externalID) }
        values[CalendarKey.location] = location.flatMap { $0.isEmpty ? nil : Value.string($0) } ?? .null
        values[CalendarKey.notes] = notes.flatMap { $0.isEmpty ? nil : Value.string($0) } ?? .null
        if let lastModified { values[CalendarKey.lastModified] = .date(lastModified) }
        return values
    }
}

/// Reads and writes the person's calendar. EventKit implements it in the
/// Apple-only UI target; tests use an in-memory one.
public protocol CalendarService {
    /// Calendars that accept new events.
    func writableCalendars() throws -> [CalendarInfo]
    /// Creates an event, or edits the one with `eventID`, and returns what the calendar then holds.
    func save(_ draft: CalendarEventDraft, eventID: String?) throws -> CalendarSnapshot
    /// The event with this device identifier, if it still exists.
    func event(withID eventID: String) throws -> CalendarSnapshot?
    /// Events carrying this server identifier (several for a recurring series).
    func events(withExternalID externalID: String) throws -> [CalendarSnapshot]
}

public enum CalendarLinkError: Error, Equatable, Sendable {
    case notFound(ObjectID)
    /// The object has no calendar event to edit.
    case notLinked(ObjectID)
}

/// What one refresh changed.
public struct CalendarRefresh: Sendable, Hashable {
    /// Objects whose event changed in the calendar, with the changed keys.
    public var changed: [ObjectID: [String]] = [:]
    /// Objects whose event is gone from the calendar.
    public var removed: [ObjectID] = []
    public var unchanged = 0

    public init() {}
}

/// Creates and edits calendar events for Nexus objects and picks up changes
/// made in the calendar.
public struct CalendarLinker {
    public let store: NexusStore
    public let service: any CalendarService
    let clock: NexusClock

    public init(store: NexusStore, service: any CalendarService, clock: NexusClock = SystemClock()) {
        self.store = store
        self.service = service
        self.clock = clock
    }

    // MARK: Drafts

    /// A first draft for scheduling `subject`: a task at its due time (or
    /// the next hour), a meeting under its own title, anything else as time
    /// to work on it. One hour long, with a 15-minute alert.
    public static func draft(for subject: ObjectRecord, now: Date) -> CalendarEventDraft {
        let nextHour = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 3600).rounded(.up) * 3600)
        if let values = linkedValues(subject), let start = values.date(CalendarKey.start), let end = values.date(CalendarKey.end) {
            return CalendarEventDraft(
                title: values.string(CalendarKey.title) ?? subject.title, start: start, end: end,
                isAllDay: values.bool(CalendarKey.allDay) ?? false, location: values.string(CalendarKey.location),
                notes: values.string(CalendarKey.notes), alerts: values.alerts, calendarID: values.string(CalendarKey.calendarID)
            )
        }
        var start = nextHour
        var notes: String?
        var title = subject.title
        switch subject.type {
        case .task:
            let task = try? TaskItem(record: subject)
            if let due = task?.dueAt { start = due.addingTimeInterval(-3600) }
            notes = task?.successCondition.map { "Done when \($0)" }
        case .meeting, .event:
            break
        default:
            title = "Work on \(subject.title)"
        }
        let link = "nexus://object/\(subject.id)"
        notes = [notes, link].compactMap { $0 }.joined(separator: "\n")
        return CalendarEventDraft(title: title, start: start, end: start.addingTimeInterval(3600), notes: notes, alerts: [-900])
    }

    // MARK: Writing

    /// Writes a new event to the calendar, then stores the link. A meeting
    /// holds its own link; anything else gets an `event` object that
    /// `schedules` it. Nothing is stored when the calendar refuses the event.
    @discardableResult
    public func schedule(_ draft: CalendarEventDraft, for subjectID: ObjectID, by author: Origin) throws -> ObjectRecord {
        guard let subject = try store.object(subjectID) else { throw CalendarLinkError.notFound(subjectID) }
        if subject.type == .meeting || subject.type == .event, Self.linkedValues(subject) != nil {
            return try edit(subjectID, to: draft, by: author)
        }
        let snapshot = try service.save(draft, eventID: nil)
        let now = clock.now()
        let recorded = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "scheduled in calendar from Nexus")
        return try store.batch { store in
            let linked: ObjectRecord
            if subject.type == .meeting || subject.type == .event {
                linked = try store.update(subjectID, by: author, instruction: "Scheduled in \(snapshot.calendarTitle)") { record in
                    for (key, value) in snapshot.values { record.attributes[key] = Attribute(value, provenance: recorded) }
                }
            } else {
                var attributes = snapshot.values.mapValues { Attribute($0) }
                attributes[CalendarKey.subject] = Attribute(.reference(subjectID))
                linked = try store.create(ObjectRecord(type: .event, title: snapshot.title, attributes: attributes, provenance: recorded))
                try store.relate(Relationship(kind: .schedules, from: linked.id, to: subjectID, provenance: recorded))
            }
            try store.record(
                Event(
                    at: now, kind: .calendarWritten, subjects: [linked.id, subjectID].uniqued(),
                    summary: "Scheduled \(snapshot.title) in \(snapshot.calendarTitle)", payload: ["eventID": .string(snapshot.eventID)],
                    provenance: recorded
                ))
            return linked
        }
    }

    /// Writes an edit made in Nexus to the calendar event, then stores what
    /// the calendar reports back. Nothing is stored when the calendar refuses it.
    @discardableResult
    public func edit(_ id: ObjectID, to draft: CalendarEventDraft, by author: Origin) throws -> ObjectRecord {
        guard let record = try store.object(id) else { throw CalendarLinkError.notFound(id) }
        guard let values = Self.linkedValues(record), let eventID = try currentEventID(values) else { throw CalendarLinkError.notLinked(id) }
        let snapshot = try service.save(draft, eventID: eventID)
        let now = clock.now()
        let recorded = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "edited in Nexus, written to calendar")
        return try store.batch { store in
            let changed = Self.changes(from: values, to: snapshot)
            let updated = try store.update(id, by: author, instruction: "Edited calendar event") { record in
                for key in changed { record.attributes[key] = Attribute(snapshot.values[key] ?? .null, provenance: recorded) }
                if record.attributes[CalendarKey.removed] != nil {
                    record.attributes[CalendarKey.removed] = Attribute(.bool(false), provenance: recorded)
                }
                if record.type == .event { record.title = snapshot.title }
            }
            try store.record(
                Event(
                    at: now, kind: .calendarWritten, subjects: [id], summary: "Edited \(snapshot.title) in \(snapshot.calendarTitle)",
                    payload: ["changed": .list(changed.map { .string($0) }), "eventID": .string(snapshot.eventID)], provenance: recorded
                ))
            return updated
        }
    }

    // MARK: Refresh

    /// Every object linked to a calendar event, meetings included.
    public func linkedObjects() throws -> [ObjectRecord] {
        try (store.objects(ofType: .event) + store.objects(ofType: .meeting))
            .filter { $0.lifecycle != .deleted && Self.linkedValues($0) != nil }
    }

    /// Reads each linked event back from the calendar. Changes made there
    /// are stored as recorded truth from the calendar (origin: the
    /// `Calendar` source object, method "calendar"); an event that is gone
    /// is marked removed, never deleted from Nexus.
    @discardableResult
    public func refresh() throws -> CalendarRefresh {
        var result = CalendarRefresh()
        for record in try linkedObjects() {
            guard let values = Self.linkedValues(record) else { continue }
            let snapshot = try find(values)
            let now = clock.now()
            guard let snapshot else {
                if values.bool(CalendarKey.removed) == true {
                    result.unchanged += 1
                    continue
                }
                let provenance = try calendarProvenance(at: now, method: "calendar: event no longer found")
                try store.batch { store in
                    try store.update(record.id, by: provenance.origin, instruction: "Removed in Calendar") {
                        $0.attributes[CalendarKey.removed] = Attribute(.bool(true), provenance: provenance)
                    }
                    try store.record(
                        Event(
                            at: now, kind: .calendarChanged, subjects: [record.id], summary: "\(record.title) was removed from the calendar",
                            payload: ["removed": .bool(true)], provenance: provenance
                        ))
                }
                result.removed.append(record.id)
                continue
            }
            var changed = Self.changes(from: values, to: snapshot)
            if values.bool(CalendarKey.removed) == true { changed.append(CalendarKey.removed) }
            guard !changed.isEmpty else {
                result.unchanged += 1
                continue
            }
            let provenance = try calendarProvenance(at: now, method: "calendar")
            try store.batch { store in
                try store.update(record.id, by: provenance.origin, instruction: "Changed in Calendar") { record in
                    for key in changed {
                        if key == CalendarKey.removed {
                            record.attributes[key] = Attribute(.bool(false), provenance: provenance)
                        } else {
                            record.attributes[key] = Attribute(snapshot.values[key] ?? .null, provenance: provenance)
                        }
                    }
                    if record.type == .event, record.title != snapshot.title { record.title = snapshot.title }
                }
                try store.record(
                    Event(
                        at: now, kind: .calendarChanged, subjects: [record.id], summary: "\(snapshot.title) changed in \(snapshot.calendarTitle)",
                        payload: ["changed": .list(changed.map { .string($0) })], provenance: provenance
                    ))
            }
            result.changed[record.id] = changed
        }
        return result
    }

    // MARK: Diff

    /// Keys whose stored value differs from what the calendar reports.
    /// Dates compare to the second, since calendars drop sub-second parts.
    public static func changes(from stored: [String: Attribute], to snapshot: CalendarSnapshot) -> [String] {
        snapshot.values.keys.sorted().filter { key in
            let incoming = snapshot.values[key] ?? .null
            let current = stored[key]?.value ?? .null
            switch (current, incoming) {
            case (.date(let a), .date(let b)): return abs(a.timeIntervalSince(b)) >= 1
            case (.list(let a), .list(let b)): return a.sortedDoubles != b.sortedDoubles
            default: return current != incoming
            }
        }
    }

    /// The calendar attributes on a record, or nil when it has no event link.
    public static func linkedValues(_ record: ObjectRecord) -> [String: Attribute]? {
        record.attributes[CalendarKey.eventID] == nil && record.attributes[CalendarKey.externalID] == nil ? nil : record.attributes
    }

    /// The device identifier first; when it no longer resolves (identifiers
    /// can change after a calendar sync), the server identifier, taking the
    /// occurrence nearest the stored start.
    func find(_ values: [String: Attribute]) throws -> CalendarSnapshot? {
        if let eventID = values.string(CalendarKey.eventID), let snapshot = try service.event(withID: eventID) {
            return snapshot
        }
        guard let externalID = values.string(CalendarKey.externalID) else { return nil }
        let start = values.date(CalendarKey.start) ?? .distantPast
        return try service.events(withExternalID: externalID).min {
            abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start))
        }
    }

    private func currentEventID(_ values: [String: Attribute]) throws -> String? {
        try find(values)?.eventID ?? values.string(CalendarKey.eventID)
    }

    /// Provenance for values read from the calendar: recorded, from the
    /// `Calendar` source object, method `method`.
    func calendarProvenance(at date: Date, method: String) throws -> Provenance {
        Provenance(origin: .importer(source: try Self.calendarSource(in: store, at: date)), truth: .recorded, timestamp: date, method: method)
    }

    /// The `source` object that stands for the person's calendar, created once.
    public static func calendarSource(in store: NexusStore, at date: Date) throws -> ObjectID {
        if let existing = try store.objects(ofType: .source).first(where: { $0.attributes["system"]?.value == .string("calendar") }) {
            return existing.id
        }
        return try store.create(
            ObjectRecord(
                type: .source, title: "Calendar", attributes: ["system": Attribute(.string("calendar"))],
                provenance: Provenance(origin: .system, truth: .recorded, timestamp: date, method: "calendar")
            )
        ).id
    }
}

// MARK: - Helpers

extension [String: Attribute] {
    fileprivate func string(_ key: String) -> String? {
        if case .string(let text)? = self[key]?.value { return text }
        return nil
    }

    fileprivate func date(_ key: String) -> Date? {
        if case .date(let date)? = self[key]?.value { return date }
        return nil
    }

    fileprivate func bool(_ key: String) -> Bool? {
        if case .bool(let flag)? = self[key]?.value { return flag }
        return nil
    }

    fileprivate var alerts: [TimeInterval] {
        if case .list(let values)? = self[CalendarKey.alerts]?.value { return values.sortedDoubles }
        return []
    }
}

extension [Value] {
    fileprivate var sortedDoubles: [Double] {
        compactMap {
            if case .double(let number) = $0 { return number }
            if case .int(let number) = $0 { return Double(number) }
            return nil
        }
        .sorted()
    }
}

extension [ObjectID] {
    fileprivate func uniqued() -> [ObjectID] {
        var seen: Set<ObjectID> = []
        return filter { seen.insert($0).inserted }
    }
}
