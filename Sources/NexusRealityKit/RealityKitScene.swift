// Apple-only RealityKit adapter over NexusReality. Compiles to nothing
// elsewhere; not exercised by Linux CI, so verify in Xcode.
#if canImport(RealityKit)
import Foundation
import Metal
import NexusCore
import NexusModel
import NexusReality
import RealityKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Stores the canonical identity on each entity.
public struct CanonicalObjectComponent: Component {
    public var object: ObjectID
    public var handle: EntityHandle

    public init(object: ObjectID, handle: EntityHandle) {
        self.object = object
        self.handle = handle
    }
}

/// What the twin should show beyond the topology.
public struct TwinPresentation: Sendable {
    public var selected: ObjectID?
    public var overlays: [OverlayValue]
    /// Nodes where observed and modeled values disagree (first divergence).
    public var alerts: Set<EntityHandle>

    public init(selected: ObjectID? = nil, overlays: [OverlayValue] = [], alerts: Set<EntityHandle> = []) {
        self.selected = selected
        self.overlays = overlays
        self.alerts = alerts
    }

    /// Nodes whose observed (or recorded) reading differs from the modeled
    /// one for the same quantity by more than `tolerance` (relative).
    public static func divergences(in overlays: [OverlayValue], tolerance: Double = 0.05) -> Set<EntityHandle> {
        var result: Set<EntityHandle> = []
        let byNode = Dictionary(grouping: overlays) { "\($0.entity.raw)|\($0.quantity)" }
        for values in byNode.values {
            let field = values.filter { $0.truth == .observed || $0.truth == .recorded }
            let model = values.filter { $0.truth == .modeled }
            for observed in field {
                for modeled in model where abs(observed.value - modeled.value) > tolerance * max(abs(modeled.value), 1e-6) {
                    result.insert(observed.entity)
                }
            }
        }
        return result
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

    /// The equipment as a lit, shadowed scene: one entity per scene node with
    /// geometry chosen by what the object is, a connector per link carrying
    /// an animated signal-flow shader, a liquid level from the level reading,
    /// alert nodes pulsing (Metal surface shader) with sparks, and a SwiftUI
    /// card per node for its readings and their truth classes. Every node is
    /// a tap target carrying its ObjectID. 3D is a view of the model; nothing
    /// here is stored.
    public static func makeEntities(for scene: SceneDescription, presentation: TwinPresentation) -> Entity {
        registerComponents()
        let root = Entity()
        root.name = "twin"
        let overlays = Dictionary(grouping: presentation.overlays, by: \.entity)

        for node in scene.nodes {
            let isSelected = node.object == presentation.selected
            let isAlert = presentation.alerts.contains(node.entity)
            let entity = Geometry.entity(for: node, level: level(in: overlays[node.entity] ?? []), selected: isSelected, alert: isAlert)
            entity.name = node.title
            entity.position = point(node.position)
            entity.components.set(CanonicalObjectComponent(object: node.object, handle: node.entity))
            entity.components.set(InputTargetComponent())
            entity.generateCollisionShapes(recursive: true)
            if isAlert {
                var sparks = ParticleEmitterComponent.Presets.sparks
                sparks.mainEmitter.birthRate = 40
                sparks.emitterShapeSize = SIMD3(repeating: 0.05)
                let emitter = Entity()
                emitter.components.set(sparks)
                emitter.position = [0, 0.18, 0]
                entity.addChild(emitter)
            }
            if let values = overlays[node.entity], !values.isEmpty,
                let card = cardEntity(OverlayCard(title: node.title, values: values, alert: isAlert))
            {
                card.position = [0, Geometry.height(of: node) / 2 + 0.2, 0]
                entity.addChild(card)
            }
            root.addChild(entity)
        }

        for link in scene.links {
            guard let from = scene.node(link.from), let to = scene.node(link.to),
                let connector = connector(from: point(from.position), to: point(to.position))
            else { continue }
            root.addChild(connector)
        }

        root.addChild(Geometry.floor(for: scene))
        root.addChild(Geometry.keyLight())
        return root
    }

    /// Kept for callers of the first adapter.
    public static func makeEntities(for scene: SceneDescription, selected: ObjectID? = nil, overlays: [OverlayValue] = [], size: Float = 0.2) -> Entity {
        makeEntities(for: scene, presentation: TwinPresentation(selected: selected, overlays: overlays))
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

    /// A SwiftUI view drawn into a texture on a plane that always faces the
    /// camera. The card is rendered at 3x for a crisp result on Pro displays.
    private static func cardEntity(_ view: OverlayCard) -> Entity? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.cgImage,
            let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        let width: Float = 0.5
        let height = width * Float(image.height) / Float(max(image.width, 1))
        let plane = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        plane.components.set(BillboardComponent())
        return plane
    }

    /// A level percentage from the node's readings, preferring observed over modeled.
    private static func level(in values: [OverlayValue]) -> Double? {
        let levels = values.filter { $0.quantity == "level" && $0.unit == "%" }
        let preferred = levels.first { $0.truth == .observed || $0.truth == .recorded } ?? levels.first
        return preferred.map { min(max($0.value / 100, 0), 1) }
    }

    private static func point(_ position: Position) -> SIMD3<Float> {
        SIMD3(Float(position.x), Float(position.y), Float(position.z))
    }

    /// A cable or pipe between two nodes, with the signal-flow shader when
    /// the Metal library is available.
    private static func connector(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Entity? {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return nil }
        let material: any RealityKit.Material = Shaders.signalFlow() ?? SimpleMaterial(color: .darkGray, isMetallic: true)
        let entity = ModelEntity(mesh: Geometry.cylinder(height: length, radius: 0.012), materials: [material])
        entity.position = (start + end) / 2
        entity.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta / length)
        return entity
    }
}

