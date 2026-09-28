#if canImport(SwiftUI)
import NexusAgents
import NexusAutomotive
import NexusCore
import NexusGraph
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusProjects
import NexusSearch
import PhotosUI
import SwiftUI

/// The workspace shows the current screen family for the focused object.
struct Workspace: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        Group {
            switch env.context.screen {
            case .commandCenter: CommandCenterScreen()
            case .project: ProjectScreen()
            case .collection: CollectionScreen()
            case .search: SearchScreen()
            case .objectDetail: ObjectDetailScreen(id: env.context.focus)
            case .research: ResearchScreen()
            case .meeting: MeetingScreen()
            case .conversation: ConversationScreen()
            case .creative: CreativeScreen()
            case .document: DocumentScreen()
            case .taskWorkflow: TaskWorkflowScreen()
            case .calendar: CalendarScreen()
            case .investigation: InvestigationScreen()
            case .simulation: DigitalTwinScreen()
            case .telemetry: TelemetryScreen()
            case .timeline: TimelineScreen()
            case .agentActivity: AgentActivityScreen()
            case .settings: PermissionsScreen()
            }
        }
        .navigationTitle(env.context.screen.title)
        .toolbar {
            ToolbarItemGroup {
                Button { env.context.back() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!env.context.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                Button { env.context.forward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!env.context.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
    }
}

/// Now, Continue, Watching and Today, with universal Ask / Create / Analyze /
/// Run. Home reports what changed rather than advertising modules.
struct CommandCenterScreen: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        _ = env.revision
        let investigations = (try? env.store.objects(ofType: .investigation)) ?? []
        let open = investigations.filter { $0.attributes["status"]?.value != .string("closed") }
        let recent = ((try? env.store.changes(after: max(0, env.store.latestChangeSequence - 20))) ?? []).reversed()
        let runs = ((try? env.store.objects(ofType: "agentRun")) ?? []).filter { $0.attributes["status"]?.value == .string("running") }
        let ready = (try? env.tasks.ready(in: env.context.activeProject ?? env.demo?.project)) ?? []
        let drafts = ((try? env.tasks.allTasks()) ?? []).filter(\.isDraft)
        let dueToday = ((try? env.tasks.allTasks()) ?? []).filter { task in
            guard let due = task.dueAt, !task.status.isClosed else { return false }
            return Calendar.current.isDateInToday(due) || due < Date()
        }
        return List {
            Section {
                HStack {
                    Button("Ask", systemImage: "sparkles") { env.context.open(.conversation) }
                    Button("Create", systemImage: "plus") { env.commands.run(.create, title: "Create") }
                    Button("Analyze", systemImage: "chart.bar.xaxis") { env.commands.run(.analyze, title: "Analyze") }
                    Button("Run", systemImage: "play") { env.commands.run(.run, title: "Run simulation") }
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
            }
            Section("Now") {
                if runs.isEmpty && drafts.isEmpty {
                    Text("Nothing is running or waiting for approval.").foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    Button { try? env.context.open(run.id, in: .agentActivity, from: .command) } label: {
                        Label(run.title, systemImage: "gearshape.2")
                    }
                }
                ForEach(drafts) { task in
                    Button { env.context.open(.taskWorkflow) } label: { Label("Approve draft: \(task.title)", systemImage: "checkmark.circle.badge.questionmark") }
                }
            }
            Section("Continue") {
                if open.isEmpty {
                    Text("No open investigations. Select equipment and choose Start Investigation (⌘K).").foregroundStyle(.secondary)
                }
                ForEach(open) { record in
                    Button {
                        try? env.context.open(record.id, in: .investigation, from: .command)
                    } label: {
                        Label(record.title, systemImage: "stethoscope")
                    }
                }
            }
            Section("Today") {
                if dueToday.isEmpty && ready.isEmpty {
                    Text("Nothing due. Tasks with a due date show here.").foregroundStyle(.secondary)
                }
                ForEach(dueToday) { TaskRow(task: $0) }
                ForEach(ready.prefix(5)) { TaskRow(task: $0) }
            }
            Section("Watching — recently changed") {
                ForEach(Array(recent), id: \.seq) { change in
                    Button {
                        try? env.context.open(change.object, from: .timeline)
                    } label: {
                        LabeledContent(env.title(change.object), value: change.kind.rawValue)
                    }
                }
            }
        }
    }
}

/// A list with multi-selection; the command surface follows the selection.
struct CollectionScreen: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        let commands = (try? env.context.availableCommands()) ?? []
        ContextColumn()
            .safeAreaInset(edge: .bottom) {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(commands) { command in
                            Button(command.title) { env.commands.run(command.commandID, title: command.title) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .accessibilityIdentifier("command.\(command.id)")
                        }
                    }
                    .padding()
                }
                .accessibilityLabel("Available commands for the selection")
            }
    }
}

