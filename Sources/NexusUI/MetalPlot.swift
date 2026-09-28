#if canImport(SwiftUI) && canImport(MetalKit)
import MetalKit
import SwiftUI

/// A line plot drawn by the GPU, for series too large for Swift Charts
/// (scopes, long telemetry). Points are normalised to the visible range on
/// the CPU once; the GPU only draws a line strip. Swift Charts stays the
/// default for ordinary sizes; this is the spec's "Metal only where needed".
struct MetalPlot {
    /// Each series is (x, y) pairs in data units, drawn in one colour per series.
    var series: [[SIMD2<Float>]]
    var colors: [SIMD4<Float>] = [SIMD4(0.2, 0.5, 1, 1), SIMD4(1, 0.55, 0.1, 1), SIMD4(0.3, 0.8, 0.4, 1), SIMD4(0.8, 0.3, 0.8, 1)]

    fileprivate static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float4 color; };
        vertex Out plot_vertex(const device float2 *points [[buffer(0)]], constant float4 &color [[buffer(1)]], uint id [[vertex_id]]) {
            Out out;
            out.position = float4(points[id], 0, 1);
            out.color = color;
            return out;
        }
        fragment float4 plot_fragment(Out in [[stage_in]]) { return in.color; }
        """

    /// Maps data to clip space (-1…1) with a small margin.
    fileprivate func normalised() -> [[SIMD2<Float>]] {
        let all = series.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else {
            return []
        }
        let spanX = max(maxX - minX, .ulpOfOne)
        let spanY = max(maxY - minY, .ulpOfOne)
        return series.map { points in
            points.map { SIMD2(($0.x - minX) / spanX * 1.9 - 0.95, ($0.y - minY) / spanY * 1.9 - 0.95) }
        }
    }
}

@MainActor
final class MetalPlotRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var buffers: [(MTLBuffer, Int)] = []
    var colors: [SIMD4<Float>] = []

    init?(device: MTLDevice, format: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: MetalPlot.shader, options: nil),
            let vertex = library.makeFunction(name: "plot_vertex"),
            let fragment = library.makeFunction(name: "plot_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
    }

    func load(_ plot: MetalPlot, device: MTLDevice) {
        colors = plot.colors
        buffers = plot.normalised().compactMap { points in
            guard !points.isEmpty else { return nil }
            return device.makeBuffer(bytes: points, length: points.count * MemoryLayout<SIMD2<Float>>.stride).map { ($0, points.count) }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, (buffer, count)) in buffers.enumerated() {
            var color = colors[index % max(colors.count, 1)]
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: count)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// SwiftUI host for `MetalPlot`. Draws on demand, not every frame.
struct MetalPlotView: PlatformViewRepresentable {
    var plot: MetalPlot

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var renderer: MetalPlotRenderer?
    }

    private func make(_ context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        if let device = view.device, let renderer = MetalPlotRenderer(device: device, format: view.colorPixelFormat) {
            renderer.load(plot, device: device)
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return view
    }

    private func update(_ view: MTKView, _ context: Context) {
        if let device = view.device { context.coordinator.renderer?.load(plot, device: device) }
        #if os(iOS)
        view.setNeedsDisplay()
        #else
        view.needsDisplay = true
        #endif
    }

    #if os(iOS)
    func makeUIView(context: Context) -> MTKView { make(context) }
    func updateUIView(_ view: MTKView, context: Context) { update(view, context) }
    #else
    func makeNSView(context: Context) -> MTKView { make(context) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, context) }
    #endif
}
#endif