/// Geometry and materials per kind of object, with meshes and materials
/// shared across entities (instancing-friendly) rather than rebuilt per node.
@MainActor
enum Geometry {
    private static var meshes: [String: MeshResource] = [:]

    static func cylinder(height: Float, radius: Float) -> MeshResource {
        cached("cyl-\(height)-\(radius)") { .generateCylinder(height: height, radius: radius) }
    }

    private static func box(_ size: SIMD3<Float>, corner: Float = 0.01) -> MeshResource {
        cached("box-\(size)") { .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: corner) }
    }

    private static func sphere(_ radius: Float) -> MeshResource {
        cached("sphere-\(radius)") { .generateSphere(radius: radius) }
    }

    private static func cached(_ key: String, _ make: () -> MeshResource) -> MeshResource {
        if let mesh = meshes[key] { return mesh }
        let mesh = make()
        meshes[key] = mesh
        return mesh
    }

    enum Kind {
        case vessel, instrument, terminal, card, controller, valve, point, generic
    }

    static func kind(of node: SceneNode) -> Kind {
        let title = node.title.lowercased()
        if node.type == .testPoint { return .point }
        if title.contains("tank") || title.contains("vessel") || title.hasPrefix("t-") { return .vessel }
        if title.contains("terminal") || title.contains("tb-") { return .terminal }
        if title.contains("valve") || title.hasPrefix("lv-") || title.hasPrefix("fv-") { return .valve }
        if title.contains("card") || title.contains(" ai ") || title.hasPrefix("ai ") { return .card }
        if title.contains("controller") || title.contains("plc") || title.contains("lic") { return .controller }
        if node.type == .sensor || title.contains("transmitter") || title.contains("lt-") { return .instrument }
        return .generic
    }

    static func height(of node: SceneNode) -> Float {
        switch kind(of: node) {
        case .vessel: 0.8
        case .instrument: 0.22
        case .terminal: 0.12
        case .card, .controller: 0.26
        case .valve: 0.18
        case .point: 0.06
        case .generic: 0.2
        }
    }

    static func entity(for node: SceneNode, level: Double?, selected: Bool, alert: Bool) -> Entity {
        let body = material(for: kind(of: node), selected: selected, alert: alert)
        switch kind(of: node) {
        case .vessel:
            let shell = ModelEntity(mesh: cylinder(height: 0.8, radius: 0.35), materials: [glass(selected: selected)])
            let fill = Float(level ?? 0.5)
            let liquid = ModelEntity(mesh: cylinder(height: max(0.8 * fill, 0.01), radius: 0.33), materials: [liquidMaterial()])
            liquid.position.y = -0.4 + 0.4 * fill
            shell.addChild(liquid)
            if alert { shell.addChild(ModelEntity(mesh: cylinder(height: 0.81, radius: 0.36), materials: [body])) }
            return shell
        case .instrument:
            let housing = ModelEntity(mesh: box([0.14, 0.16, 0.12], corner: 0.02), materials: [body])
            let stem = ModelEntity(mesh: cylinder(height: 0.14, radius: 0.025), materials: [steel()])
            stem.position.y = -0.14
            housing.addChild(stem)
            return housing
        case .terminal:
            let rail = ModelEntity(mesh: box([0.32, 0.03, 0.06]), materials: [steel()])
            for index in 0..<6 {
                let block = ModelEntity(mesh: box([0.045, 0.1, 0.07], corner: 0.004), materials: [index == 3 ? body : plastic()])
                block.position = [Float(index) * 0.05 - 0.125, 0.06, 0]
                rail.addChild(block)
            }
            return rail
        case .card:
            return ModelEntity(mesh: box([0.05, 0.26, 0.2], corner: 0.005), materials: [body])
        case .controller:
            return ModelEntity(mesh: box([0.3, 0.26, 0.12], corner: 0.01), materials: [body])
        case .valve:
            let valveBody = ModelEntity(mesh: sphere(0.08), materials: [body])
            let pipe = ModelEntity(mesh: cylinder(height: 0.36, radius: 0.04), materials: [steel()])
            pipe.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            valveBody.addChild(pipe)
            let actuator = ModelEntity(mesh: cylinder(height: 0.12, radius: 0.07), materials: [plastic()])
            actuator.position.y = 0.12
            valveBody.addChild(actuator)
            return valveBody
        case .point:
            return ModelEntity(mesh: sphere(0.03), materials: [body])
        case .generic:
            return ModelEntity(mesh: box([0.2, 0.2, 0.2], corner: 0.01), materials: [body])
        }
    }

    static func material(for kind: Kind, selected: Bool, alert: Bool) -> any RealityKit.Material {
        if alert, let pulse = Shaders.alertPulse() { return pulse }
        var material = PhysicallyBasedMaterial()
        let tint: UIColorLike = switch kind {
        case .instrument: .init(0.20, 0.45, 0.85)
        case .terminal: .init(0.95, 0.55, 0.15)
        case .card: .init(0.15, 0.6, 0.35)
        case .controller: .init(0.35, 0.35, 0.4)
        case .valve: .init(0.8, 0.2, 0.2)
        case .point: .init(0.95, 0.85, 0.2)
        case .vessel, .generic: .init(0.6, 0.62, 0.66)
        }
        material.baseColor = .init(tint: tint.color)
        material.roughness = 0.45
        material.metallic = kind == .controller || kind == .generic ? 0.6 : 0.15
        if alert {
            material.emissiveColor = .init(color: .init(red: 1, green: 0.2, blue: 0.1, alpha: 1))
            material.emissiveIntensity = 2
        } else if selected {
            material.emissiveColor = .init(color: .init(red: 0.2, green: 0.5, blue: 1, alpha: 1))
            material.emissiveIntensity = 1.2
        }
        return material
    }

    private static func glass(selected: Bool) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: selected ? UIColorLike(0.6, 0.75, 1).color : UIColorLike(0.8, 0.85, 0.9).color)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.28))
        material.roughness = 0.08
        material.metallic = 0.1
        return material
    }

    private static func liquidMaterial() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColorLike(0.1, 0.45, 0.8).color)
        material.roughness = 0.15
        material.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        return material
    }

    private static func steel() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColorLike(0.7, 0.72, 0.75).color)
        material.metallic = 0.9
        material.roughness = 0.3
        return material
    }

    private static func plastic() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColorLike(0.25, 0.27, 0.3).color)
        material.roughness = 0.7
        return material
    }

    /// A floor under the equipment that receives shadows.
    static func floor(for scene: SceneDescription) -> Entity {
        let xs = scene.nodes.map { Float($0.position.x) }
        let ys = scene.nodes.map { Float($0.position.y) }
        let zs = scene.nodes.map { Float($0.position.z) }
        let width = (xs.max() ?? 1) - (xs.min() ?? 0) + 2
        let depth = (zs.max() ?? 1) - (zs.min() ?? 0) + 2
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColorLike(0.18, 0.19, 0.21).color)
        material.roughness = 0.9
        let floor = ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [material])
        floor.position = [((xs.max() ?? 0) + (xs.min() ?? 0)) / 2, (ys.min() ?? 0) - 0.5, ((zs.max() ?? 0) + (zs.min() ?? 0)) / 2]
        floor.name = "floor"
        return floor
    }

    /// A key light that casts shadows.
    static func keyLight() -> Entity {
        let light = DirectionalLight()
        light.light.intensity = 3_000
        light.shadow = DirectionalLightComponent.Shadow(maximumDistance: 12, depthBias: 2)
        light.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0.3, 0])
        return light
    }
}

