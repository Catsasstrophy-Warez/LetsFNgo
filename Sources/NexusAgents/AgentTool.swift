import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPersistence

/// What a tool can see and who it acts as.
public struct ToolContext: Sendable {
    public var store: NexusStore
    public var run: ObjectID
    public var agentID: String
    public var project: ObjectID?
    public var clock: NexusClock

    /// Everything a tool writes is attributed to this agent run.
    public var origin: Origin { .agent(id: agentID, run: run) }

    public func provenance(method: String? = nil, dependencies: [ObjectID] = []) -> Provenance {
        Provenance(origin: origin, truth: .agentInterpretation, timestamp: clock.now(), method: method, dependencies: dependencies)
    }
}

public struct ToolOutcome: Sendable, Hashable {
    /// Text returned to the model.
    public var content: String
    /// Objects read or referenced.
    public var touched: [ObjectID]
    /// Objects created.
    public var produced: [ObjectID]

    public init(content: String, touched: [ObjectID] = [], produced: [ObjectID] = []) {
        self.content = content
        self.touched = touched
        self.produced = produced
    }
}

/// What a tool call touches, for permission scoping: the object types it
/// reads or writes, the data source it reads from, and the external service
/// it reaches. Policies can allow or forbid by each of them, and approvals
/// are remembered per scope.
public struct ToolScope: Sendable, Hashable {
    public var objectTypes: Set<ObjectType>
    public var dataSource: String?
    public var service: String?

    public init(objectTypes: Set<ObjectType> = [], dataSource: String? = nil, service: String? = nil) {
        self.objectTypes = objectTypes
        self.dataSource = dataSource
        self.service = service
    }

    /// Data sources tools declare.
    public static let worldModel = "world"
    public static let documents = "documents"
    public static let measurements = "measurements"
    public static let tasks = "tasks"
    public static let meetings = "meetings"
}

/// A capability an agent can invoke. The runtime runs each call inside a
/// store batch, so a tool that throws leaves no partial writes behind.
///
/// Before the call the runtime asks the tool for its `scope` and puts it on
/// the permission request, so a rule such as "never touch hypotheses" or
/// "ask before using the email service" applies to it.
public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// The scope every call has, whatever its arguments.
    var declaredScope: ToolScope { get }
    /// The scope of one call. Default: `declaredScope`. Tools that act on a
    /// target object add the target's type.
    func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope
    func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome
}

extension AgentTool {
    public var declaredScope: ToolScope { ToolScope() }

    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope { declaredScope }
}

/// Runs another agent as a sub-run of the current one. Handed to a
/// `DelegatingTool` by the runtime.
public struct Delegation: Sendable {
    /// The run that is delegating.
    public let parentRun: ObjectID
    /// How many delegations deep the new run will be (1 for the first).
    public let depth: Int
    let runner: @Sendable (AgentProfile, String) async throws -> AgentRunResult

    /// Runs `goal` under `profile`, as a separate run linked to the parent.
    public func run(_ goal: String, as profile: AgentProfile) async throws -> AgentRunResult {
        try await runner(profile, goal)
    }
}

/// A tool that runs other agents. It is not run inside a store batch: the
/// sub-run's own tool calls are each atomic.
public protocol DelegatingTool: AgentTool {
    func delegate(_ arguments: [String: Value], in context: ToolContext, via delegation: Delegation) async throws -> ToolOutcome
}

public enum ToolError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingArgument(String)
    case invalidArgument(String)
    case notFound(String)
    /// The call is well-formed but not allowed, with the reason.
    case refused(String)

    public var description: String {
        switch self {
        case .missingArgument(let name): "Missing argument '\(name)'"
        case .invalidArgument(let name): "Invalid argument '\(name)'"
        case .notFound(let what): "Not found: \(what)"
        case .refused(let reason): "Refused: \(reason)"
        }
    }
}

extension Dictionary where Key == String, Value == NexusModel.Value {
    func string(_ key: String) throws -> String {
        guard case .string(let text)? = self[key] else { throw ToolError.missingArgument(key) }
        return text
    }

    func optionalString(_ key: String) -> String? {
        if case .string(let text)? = self[key] { return text }
        return nil
    }

    /// A string that must be present and not blank, at most `maxLength` characters.
    func text(_ key: String, maxLength: Int = 2_000) throws -> String {
        let text = try string(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { throw ToolError.invalidArgument(key) }
        return text
    }

    /// An optional string; present but blank or too long is invalid.
    func optionalText(_ key: String, maxLength: Int = 2_000) throws -> String? {
        guard let value = self[key], value != .null else { return nil }
        guard case .string(let raw) = value else { throw ToolError.invalidArgument(key) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { throw ToolError.invalidArgument(key) }
        return text
    }

    func optionalObjectID(_ key: String) throws -> ObjectID? {
        guard let value = self[key], value != .null else { return nil }
        if case .string(let text) = value, text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return try objectID(key)
    }

    /// Object IDs given as a list, or as one ID.
    func objectIDs(_ key: String) throws -> [ObjectID] {
        switch self[key] {
        case nil, .null?: return []
        case .list(let values)?:
            return try values.map { value in
                switch value {
                case .reference(let id): return id
                case .string(let text):
                    guard let id = ObjectID(text) else { throw ToolError.invalidArgument(key) }
                    return id
                default: throw ToolError.invalidArgument(key)
                }
            }
        default: return [try objectID(key)]
        }
    }

    /// An optional whole number within `range`; numbers as text are accepted.
    func optionalInt(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = self[key], value != .null else { return nil }
        let number = try double(key)
        guard number == number.rounded(), let whole = Int(exactly: number), range.contains(whole) else { throw ToolError.invalidArgument(key) }
        return whole
    }

    func optionalBool(_ key: String) throws -> Bool? {
        switch self[key] {
        case nil, .null?: return nil
        case .bool(let flag)?: return flag
        case .string(let text)?:
            switch text.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: throw ToolError.invalidArgument(key)
            }
        default: throw ToolError.invalidArgument(key)
        }
    }

    /// An optional number within `range`.
    func optionalDouble(_ key: String, in range: ClosedRange<Double>) throws -> Double? {
        guard let value = self[key], value != .null else { return nil }
        let number = try double(key)
        guard range.contains(number) else { throw ToolError.invalidArgument(key) }
        return number
    }

    func objectID(_ key: String) throws -> ObjectID {
        switch self[key] {
        case .reference(let id)?: return id
        case .string(let text)?:
            guard let id = ObjectID(text) else { throw ToolError.invalidArgument(key) }
            return id
        default: throw ToolError.missingArgument(key)
        }
    }

    func double(_ key: String) throws -> Double {
        switch self[key] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        case .string(let text)?:
            // Models often send numbers as text; accept them, reject anything else.
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else {
                throw ToolError.invalidArgument(key)
            }
            return value
        default: throw ToolError.missingArgument(key)
        }
    }
}
