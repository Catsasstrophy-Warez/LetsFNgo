#if canImport(SwiftUI)
import Foundation
import NexusAgents
import NexusCore
import NexusDemo
import NexusGraph
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusProjects
import NexusSearch
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
    /// Set by the app once a language model is available on this device.
    public var agents: AgentRuntime?
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
        search = SearchEngine(store: store, graph: graph)
        projects = ProjectRuntime(store: store, graph: graph)
        investigations = InvestigationRuntime(store: store)
        permissions = try PermissionEngine(store: store)
        context = ContextRuntime(store: store)
        if seedDemo {
            demo = try DemoWorld.seedIfNeeded(into: store)
        }
        observation = store.observeChanges { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        }
    }

    /// The on-disk store in Application Support, created on first launch.
    public static func live(seedDemo: Bool) throws -> NexusEnvironment {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Nexus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
}
#endif
