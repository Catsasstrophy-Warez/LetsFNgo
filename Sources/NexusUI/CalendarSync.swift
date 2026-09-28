#if canImport(SwiftUI) && canImport(EventKit)
import EventKit
import Foundation
import NexusCore
import NexusModel
import NexusTasks
import SwiftUI

/// The person's own calendar and reminders, through EventKit. Calendar
/// events are shown as fixed time but never copied into the store; tasks
/// are sent to Reminders on request, and the reminder's id is kept on the
/// task (recorded, by the person) so it isn't added twice.
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

    private(set) var events: [Fixed] = []
    private(set) var calendarAccess = false
    @ObservationIgnored private let store = EKEventStore()

    static let reminderKey = "reminderID"

    func loadWeek() async {
        do {
            calendarAccess = try await store.requestFullAccessToEvents()
        } catch {
            calendarAccess = false
        }
        guard calendarAccess else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(7 * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map {
            Fixed(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate, calendar: $0.calendar?.title ?? "")
        }
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
                    Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendar)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
