import Foundation
import NexusCore
import NexusMeetings
import NexusModel
import NexusPersistence
import NexusTasks
import Testing

/// An in-memory calendar standing in for EventKit.
final class FakeCalendar: CalendarService {
    var events: [String: CalendarSnapshot] = [:]
    var saves = 0
    var refuse = false
    private var next = 0
    let calendars = [CalendarInfo(id: "work", title: "Work", isDefault: true), CalendarInfo(id: "home", title: "Home")]

    struct Refused: Error {}

    func writableCalendars() throws -> [CalendarInfo] { calendars }

    func save(_ draft: CalendarEventDraft, eventID: String?) throws -> CalendarSnapshot {
        if refuse { throw Refused() }
        saves += 1
        let id =
            eventID.flatMap { events[$0] == nil ? nil : $0 }
            ?? {
                next += 1; return "ev-\(next)"
            }()
        let calendar = calendars.first { $0.id == draft.calendarID } ?? calendars[0]
        let snapshot = CalendarSnapshot(
            eventID: id, externalID: events[id]?.externalID ?? "ext-\(id)", calendarID: calendar.id, calendarTitle: calendar.title,
            title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location, notes: draft.notes,
            alerts: draft.alerts
        )
        events[id] = snapshot
        return snapshot
    }

    func event(withID eventID: String) throws -> CalendarSnapshot? { events[eventID] }

    func events(withExternalID externalID: String) throws -> [CalendarSnapshot] {
        events.values.filter { $0.externalID == externalID }
    }
}

@Suite struct CalendarLinkTests {
    let person = Origin.user(id: "sam")
    let t0 = Date(timeIntervalSinceReferenceDate: 810_000_000)

