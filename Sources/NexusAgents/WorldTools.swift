import Foundation
import NexusAI
import NexusCore
import NexusGraph
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusSearch

/// Tools over the canonical world model. They read through the same store,
/// graph and search as the UI; writes are agent interpretations or drafts.
public enum WorldTools {
    /// Every tool: the world-model tools, then tasks, documents, meetings,
    /// research, the read-only domain tools and delegation.
    public static var all: [any AgentTool] {
        world + WorkTools.all + DomainTools.all + [DelegateTool()]
    }

    /// Tools over objects, relationships and measurements.
    public static var world: [any AgentTool] {
        [SearchObjects(), GetObject(), RelatedObjects(), GetMeasurements(), ProposeHypothesis(), AnnotateObject(), SendMessage()]
    }
}

/// The type of the object `key` names, for permission scoping. Empty when
/// the argument is missing or names nothing: the call then fails in `run`.
func targetTypes(_ arguments: [String: Value], _ key: String, in context: ToolContext) throws -> Set<ObjectType> {
    guard let id = try? arguments.objectID(key), let record = try context.store.object(id) else { return [] }
    return [record.type]
}

func objectArg(_ description: String) -> Value {
    .map(["type": .string("string"), "description": .string(description)])
}

func schema(_ properties: [String: Value], required: [String]) -> Value {
    .map(["type": .string("object"), "properties": .map(properties), "required": .list(required.map(Value.string))])
}

/// P0. Full-text search, scoped to the run's project when there is one.
public struct SearchObjects: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "search_objects", description: "Search the world model by text. Returns IDs, types and titles.",
        parameters: schema(["query": objectArg("Words to search for")], required: ["query"]), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(dataSource: ToolScope.worldModel) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let graph = ObjectGraph(store: context.store, clock: context.clock)
        let engine = SearchEngine(store: context.store, graph: graph)
        let results = try engine.search(SearchQuery(try arguments.string("query"), scope: context.project, limit: 10))
        let lines = results.map { "\($0.id) [\($0.type)] \($0.title)" }
        return ToolOutcome(content: lines.isEmpty ? "No matches." : lines.joined(separator: "\n"), touched: results.map(\.id))
    }
}

/// P0. An object with each attribute's truth class, so the model can tell
/// an observation from an interpretation.
public struct GetObject: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "get_object", description: "Read one object, with each attribute's truth class.",
        parameters: schema(["id": objectArg("Object ID")], required: ["id"]), permission: .observe
    )

    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope {
        ToolScope(objectTypes: try targetTypes(arguments, "id", in: context), dataSource: ToolScope.worldModel)
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("id")
        guard let record = try context.store.object(id) else { throw ToolError.notFound(id.description) }
        var lines = ["\(record.title) [\(record.type)] (\(record.provenance.truth.rawValue))"]
        for key in record.attributes.keys.sorted() {
            lines.append("- \(key) = \(render(record.attributes[key]!.value)) (\(record.truth(of: key)!.rawValue))")
        }
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: [id])
    }
}

/// P0. Current relationships of an object.
public struct RelatedObjects: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "related_objects", description: "List objects related to an object and how.",
        parameters: schema(["id": objectArg("Object ID")], required: ["id"]), permission: .observe
    )

    /// The object and every neighbor it would reveal.
    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope {
        var types = try targetTypes(arguments, "id", in: context)
        if !types.isEmpty, let id = try? arguments.objectID("id") {
            let edges = try ObjectGraph(store: context.store, clock: context.clock).edges(of: id)
            types.formUnion(try context.store.objects(edges.map(\.neighbor)).map(\.type))
        }
        return ToolScope(objectTypes: types, dataSource: ToolScope.worldModel)
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("id")
        let graph = ObjectGraph(store: context.store, clock: context.clock)
        let edges = try graph.edges(of: id)
        let neighbors = try context.store.objects(edges.map(\.neighbor))
        let titles = Dictionary(uniqueKeysWithValues: neighbors.map { ($0.id, $0.title) })
        let lines = edges.map { edge in
            let arrow = edge.direction == .outgoing ? "→" : "←"
            return "\(arrow) \(edge.relationship.kind) \(edge.neighbor) \(titles[edge.neighbor] ?? "?")"
        }
        return ToolOutcome(content: lines.isEmpty ? "No relationships." : lines.joined(separator: "\n"), touched: [id] + edges.map(\.neighbor))
    }
}

