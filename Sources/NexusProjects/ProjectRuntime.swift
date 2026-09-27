import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence

public enum ProjectError: Error, Equatable, Sendable {
    case notAProject(ObjectID)
    case notAMember(object: ObjectID, project: ObjectID)
}

/// Projects are bounded context over the one global graph, not folders.
/// Membership is a `contains` relationship from the project, so an object can
/// belong to several projects without being copied, and leaving a project
/// ends the relationship rather than deleting it.
public struct ProjectRuntime: Sendable {
    public let store: NexusStore
    public let graph: ObjectGraph
    private let clock: NexusClock

    public init(store: NexusStore, graph: ObjectGraph, clock: NexusClock = SystemClock()) {
        self.store = store
        self.graph = graph
        self.clock = clock
    }

    @discardableResult
    public func createProject(
        title: String,
        mission: String? = nil,
        objectives: [String] = [],
        by author: Origin
    ) throws -> ObjectRecord {
        var attributes: [String: Attribute] = [:]
        if let mission { attributes["mission"] = Attribute(.string(mission)) }
        if !objectives.isEmpty { attributes["objectives"] = Attribute(.list(objectives.map(Value.string))) }
        return try store.create(ObjectRecord(
            type: .project, title: title, attributes: attributes,
            provenance: Provenance(origin: author, truth: Self.truth(for: author), timestamp: clock.now())
        ))
    }

    /// Adds `object` to `project`. Idempotent: an existing current membership is returned as is.
    @discardableResult
    public func add(_ object: ObjectID, to project: ObjectID, by author: Origin) throws -> Relationship {
        try requireProject(project)
        if let existing = try membership(of: object, in: project) {
            return existing
        }
        let now = clock.now()
        return try store.relate(Relationship(
            kind: .contains, from: project, to: object, validFrom: now,
            provenance: Provenance(origin: author, truth: Self.truth(for: author), timestamp: now)
        ))
    }

    /// Ends `object`'s membership in `project`. The object itself is untouched.
    public func remove(_ object: ObjectID, from project: ObjectID, by author: Origin) throws {
        try requireProject(project)
        guard let membership = try membership(of: object, in: project) else {
            throw ProjectError.notAMember(object: object, project: project)
        }
        try store.end(membership.id, at: clock.now(), by: author)
    }

    /// Current members, directly or (with `transitive`) through nested containment.
    public func members(
        of project: ObjectID,
        types: Set<ObjectType>? = nil,
        transitive: Bool = false
    ) throws -> [ObjectRecord] {
        try requireProject(project)
        let reached = try graph.traverse(
            from: project, kinds: [.contains], direction: .outgoing, maxDepth: transitive ? .max : 1
        )
        return try store.objects(reached.map(\.id))
            .filter { $0.lifecycle != .deleted && (types?.contains($0.type) ?? true) }
    }

    /// Projects that currently contain `object` directly.
    public func projects(containing object: ObjectID) throws -> [ObjectRecord] {
        let containers = try graph.edges(of: object, kinds: [.contains], direction: .incoming).map(\.neighbor)
        return try store.objects(containers).filter { $0.type == .project }
    }

    private func membership(of object: ObjectID, in project: ObjectID) throws -> Relationship? {
        try graph.edges(of: project, kinds: [.contains], direction: .outgoing)
            .first { $0.neighbor == object }?
            .relationship
    }

    private func requireProject(_ id: ObjectID) throws {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .project else { throw ProjectError.notAProject(id) }
    }

    /// Organizing done by people or the system is recorded fact; organizing
    /// proposed by an agent or model stays an interpretation until confirmed.
    static func truth(for author: Origin) -> TruthClass {
        switch author {
        case .agent, .model: .agentInterpretation
        default: .recorded
        }
    }
}
