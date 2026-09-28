#if canImport(SwiftUI)
import Foundation
import NexusCRM
import NexusCore
import NexusModel
import SwiftUI
import UniformTypeIdentifiers

/// People in the Project screen: who is past their keep-in-touch cadence,
/// vCard and address-book import, and follow-up tasks for the overdue.
struct ContactsSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var importing = false
    @State private var readingAddressBook = false
    @State private var summary: String?
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let contacts = ContactsRuntime(store: env.store)
        let overdue = (try? contacts.overdue(asOf: Date())) ?? []
        return Section("Keep in touch (\(overdue.count) overdue)") {
            ForEach(overdue.prefix(8), id: \.contact.id) { standing in
                Button { try? env.context.open(standing.contact.id, from: .project) } label: {
                    HStack {
                        Text(standing.contact.name)
                        Spacer()
                        Text(standing.daysSince.map { "\($0) days" } ?? "Never").font(.caption)
                        TruthBadge(standing.truth)
                    }
                }
            }
            Button("Create follow-ups for overdue people", systemImage: "person.badge.clock") { scheduleFollowUps() }.disabled(overdue.isEmpty)
            Button("Import contacts (.vcf)", systemImage: "person.crop.rectangle.stack") { importing = true }
            #if canImport(Contacts)
            Button(readingAddressBook ? "Reading Contacts…" : "Import from Contacts", systemImage: "person.2.circle") { importAddressBook() }
                .disabled(readingAddressBook)
            #endif
            if let summary { Label(summary, systemImage: "checkmark.circle").font(.caption) }
            if let error { ClassifiedErrorView(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.vCard, .data]) { importVCards($0) }
    }

    private func scheduleFollowUps() {
        do {
            let tasks = try ContactsRuntime(store: env.store).scheduleFollowUps(asOf: Date(), by: env.user)
            summary = "Added \(tasks.count) follow-up task(s)."
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func importVCards(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let imported = try ContactImporter(store: env.store).importVCards(Data(contentsOf: url), named: url.lastPathComponent, by: env.user)
            summary = "Added \(imported.created.count) people and updated \(imported.merged.count); \(imported.unchanged) unchanged."
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing from the file was stored; an import is all or nothing.")
        }
    }

    #if canImport(Contacts)
    private func importAddressBook() {
        readingAddressBook = true
        Task {
            defer { readingAddressBook = false }
            do {
                let imported = try await AppleContacts.importAll(into: env.store, by: env.user)
                summary = "Contacts: added \(imported.created.count) people and updated \(imported.merged.count); \(imported.unchanged) unchanged."
                error = nil
            } catch {
                self.error = classify(error).preserving("Your address book was only read, never changed.")
            }
        }
    }
    #endif
}

/// A person inside Object Detail: last contact and cadence (derived),
/// interactions, logging one, and follow-ups.
struct PersonDomainView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var channel = InteractionChannel.call
    @State private var note = ""
    @State private var error: ClassifiedError?

    private static let cadences = [0, 14, 30, 60, 90, 180, 365]

    var body: some View {
        _ = env.revision
        let contacts = ContactsRuntime(store: env.store)
        return Group {
            if let standing = try? contacts.standing(of: id, asOf: Date()) {
                Section("Relationship") {
                    HStack {
                        LabeledContent("Last contacted", value: standing.lastContacted?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                        TruthBadge(standing.truth)
                    }
                    Picker("Keep in touch", selection: Binding(get: { standing.contact.cadenceDays ?? 0 }, set: { setCadence($0) })) {
                        ForEach(Self.cadences, id: \.self) { days in
                            Text(days == 0 ? "Default (\(ContactsRuntime.defaultCadenceDays) days)" : "Every \(days) days").tag(days)
                        }
                    }
                    if standing.isOverdue { Label("\(standing.daysOverdue) days past the cadence", systemImage: "clock.badge.exclamationmark") }
                    ForEach((try? contacts.organizations(of: id)) ?? []) { organization in
                        Button { try? env.context.open(organization.id, from: .collection) } label: { LabeledContent("Works at", value: organization.title) }
                    }
                }
                Section("Log an interaction") {
                    Picker("How", selection: $channel) {
                        ForEach(InteractionChannel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    TextField("What was it about?", text: $note)
                    Button("Log") { log(name: standing.contact.name) }.disabled(note.isEmpty)
                }
                Section("Interactions") {
                    let interactions = (try? contacts.interactions(with: id)) ?? []
                    if interactions.isEmpty { Text("None logged.").foregroundStyle(.secondary) }
                    ForEach(interactions.prefix(20)) { event in
                        HStack {
                            LabeledContent(event.summary, value: event.at.formatted(date: .abbreviated, time: .omitted)).font(.callout)
                            TruthBadge(event.provenance.truth)
                        }
                    }
                }
                Section("Follow-ups") {
                    ForEach((try? contacts.followUps(for: id)) ?? []) { task in
                        Button(task.title) { try? env.context.open(task.id, from: .collection) }
                    }
                    Button("Add follow-up in a week", systemImage: "plus") { addFollowUp() }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
    }

    private func setCadence(_ days: Int) {
        do {
            _ = try ContactsRuntime(store: env.store).setCadence(days == 0 ? nil : days, for: id, by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func log(name: String) {
        do {
            _ = try ContactsRuntime(store: env.store).logInteraction(
                with: [id], channel: channel, summary: "\(channel.rawValue.capitalized) with \(name): \(note)", note: note, by: env.user)
            note = ""
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func addFollowUp() {
        do {
            _ = try ContactsRuntime(store: env.store).addFollowUp(with: id, due: Date().addingTimeInterval(7 * 86_400), by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}
#endif
