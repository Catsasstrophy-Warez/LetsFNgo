#if canImport(AppIntents) && canImport(SwiftUI)
import AppIntents
import Foundation
import NexusAgents
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusProjects
import NexusSearch
import NexusUI

/// Any canonical object, as Siri, Shortcuts, Spotlight actions and Visual
/// Intelligence see it. The identifier is the ObjectID, so every system
/// surface resolves to the same object the app shows.
public struct NexusObjectEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nexus Object"
    public static let defaultQuery = NexusObjectQuery()

    public let id: String
    public let title: String
    public let kind: String

    public init(id: String, title: String, kind: String) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind)")
    }
}

public struct NexusObjectQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [NexusObjectEntity] {
        try await MainActor.run {
            let env = try AppleIntelligence.requireEnvironment()
            return env.objects(identifiers.compactMap(ObjectID.init)).map(NexusObjectEntity.init(record:))
        }
    }

    public func entities(matching string: String) async throws -> [NexusObjectEntity] {
        try await MainActor.run {
            let env = try AppleIntelligence.requireEnvironment()
            let hits = try env.search.search(SearchQuery(string, limit: 20))
            return hits.map { NexusObjectEntity(id: $0.id.description, title: $0.title, kind: $0.type.rawValue) }
        }
    }

    public func suggestedEntities() async throws -> [NexusObjectEntity] {
        try await MainActor.run {
            let env = try AppleIntelligence.requireEnvironment()
            guard let project = env.context.activeProject ?? env.demo?.project else { return [] }
            return try env.projects.members(of: project).map(NexusObjectEntity.init(record:))
        }
    }
}

extension NexusObjectEntity {
    init(record: ObjectRecord) {
        self.init(id: record.id.description, title: record.title, kind: record.type.rawValue)
    }

    var objectID: ObjectID {
        get throws {
            guard let id = ObjectID(id) else { throw AppleIntelligenceError.notFound(title) }
            return id
        }
    }
}

/// An `OpenIntent`, so the system can open any Nexus object it surfaces
/// (Spotlight, Siri, Visual Intelligence results).
public struct OpenObjectIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open in Nexus"
    public static let description = IntentDescription("Opens an object, keeping it as the context for everything else.")
    public static let openAppWhenRun = true

    @Parameter(title: "Object") public var target: NexusObjectEntity

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try AppleIntelligence.requireEnvironment().context.open(try target.objectID, from: .command)
        return .result()
    }
}

public struct AskNexusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask Nexus"
    public static let description = IntentDescription("Asks the on-device assistant about your projects and equipment.")

    @Parameter(title: "Question") public var question: String

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try AppleIntelligence.requireEnvironment()
        guard let agents = env.agents else { throw AppleIntelligenceError.unavailable("Apple Intelligence") }
        let request = AgentRequest(goal: question, project: env.context.activeProject ?? env.demo?.project, focus: env.context.selection)
        let result = try await agents.run(request, as: .diagnostician, approver: SiriApprover())
        return .result(dialog: "\(result.output.isEmpty ? "I couldn't finish that." : result.output)")
    }
}

public struct StartInvestigationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Investigation"
    public static let openAppWhenRun = true

    @Parameter(title: "Equipment") public var subject: NexusObjectEntity
    @Parameter(title: "Symptom") public var symptom: String

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<NexusObjectEntity> {
        let env = try AppleIntelligence.requireEnvironment()
        let investigation = try env.investigations.open(symptom: symptom, subjects: [try subject.objectID], by: env.user)
        if let project = env.context.activeProject ?? env.demo?.project {
            try env.projects.add(investigation.id, to: project, by: env.user)
        }
        try env.context.open(investigation.id, in: .investigation, from: .command)
        return .result(value: NexusObjectEntity(record: investigation))
    }
}

public struct MeasureIntent: AppIntent {
    public static let title: LocalizedStringResource = "Measure"
    public static let openAppWhenRun = true

    @Parameter(title: "Test point") public var point: NexusObjectEntity

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try AppleIntelligence.requireEnvironment().context.open(try point.objectID, in: .telemetry, from: .command)
        return .result()
    }
}

public struct RunSimulationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Run Simulation"
    public static let openAppWhenRun = true

    @Parameter(title: "Equipment") public var equipment: NexusObjectEntity

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try AppleIntelligence.requireEnvironment().context.open(try equipment.objectID, in: .simulation, from: .command)
        return .result()
    }
}

public struct CreateTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "Create Task"

    @Parameter(title: "Task") public var task: String
    @Parameter(title: "About") public var about: NexusObjectEntity?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<NexusObjectEntity> & ProvidesDialog {
        let env = try AppleIntelligence.requireEnvironment()
        let record = try env.store.create(ObjectRecord(
            type: .task, title: task, attributes: ["status": Attribute(.string("open"))],
            provenance: Provenance(origin: env.user, truth: .recorded, timestamp: Date(), method: "Siri")
        ))
        if let about {
            try env.store.relate(Relationship(
                kind: .dependsOn, from: record.id, to: try about.objectID,
                provenance: Provenance(origin: env.user, truth: .recorded, timestamp: Date())
            ))
        }
        if let project = env.context.activeProject ?? env.demo?.project {
            try env.projects.add(record.id, to: project, by: env.user)
        }
        return .result(value: NexusObjectEntity(record: record), dialog: "Added “\(task)”.")
    }
}

/// Siri runs have no alert to show, so anything that needs approval is declined
/// and left for the person to do in the app.
struct SiriApprover: ApprovalHandler {
    func approve(_ request: PermissionRequest, reason: String) async -> Bool { false }
}

/// Lets the app target include this package's intents in its metadata.
public struct NexusIntentsPackage: AppIntentsPackage {}
#endif

#if canImport(AppIntents) && canImport(SwiftUI)
/// Opens the investigation workspace; used by the Control Center control.
public struct OpenInvestigationsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Investigations"
    public static let openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try AppleIntelligence.requireEnvironment().context.open(.investigation)
        return .result()
    }
}
#endif
