#if canImport(SwiftUI)
import Foundation
import NexusCore
import NexusDocuments
import NexusModel
import NexusTasks
import SwiftUI
import UniformTypeIdentifiers

/// Objective, owner, dependencies, gate, success condition, status. Tasks go
/// through `TaskRuntime`, so an agent's tasks stay drafts until a person
/// approves them and "done" needs a person and the required evidence.
struct TaskWorkflowScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var filter = Filter.ready
    @State private var newTitle = ""
    @State private var newCondition = ""
    @State private var error: String?

    enum Filter: String, CaseIterable {
        case ready = "Ready"
        case blocked = "Blocked"
        case drafts = "Drafts"
        case all = "All"
    }

    private var project: ObjectID? { env.context.activeProject ?? env.demo?.project }

    var body: some View {
        _ = env.revision
        let tasks = load()
        return Form {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Section("New task") {
                TextField("What needs doing", text: $newTitle)
                TextField("Done when… (success condition)", text: $newCondition)
                Button("Create task") { create() }.disabled(newTitle.isEmpty)
            }
            Section(filter.rawValue) {
                if tasks.isEmpty {
                    NextActionEmptyState("No \(filter.rawValue.lowercased()) tasks", message: nextAction, systemImage: "checklist")
                }
                ForEach(tasks) { task in
                    NavigationLink {
                        TaskDetail(id: task.id).environment(env)
                    } label: {
                        TaskRow(task: task)
                    }
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle") }
            }
        }
        .formStyle(.grouped)
    }

    private var nextAction: String {
        switch filter {
        case .ready: "Create a task above, or turn meeting notes into tasks from Meetings."
        case .blocked: "Nothing is waiting on another task or on evidence."
        case .drafts: "Tasks proposed by agents appear here for approval."
        case .all: "Create a task above."
        }
    }

    private func load() -> [TaskItem] {
        let all = (try? project.map { try env.tasks.tasks(in: $0) } ?? env.tasks.allTasks()) ?? []
        switch filter {
        case .ready: return (try? env.tasks.ready(in: project)) ?? []
        case .blocked: return (try? env.tasks.blocked(in: project)) ?? []
        case .drafts: return all.filter(\.isDraft)
        case .all: return all
        }
    }

    private func create() {
        do {
            try env.tasks.create(newTitle, successCondition: newCondition.isEmpty ? nil : newCondition, in: project, by: env.user)
            newTitle = ""
            newCondition = ""
            error = nil
        } catch {
            self.error = "The task wasn't created: \(error). Nothing was saved."
        }
    }
}

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(task.title)
                Spacer()
                Label(task.status.rawValue, systemImage: symbol).font(.caption).labelStyle(.titleAndIcon)
            }
            HStack {
                if task.isDraft { Text("Draft").font(.caption.bold()) }
                if let due = task.dueAt { Text("Due \(due.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                if let condition = task.successCondition { Text("Done when \(condition)").font(.caption).lineLimit(1) }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch task.status {
        case .open: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}

struct TaskDetail: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var error: String?

    var body: some View {
        _ = env.revision
        return Form {
            if let task = try? env.tasks.task(id) {
                let gate = try? env.tasks.gate(for: id)
                Section("Objective") {
                    Text(task.title).font(.headline)
                    LabeledContent("Owner", value: env.describe(task.owner))
                    if let condition = task.successCondition { LabeledContent("Success condition", value: condition) }
                    if let due = task.dueAt { LabeledContent("Due", value: due.formatted()) }
                    LabeledContent("Status", value: task.status.rawValue)
                }
                Section("Gate") {
                    if gate?.isOpen ?? true {
                        Label("Nothing is holding this task.", systemImage: "checkmark.seal")
                    }
                    ForEach(gate?.unfinishedDependencies ?? [], id: \.self) { dependency in
                        Label("Waiting on \(env.title(dependency))", systemImage: "arrow.turn.down.right")
                    }
                    ForEach(Array((gate?.missingEvidence ?? []).enumerated()), id: \.offset) { _, requirement in
                        Label("Needs evidence: \(String(describing: requirement))", systemImage: "doc.badge.ellipsis")
                    }
                }
                Section("Dependencies") {
                    let dependencies = (try? env.tasks.dependencies(of: id)) ?? []
                    if dependencies.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(dependencies) { TaskRow(task: $0) }
                }
                Section("Actions") {
                    if task.isDraft {
                        Button("Approve draft") { act { _ = try env.tasks.approve(id, by: env.user) } }
                    }
                    ForEach(TaskStatus.allCases.filter { task.status.canMove(to: $0) }, id: \.self) { next in
                        Button("Mark \(next.rawValue)") { act { _ = try env.tasks.setStatus(next, of: id, by: env.user) } }
                    }
                    Button("Open as object") { try? env.context.open(id, from: .collection) }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle") }
                }
            } else {
                NextActionEmptyState("Task not found", message: "It may have been deleted. Go back to Tasks.", systemImage: "checklist")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Task")
    }

    private func act(_ work: () throws -> Void) {
        do {
            try work()
            error = nil
        } catch {
            self.error = "Not changed: \(error). The task keeps its previous state."
        }
    }
}

/// Fixed, flexible and conditional time. Fixed: work with a due date.
/// Flexible: open work with no date. Conditional: work that starts when
/// other work (a future state of the system) is done.
struct CalendarScreen: View {
    @Environment(NexusEnvironment.self) private var env
    #if canImport(EventKit)
    @State private var sync = CalendarSync()
    @State private var error: ClassifiedError?
    #endif

    var body: some View {
        _ = env.revision
        let project = env.context.activeProject ?? env.demo?.project
        let open = ((try? project.map { try env.tasks.tasks(in: $0) } ?? env.tasks.allTasks()) ?? []).filter { !$0.status.isClosed }
        let fixed = open.filter { $0.dueAt != nil }.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        let conditional = open.filter { $0.dueAt == nil && !((try? env.tasks.gate(for: $0.id))?.isOpen ?? true) }
        let flexible = open.filter { task in task.dueAt == nil && !conditional.contains { $0.id == task.id } }
        let days = Dictionary(grouping: fixed) { Calendar.current.startOfDay(for: $0.dueAt ?? .distantFuture) }
        return Form {
            if open.isEmpty {
                NextActionEmptyState("Nothing scheduled", message: "Create tasks in Tasks; give them a due date to fix them in time.", systemImage: "calendar")
            }
            #if canImport(EventKit)
            FixedTimeSection(sync: sync)
            if let error { Section { ClassifiedErrorView(error) } }
            #endif
            ForEach(days.keys.sorted(), id: \.self) { day in
                Section(day.formatted(date: .complete, time: .omitted)) {
                    ForEach(days[day] ?? []) { task in
                        TaskRow(task: task)
                        #if canImport(EventKit)
                        if task.record.attributes[CalendarSync.reminderKey] == nil {
                            Button("Add to Reminders", systemImage: "checklist") { sendToReminders(task) }.font(.caption)
                        }
                        #endif
                    }
                }
            }
            let waiting = (try? env.tasks.waitingOnConditions()) ?? []
            if !waiting.isEmpty {
                Section("Conditional — starts when the system reaches a state") {
                    ForEach(waiting) { task in
                        VStack(alignment: .leading) {
                            TaskRow(task: task)
                            ForEach(((try? env.tasks.conditions(for: task.id)) ?? []), id: \.self) { condition in
                                Label(condition.label, systemImage: "bolt.horizontal.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !flexible.isEmpty {
                Section("Flexible — any time") { ForEach(flexible) { TaskRow(task: $0) } }
            }
            if !conditional.isEmpty {
                Section("Conditional — waiting on other work") {
                    ForEach(conditional) { task in
                        VStack(alignment: .leading) {
                            TaskRow(task: task)
                            let waiting = ((try? env.tasks.gate(for: task.id))?.unfinishedDependencies ?? []).map(env.title)
                            Text("after \(waiting.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if canImport(EventKit)
        .task { await sync.loadWeek() }
        #endif
    }

    #if canImport(EventKit)
    private func sendToReminders(_ task: TaskItem) {
        Task {
            do {
                try await sync.sendToReminders(task, env: env)
                error = nil
            } catch {
                self.error = classify(error).preserving("The task is unchanged.")
            }
        }
    }
    #endif
}

/// Mission, objectives, and the project's objects grouped by what they are.
struct ProjectScreen: View {
    @Environment(NexusEnvironment.self) private var env

    private struct MemberGroup {
        var title: String
        var types: Set<ObjectType>
    }

    private static let groups: [MemberGroup] = [
        MemberGroup(title: "Equipment", types: [.equipment, .component, .sensor, .signal, .testPoint, .instrument]),
        MemberGroup(title: "Knowledge", types: [.document, .source, .claim]),
        MemberGroup(title: "Decisions", types: [.decision]),
        MemberGroup(title: "Work", types: [.task, .procedure]),
        MemberGroup(title: "Investigations", types: [.investigation, .hypothesis]),
        MemberGroup(title: "People", types: [.person, .organization]),
        MemberGroup(title: "Outputs", types: [.artifact, "report", "trainingScenario"]),
    ]

    var body: some View {
        _ = env.revision
        let projectID = env.context.activeProject ?? env.demo?.project
        return Group {
            if let projectID, let project = env.object(projectID) {
                let members = (try? env.projects.members(of: projectID, transitive: true)) ?? []
                Form {
                    Section("Mission") {
                        Text(project.title).font(.headline)
                        if case .string(let mission)? = project.attributes["mission"]?.value { Text(mission) }
                        if case .list(let objectives)? = project.attributes["objectives"]?.value {
                            ForEach(Array(objectives.enumerated()), id: \.offset) { _, objective in
                                if case .string(let text) = objective { Label(text, systemImage: "target") }
                            }
                        }
                    }
                    GarageSection()
                    MoneySection()
                    TravelSection()
                    ContactsSection()
                    CareerSection()
                    SpacesSection()
                    ForEach(Self.groups, id: \.title) { group in
                        let items = members.filter { group.types.contains($0.type) }
                        if !items.isEmpty {
                            Section("\(group.title) (\(items.count))") {
                                ForEach(items) { record in
                                    Button { try? env.context.open(record.id, from: .project) } label: { ObjectRow(record: record) }
                                }
                            }
                        }
                    }
                    let known = Set(Self.groups.flatMap(\.types))
                    let other = members.filter { !known.contains($0.type) }
                    if !other.isEmpty {
                        Section("Other") {
                            ForEach(other) { record in
                                Button { try? env.context.open(record.id, from: .project) } label: { ObjectRow(record: record) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                NextActionEmptyState("No project open", message: "Open a project from Search or ⌘K.", systemImage: "folder")
            }
        }
    }
}

/// Documents in the library: import, read passages, and turn a passage into
/// a claim that cites it verbatim.
struct DocumentScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var importing = false
    @State private var error: String?
    @State private var claimFor: Passage?

    var body: some View {
        _ = env.revision
        let focus = env.object(env.context.focus)
        return Group {
            if let focus, focus.type == .document {
                reader(focus)
            } else {
                library
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText]) { result in
            importFile(result)
        }
        .sheet(item: $claimFor) { passage in
            ClaimSheet(passage: passage).environment(env)
        }
    }

    private var library: some View {
        let documents = (try? env.store.objects(ofType: .document)) ?? []
        return Form {
            Section {
                Button { importing = true } label: { Label("Import document", systemImage: "square.and.arrow.down") }
            }
            Section("Library") {
                if documents.isEmpty {
                    NextActionEmptyState("No documents", message: "Import a manual, datasheet or procedure to cite it.", systemImage: "doc.text")
                }
                ForEach(documents) { record in
                    Button { try? env.context.open(record.id, in: .document, from: .collection) } label: { ObjectRow(record: record) }
                }
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle") } }
        }
        .formStyle(.grouped)
    }

    private func reader(_ document: ObjectRecord) -> some View {
        let passages = (try? env.documents.passages(of: document.id)) ?? []
        let state = try? env.documents.extractionState(of: document.id)
        return List {
            Section {
                Text(document.title).font(.headline)
                if state == .needsExtraction {
                    Label("Text hasn't been extracted from this file yet.", systemImage: "doc.badge.clock")
                }
                if case .string(let body)? = document.attributes["body"]?.value, passages.isEmpty {
                    Text(body)
                }
            }
            ForEach(passages) { passage in
                VStack(alignment: .leading, spacing: 6) {
                    if let section = passage.section { Text(section).font(.caption.bold()) }
                    Text(passage.text).textSelection(.enabled)
                    let claims = (try? env.documents.claims(citing: passage.id)) ?? []
                    ForEach(claims, id: \.id) { claim in
                        Label(claim.statement, systemImage: "quote.bubble").font(.caption)
                    }
                    Button("Make a claim from this passage") { claimFor = passage }.font(.caption)
                }
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let type = UTType(filenameExtension: url.pathExtension)
            let mediaType = type?.conforms(to: .pdf) == true ? "application/pdf" : (url.pathExtension == "md" ? "text/markdown" : "text/plain")
            let project = env.context.activeProject ?? env.demo?.project
            let ingested = try env.documents.ingest(data, title: url.deletingPathExtension().lastPathComponent, mediaType: mediaType, in: project, by: env.user)
            try env.context.open(ingested.document.id, in: .document, from: .collection)
            error = nil
        } catch {
            self.error = "Import failed: \(error). The library is unchanged."
        }
    }
}

struct ClaimSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let passage: Passage
    @State private var statement = ""
    @State private var sourceClass = SourceClass.primary
    @State private var applicability = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Passage") { Text(passage.text).font(.callout) }
                Section("Claim") {
                    TextField("What the passage asserts", text: $statement, axis: .vertical)
                    Picker("Source class", selection: $sourceClass) {
                        ForEach(SourceClass.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    TextField("Applies to (configuration, model, range)", text: $applicability)
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle") } }
            }
            .navigationTitle("New claim")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(statement.isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            try env.documents.extractClaim(
                from: passage.id, statement: statement, sourceClass: sourceClass,
                applicability: applicability.isEmpty ? nil : applicability, by: env.user
            )
            dismiss()
        } catch {
            self.error = "Not saved: \(error). The passage is unchanged."
        }
    }
}
#endif
