import Foundation
import NexusCore
import NexusModel
import NexusPersistence

public enum Direction: Sendable, Hashable {
    case outgoing
    case incoming
    case both
}

/// Which relationships count, by their validity interval.
public enum Validity: Sendable, Hashable {
    /// Valid at the graph clock's current time.
    case current
    /// Valid at a specific instant (`validFrom <= date < validTo`).
    case at(Date)
    /// Every relationship ever recorded, ended or not.
    case any
}

/// One hop: a relationship seen from one of its endpoints.
public struct Edge: Sendable, Hashable {
    public var relationship: Relationship
    public var neighbor: ObjectID
    /// `.outgoing` when the relationship points away from the object asked about.
    public var direction: Direction
}

/// An object reached during traversal and the edges that led to it.
public struct Reach: Sendable, Hashable {
    public var id: ObjectID
    public var depth: Int
    public var path: [Edge]
}

/// Typed traversal over the relationships held in `NexusStore`. The graph owns
/// no state of its own: every query reads the canonical store.
public struct ObjectGraph: Sendable {
    public let store: NexusStore
    private let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Relationships touching `id`, ordered deterministically by neighbor then relationship ID.
    public func edges(
        of id: ObjectID,
        kinds: Set<RelationKind>? = nil,
        direction: Direction = .both,
        validity: Validity = .current
    ) throws -> [Edge] {
        var edges: [Edge] = []
        if direction != .incoming {
            edges += try store.relationships(from: id).map { Edge(relationship: $0, neighbor: $0.to, direction: .outgoing) }
        }
        if direction != .outgoing {
            edges += try store.relationships(to: id).map { Edge(relationship: $0, neighbor: $0.from, direction: .incoming) }
        }
        let instant = instant(for: validity)
        return edges
            .filter { kinds?.contains($0.relationship.kind) ?? true }
            .filter { instant.map($0.relationship.isValid(at:)) ?? true }
            .sorted { ($0.neighbor, $0.relationship.id) < ($1.neighbor, $1.relationship.id) }
    }

    /// Breadth-first reachability from `root`, excluding `root` itself. Each
    /// object appears once, at its shortest depth. Cycles are safe.
    public func traverse(
        from root: ObjectID,
        kinds: Set<RelationKind>? = nil,
        direction: Direction = .outgoing,
        maxDepth: Int = .max,
        validity: Validity = .current
    ) throws -> [Reach] {
        var visited: Set<ObjectID> = [root]
        var frontier = [Reach(id: root, depth: 0, path: [])]
        var reached: [Reach] = []
        while !frontier.isEmpty, let depth = frontier.first?.depth, depth < maxDepth {
            var next: [Reach] = []
            for node in frontier {
                for edge in try edges(of: node.id, kinds: kinds, direction: direction, validity: validity)
                where visited.insert(edge.neighbor).inserted {
                    next.append(Reach(id: edge.neighbor, depth: depth + 1, path: node.path + [edge]))
                }
            }
            reached += next
            frontier = next
        }
        return reached
    }

    /// The shortest chain of relationships from `start` to `goal`, or nil.
    public func shortestPath(
        from start: ObjectID,
        to goal: ObjectID,
        kinds: Set<RelationKind>? = nil,
        direction: Direction = .both,
        maxDepth: Int = 16,
        validity: Validity = .current
    ) throws -> [Edge]? {
        if start == goal { return [] }
        var visited: Set<ObjectID> = [start]
        var frontier = [Reach(id: start, depth: 0, path: [])]
        for depth in 0..<maxDepth {
            var next: [Reach] = []
            for node in frontier {
                for edge in try edges(of: node.id, kinds: kinds, direction: direction, validity: validity)
                where visited.insert(edge.neighbor).inserted {
                    let reach = Reach(id: edge.neighbor, depth: depth + 1, path: node.path + [edge])
                    if edge.neighbor == goal { return reach.path }
                    next.append(reach)
                }
            }
            if next.isEmpty { return nil }
            frontier = next
        }
        return nil
    }

    private func instant(for validity: Validity) -> Date? {
        switch validity {
        case .current: clock.now()
        case .at(let date): date
        case .any: nil
        }
    }
}

extension Relationship {
    /// Whether the relationship holds at `date`: `validFrom <= date < validTo`,
    /// with open ends unbounded.
    public func isValid(at date: Date) -> Bool {
        if let validFrom, date < validFrom { return false }
        if let validTo, date >= validTo { return false }
        return true
    }
}
