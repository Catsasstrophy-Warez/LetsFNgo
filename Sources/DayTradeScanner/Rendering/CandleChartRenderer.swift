import SwiftUI
import MetalKit
import simd

/// GPU-side vertex layout — must stay bit-for-bit identical to `ChartVertex`
/// in ChartShaders.metal.
struct ChartVertexGPU {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ChartUniformsGPU {
    var projection: simd_float4x4
}

/// Owns the Metal pipeline and turns a window of bars into a triangle/line
/// vertex buffer every time the visible data or range changes.
///
/// This is the "full use of Metal" piece of the app's rendering stack: a
/// 390-bar intraday series (or a multi-year daily series for swing/long-term)
/// draws as one GPU draw call instead of hundreds of SwiftUI `Path` segments,
/// which is what lets pinch-zoom and pan stay smooth on a device rendering
/// the rest of the scan list at the same time.
final class ChartMetalCoordinator: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0

    // Data
    private var bars: [MinuteBar] = []
    private var vwaps: [Double] = []

    // Visible window, as an index range into `bars`. Pinch/pan mutate this;
    // it always stays clamped to `bars.indices`.
    private var visibleRange: Range<Int> = 0..<0
    /// Drag/pinch deltas accumulate here between gesture callbacks and
    /// `draw(in:)`, which is the only place that owns `visibleRange` — this
    /// keeps gesture handling and geometry rebuilding on the same thread
    /// without a lock.
    private var pendingPanBars: Double = 0
    private var pendingZoomFactor: Double = 1
    private var needsRebuild = true

