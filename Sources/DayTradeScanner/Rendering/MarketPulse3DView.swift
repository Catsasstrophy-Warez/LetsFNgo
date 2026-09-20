import SwiftUI
import RealityKit

/// A RealityKit "market landscape": the current ranked list as a field of
/// extruded bars, height = score, color = direction. This is the optional
/// spatial view called out in BUILDOUT_PLAN.md — the core scan list and
/// price charts stay 2D/Metal because that's what a phone-in-hand trading
/// workflow actually rewards, but a glanceable 3D overview of "where is the
/// market's attention right now" is a reasonable non-AR use of RealityKit on
/// iOS/iPadOS, and it costs nothing to the primary workflow since it lives
/// behind an explicit toolbar action rather than replacing anything.
///
/// Uses `RealityView`, available on iOS/iPadOS 18+, in its plain (non-AR)
/// windowed mode — no camera passthrough, no ARSession, just a rendered
/// RealityKit scene embedded like any other SwiftUI view.
struct MarketPulse3DView: View {
    let candidates: [Candidate]
    @Environment(\.dismiss) private var dismiss
    @State private var rotation: Double = 0

    var body: some View {
        NavigationStack {
            RealityView { content in
                content.add(makeScene(candidates: candidates))
            } update: { content in
                // Rebuild on data change rather than mutating in place — the
                // candidate list is small (capped at `maxRankedResults`) and
                // this view is opened occasionally, so simplicity wins over
                // incremental diffing here.
                content.entities.removeAll()
                content.add(makeScene(candidates: candidates))
            }
            .gesture(
                DragGesture()
                    .onChanged { value in rotation = Double(value.translation.width) * 0.01 }
            )
            .background(Palette.canvas)
            .navigationTitle("Market Pulse 3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func makeScene(candidates: [Candidate]) -> Entity {
        let root = Entity()
        root.transform.rotation = simd_quatf(angle: Float(rotation), axis: [0, 1, 0])

        let shown = Array(candidates.prefix(24))
        guard !shown.isEmpty else { return root }

        let columns = Int(ceil(sqrt(Double(shown.count))))
        let spacing: Float = 0.12

        for (index, candidate) in shown.enumerated() {
            let row = index / columns
            let col = index % columns
            let x = (Float(col) - Float(columns) / 2) * spacing
            let z = (Float(row) - Float(shown.count / columns) / 2) * spacing

            let height = max(Float(candidate.score) * 0.5, 0.01)
            let isUp = candidate.snapshot.changePercent >= 0
            let color: UIColor = isUp
                ? UIColor(red: 0.11, green: 0.62, blue: 0.42, alpha: 1)
                : UIColor(red: 0.78, green: 0.24, blue: 0.24, alpha: 1)

            let mesh = MeshResource.generateBox(width: 0.08, height: height, depth: 0.08, cornerRadius: 0.01)
            let material = SimpleMaterial(color: color, roughness: 0.4, isMetallic: true)
            let bar = ModelEntity(mesh: mesh, materials: [material])
            bar.position = SIMD3(x, height / 2, z)
            root.addChild(bar)
        }

        // A simple directional light so the boxes read as 3D rather than flat.
        var lightComponent = DirectionalLightComponent()
        lightComponent.intensity = 3000
        let light = Entity()
        light.components.set(lightComponent)
        light.look(at: .zero, from: [0.4, 0.6, 0.4], relativeTo: nil)
        root.addChild(light)

        return root
    }
}
