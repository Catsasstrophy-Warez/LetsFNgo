#if canImport(SwiftUI)
import NexusAgents
import NexusCore
import NexusGraph
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusProjects
import NexusSearch
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
            case .objectDetail, .research: ObjectDetailScreen(id: env.context.focus)
            case .document: DocumentScreen()
            case .taskWorkflow: TaskWorkflowScreen()
            case .calendar: CalendarScreen()
            case .investigation: InvestigationScreen()
            case .simulation: DigitalTwinScreen()
            case .telemetry: TelemetryScreen()
            case .timeline: TimelineScreen()
            case .agentActivity: AgentActivityScreen()
            case .settings: PermissionsScreen()
            case .conversation, .meeting, .creative:
                NextActionEmptyState(
                    env.context.screen.title, message: "This workspace arrives after the Golden Slice. Use Search or ⌘K meanwhile.",
                    systemImage: env.context.screen.symbol
                )
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

/// Now / Continue: open investigations and recent changes.
struct CommandCenterScreen: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        _ = env.revision
        let investigations = (try? env.store.objects(ofType: .investigation)) ?? []
        let open = investigations.filter { $0.attributes["status"]?.value != .string("closed") }
        let recent = ((try? env.store.changes(after: max(0, env.store.latestChangeSequence - 20))) ?? []).reversed()
        return List {
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
            Section("Recently changed") {
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
                            Text(command.title)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
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

    var body: some View {
        _ = env.revision
        let results = query.isEmpty ? [] : ((try? env.search.search(SearchQuery(query, truth: truth.map { [$0] }, limit: 50))) ?? [])
        return List(results) { result in
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
        .overlay {
            if query.isEmpty {
                NextActionEmptyState("Search everything", message: "Type a tag, a title, a phrase from a manual, or paste an object ID.", systemImage: "magnifyingglass")
            }
        }
        .searchable(text: $query)
        .toolbar {
            Picker("Truth", selection: $truth) {
                Text("Any truth").tag(TruthClass?.none)
                ForEach(TruthClass.allCases, id: \.self) { Text($0.label).tag(TruthClass?.some($0)) }
            }
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
                Section("Revisions") {
                    ForEach(revisions) { revision in
                        LabeledContent("#\(revision.sequence) \(revision.instruction ?? "")", value: revision.at.formatted(date: .abbreviated, time: .shortened))
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
        } else {
            NextActionEmptyState("Nothing selected", message: "Select an object in the context list, in 3D, or with ⌘K.", systemImage: "cube")
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
