#if canImport(SwiftUI)
import NexusAgents
import NexusCore
import NexusModel
import NexusProjects
import SwiftUI

extension ScreenFamily {
    var title: String {
        switch self {
        case .commandCenter: "Command Center"
        case .project: "Project"
        case .search: "Search"
        case .objectDetail: "Object"
        case .collection: "Collection"
        case .document: "Document"
        case .research: "Research"
        case .conversation: "Conversation"
        case .meeting: "Meeting"
        case .timeline: "Timeline"
        case .taskWorkflow: "Tasks"
        case .calendar: "Calendar"
        case .investigation: "Investigation"
        case .telemetry: "Telemetry"
        case .simulation: "Digital Twin"
        case .creative: "Creative"
        case .agentActivity: "Agent Activity"
        case .settings: "Settings & Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .commandCenter: "square.grid.2x2"
        case .project: "folder"
        case .search: "magnifyingglass"
        case .objectDetail: "cube"
        case .collection: "list.bullet"
        case .document: "doc.text"
        case .research: "books.vertical"
        case .conversation: "bubble.left.and.bubble.right"
        case .meeting: "person.3"
        case .timeline: "clock"
        case .taskWorkflow: "checklist"
        case .calendar: "calendar"
        case .investigation: "stethoscope"
        case .telemetry: "waveform.path.ecg"
        case .simulation: "cube.transparent"
        case .creative: "paintbrush"
        case .agentActivity: "sparkles"
        case .settings: "lock.shield"
        }
    }
}

/// Mac: Navigation | Context | Workspace | Intelligence.
/// iPad: the same, workspace first, side panels collapsible.
/// iPhone: one object or task full screen, with a contextual bottom bar.
public struct RootView: View {
    @Environment(NexusEnvironment.self) private var env
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showPalette = false
    @State private var showIntelligence = true

    public init() {}

