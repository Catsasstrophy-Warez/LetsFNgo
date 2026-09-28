#if canImport(SwiftUI)
import Foundation
import NexusActions
import NexusAutomation
import NexusAgents
import NexusCore
import NexusDemo
import NexusDocuments
import NexusGraph
import NexusInvestigation
import NexusLearning
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusProjects
import NexusResearch
import NexusSearch
import NexusSync
import NexusTasks
import Observation

/// The composition root: one store and every runtime over it.
///
/// Views read through the runtimes and observe `revision`, which advances
/// whenever the store's change feed reports committed work, so every screen
/// refreshes from the canonical model rather than from copies.
@MainActor
@Observable
public final class NexusEnvironment {
    public let store: NexusStore
    public let graph: ObjectGraph
    public let search: SearchEngine
    public let projects: ProjectRuntime
    public let investigations: InvestigationRuntime
    public let permissions: PermissionEngine
    public let context: ContextRuntime
    public let tasks: TaskRuntime
    public let documents: DocumentLibrary
    /// Carries out every command against the store, as `user`.
    public let actions: ActionExecutor
    /// Runs commands for the UI: input forms, navigation, errors.
    public let commands = CommandRunner()
    public let research: ResearchRuntime
    public let learning: LearningRuntime
    public let reviews: ReviewRuntime
    public let learners: LearnerRecords
    /// Rules that act on the store's changes; started with the environment.
    public let automation: AutomationRuntime
    /// iCloud sync, off by default. The app supplies the transport.
    public let sync: SyncController
    /// Set by the app once a language model is available on this device.
    public var agents: AgentRuntime?
    /// Names of the installed language models, for Settings.
    public var installedModels: [String] = []
    /// Rebuilds the model list, e.g. after a cloud key changes. Set by the app.
    @ObservationIgnored public var reinstallModels: (@MainActor () async -> Void)?
    /// Mirrors an agent run somewhere outside the app (a Live Activity).
    /// Receives the goal and the run's events; runs off the main actor.
    @ObservationIgnored public var runMirror: (@Sendable (String, AsyncStream<AgentEvent>) async -> Void)?
    /// Transcribes an audio file on device (Speech). Set by the app.
    @ObservationIgnored public var transcribe: (@Sendable (URL) async throws -> String)?
    /// Reads an equipment nameplate in a photo and returns matching objects
    /// (Vision OCR). Set by the app.
    @ObservationIgnored public var identifyNameplate: (@MainActor (Data) async throws -> [ObjectID])?
    public private(set) var demo: DemoWorld?
    /// Advances on every committed change; read it in `body` to refresh.
    public private(set) var revision = 0
    /// The person using the app, as an origin for their edits.
    public let user: Origin

    @ObservationIgnored private var observation: ChangeObservation?

    public init(store: NexusStore, user: Origin = .user(id: "local"), seedDemo: Bool = false) throws {
        self.store = store
        self.user = user
        graph = ObjectGraph(store: store)
        // Full text fused with semantic vectors ("xmtr" finds a transmitter).
        search = (try? SearchEngine.withVectors(store: store, graph: graph)) ?? SearchEngine(store: store, graph: graph)
        projects = ProjectRuntime(store: store, graph: graph)
        investigations = InvestigationRuntime(store: store)
        permissions = try PermissionEngine(store: store)
        context = ContextRuntime(store: store)
        tasks = TaskRuntime(store: store)
        documents = DocumentLibrary(store: store, pdfExtractor: DocumentLibrary.platformPDFExtractor)
        research = ResearchRuntime(store: store)
        learning = LearningRuntime(store: store)
        reviews = ReviewRuntime(store: store)
        learners = LearnerRecords(store: store)
        let seeded = seedDemo ? try DemoWorld.seedIfNeeded(into: store) : nil
        let loops = seeded.map { [LoopBinding(loop: $0.loop, faults: [$0.fault], tests: $0.tests)] } ?? []
        actions = ActionExecutor(
            store: store, graph: graph, projects: projects, investigations: investigations, tasks: tasks, documents: documents,
            learning: learning, searchEngine: search, actor: user, loops: loops
        )
        automation = AutomationRuntime(store: store, permissions: permissions, loops: loops)
        sync = SyncController(store: store)
        // Observable properties are set only once every stored `let` is.
        demo = seeded
        commands.env = self
        try? automation.start()
        observation = store.observeChanges { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        }
    }

    /// The on-disk store in Application Support, created on first launch.
    public static func live(seedDemo: Bool) throws -> NexusEnvironment {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Nexus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // Encrypted at rest by Data Protection; readable after first unlock so
        // Spotlight indexing and background agent runs keep working.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path
        )
        #endif
        let store = try NexusStore(.file(directory.appendingPathComponent("nexus.sqlite")))
        return try NexusEnvironment(store: store, seedDemo: seedDemo)
    }

    /// An in-memory environment with the demo world, for previews and UI tests.
    public static func preview() -> NexusEnvironment {
        do {
            return try NexusEnvironment(store: try NexusStore(.inMemory), seedDemo: true)
        } catch {
            fatalError("Preview environment failed: \(error)")
        }
    }

    // MARK: Convenience reads (views call these inside `body`)

    public func object(_ id: ObjectID?) -> ObjectRecord? {
        _ = revision
        guard let id else { return nil }
        return try? store.object(id)
    }

    public func objects(_ ids: [ObjectID]) -> [ObjectRecord] {
        _ = revision
        return (try? store.objects(ids)) ?? []
    }

    public func title(_ id: ObjectID) -> String {
        object(id)?.title ?? id.description
    }

    /// Who or what an origin is, in words.
    public func describe(_ origin: Origin) -> String {
        switch origin {
        case .user(let id): id == "local" ? "You" : id
        case .agent(let id, _): "Agent \(id)"
        case .importer(let source): "Imported from \(title(source))"
        case .simulation: "Simulation"
        case .instrument(let id): title(id)
        case .model(let ref): ref.modelID
        case .system: "Nexus"
        }
    }
}
#endif
