#if canImport(SwiftUI) && canImport(EventKit)
import EventKit
import Foundation
import NexusCore
import NexusMeetings
import NexusModel
import NexusTasks
import SwiftUI

/// The person's own calendar and reminders, through EventKit.
///
/// Calendar events are shown as fixed time. Events the person creates from
/// Nexus (for a task, a meeting or any object) are written to the calendar
/// and linked: `CalendarLinker` keeps the event identifiers on an `event`
/// object (or on the meeting) and reads the calendar back on refresh, so
/// changes made in Calendar arrive as recorded truth from the calendar.
/// Tasks are sent to Reminders on request, and the reminder's id is kept on
/// the task (recorded, by the person) so it isn't added twice.
@MainActor
@Observable
final class CalendarSync {
    struct Fixed: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendar: String
    }

    /// One event store for the app; EventKit prefers a single long-lived one.
    static let shared = CalendarSync()

    private(set) var events: [Fixed] = []
    private(set) var calendarAccess = false
    /// What the last refresh of linked events found.
    private(set) var lastRefresh: CalendarRefresh?
    @ObservationIgnored private let store: EKEventStore
    @ObservationIgnored let service: EventKitCalendar

    static let reminderKey = "reminderID"

    init() {
        let store = EKEventStore()
        self.store = store
        service = EventKitCalendar(store: store)
    }

    /// Asks once for full calendar access (needed to write and to read back).
    func requestAccess() async -> Bool {
        do {
            calendarAccess = try await store.requestFullAccessToEvents()
        } catch {
            calendarAccess = false
        }
        return calendarAccess
    }

    func loadWeek() async {
        guard await requestAccess() else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(7 * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map {
            Fixed(
                id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                calendar: $0.calendar?.title ?? "")
        }
    }

    func linker(_ env: NexusEnvironment) -> CalendarLinker {
        CalendarLinker(store: env.store, service: service)
    }

    /// Reads every linked event back from the calendar.
    func refreshLinks(_ env: NexusEnvironment) throws {
        guard calendarAccess else { return }
        lastRefresh = try linker(env).refresh()
    }

    /// Adds the task to Reminders and remembers the reminder on the task.
    func sendToReminders(_ task: TaskItem, env: NexusEnvironment) async throws {
        guard try await store.requestFullAccessToReminders() else {
            throw ClassifiedError(
                category: .dataSource, whatHappened: "Reminders access wasn't granted.",
                nextActions: [NextAction("Allow Reminders for Nexus in Settings")]
            )
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = task.title
        reminder.notes = task.successCondition.map { "Done when \($0)" }
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = task.dueAt {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        try store.save(reminder, commit: true)
        let identifier = reminder.calendarItemIdentifier
        _ = try env.store.update(task.id, by: env.user, instruction: "Sent to Reminders") {
            $0.attributes[Self.reminderKey] = Attribute(.string(identifier))
        }
    }
}

/// `CalendarService` over EventKit. Mapping and diffing live in
/// `CalendarLinker` (NexusMeetings), which tests on Linux.
final class EventKitCalendar: CalendarService {
    let store: EKEventStore

    init(store: EKEventStore) {
        self.store = store
    }

    func writableCalendars() throws -> [CalendarInfo] {
        let fallback = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).filter(\.allowsContentModifications).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, isDefault: $0.calendarIdentifier == fallback)
        }
    }

    func save(_ draft: CalendarEventDraft, eventID: String?) throws -> CalendarSnapshot {
        let event = eventID.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        event.alarms = draft.alerts.map { EKAlarm(relativeOffset: $0) }
        if let id = draft.calendarID, let calendar = store.calendar(withIdentifier: id) {
            event.calendar = calendar
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendarForNewEvents
        }
        try store.save(event, span: .thisEvent, commit: true)
        return snapshot(event)
    }

    func event(withID eventID: String) throws -> CalendarSnapshot? {
        store.event(withIdentifier: eventID).map(snapshot)
    }

    func events(withExternalID externalID: String) throws -> [CalendarSnapshot] {
        store.calendarItems(withExternalIdentifier: externalID).compactMap { $0 as? EKEvent }.map(snapshot)
    }

    private func snapshot(_ event: EKEvent) -> CalendarSnapshot {
        CalendarSnapshot(
            eventID: event.eventIdentifier ?? "", externalID: event.calendarItemExternalIdentifier,
            calendarID: event.calendar?.calendarIdentifier ?? "", calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, location: event.location,
            notes: event.notes, alerts: (event.alarms ?? []).map(\.relativeOffset), lastModified: event.lastModifiedDate
        )
    }
}

/// An object to schedule, or a linked event to edit, for `.sheet(item:)`.
struct CalendarEditTarget: Identifiable, Hashable {
    let id: ObjectID
}