    // Palette, matched to the app's cyan/up/down scheme rather than a
    /// generic red/green so it reads consistently with `Palette` elsewhere.
    private let upColor = SIMD4<Float>(0.11, 0.62, 0.42, 1.0)
    private let downColor = SIMD4<Float>(0.78, 0.24, 0.24, 1.0)
    private let vwapColor = SIMD4<Float>(0.85, 0.85, 0.85, 0.65)
    private let volumeColor = SIMD4<Float>(0.30, 0.55, 0.75, 0.35)

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device.")
        }
        self.device = device
        self.commandQueue = queue
        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        guard let library = try? device.makeDefaultLibrary(bundle: .main),
              let vertexFn = library.makeFunction(name: "chart_vertex_main"),
              let fragmentFn = library.makeFunction(name: "chart_fragment_main") else {
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Data updates

    func update(bars: [MinuteBar], vwaps: [Double]) {
        self.bars = bars
        self.vwaps = vwaps
        // Default to showing everything; a live gesture in progress keeps
        // its own window rather than snapping back on every new bar.
        if visibleRange.isEmpty || visibleRange.upperBound > bars.count {
            visibleRange = 0..<bars.count
        } else {
            // A new bar arrived — keep the trailing edge pinned so the chart
            // scrolls forward with the stream unless the user has panned back.
            let wasAtEnd = visibleRange.upperBound >= bars.count - 1
            if wasAtEnd { visibleRange = max(0, bars.count - visibleWidth())..<bars.count }
        }
        needsRebuild = true
    }

    private func visibleWidth() -> Int { max(visibleRange.count, 1) }

    // MARK: - Gestures

    func applyPan(deltaBars: Double) {
        pendingPanBars += deltaBars
        needsRebuild = true
    }

    func applyZoom(factor: Double) {
        pendingZoomFactor *= factor
        needsRebuild = true
    }

    private func resolveGestures() {
        guard !bars.isEmpty else { return }

        if pendingZoomFactor != 1 {
            let currentWidth = Double(visibleRange.count)
            // Clamp so a pinch can't zoom past ~8 bars or wider than the data.
            let newWidth = min(Double(bars.count), max(8, currentWidth / pendingZoomFactor))
            let center = Double(visibleRange.lowerBound) + currentWidth / 2
            let lower = max(0, Int((center - newWidth / 2).rounded()))
            let upper = min(bars.count, lower + Int(newWidth.rounded()))
            visibleRange = min(lower, upper)..<upper
            pendingZoomFactor = 1
        }

        if pendingPanBars != 0 {
            let width = visibleRange.count
            var lower = visibleRange.lowerBound - Int(pendingPanBars.rounded())
            lower = max(0, min(lower, bars.count - width))
            visibleRange = lower..<(lower + width)
            pendingPanBars = 0
        }
    }

    // MARK: - Geometry

    private func rebuildGeometry(viewSize: CGSize) {
        resolveGestures()
        needsRebuild = false

        guard !bars.isEmpty, !visibleRange.isEmpty, viewSize.width > 0, viewSize.height > 0 else {
            vertexBuffer = nil
            vertexCount = 0
            return
        }

        let window = Array(bars[visibleRange])
        let windowVWAPs = vwaps.count == bars.count ? Array(vwaps[visibleRange]) : []

        let priceHigh = window.map(\.high).max() ?? 1
        let priceLow = window.map(\.low).min() ?? 0
        let priceSpan = max(priceHigh - priceLow, 0.0001)
        let volumeMax = window.map(\.volume).max() ?? 1

        // Layout: top 78% of chart space is price, bottom 22% is volume,
        // with a small gap between them.
        let priceTop: Double = 1.0
        let priceBottom: Double = 0.26
        let volumeTop: Double = 0.20
        let volumeBottom: Double = 0.0

        func priceY(_ price: Double) -> Double {
            let t = (price - priceLow) / priceSpan
            return priceBottom + t * (priceTop - priceBottom)
        }
        func volumeY(_ volume: Double) -> Double {
            guard volumeMax > 0 else { return volumeBottom }
            let t = volume / volumeMax
            return volumeBottom + t * (volumeTop - volumeBottom)
        }

        var verts: [ChartVertexGPU] = []
        verts.reserveCapacity(window.count * 18)

        let count = window.count
        let slotWidth = 2.0 / Double(count)          // chart space spans -1...1 in x
        let bodyWidth = slotWidth * 0.7
        let wickWidth = slotWidth * 0.12

        func quad(x0: Double, x1: Double, y0: Double, y1: Double, color: SIMD4<Float>) {
            let clipY0 = Float(y0 * 2 - 1)
            let clipY1 = Float(y1 * 2 - 1)
            let fx0 = Float(x0), fx1 = Float(x1)
            let p00 = SIMD2<Float>(fx0, clipY0)
            let p10 = SIMD2<Float>(fx1, clipY0)
            let p01 = SIMD2<Float>(fx0, clipY1)
            let p11 = SIMD2<Float>(fx1, clipY1)
            verts.append(ChartVertexGPU(position: p00, color: color))
            verts.append(ChartVertexGPU(position: p10, color: color))
            verts.append(ChartVertexGPU(position: p01, color: color))
            verts.append(ChartVertexGPU(position: p10, color: color))
            verts.append(ChartVertexGPU(position: p11, color: color))
            verts.append(ChartVertexGPU(position: p01, color: color))
        }

        for (index, bar) in window.enumerated() {
            let slotCenter = -1.0 + slotWidth * (Double(index) + 0.5)
            let isUp = bar.close >= bar.open
            let color = isUp ? upColor : downColor

            // Wick.
            quad(
                x0: slotCenter - wickWidth / 2, x1: slotCenter + wickWidth / 2,
                y0: priceY(bar.low), y1: priceY(bar.high),
                color: color
            )
            // Body.
            let bodyLow = priceY(min(bar.open, bar.close))
            let bodyHigh = max(priceY(max(bar.open, bar.close)), bodyLow + 0.002)
            quad(
                x0: slotCenter - bodyWidth / 2, x1: slotCenter + bodyWidth / 2,
                y0: bodyLow, y1: bodyHigh,
                color: color
            )
            // Volume bar.
            quad(
                x0: slotCenter - bodyWidth / 2, x1: slotCenter + bodyWidth / 2,
                y0: volumeBottom, y1: max(volumeY(bar.volume), volumeBottom + 0.002),
                color: volumeColor
            )
        }

        // VWAP line, as a thin ribbon of quads between consecutive points —
        // avoids needing a separate line-primitive pipeline for one overlay.
        if windowVWAPs.count == count, count > 1 {
            let lineHalfWidth = 0.006
            for index in 1..<count {
                let x0 = -1.0 + slotWidth * (Double(index - 1) + 0.5)
                let x1 = -1.0 + slotWidth * (Double(index) + 0.5)
                let y0 = priceY(windowVWAPs[index - 1])
                let y1 = priceY(windowVWAPs[index])
                // A short quad angled between the two points approximates a
                // line segment closely enough at this vertex density.
                let midY = (y0 + y1) / 2
                quad(x0: x0, x1: x1, y0: midY - lineHalfWidth, y1: midY + lineHalfWidth, color: vwapColor)
            }
        }

        vertexCount = verts.count
        guard vertexCount > 0 else { vertexBuffer = nil; return }
        vertexBuffer = device.makeBuffer(bytes: verts, length: MemoryLayout<ChartVertexGPU>.stride * verts.count, options: [.storageModeShared])
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRebuild = true
    }

    func draw(in view: MTKView) {
        guard let pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        if needsRebuild {
            rebuildGeometry(viewSize: view.drawableSize)
        }

        guard let vertexBuffer, vertexCount > 0,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            // Still need to present an (empty) frame so the view doesn't stall.
            if let commandBuffer = commandQueue.makeCommandBuffer() {
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
            return
        }

        // Orthographic identity — geometry is already generated in
        // -1...1 clip space, so projection is just a pass-through. Kept as a
        // real uniform (rather than removed) so a future pixel-space
        // coordinate system or aspect correction is a one-line change here
        // instead of a geometry rewrite.
        var uniforms = ChartUniformsGPU(projection: matrix_identity_float4x4)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ChartUniformsGPU>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// SwiftUI wrapper around an `MTKView` driven by `ChartMetalCoordinator`.
/// Pinch-to-zoom and pan are implemented as plain `UIPanGestureRecognizer`/
/// `UIPinchGestureRecognizer` on the underlying view rather than SwiftUI
/// gestures, since the coordinate space they need to mutate (the visible
/// bar-index window) lives on the Metal side, not in SwiftUI state.
struct CandleChartView: UIViewRepresentable {
    let bars: [MinuteBar]
    let vwaps: [Double]

    func makeCoordinator() -> ChartMetalCoordinator { ChartMetalCoordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(ChartMetalCoordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(ChartMetalCoordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        context.coordinator.update(bars: bars, vwaps: vwaps)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.update(bars: bars, vwaps: vwaps)
    }
}

extension ChartMetalCoordinator {
    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view)
        // Roughly one bar per 8 points of drag, independent of zoom level's
        // absolute pixel width — good enough for a touch gesture where
        // precision to the bar doesn't matter.
        let barsPerPoint = 1.0 / 8.0
        applyPan(deltaBars: -Double(translation.x) * barsPerPoint)
        recognizer.setTranslation(.zero, in: view)
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.scale.isFinite, recognizer.scale > 0 else { return }
        applyZoom(factor: Double(recognizer.scale))
        recognizer.scale = 1
    }
}
