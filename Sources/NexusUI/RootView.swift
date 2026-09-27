#if canImport(SwiftUI)
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
                        Button { env.context.open(.search) } label: { Label("New", systemImage: "plus.circle.fill") }
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
                            perform(command.id)
                            dismiss()
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

    private func perform(_ id: String) {
        switch id {
        case "open": env.context.open(.objectDetail)
        case "search": env.context.open(.search)
        case "investigate": env.context.open(.investigation)
        case "simulate", "trace": env.context.open(.simulation)
        case "measure": env.context.open(.telemetry)
        case "ask", "analyze": env.context.open(.agentActivity)
        case "compare", "runAnalysis", "group", "export": env.context.open(.collection)
        default: env.context.open(.commandCenter)
        }
    }
}

/// The Intelligence panel: what the selection can do, and a place to ask.
struct IntelligencePanel: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var goal = ""
    @State private var running = false
    @State private var lastOutput: String?

    var body: some View {
        Form {
            Section("Selection") {
                let focus = env.object(env.context.focus)
                Text(focus?.title ?? "Nothing selected")
                if let focus { TruthBadge(focus.provenance.truth) }
            }
            Section("Ask") {
                TextField("Ask about the selection", text: $goal, axis: .vertical)
                Button(running ? "Working…" : "Ask") { ask() }
                    .disabled(goal.isEmpty || running || env.agents == nil)
                if env.agents == nil {
                    Text("No language model is available on this device yet.").font(.caption).foregroundStyle(.secondary)
                }
                if let lastOutput {
                    Text(lastOutput).textSelection(.enabled)
                    TruthBadge(.agentInterpretation)
                }
            }
        }
        .navigationTitle("Intelligence")
    }

    private func ask() {
        guard let agents = env.agents else { return }
        running = true
        let request = AgentRequestFactory.request(goal: goal, env: env)
        Task {
            let result = try? await agents.run(request, as: .diagnostician, approver: AlertApprover.shared)
            lastOutput = result?.output ?? "The run did not complete."
            running = false
        }
    }
}
#endif