/// P0. Readings at a test point, each labeled with its truth class.
public struct GetMeasurements: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "get_measurements", description: "Readings at a test point, labeled observed/modeled/display/etc.",
        parameters: schema(["test_point": objectArg("Test point ID")], required: ["test_point"]), permission: .observe
    )

    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope {
        ToolScope(objectTypes: try targetTypes(arguments, "test_point", in: context).union([.measurement]), dataSource: ToolScope.measurements)
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let point = try arguments.objectID("test_point")
        let readings = try context.store.measurements(at: point)
        let lines = readings.map { "\($0.id) \($0.quantityName) = \($0.value.value) \($0.value.unit) (\($0.truth.rawValue)\($0.loading.map { ", " + $0 } ?? ""))" }
        return ToolOutcome(content: lines.isEmpty ? "No readings." : lines.joined(separator: "\n"), touched: [point] + readings.map(\.id))
    }
}

/// P2. Adds a hypothesis to an investigation, as the agent's interpretation.
public struct ProposeHypothesis: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "propose_hypothesis",
        description: "Propose a cause in an investigation, with a testable prediction at one test point.",
        parameters: schema([
            "investigation": objectArg("Investigation ID"), "statement": objectArg("The proposed cause"),
            "test_point": objectArg("Where it predicts a value"), "quantity": objectArg("Quantity name"),
            "unit": objectArg("Unit"), "low": objectArg("Lowest predicted value"), "high": objectArg("Highest predicted value"),
        ], required: ["investigation", "statement"]),
        permission: .createDraft
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.investigation, .hypothesis]) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let investigation = try arguments.objectID("investigation")
        var predictions: [Prediction] = []
        if arguments["test_point"] != nil {
            predictions.append(Prediction(
                testPoint: try arguments.objectID("test_point"), quantity: try arguments.string("quantity"),
                unit: try arguments.string("unit"), low: try arguments.double("low"), high: try arguments.double("high")
            ))
        }
        let runtime = InvestigationRuntime(store: context.store, clock: context.clock)
        let hypothesis = try runtime.propose(
            try arguments.string("statement"), in: investigation, predictions: predictions, by: context.origin
        )
        return ToolOutcome(content: "Proposed hypothesis \(hypothesis.id)", touched: [investigation], produced: [hypothesis.id])
    }
}

/// P3. Writes a note attribute on an object. The store's truth policy still
/// applies: an agent cannot overwrite recorded or observed values.
public struct AnnotateObject: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "annotate_object", description: "Set a text attribute on an object.",
        parameters: schema(["id": objectArg("Object ID"), "key": objectArg("Attribute"), "value": objectArg("Text")], required: ["id", "key", "value"]),
        permission: .modifyInternalState
    )

    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope {
        ToolScope(objectTypes: try targetTypes(arguments, "id", in: context))
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("id")
        let key = try arguments.string("key")
        let value = try arguments.string("value")
        try context.store.update(id, by: context.origin, instruction: "Agent annotation") {
            $0.attributes[key] = Attribute(.string(value), provenance: context.provenance(method: "annotation"))
        }
        return ToolOutcome(content: "Set \(key) on \(id)", touched: [id])
    }
}

/// P4. Sends a message outside Nexus. Here it only records an outbox event;
/// a real transport plugs in later behind the same permission.
public struct SendMessage: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "send_message", description: "Send a message to a person outside Nexus.",
        parameters: schema([
            "to": objectArg("Recipient"), "text": objectArg("Message"),
            "channel": objectArg("How to send it: message (default), email, sms, …"),
        ], required: ["to", "text"]),
        permission: .externalAction
    )

    /// The channel is the external service, so policy can treat email and SMS differently.
    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope {
        ToolScope(service: try Self.channel(arguments))
    }

    static func channel(_ arguments: [String: Value]) throws -> String {
        guard let channel = try arguments.optionalText("channel", maxLength: 40) else { return "message" }
        guard channel.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            throw ToolError.invalidArgument("channel")
        }
        return channel.lowercased()
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let channel = try Self.channel(arguments)
        let event = Event(
            at: context.clock.now(), kind: .message, subjects: [context.run],
            summary: "To \(try arguments.text("to", maxLength: 200)): \(try arguments.text("text", maxLength: 10_000))",
            payload: ["outbox": .bool(true), "channel": .string(channel)], provenance: context.provenance(method: "outbox")
        )
        try context.store.record(event)
        return ToolOutcome(content: "Queued message \(event.id)")
    }
}

func render(_ value: Value) -> String {
    switch value {
    case .string(let text): text
    case .int(let number): String(number)
    case .double(let number): String(number)
    case .bool(let flag): String(flag)
    case .date(let date): date.description
    case .quantity(let quantity): "\(quantity.value) \(quantity.unit)"
    case .reference(let id): id.description
    case .list(let values): "[" + values.map(render).joined(separator: ", ") + "]"
    case .map(let map): "{" + map.keys.sorted().map { "\($0): \(render(map[$0]!))" }.joined(separator: ", ") + "}"
    case .null: "null"
    }
}
