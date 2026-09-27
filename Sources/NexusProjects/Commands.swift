import NexusModel

/// Where a command sits in the permission model (P0–P5 in the handoff).
public enum PermissionLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    case observe = 0
    case analyze = 1
    case createDraft = 2
    case modifyInternalState = 3
    case externalAction = 4
    case sensitive = 5

    public static func < (lhs: PermissionLevel, rhs: PermissionLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Command: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var permission: PermissionLevel

    public init(id: String, title: String, permission: PermissionLevel) {
        self.id = id
        self.title = title
        self.permission = permission
    }
}

/// Contributes commands for a selection. Domain modules register their own
/// providers, so selecting a test point offers Measure without the core
/// knowing anything about measurement.
public protocol CommandProvider: Sendable {
    func commands(for selection: [ObjectRecord]) -> [Command]
}

/// The universal grammar: what any selection can do, by selection size.
public struct UniversalCommands: CommandProvider {
    public init() {}

    public func commands(for selection: [ObjectRecord]) -> [Command] {
        switch selection.count {
        case 0:
            [
                Command(id: "ask", title: "Ask", permission: .analyze),
                Command(id: "create", title: "Create", permission: .createDraft),
                Command(id: "search", title: "Search", permission: .observe),
                Command(id: "run", title: "Run", permission: .modifyInternalState),
            ]
        case 1:
            [
                Command(id: "open", title: "Open", permission: .observe),
                Command(id: "ask", title: "Ask", permission: .analyze),
                Command(id: "analyze", title: "Analyze", permission: .analyze),
                Command(id: "link", title: "Link", permission: .modifyInternalState),
            ]
        default:
            [
                Command(id: "compare", title: "Compare", permission: .analyze),
                Command(id: "group", title: "Group", permission: .modifyInternalState),
                Command(id: "export", title: "Export", permission: .createDraft),
                Command(id: "runAnalysis", title: "Run Analysis", permission: .analyze),
            ]
        }
    }
}

/// Engineering selections expose Trace / Measure / Simulate / Investigate.
/// Lives here until NexusEngineering exists; it will move there.
public struct EngineeringCommands: CommandProvider {
    static let physical: Set<ObjectType> = [.equipment, .component, .sensor, .signal, .testPoint]

    public init() {}

    public func commands(for selection: [ObjectRecord]) -> [Command] {
        guard !selection.isEmpty, selection.allSatisfy({ Self.physical.contains($0.type) }) else { return [] }
        var commands = [
            Command(id: "trace", title: "Trace", permission: .analyze),
            Command(id: "simulate", title: "Simulate", permission: .modifyInternalState),
            Command(id: "investigate", title: "Start Investigation", permission: .createDraft),
        ]
        if selection.contains(where: { $0.type == .testPoint }) {
            commands.insert(Command(id: "measure", title: "Measure", permission: .createDraft), at: 1)
        }
        return commands
    }
}

public struct CommandRegistry: Sendable {
    public var providers: [any CommandProvider]

    public init(providers: [any CommandProvider] = [UniversalCommands(), EngineeringCommands()]) {
        self.providers = providers
    }

    /// Commands from every provider, in provider order, first occurrence of an ID winning.
    public func commands(for selection: [ObjectRecord]) -> [Command] {
        var seen: Set<String> = []
        return providers
            .flatMap { $0.commands(for: selection) }
            .filter { seen.insert($0.id).inserted }
    }
}
