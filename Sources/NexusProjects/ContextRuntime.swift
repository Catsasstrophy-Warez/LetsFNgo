import NexusCore
import NexusModel
import NexusPersistence
import Observation

/// The 18 canonical screen families.
public enum ScreenFamily: String, Sendable, Hashable, CaseIterable {
    case commandCenter
    case project
    case search
    case objectDetail
    case collection
    case document
    case research
    case conversation
    case meeting
    case timeline
    case taskWorkflow
    case calendar
    case investigation
    case telemetry
    case simulation
    case creative
    case agentActivity
    case settings
}

/// Where a selection came from. Identity must not depend on it: selecting the
/// same object from search, a 3D view or an investigation yields the same ID.
public enum SelectionSource: Sendable, Hashable {
    case project
    case search
    case collection
    case spatial
    case investigation
    case conversation
    case timeline
    case command
}

public struct Location: Sendable, Hashable {
    public var screen: ScreenFamily
    public var focus: ObjectID?
    public var project: ObjectID?
}

/// Context follows the object. Switching screen family keeps the focused
/// object, so opening Documents, Simulation or Ask while looking at a
/// component keeps that component as the anchor.
@MainActor
@Observable
public final class ContextRuntime {
    public private(set) var screen: ScreenFamily = .commandCenter
    public private(set) var activeProject: ObjectID?
    /// Ordered, unique. The last item selected is the focus.
    public private(set) var selection: [ObjectID] = []
    public private(set) var lastSource: SelectionSource?

    @ObservationIgnored private let store: NexusStore
    @ObservationIgnored private let registry: CommandRegistry
    @ObservationIgnored private var backStack: [Location] = []
    @ObservationIgnored private var forwardStack: [Location] = []

    public init(store: NexusStore, registry: CommandRegistry = CommandRegistry()) {
        self.store = store
        self.registry = registry
    }

    public var focus: ObjectID? { selection.last }

    public var location: Location {
        Location(screen: screen, focus: focus, project: activeProject)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: Selection

    /// Replaces the selection with one object.
    public func select(_ id: ObjectID, from source: SelectionSource) throws {
        try select([id], from: source)
    }

    /// Replaces the selection. Every ID must exist.
    public func select(_ ids: [ObjectID], from source: SelectionSource) throws {
        try requireExisting(ids)
        var seen: Set<ObjectID> = []
        selection = ids.filter { seen.insert($0).inserted }
        lastSource = source
    }

    /// Adds or removes one object, as with Command-click.
    public func toggle(_ id: ObjectID, from source: SelectionSource) throws {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            try requireExisting([id])
            selection.append(id)
        }
        lastSource = source
    }

    public func clearSelection() {
        selection = []
    }

    // MARK: Navigation

    /// Moves to another screen family. The focus and project carry over.
    public func open(_ screen: ScreenFamily) {
        guard screen != self.screen else { return }
        navigate { self.screen = screen }
    }

    /// Selects `id` and opens it in `screen`.
    public func open(_ id: ObjectID, in screen: ScreenFamily = .objectDetail, from source: SelectionSource) throws {
        try requireExisting([id])
        navigate {
            self.selection = [id]
            self.lastSource = source
            self.screen = screen
        }
    }

    public func enterProject(_ id: ObjectID) throws {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .project else { throw ProjectError.notAProject(id) }
        navigate {
            self.activeProject = id
            self.selection = []
            self.screen = .project
        }
    }

    public func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        restore(previous)
    }

    public func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        restore(next)
    }

    // MARK: Commands

    /// The command surface for the current selection.
    public func availableCommands() throws -> [Command] {
        registry.commands(for: try store.objects(selection))
    }

    // MARK: Private

    private func navigate(_ change: () -> Void) {
        let before = location
        change()
        guard location != before else { return }
        backStack.append(before)
        forwardStack.removeAll()
    }

    private func restore(_ location: Location) {
        screen = location.screen
        activeProject = location.project
        selection = location.focus.map { [$0] } ?? []
    }

    private func requireExisting(_ ids: [ObjectID]) throws {
        let found = Set(try store.objects(ids).map(\.id))
        if let missing = ids.first(where: { !found.contains($0) }) {
            throw StoreError.notFound(missing)
        }
    }
}
