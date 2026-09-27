// Apple-only RealityKit adapter over NexusReality. Compiles to nothing
// elsewhere; not exercised by Linux CI, so verify in Xcode.
#if canImport(RealityKit)
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
    /// Call once at launch before building scenes.
    public static func registerComponents() {
        CanonicalObjectComponent.registerComponent()
    }

    /// One entity per scene node, parented as in the description. Each
    /// entity carries a `CanonicalObjectComponent`, so a hit test resolves to
    /// the ObjectID without any lookup table of the renderer's own.
    public static func makeEntities(for scene: SceneDescription, size: Float = 0.2) -> Entity {
        var entities: [EntityHandle: Entity] = [:]
        let root = Entity()
        for node in scene.nodes {
            let entity = ModelEntity(
                mesh: .generateBox(size: size),
                materials: [SimpleMaterial(color: .gray, isMetallic: false)]
            )
            entity.name = node.title
            entity.position = SIMD3<Float>(Float(node.position.x), Float(node.position.y), Float(node.position.z))
            entity.components.set(CanonicalObjectComponent(object: node.object, handle: node.entity))
            entity.generateCollisionShapes(recursive: false)
            entities[node.entity] = entity
            if let parent = node.parent, let parentEntity = entities[parent] {
                parentEntity.addChild(entity, preservingWorldTransform: true)
            } else {
                root.addChild(entity)
            }
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
}
#endif