struct SearchScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var query = ""
    @State private var truth: TruthClass?
    @State private var type: ObjectType?
    @State private var window = Window.any
    @State private var inProject = false
    @State private var photo: PhotosPickerItem?
    @State private var nameplateMatches: [ObjectID] = []
    @State private var reading = false
    @State private var error: ClassifiedError?

    enum Window: String, CaseIterable {
        case any = "Any time"
        case day = "Last day"
        case week = "Last week"
        case month = "Last month"

        var start: Date? {
            switch self {
            case .any: nil
            case .day: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-30 * 86_400)
            }
        }
    }

    private static let types: [ObjectType] = [.equipment, .component, .testPoint, .document, .claim, .investigation, .hypothesis, .task, .measurement]

    var body: some View {
        _ = env.revision
        let project = inProject ? (env.context.activeProject ?? env.demo?.project) : nil
        let search = SearchQuery(
            query, types: type.map { [$0] }, truth: truth.map { [$0] }, updatedFrom: window.start, scope: project, limit: 50
        )
        let results = query.isEmpty ? [] : ((try? env.search.search(search)) ?? [])
        return List {
            if !nameplateMatches.isEmpty {
                Section("From the nameplate photo") {
                    ForEach(nameplateMatches, id: \.self) { id in
                        Button(env.title(id)) { try? env.context.open(id, from: .search) }
                    }
                }
            }
            if reading { ProgressView("Reading the nameplate on device…") }
            if let error { ClassifiedErrorView(error) }
            Section {
                ForEach(results) { result in
                    Button {
                        try? env.context.open(result.id, from: .search)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(result.title)
                            Text("\(result.type.rawValue) · \(result.matchedBy.map(\.rawValue).sorted().joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if query.isEmpty && nameplateMatches.isEmpty {
                NextActionEmptyState("Search everything", message: "Type a tag, a title, a phrase from a manual, paste an object ID, or photograph a nameplate.", systemImage: "magnifyingglass")
            }
        }
        .searchable(text: $query)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Type", selection: $type) {
                        Text("Any type").tag(ObjectType?.none)
                        ForEach(Self.types, id: \.self) { Text($0.rawValue).tag(ObjectType?.some($0)) }
                    }
                    Picker("Truth", selection: $truth) {
                        Text("Any truth").tag(TruthClass?.none)
                        ForEach(TruthClass.allCases, id: \.self) { Text($0.label).tag(TruthClass?.some($0)) }
                    }
                    Picker("Changed", selection: $window) {
                        ForEach(Window.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Only this project", isOn: $inProject)
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                if env.identifyNameplate != nil {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Nameplate photo", systemImage: "camera.viewfinder")
                    }
                }
            }
        }
        .onChange(of: photo) { identify() }
    }

    private func identify() {
        guard let photo, let identify = env.identifyNameplate else { return }
        reading = true
        Task {
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                nameplateMatches = try await identify(data)
                error = nameplateMatches.isEmpty
                    ? ClassifiedError(category: .dataSource, whatHappened: "No equipment matched the text on that nameplate.", nextActions: [NextAction("Type the tag instead")])
                    : nil
            } catch {
                self.error = classify(error).preserving("Search is unchanged.")
            }
            reading = false
        }
    }
}

