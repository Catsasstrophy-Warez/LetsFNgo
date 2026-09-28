import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusSimulation

/// Opaque handle a renderer assigns to one entity. Kept separate from
/// ObjectID so a renderer's identity never leaks into the world model.
public struct EntityHandle: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: UInt64

    public init(_ raw: UInt64) {
        self.raw = raw
    }

    public var description: String { "entity#\(raw)" }

    public static func < (lhs: EntityHandle, rhs: EntityHandle) -> Bool { lhs.raw < rhs.raw }
}

public struct Position: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// One object as it appears in a scene. The scene is a projection of the
/// graph: nodes come from `contains`, links from `connectedTo`.
public struct SceneNode: Hashable, Sendable, Identifiable {
    public var entity: EntityHandle
    public var object: ObjectID
    public var title: String
    public var type: ObjectType
    public var parent: EntityHandle?
    public var position: Position

    public var id: EntityHandle { entity }
}

public struct SceneLink: Hashable, Sendable {
    public var from: EntityHandle
    public var to: EntityHandle
    public var relationship: ObjectID
}

/// A value drawn on a node, labeled with its truth class so an observed
/// reading and a modeled one are never shown as the same thing.
public struct OverlayValue: Hashable, Sendable {
    public var entity: EntityHandle
    public var quantity: String
    public var value: Double
    public var unit: String
    public var truth: TruthClass
}

/// A renderer-independent description of a scene. Renderers build their
/// entities from it and report taps back as `EntityHandle`s.
public struct SceneDescription: Sendable, Hashable {
    public var root: EntityHandle
    public var nodes: [SceneNode]
    public var links: [SceneLink]

    private var byEntity: [EntityHandle: ObjectID] { Dictionary(uniqueKeysWithValues: nodes.map { ($0.entity, $0.object) }) }
    private var byObject: [ObjectID: EntityHandle] { Dictionary(uniqueKeysWithValues: nodes.map { ($0.object, $0.entity) }) }

    /// Selection round-trip: a tapped entity resolves to its canonical object.
    public func object(for entity: EntityHandle) -> ObjectID? { byEntity[entity] }

    /// And back: the entity showing an object in this scene, if any.
    public func entity(for object: ObjectID) -> EntityHandle? { byObject[object] }

    public func node(_ entity: EntityHandle) -> SceneNode? { nodes.first { $0.entity == entity } }
}

public enum SceneBuilder {
    /// Builds a scene rooted at `root`, following `contains` for hierarchy and
    /// `connectedTo` between included objects for links. An object with a
    /// `position` attribute (a list of three numbers) is placed there;
    /// otherwise children are laid out in a row under their parent.
    ///
    /// Entity handles are assigned in deterministic breadth-first order, so
    /// the same graph always yields the same scene.
    public static func build(root: ObjectID, graph: ObjectGraph, spacing: Double = 1) throws -> SceneDescription {
        guard let rootRecord = try graph.store.object(root) else { throw StoreError.notFound(root) }
        var next: UInt64 = 1
        func handle() -> EntityHandle {
            defer { next += 1 }
            return EntityHandle(next)
        }

        let rootNode = SceneNode(
            entity: handle(), object: root, title: rootRecord.title, type: rootRecord.type, parent: nil,
            position: position(of: rootRecord) ?? Position(0, 0, 0)
        )
        var nodes = [rootNode]
        var frontier = [rootNode]
        var included: Set<ObjectID> = [root]
        while !frontier.isEmpty {
            var level: [SceneNode] = []
            for parent in frontier {
                let children = try graph.edges(of: parent.object, kinds: [.contains], direction: .outgoing)
                    .map(\.neighbor).filter { included.insert($0).inserted }
                let records = try graph.store.objects(children)
                for (index, record) in records.enumerated() {
                    let offset = (Double(index) - Double(records.count - 1) / 2) * spacing
                    let fallback = Position(parent.position.x + offset, parent.position.y - spacing, parent.position.z)
                    level.append(SceneNode(
                        entity: handle(), object: record.id, title: record.title, type: record.type,
                        parent: parent.entity, position: position(of: record) ?? fallback
                    ))
                }
            }
            nodes += level
            frontier = level
        }

        let entities = Dictionary(uniqueKeysWithValues: nodes.map { ($0.object, $0.entity) })
        var links: [SceneLink] = []
        for node in nodes {
            for edge in try graph.edges(of: node.object, kinds: [.connectedTo], direction: .outgoing) {
                if let target = entities[edge.neighbor] {
                    links.append(SceneLink(from: node.entity, to: target, relationship: edge.relationship.id))
                }
            }
        }
        return SceneDescription(root: rootNode.entity, nodes: nodes, links: links)
    }

    private static func position(of record: ObjectRecord) -> Position? {
        guard case .list(let values)? = record.attributes["position"]?.value, values.count == 3 else { return nil }
        let numbers = values.compactMap { value -> Double? in
            switch value {
            case .double(let number): number
            case .int(let number): Double(number)
            default: nil
            }
        }
        return numbers.count == 3 ? Position(numbers[0], numbers[1], numbers[2]) : nil
    }
}

public enum OverlayBuilder {
    /// Modeled values from a simulation snapshot, for every node in the scene.
    public static func modeled(_ snapshot: Snapshot, in scene: SceneDescription, units: [String: String] = [:]) -> [OverlayValue] {
        snapshot.values.keys.sorted().compactMap { key in
            guard let entity = scene.entity(for: key.object) else { return nil }
            return OverlayValue(
                entity: entity, quantity: key.quantity, value: snapshot.values[key]!, unit: units[key.quantity] ?? "", truth: .modeled
            )
        }
    }

    /// The latest stored reading of each quantity at each node, with its own
    /// truth class (observed, display, recorded…).
    public static func measured(in scene: SceneDescription, store: NexusStore) throws -> [OverlayValue] {
        var overlay: [OverlayValue] = []
        for node in scene.nodes {
            let readings = try store.measurements(at: node.object)
            var latest: [String: MeasurementRecord] = [:]
            for reading in readings {
                let key = "\(reading.quantityName)|\(reading.truth.rawValue)"
                if latest[key].map({ $0.sampledAt <= reading.sampledAt }) ?? true {
                    latest[key] = reading
                }
            }
            overlay += latest.keys.sorted().map { key in
                let reading = latest[key]!
                return OverlayValue(
                    entity: node.entity, quantity: reading.quantityName, value: reading.value.value, unit: reading.value.unit, truth: reading.truth
                )
            }
        }
        return overlay
    }
}