    public var body: some View {
        Group {
            #if os(iOS)
            if sizeClass == .compact {
                CompactRoot(showPalette: $showPalette)
            } else {
                RegularRoot(showIntelligence: $showIntelligence)
            }
            #else
            RegularRoot(showIntelligence: $showIntelligence)
            #endif
        }
        .sheet(isPresented: $showPalette) {
            CommandPalette()
                .environment(env)
        }
        .commandPresentation()
        .background {
            Button("Command Palette") { showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }
}

struct RegularRoot: View {
    @Environment(NexusEnvironment.self) private var env
    @Binding var showIntelligence: Bool

    private var screen: Binding<ScreenFamily?> {
        Binding(get: { env.context.screen }, set: { if let value = $0 { env.context.open(value) } })
    }

    var body: some View {
        NavigationSplitView {
            List(ScreenFamily.allCases, id: \.self, selection: screen) { family in
                Label(family.title, systemImage: family.symbol)
            }
            .navigationTitle("Nexus")
        } content: {
            ContextColumn()
        } detail: {
            Workspace()
                .inspector(isPresented: $showIntelligence) {
                    IntelligencePanel()
                        .inspectorColumnWidth(min: 260, ideal: 320)
                }
                .toolbar {
                    ToolbarItem {
                        Button {
                            showIntelligence.toggle()
                        } label: {
                            Label("Intelligence", systemImage: "sidebar.trailing")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
        }
    }
}

#if os(iOS)
struct CompactRoot: View {
    @Environment(NexusEnvironment.self) private var env
    @Binding var showPalette: Bool
    @State private var showContext = false
    @State private var showIntelligence = false

    var body: some View {
        NavigationStack {
            Workspace()
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { showContext = true } label: { Label("Context", systemImage: "list.bullet.indent") }
                        Spacer()
                        Button { showIntelligence = true } label: { Label("Ask", systemImage: "sparkles") }
                        Spacer()
                        Button { env.commands.run(.create, title: "New") } label: { Label("New", systemImage: "plus.circle.fill") }
                        Spacer()
                        Button { showPalette = true } label: { Label("Actions", systemImage: "bolt") }
                        Spacer()
                        Menu {
                            ForEach(ScreenFamily.allCases, id: \.self) { family in
                                Button { env.context.open(family) } label: { Label(family.title, systemImage: family.symbol) }
                                    .accessibilityIdentifier("screen.\(family.rawValue)")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("more")
                    }
                }
        }
        .sheet(isPresented: $showContext) {
            NavigationStack { ContextColumn() }
                .environment(env)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showIntelligence) {
            NavigationStack { IntelligencePanel() }
                .environment(env)
                .presentationDetents([.medium, .large])
        }
    }
}
#endif

/// The context column: the active project's members, or everything in the demo.
struct ContextColumn: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        let project = env.context.activeProject ?? env.demo?.project
        let members = project.flatMap { try? env.projects.members(of: $0, transitive: true) } ?? []
        let selection = Binding<Set<ObjectID>>(
            get: { Set(env.context.selection) },
            set: { try? env.context.select(Array($0).sorted(), from: .collection) }
        )
        _ = env.revision
        return List(selection: selection) {
            if members.isEmpty {
                NextActionEmptyState("No project open", message: "Open a project from Search or the Command Palette (⌘K).", systemImage: "folder")
            }
            ForEach(members) { record in
                ObjectRow(record: record)
                    .tag(record.id)
                    .onTapGesture(count: 2) { try? env.context.open(record.id, from: .collection) }
            }
        }
        .navigationTitle(project.map(env.title) ?? "Context")
    }
}

struct ObjectRow: View {
    let record: ObjectRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(record.title)
                Text(record.type.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TruthBadge(record.provenance.truth)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Everything the selection can do, plus a search box, behind ⌘K.
struct CommandPalette: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let commands = ((try? env.context.availableCommands()) ?? [])
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let hits = query.count < 2 ? [] : ((try? env.search.search(.init(query, limit: 12))) ?? [])
        NavigationStack {
            List {
                Section("Commands") {
                    ForEach(commands) { command in
                        Button {
                            perform(command)
                        } label: {
                            HStack {
                                Text(command.title)
                                Spacer()
                                Text("P\(command.permission.rawValue)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .accessibilityLabel("Permission level \(command.permission.rawValue)")
                            }
                        }
                    }
                }
                if !hits.isEmpty {
                    Section("Objects") {
                        ForEach(hits) { hit in
                            Button {
                                try? env.context.open(hit.id, from: .search)
                                dismiss()
                            } label: {
                                LabeledContent(hit.title, value: hit.type.rawValue)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Command or object")
            .navigationTitle("Command Palette")
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func perform(_ command: Command) {
        dismiss()
        // Let the palette close before a command's own form can appear.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            env.commands.run(command.commandID, title: command.title)
        }
    }
}

/// The Intelligence panel: what the selection can do, and a place to ask.
struct IntelligencePanel: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var goal = ""
    @State private var task: Task<Void, Never>?
    @State private var streamed = ""
    @State private var steps: [(phase: AgentPhase, summary: String)] = []
    @State private var result: AgentRunResult?
    @State private var failure: String?

    private var running: Bool { task != nil }

    var body: some View {
        Form {
            Section("Selection") {
                let focus = env.object(env.context.focus)
                Text(focus?.title ?? "Nothing selected")
                if let focus { TruthBadge(focus.provenance.truth) }
            }
            Section("Ask") {
                TextField("Ask about the selection", text: $goal, axis: .vertical)
                    .accessibilityIdentifier("ask.field")
                HStack {
                    Button("Ask") { ask() }
                        .disabled(goal.isEmpty || running || env.agents == nil)
                        .accessibilityIdentifier("ask.submit")
                    if running {
                        Button("Stop", role: .cancel) { task?.cancel() }
                    }
                }
                if env.agents == nil {
                    Text("No language model is installed. See Settings → Models.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !steps.isEmpty {
                // Inspectable progress: each ledger step as it happens.
                Section(running ? "Working (\(steps.count) steps)" : "Steps") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        LabeledContent(step.phase.rawValue.capitalized, value: step.summary)
                            .font(.caption)
                    }
                }
            }
            if !streamed.isEmpty || result != nil {
                Section("Answer") {
                    Text(result?.output ?? streamed).textSelection(.enabled)
                    HStack {
                        TruthBadge(.agentInterpretation)
                        if let result {
                            Text("\(result.status.rawValue) · \(result.model.modelID)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let result {
                        Button("Open run") { try? env.context.open(result.run, in: .agentActivity, from: .command) }
                    }
                }
            }
            if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle") }
            }
        }
        .navigationTitle("Intelligence")
    }

    private func ask() {
        guard let agents = env.agents else { return }
        streamed = ""
        steps = []
        result = nil
        failure = nil
        var request = AgentRequestFactory.request(goal: goal, env: env)
        request.privacy = ModelPrivacy.current.requirement
        let (events, sink) = AsyncStream<AgentEvent>.makeStream()
        let (mirrored, mirrorSink) = AsyncStream<AgentEvent>.makeStream()
        if let mirror = env.runMirror {
            let goal = goal
            Task.detached { await mirror(goal, mirrored) }
        } else {
            mirrorSink.finish()
        }
        task = Task {
            let consumer = Task {
                for await event in events { apply(event) }
            }
            do {
                result = try await agents.run(request, as: .diagnostician, approver: AlertApprover.shared) { event in
                    sink.yield(event)
                    mirrorSink.yield(event)
                }
            } catch is CancellationError {
                failure = "Stopped. Steps already recorded stay in the run's ledger; nothing else changed."
            } catch {
                failure = "The run failed: \(error). Completed steps are kept in Agent Activity; partial tool writes were rolled back."
            }
            sink.finish()
            mirrorSink.finish()
            await consumer.value
            task = nil
        }
    }

    private func apply(_ event: AgentEvent) {
        if case .step(let phase, let summary) = event { steps.append((phase, summary)) }
        if case .textDelta(let text) = event { streamed += text }
    }
}
#endif