/// Identity, attributes with truth, relationships, revisions and timeline.
struct ObjectDetailScreen: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID?

    var body: some View {
        if let record = env.object(id) {
            let edges = (try? env.graph.edges(of: record.id)) ?? []
            let revisions = (try? env.store.revisions(of: record.id)) ?? []
            let events = (try? env.store.events(about: record.id)) ?? []
            Form {
                Section("Identity") {
                    LabeledContent("Title", value: record.title)
                    LabeledContent("Type", value: record.type.rawValue)
                    LabeledContent("Lifecycle", value: record.lifecycle.rawValue)
                    HStack { Text("Provenance"); Spacer(); TruthBadge(record.provenance.truth) }
                    LabeledContent("ID", value: record.id.description).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("Attributes") {
                    ForEach(record.attributes.keys.sorted(), id: \.self) { key in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(key).font(.caption).foregroundStyle(.secondary)
                                Text(render(record.attributes[key]!.value)).textSelection(.enabled)
                            }
                            Spacer()
                            TruthBadge(record.truth(of: key) ?? record.provenance.truth)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Notes") {
                    NotesEditor(record: record)
                }
                Section("Relationships") {
                    ForEach(edges, id: \.relationship.id) { edge in
                        Button {
                            try? env.context.open(edge.neighbor, from: .collection)
                        } label: {
                            LabeledContent(edge.relationship.kind.rawValue, value: "\(edge.direction == .outgoing ? "→" : "←") \(env.title(edge.neighbor))")
                        }
                    }
                }
                if record.type == .vehicle {
                    VehicleDomainView(id: record.id)
                }
                #if canImport(PencilKit) && os(iOS)
                Section { MarkupButton(subject: record.id) }
                #endif
                Section("Actions") {
                    let commands = CommandRegistry().commands(for: [record]).filter { $0.commandID != .open }
                    ForEach(commands) { command in
                        Button(command.title) { env.commands.run(command.commandID, title: command.title, selection: [record.id]) }
                            .accessibilityIdentifier("action.\(command.id)")
                    }
                }
                Section("Revisions") {
                    ForEach(revisions.reversed()) { revision in
                        RevisionRow(record: record, revision: revision, isHead: revision.id == revisions.last?.id)
                    }
                }
                Section("Timeline") {
                    ForEach(events) { event in
                        VStack(alignment: .leading) {
                            Text(event.summary)
                            HStack { Text(event.kind.rawValue).font(.caption); TruthBadge(event.provenance.truth) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // Sideways swipe: to the first related object, or back.
            .simultaneousGesture(
                DragGesture(minimumDistance: 40).onEnded { drag in
                    let dx = drag.translation.width
                    guard abs(dx) > 100, abs(dx) > abs(drag.translation.height) * 2 else { return }
                    if dx < 0, let next = edges.first?.neighbor {
                        try? env.context.open(next, from: .collection)
                    } else if dx > 0 {
                        env.context.back()
                    }
                }
            )
        } else {
            NextActionEmptyState("Nothing selected", message: "Select an object in the context list, in 3D, or with ⌘K.", systemImage: "cube")
        }
    }
}

#if canImport(PencilKit) && os(iOS)
struct MarkupButton: View {
    let subject: ObjectID
    @Environment(NexusEnvironment.self) private var env
    @State private var drawing = false

    var body: some View {
        Button("Markup with Pencil", systemImage: "pencil.tip.crop.circle") { drawing = true }
            .fullScreenCover(isPresented: $drawing) { MarkupSheet(subject: subject).environment(env) }
    }
}
#endif

/// One revision: who changed what (with each value's truth class), and a
/// restore that writes a new revision rather than rewriting history.
struct RevisionRow: View {
    @Environment(NexusEnvironment.self) private var env
    let record: ObjectRecord
    let revision: Revision
    let isHead: Bool
    @State private var error: ClassifiedError?

    var body: some View {
        DisclosureGroup {
            if let parent = revision.parent, let diff = try? env.store.diff(of: record.id, from: parent, to: revision.id) {
                if let title = diff.title { Text("Title: \(title.old) → \(title.new)").font(.caption) }
                if let lifecycle = diff.lifecycle { Text("Lifecycle: \(lifecycle.old.rawValue) → \(lifecycle.new.rawValue)").font(.caption) }
                ForEach(diff.attributes, id: \.key) { change in
                    HStack {
                        Text("\(change.key): \(change.old.map { render($0.value) } ?? "—") → \(change.new.map { render($0.value) } ?? "—")")
                            .font(.caption)
                        Spacer()
                        if let truth = change.newTruth ?? change.oldTruth { TruthBadge(truth) }
                    }
                }
                if diff.title == nil && diff.lifecycle == nil && diff.attributes.isEmpty {
                    Text("No field changes").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("First revision").font(.caption).foregroundStyle(.secondary)
            }
            if !isHead {
                Button("Restore this revision") { restore() }
            }
            if let error { ClassifiedErrorView(error) }
        } label: {
            VStack(alignment: .leading) {
                Text("#\(revision.sequence) \(revision.instruction ?? "Edit")")
                Text("\(env.describe(revision.author)) · \(revision.at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func restore() {
        do {
            try env.store.restore(record.id, toRevision: revision.id, by: env.user, instruction: "Restored revision #\(revision.sequence)")
            error = nil
        } catch {
            self.error = classify(error).preserving("The current revision is unchanged.")
        }
    }
}

/// Free-text notes on an object, with Writing Tools. Saved as a revision by
/// the person, so notes carry recorded truth and full history.
struct NotesEditor: View {
    @Environment(NexusEnvironment.self) private var env
    let record: ObjectRecord
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .trailing) {
            TextEditor(text: $text)
                .frame(minHeight: 100)
                .writingToolsBehavior(.complete)
                .accessibilityLabel("Notes for \(record.title)")
            Button("Save notes") {
                _ = try? env.store.update(record.id, by: env.user, instruction: "Edited notes") {
                    $0.attributes["notes"] = Attribute(.string(text))
                }
            }
            .disabled(text == current)
        }
        .onAppear {
            guard !loaded else { return }
            text = current
            loaded = true
        }
    }

    private var current: String {
        if case .string(let notes)? = record.attributes["notes"]?.value { return notes }
        return ""
    }
}

struct TimelineScreen: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        _ = env.revision
        let events = ((try? env.store.timeline()) ?? []).reversed()
        return List(Array(events)) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text(event.summary)
                HStack {
                    Text(event.at.formatted(date: .abbreviated, time: .standard)).font(.caption)
                    Text(event.kind.rawValue).font(.caption.monospaced())
                    TruthBadge(event.provenance.truth)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .overlay {
            if events.isEmpty {
                NextActionEmptyState("No events yet", message: "Measurements, repairs, agent actions and approvals appear here.", systemImage: "clock")
            }
        }
    }
}

/// Every agent run: goal, status, steps, outputs.
struct AgentActivityScreen: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        _ = env.revision
        let runs = ((try? env.store.objects(ofType: .agentRun)) ?? []).reversed()
        return List {
            if runs.isEmpty {
                NextActionEmptyState("No agent runs", message: "Ask a question in the Intelligence panel to start one.", systemImage: "sparkles")
            }
            ForEach(Array(runs)) { run in
                DisclosureGroup {
                    let steps = (try? env.store.events(about: run.id).filter { $0.kind == .agentAction }) ?? []
                    ForEach(steps) { step in
                        HStack(alignment: .top) {
                            Text(phase(of: step)).font(.caption.monospaced()).frame(width: 90, alignment: .leading)
                            Text(step.summary).font(.callout)
                        }
                    }
                    if case .string(let output)? = run.attributes["output"]?.value {
                        VStack(alignment: .leading) {
                            Text(output)
                            TruthBadge(.agentInterpretation)
                        }
                    }
                } label: {
                    LabeledContent(run.title, value: render(run.attributes["status"]?.value ?? .null))
                }
            }
        }
    }

    private func phase(of event: Event) -> String {
        if case .string(let phase)? = event.payload["phase"] { return phase }
        return "step"
    }
}

/// The trust control center: rules by agent, action, level and scope.
struct PermissionsScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var agent = ""
    @State private var action = ""
    @State private var level: PermissionLevel = .modifyInternalState
    @State private var grant: Grant = .askOncePerProject
    @State private var rules: [PolicyRule] = []

    var body: some View {
        Form {
            Section("Defaults") {
                ForEach(PermissionLevel.allCases, id: \.self) { level in
                    LabeledContent("P\(level.rawValue) \(name(level))", value: PermissionEngine.defaultGrant(for: level).rawValue)
                }
                Text("Sensitive actions always ask. External actions can only be pre-approved for a named agent and action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rules") {
                ForEach(rules) { rule in
                    LabeledContent("\(rule.agent ?? "any agent") · \(rule.action ?? "any action")\(rule.level.map { " · P\($0.rawValue)" } ?? "")", value: rule.grant.rawValue)
                }
                .onDelete { offsets in
                    for index in offsets {
                        try? env.permissions.remove(rules[index].id, by: env.user)
                    }
                    rules = env.permissions.rules
                }
            }
            ModelSettingsSection()
            Section("Add rule") {
                TextField("Agent (blank = any)", text: $agent)
                TextField("Action (blank = any)", text: $action)
                Picker("Level", selection: $level) {
                    ForEach(PermissionLevel.allCases, id: \.self) { Text("P\($0.rawValue) \(name($0))").tag($0) }
                }
                Picker("Grant", selection: $grant) {
                    ForEach([Grant.always, .askOncePerProject, .askOncePerSession, .askEveryTime, .never], id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Add") {
                    let rule = PolicyRule(agent: agent.isEmpty ? nil : agent, action: action.isEmpty ? nil : action, level: level, grant: grant)
                    try? env.permissions.add(rule, by: env.user)
                    rules = env.permissions.rules
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { rules = env.permissions.rules }
    }

    private func name(_ level: PermissionLevel) -> String {
        switch level {
        case .observe: "Observe"
        case .analyze: "Analyze"
        case .createDraft: "Create draft"
        case .modifyInternalState: "Modify"
        case .externalAction: "External action"
        case .sensitive: "Sensitive"
        }
    }
}
#endif
