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

/// A capability an agent can invoke. The runtime runs each call inside a
/// store batch, so a tool that throws leaves no partial writes behind.
public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome
}

public enum ToolError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingArgument(String)
    case invalidArgument(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .missingArgument(let name): "Missing argument '\(name)'"
        case .invalidArgument(let name): "Invalid argument '\(name)'"
        case .notFound(let what): "Not found: \(what)"
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
        default: throw ToolError.missingArgument(key)
        }
    }
}