/// A colour that works with RealityKit on iOS (UIColor) and macOS (NSColor).
struct UIColorLike {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    #if os(iOS)
    var color: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    #else
    var color: NSColor { NSColor(red: red, green: green, blue: blue, alpha: 1) }
    #endif
}

/// Custom Metal surface shaders compiled into the app (App/Shaders/NexusShaders.metal).
/// Nil when the default library or custom materials aren't available (the
/// Simulator, previews, tests), so callers fall back to physically based materials.
@MainActor
enum Shaders {
    private static let library: MTLLibrary? = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
    private static var cache: [String: CustomMaterial] = [:]

    static func signalFlow() -> CustomMaterial? {
        material("nexusSignalFlow", tint: UIColorLike(0.2, 0.75, 1))
    }

    static func alertPulse() -> CustomMaterial? {
        material("nexusAlertPulse", tint: UIColorLike(1, 0.25, 0.1))
    }

    private static func material(_ name: String, tint: UIColorLike) -> CustomMaterial? {
        if let cached = cache[name] { return cached }
        guard let library, library.makeFunction(name: name) != nil else { return nil }
        guard var material = try? CustomMaterial(surfaceShader: CustomMaterial.SurfaceShader(named: name, in: library), lightingModel: .lit) else {
            return nil
        }
        material.baseColor = .init(tint: tint.color)
        cache[name] = material
        return material
    }
}

/// A node's readings, as a card floating above it. Truth classes are shown
/// in words and symbols, never by colour alone.
struct OverlayCard: View {
    let title: String
    let values: [OverlayValue]
    let alert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if alert { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text(title).font(.headline)
            }
            ForEach(values, id: \.self) { value in
                HStack(spacing: 6) {
                    Text("\(value.quantity) \(value.value.formatted(.number.precision(.significantDigits(1...4)))) \(value.unit)")
                        .font(.caption.monospacedDigit())
                    Label(value.truth.rawValue, systemImage: symbol(value.truth))
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 4)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
            }
        }
        .padding(10)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ truth: TruthClass) -> String {
        switch truth {
        case .recorded: "checkmark.seal"
        case .observed: "eye"
        case .modeled: "cube.transparent"
        case .claimed: "quote.bubble"
        case .derived: "function"
        case .display: "display"
        case .agentInterpretation: "sparkles"
        }
    }
}
#endif
