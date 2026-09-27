// Apple-only RealityKit adapter over NexusReality. Compiles to nothing
// elsewhere; not exercised by Linux CI, so verify in Xcode.
#if canImport(RealityKit)
import Foundation
import NexusCore
import NexusReality
import RealityKit

/// Stores the canonical identity on each entity.
public struct CanonicalObjectComponent: Component {
    public var object: ObjectID
    public var handle: EntityHandle

    public init(object: ObjectID, handle: EntityHandle) {
        self.object = object
        self.handle = handle
    }
}

@MainActor
public enum RealityKitSceneBuilder {
    private static var registered = false

    /// Registers Nexus components. Idempotent; `makeEntities` calls it too.
    public static func registerComponents() {
        guard !registered else { return }
        CanonicalObjectComponent.registerComponent()
        registered = true
    }

    /// One entity per scene node, parented as in the description, plus a
    /// connector per link and a text label per overlay value. Each node
    /// entity carries a `CanonicalObjectComponent` and is a tap target, so a
    /// hit test resolves to the ObjectID without a lookup table of the
    /// renderer's own. 3D is a view of the model: nothing here is stored.
    public static func makeEntities(
        for scene: SceneDescription,
        selected: ObjectID? = nil,
        overlays: [OverlayValue] = [],
        size: Float = 0.2
    ) -> Entity {
        registerComponents()
        var entities: [EntityHandle: Entity] = [:]
        let root = Entity()
        let box = MeshResource.generateBox(size: size)
        for node in scene.nodes {
            let isSelected = node.object == selected
            let entity = ModelEntity(mesh: box, materials: [material(isSelected: isSelected)])
            entity.name = node.title
            entity.position = point(node.position)
            if isSelected { entity.scale = SIMD3(repeating: 1.3) }
            entity.components.set(CanonicalObjectComponent(object: node.object, handle: node.entity))
            entity.components.set(InputTargetComponent())
            entity.generateCollisionShapes(recursive: false)
            entities[node.entity] = entity
            root.addChild(entity)
        }
        for link in scene.links {
            guard let from = scene.node(link.from), let to = scene.node(link.to) else { continue }
            if let connector = connector(from: point(from.position), to: point(to.position)) {
                root.addChild(connector)
            }
        }
        // Overlays are labelled with their truth class in words, never by colour alone.
        let grouped = Dictionary(grouping: overlays, by: \.entity)
        for (handle, values) in grouped {
            guard let node = scene.node(handle) else { continue }
            let text = values.map { value in
                "\(value.quantity) \(value.value.formatted(.number.precision(.significantDigits(1...4)))) \(value.unit) (\(value.truth.rawValue))"
            }
            .joined(separator: "\n")
            let label = ModelEntity(
                mesh: .generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.04)),
                materials: [UnlitMaterial(color: .white)]
            )
            label.position = point(node.position) + SIMD3(-size / 2, size, 0)
            root.addChild(label)
        }
        return root
    }

    /// The canonical object behind a tapped entity (or its nearest tagged ancestor).
    public static func object(for entity: Entity) -> ObjectID? {
        var current: Entity? = entity
        while let candidate = current {
            if let component = candidate.components[CanonicalObjectComponent.self] {
                return component.object
            }
            current = candidate.parent
        }
        return nil
    }

    private static func point(_ position: Position) -> SIMD3<Float> {
        SIMD3(Float(position.x), Float(position.y), Float(position.z))
    }

    private static func material(isSelected: Bool) -> SimpleMaterial {
        SimpleMaterial(color: isSelected ? .systemBlue : .gray, isMetallic: false)
    }

    /// A thin cylinder from one node to another (a wire or pipe in the topology).
    private static func connector(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Entity? {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return nil }
        let entity = ModelEntity(
            mesh: .generateCylinder(height: length, radius: 0.01),
            materials: [SimpleMaterial(color: .darkGray, isMetallic: true)]
        )
        entity.position = (start + end) / 2
        entity.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta / length)
        return entity
    }
}
#endif