/// Title, time, location, notes, alerts and calendar for a new or linked
/// event. Saving writes to the calendar first; Nexus stores the link only
/// once the calendar has accepted the event.
struct CalendarEventEditor: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let target: ObjectID
    let sync: CalendarSync
    @State private var draft: CalendarEventDraft?
    @State private var calendars: [CalendarInfo] = []
    @State private var error: ClassifiedError?

    private struct AlertChoice: Hashable {
        let title: String
        let offset: TimeInterval
    }

    private static let alertChoices = [
        AlertChoice(title: "At time of event", offset: 0), AlertChoice(title: "5 minutes before", offset: -300),
        AlertChoice(title: "15 minutes before", offset: -900), AlertChoice(title: "1 hour before", offset: -3600),
        AlertChoice(title: "1 day before", offset: -86_400),
    ]

    private var isEdit: Bool { env.object(target).flatMap(CalendarLinker.linkedValues) != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let draft = Binding($draft) {
                    Section("Event") {
                        TextField("Title", text: draft.title)
                        Toggle("All day", isOn: draft.isAllDay)
                        DatePicker("Starts", selection: draft.start, displayedComponents: components(draft.wrappedValue))
                        DatePicker("Ends", selection: draft.end, in: draft.wrappedValue.start..., displayedComponents: components(draft.wrappedValue))
                        TextField("Location", text: text(draft.location))
                        TextField("Notes", text: text(draft.notes), axis: .vertical).lineLimit(3...8)
                    }
                    Section("Alerts") {
                        ForEach(Self.alertChoices, id: \.self) { choice in
                            Toggle(choice.title, isOn: alert(choice.offset, in: draft))
                        }
                    }
                    Section("Calendar") {
                        Picker("Calendar", selection: draft.calendarID) {
                            ForEach(calendars) { Text($0.title).tag(Optional($0.id)) }
                        }
                    }
                } else if sync.calendarAccess {
                    ProgressView()
                } else {
                    NextActionEmptyState(
                        "Calendar access needed", message: "Allow full Calendar access for Nexus in Settings to create and edit events.",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .formStyle(.grouped)
            .navigationTitle(isEdit ? "Edit event" : "Schedule in Calendar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(draft?.title.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                }
            }
            .task { await load() }
        }
    }

    private func components(_ draft: CalendarEventDraft) -> DatePickerComponents {
        draft.isAllDay ? [.date] : [.date, .hourAndMinute]
    }

    private func text(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func alert(_ offset: TimeInterval, in draft: Binding<CalendarEventDraft>) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.alerts.contains(offset) },
            set: { on in
                draft.wrappedValue.alerts.removeAll { $0 == offset }
                if on { draft.wrappedValue.alerts.append(offset) }
            }
        )
    }

    private func load() async {
        guard draft == nil, await sync.requestAccess(), let record = env.object(target) else { return }
        do {
            calendars = try sync.service.writableCalendars()
            var initial = CalendarLinker.draft(for: record, now: Date())
            if initial.calendarID == nil || !calendars.contains(where: { $0.id == initial.calendarID }) {
                initial.calendarID = (calendars.first(where: \.isDefault) ?? calendars.first)?.id
            }
            draft = initial
        } catch {
            self.error = classify(error).preserving("Nothing was changed in Calendar or in Nexus.")
        }
    }

    private func save() {
        guard var draft else { return }
        if draft.isAllDay {
            draft.start = Calendar.current.startOfDay(for: draft.start)
            draft.end = max(draft.start, Calendar.current.startOfDay(for: draft.end))
        }
        do {
            let linker = sync.linker(env)
            if isEdit {
                try linker.edit(target, to: draft, by: env.user)
            } else {
                try linker.schedule(draft, for: target, by: env.user)
            }
            error = nil
            dismiss()
        } catch {
            self.error = classify(error).preserving("Nexus stores the link only after Calendar saves the event; nothing half-saved was kept.")
        }
    }
}

/// Calendar events for an object: its own link (a linked event or meeting)
/// and events that schedule it, with create and edit.
struct CalendarLinkSection: View {
    @Environment(NexusEnvironment.self) private var env
    let record: ObjectRecord
    @State private var editing: CalendarEditTarget?
    private var sync: CalendarSync { .shared }

    var body: some View {
        let scheduling = (try? env.store.relationships(to: record.id, kind: .schedules).map(\.from)) ?? []
        let linked = ([record].filter { CalendarLinker.linkedValues($0) != nil } + env.objects(scheduling))
        Section("Calendar") {
            ForEach(linked) { event in
                LinkedEventRow(record: event) { editing = CalendarEditTarget(id: event.id) }
            }
            if CalendarLinker.linkedValues(record) == nil {
                Button("Schedule in Calendar", systemImage: "calendar.badge.plus") { editing = CalendarEditTarget(id: record.id) }
            }
        }
        .sheet(item: $editing) { target in
            CalendarEventEditor(target: target.id, sync: sync).environment(env)
        }
    }
}

/// One linked event: when, where, which calendar, and whether Calendar
/// still has it. The truth badge is the start time's (recorded by the
/// person, or by the calendar after a change there).
struct LinkedEventRow: View {
    @Environment(NexusEnvironment.self) private var env
    let record: ObjectRecord
    let edit: () -> Void

    var body: some View {
        let values = record.attributes
        HStack {
            VStack(alignment: .leading) {
                Text(values.text(CalendarKey.title) ?? record.title)
                if let start = values.date(CalendarKey.start), let end = values.date(CalendarKey.end) {
                    Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text([values.text(CalendarKey.location), values.text(CalendarKey.calendarTitle)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if values[CalendarKey.removed]?.value == .bool(true) {
                    Label("Removed in Calendar", systemImage: "calendar.badge.minus").font(.caption)
                }
                if let provenance = values[CalendarKey.start]?.provenance {
                    Text("Last set by \(env.describe(provenance.origin))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TruthBadge(record.truth(of: CalendarKey.start) ?? record.provenance.truth)
            Button("Edit", action: edit).buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
    }
}

extension [String: Attribute] {
    fileprivate func text(_ key: String) -> String? {
        if case .string(let text)? = self[key]?.value, !text.isEmpty { return text }
        return nil
    }

    fileprivate func date(_ key: String) -> Date? {
        if case .date(let date)? = self[key]?.value { return date }
        return nil
    }
}

/// The week's calendar events as fixed time, read-only.
struct FixedTimeSection: View {
    let sync: CalendarSync

    var body: some View {
        Section("Your calendar this week") {
            if !sync.calendarAccess {
                Text("Allow Calendar access to see fixed events here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sync.events) { event in
                VStack(alignment: .leading) {
                    Text(event.title)
                    Text(
                        "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendar)"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
