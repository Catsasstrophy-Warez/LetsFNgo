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
    @State private var showAccessibleList = false

    /// The individual bars in the RealityKit scene aren't accessibility
    /// elements — there's no practical way to make 24 freeform-positioned
    /// 3D boxes individually VoiceOver-navigable the way a SwiftUI List row
    /// is. Rather than leave the view silent, this gives VoiceOver one
    /// meaningful summary (top few by score) and a "List" toolbar action
    /// below presents the full data as an ordinary accessible list.
    private var summary: String {
        guard !candidates.isEmpty else { return "Market pulse, no candidates yet" }
        let top = candidates.prefix(3).map { "\($0.symbol) at \(Fmt.score($0.score))" }
        return "Market pulse, \(candidates.count) candidates. Top: \(top.joined(separator: ", "))."
    }

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            .background(Palette.canvas)
            .navigationTitle("Market Pulse 3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("List") { showAccessibleList = true }
                        .accessibilityHint("Shows the same ranked candidates as an accessible list")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showAccessibleList) {
                MarketPulseAccessibleListView(candidates: candidates)
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

/// The accessible equivalent of the 3D scene above — same top-24 candidates,
/// same score-driven ordering, as an ordinary VoiceOver-navigable list.
private struct MarketPulseAccessibleListView: View {
    let candidates: [Candidate]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates.prefix(24)) { candidate in
                HStack {
                    Text(candidate.symbol).font(.subheadline.monospaced())
                    Spacer()
                    Text(String(format: "%+.1f%%", candidate.snapshot.changePercent * 100))
                        .foregroundStyle(Palette.direction(candidate.snapshot.changePercent))
                    Text(Fmt.score(candidate.score))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            .navigationTitle("Market Pulse — List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