    @Test func schedulesATaskAsALinkedEventObject() throws {
        let store = try NexusStore(.inMemory)
        let calendar = FakeCalendar()
        let linker = CalendarLinker(store: store, service: calendar)
        let task = try TaskRuntime(store: store).create("Calibrate LT-101", successCondition: "reads 4–20 mA", dueAt: t0, by: person)

        var draft = CalendarLinker.draft(for: try #require(try store.object(task.id)), now: t0)
        #expect(draft.title == "Calibrate LT-101")
        #expect(draft.notes?.contains("Done when reads 4–20 mA") == true)
        #expect(draft.alerts == [-900])
        #expect(draft.start == t0.addingTimeInterval(-3600))
        draft.location = "Pump house"
        draft.calendarID = "home"

        let event = try linker.schedule(draft, for: task.id, by: person)
        #expect(event.type == .event)
        #expect(event.attributes[CalendarKey.eventID]?.value == .string("ev-1"))
        #expect(event.attributes[CalendarKey.externalID]?.value == .string("ext-ev-1"))
        #expect(event.attributes[CalendarKey.calendarTitle]?.value == .string("Home"))
        #expect(event.attributes[CalendarKey.location]?.value == .string("Pump house"))
        #expect(event.attributes[CalendarKey.subject]?.value == .reference(task.id))
        #expect(event.provenance.truth == .recorded && event.provenance.origin == person)
        let edges = try store.relationships(from: event.id, kind: .schedules)
        #expect(edges.map(\.to) == [task.id])
        #expect(try store.events(about: task.id).contains { $0.kind == .calendarWritten })
    }

    @Test func aMeetingHoldsItsOwnLink() throws {
        let store = try NexusStore(.inMemory)
        let linker = CalendarLinker(store: store, service: FakeCalendar())
        let meeting = try NotePromotion.promote(transcript: "Ana: hello", title: "Weekly sync", in: store, by: person, at: t0).meeting
        let draft = CalendarLinker.draft(for: try #require(try store.object(meeting)), now: t0)
        #expect(draft.title == "Weekly sync")
        let linked = try linker.schedule(draft, for: meeting, by: person)
        #expect(linked.id == meeting)
        #expect(linked.attributes[CalendarKey.eventID] != nil)
        #expect(try store.objects(ofType: .event).isEmpty)
        #expect(try linker.linkedObjects().map(\.id) == [meeting])
    }

    @Test func nexusEditsWriteThroughToTheCalendar() throws {
        let store = try NexusStore(.inMemory)
        let calendar = FakeCalendar()
        let linker = CalendarLinker(store: store, service: calendar)
        let subject = try store.create(
            ObjectRecord(type: .equipment, title: "Pump P-7", provenance: Provenance(origin: person, truth: .recorded, timestamp: t0)))
        let draft = CalendarLinker.draft(for: subject, now: t0)
        #expect(draft.title == "Work on Pump P-7")
        let event = try linker.schedule(draft, for: subject.id, by: person)

        // Scheduling the event object again edits it rather than adding one.
        var edited = CalendarLinker.draft(for: event, now: t0)
        #expect(edited.title == "Work on Pump P-7" && edited.start == draft.start)
        edited.title = "Rebuild P-7 seal"
        edited.end = edited.end.addingTimeInterval(1800)
        edited.alerts = [-3600, 0]
        let updated = try linker.edit(event.id, to: edited, by: person)
        #expect(calendar.saves == 2 && calendar.events.count == 1)
        #expect(calendar.events["ev-1"]?.title == "Rebuild P-7 seal")
        #expect(updated.title == "Rebuild P-7 seal")
        #expect(updated.attributes[CalendarKey.alerts]?.value == .list([.double(-3600), .double(0)]))
        let edit = try #require(try store.events(about: event.id).last { $0.kind == .calendarWritten })
        #expect(edit.payload["changed"] == .list([.string(CalendarKey.alerts), .string(CalendarKey.end), .string(CalendarKey.title)]))

        #expect(throws: CalendarLinkError.notLinked(subject.id)) { try linker.edit(subject.id, to: edited, by: person) }
    }

    @Test func aRefusedWriteStoresNothing() throws {
        let store = try NexusStore(.inMemory)
        let calendar = FakeCalendar()
        calendar.refuse = true
        let linker = CalendarLinker(store: store, service: calendar)
        let subject = try store.create(ObjectRecord(type: .equipment, title: "Pump", provenance: Provenance(origin: person, truth: .recorded, timestamp: t0)))
        #expect(throws: FakeCalendar.Refused.self) { try linker.schedule(CalendarLinker.draft(for: subject, now: t0), for: subject.id, by: person) }
        #expect(try store.objects(ofType: .event).isEmpty)
    }

    @Test func calendarChangesArePickedUpAsRecordedTruthFromTheCalendar() throws {
        let store = try NexusStore(.inMemory)
        let calendar = FakeCalendar()
        let linker = CalendarLinker(store: store, service: calendar)
        let subject = try store.create(ObjectRecord(type: .equipment, title: "Pump", provenance: Provenance(origin: person, truth: .recorded, timestamp: t0)))
        let event = try linker.schedule(CalendarLinker.draft(for: subject, now: t0), for: subject.id, by: person)

        #expect(try linker.refresh().unchanged == 1)

        // Moved and retitled in Calendar; its device identifier also changed after a sync.
        let original = calendar.events.removeValue(forKey: "ev-1")
        var moved = try #require(original)
        moved.eventID = "ev-synced"
        moved.title = "Pump inspection"
        moved.start = moved.start.addingTimeInterval(86_400)
        moved.end = moved.end.addingTimeInterval(86_400)
        moved.location = "Site B"
        calendar.events["ev-synced"] = moved

        let refresh = try linker.refresh()
        #expect(
            refresh.changed[event.id] == [CalendarKey.eventID, CalendarKey.end, CalendarKey.title, CalendarKey.location, CalendarKey.start]
        )
        let stored = try #require(try store.object(event.id))
        #expect(stored.title == "Pump inspection")
        #expect(stored.attributes[CalendarKey.eventID]?.value == .string("ev-synced"))
        let start = try #require(stored.attributes[CalendarKey.start]?.provenance)
        #expect(start.truth == .recorded && start.method == "calendar")
        guard case .importer(let source) = start.origin else {
            Issue.record("expected the calendar as origin")
            return
        }
        #expect(try store.object(source)?.title == "Calendar")
        #expect(try CalendarLinker.calendarSource(in: store, at: t0) == source)
        #expect(try store.events(about: event.id).contains { $0.kind == .calendarChanged && $0.provenance.method == "calendar" })

        // Deleted in Calendar: marked, never deleted from Nexus; marked once.
        calendar.events.removeAll()
        #expect(try linker.refresh().removed == [event.id])
        #expect(try store.object(event.id)?.attributes[CalendarKey.removed]?.value == .bool(true))
        #expect(try linker.refresh().removed.isEmpty)
    }

    @Test func diffIgnoresSubSecondDatesAndAlertOrder() {
        let snapshot = CalendarSnapshot(
            eventID: "a", externalID: nil, calendarID: "c", calendarTitle: "C", title: "T", start: t0, end: t0.addingTimeInterval(60),
            alerts: [0, -300]
        )
        var stored = snapshot.values.mapValues { Attribute($0) }
        stored[CalendarKey.start] = Attribute(.date(t0.addingTimeInterval(0.4)))
        stored[CalendarKey.alerts] = Attribute(.list([.double(-300), .int(0)]))
        #expect(CalendarLinker.changes(from: stored, to: snapshot).isEmpty)
        stored[CalendarKey.location] = Attribute(.string("Lab"))
        #expect(CalendarLinker.changes(from: stored, to: snapshot) == [CalendarKey.location])
    }
}
