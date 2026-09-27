import Foundation
import NexusCore
import Testing

@testable import NexusVisualization

func sine(count: Int, sampleRate: Double, frequency: Double, amplitude: Double = 1, offset: Double = 0, phase: Double = 0) -> [DataPoint] {
    (0..<count).map { index in
        let t = Double(index) / sampleRate
        return DataPoint(t, offset + amplitude * sin(2 * Double.pi * frequency * t + phase))
    }
}

@Suite struct DownsamplingTests {
    @Test func lttbKeepsEndpointsAndTheRequestedCount() {
        let points = sine(count: 10_000, sampleRate: 1_000, frequency: 3)
        for threshold in [3, 10, 257, 1_000] {
            let reduced = Downsampling.lttb(points, threshold: threshold)
            #expect(reduced.count == threshold)
            #expect(reduced.first == points.first)
            #expect(reduced.last == points.last)
            #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.x < $1.x }, "Order is preserved")
        }
    }

    @Test func lttbReturnsSmallInputsUnchanged() {
        let points = sine(count: 50, sampleRate: 10, frequency: 1)
        #expect(Downsampling.lttb(points, threshold: 50) == points)
        #expect(Downsampling.lttb(points, threshold: 100) == points)
        #expect(Downsampling.lttb(points, threshold: 2) == points, "Below 3 there is nothing sensible to keep")
        #expect(Downsampling.lttb([], threshold: 10).isEmpty)
    }

    @Test func lttbKeepsASingleSpikeThatDecimationWouldMiss() {
        var points = (0..<5_000).map { DataPoint(Double($0), 0) }
        points[2_345].y = 100
        let reduced = Downsampling.lttb(points, threshold: 100)
        #expect(reduced.contains(DataPoint(2_345, 100)))
        // Plain every-50th decimation drops it.
        #expect(!stride(from: 0, to: points.count, by: 50).map { points[$0] }.contains { $0.y == 100 })
    }

    @Test func lttbOnASeriesKeepsUnitAndTruth() {
        let series = SeriesSpec(name: "Loop current", unit: "mA", truth: .modeled, points: sine(count: 500, sampleRate: 100, frequency: 1))
        let reduced = Downsampling.lttb(series, threshold: 20)
        #expect(reduced.points.count == 20)
        #expect(reduced.unit == "mA" && reduced.truth == .modeled && reduced.id == series.id)
    }
}

@Suite struct SpectrumTests {
    @Test func sineOnABinPeaksAtThatBinAtZeroDecibels() throws {
        // 1024 samples at 1024 Hz: bins are 1 Hz apart, so 50 Hz is bin 50.
        let samples = sine(count: 1_024, sampleRate: 1_024, frequency: 50).map(\.y)
        let spectrum = try Spectrum.analyze(samples, sampleRate: 1_024, window: .hann)
        let peak = try #require(spectrum.peak)
        #expect(peak.bin == 50)
        #expect(peak.frequency == 50)
        #expect(abs(peak.amplitude - 1) < 1e-9, "Coherent-gain correction recovers the amplitude")
        #expect(abs(spectrum.magnitudesDB[50]) < 1e-6)
        #expect(spectrum.frequencies.count == 513)
        #expect(spectrum.frequencies.last == 512, "The axis ends at Nyquist")
        // Hann leakage is confined to the neighbouring bins.
        #expect(spectrum.magnitudesDB[40] < -100)
    }

    @Test func amplitudeAndDCAreRecoveredWithARectangularWindow() throws {
        let samples = sine(count: 256, sampleRate: 256, frequency: 16, amplitude: 3, offset: 2).map(\.y)
        let spectrum = try Spectrum.analyze(samples, sampleRate: 256, window: .rectangular)
        #expect(abs(spectrum.amplitudes[0] - 2) < 1e-9, "DC is the mean")
        #expect(abs(spectrum.amplitudes[16] - 3) < 1e-9)
        #expect(abs(spectrum.magnitudesDB[16] - 20 * log10(3)) < 1e-9)
    }

    @Test func nonPowerOfTwoInputIsZeroPaddedAndPeaksNearTheTone() throws {
        let samples = sine(count: 1_000, sampleRate: 2_000, frequency: 440).map(\.y)
        let spectrum = try Spectrum.analyze(samples, sampleRate: 2_000)
        #expect(spectrum.fftLength == 1_024)
        #expect(spectrum.sampleCount == 1_000)
        let peak = try #require(spectrum.peak)
        #expect(abs(peak.frequency - 440) <= spectrum.binSpacing)
    }

    @Test func fftMatchesADirectDFT() {
        var generator = SplitMix(seed: 9)
        let input = (0..<64).map { _ in generator.nextUnit() * 2 - 1 }
        var real = input
        var imaginary = [Double](repeating: 0, count: 64)
        FFT.transform(real: &real, imaginary: &imaginary)
        for k in 0..<64 {
            var sumReal = 0.0
            var sumImaginary = 0.0
            for n in 0..<64 {
                let angle = -2 * Double.pi * Double(k * n) / 64
                sumReal += input[n] * cos(angle)
                sumImaginary += input[n] * sin(angle)
            }
            #expect(abs(real[k] - sumReal) < 1e-9)
            #expect(abs(imaginary[k] - sumImaginary) < 1e-9)
        }
    }

    @Test func invalidInputsThrow() {
        #expect(throws: VisualizationError.emptyInput) { try Spectrum.analyze([], sampleRate: 10) }
        #expect(throws: VisualizationError.invalidParameter("sampleRate")) { try Spectrum.analyze([1, 2], sampleRate: 0) }
    }
}

@Suite struct BinningTests {
    @Test func histogramCountsEveryValueAndClosesTheLastBin() throws {
        let values: [Double] = [0, 1, 1, 2, 3, 4, 4, 4, 5, .nan]
        let histogram = try Histogram.bin(values, binCount: 5)
        #expect(histogram.edges == [0, 1, 2, 3, 4, 5])
        #expect(histogram.counts == [1, 2, 1, 1, 4], "The maximum (5) lands in the last bin")
        #expect(histogram.total == 9)
        #expect(histogram.nonFinite == 1)
        #expect(histogram.centers.first == 0.5)
    }

    @Test func histogramReportsValuesOutsideAFixedRange() throws {
        let histogram = try Histogram.bin([-5, 0, 5, 10, 15], binCount: 2, range: 0...10)
        #expect(histogram.counts == [1, 2])
        #expect(histogram.underflow == 1)
        #expect(histogram.overflow == 1)
    }

    @Test func histogramDefaultsToSturgesAndHandlesAConstant() throws {
        #expect(try Histogram.bin((0..<100).map(Double.init)).binCount == 8)  // ⌈log2 100⌉ + 1
        let constant = try Histogram.bin([3, 3, 3], binCount: 4)
        #expect(constant.total == 3)
        #expect(constant.binWidth > 0)
        #expect(throws: VisualizationError.emptyInput) { try Histogram.bin([.nan]) }
    }

    @Test func heatmapCountsMeansAndLeavesEmptyCellsNil() throws {
        let x: [Double] = [0.1, 0.2, 0.9, 0.9, 5]
        let y: [Double] = [0.1, 0.2, 0.9, 0.95, 0.5]
        let z: [Double] = [1, 3, 10, 20, 99]
        let counts = try HeatmapGrid.bin(x: x, y: y, xBins: 2, yBins: 2, xRange: 0...1, yRange: 0...1)
        #expect(counts.cells == [[2, 0], [0, 2]])
        #expect(counts.excluded == 1, "The point at x = 5 is outside the range")

        let means = try HeatmapGrid.bin(x: x, y: y, z: z, xBins: 2, yBins: 2, xRange: 0...1, yRange: 0...1, aggregate: .mean)
        #expect(means.cells[0][0] == 2)
        #expect(means.cells[1][1] == 15)
        #expect(means.cells[0][1] == nil, "Empty cells have no value, not zero")

        let maxima = try HeatmapGrid.bin(x: x, y: y, z: z, xBins: 2, yBins: 2, xRange: 0...1, yRange: 0...1, aggregate: .max)
        #expect(maxima.cells[1][1] == 20)
        #expect(throws: VisualizationError.invalidParameter("z")) { try HeatmapGrid.bin(x: x, y: y, xBins: 2, yBins: 2, aggregate: .mean) }
    }
}

@Suite struct ScopeTriggerTests {
    @Test func risingEdgeInterpolatesTheCrossingTime() throws {
        // 5 Hz sine sampled at 100 Hz with a phase so crossings fall between samples.
        let samples = sine(count: 200, sampleRate: 100, frequency: 5, phase: -0.3)
        let triggers = ScopeTrigger.triggers(in: samples, mode: .risingEdge(level: 0))
        #expect(triggers.count == 10)
        // sin(2π·5·t − 0.3) = 0 rising at t = 0.3 / (2π·5) + k / 5.
        for (k, trigger) in triggers.enumerated() {
            let expected = 0.3 / (2 * Double.pi * 5) + Double(k) / 5
            #expect(abs(trigger.time - expected) < 2e-4)
        }
    }

    @Test func hysteresisIgnoresNoiseAroundTheLevel() {
        // A signal chattering around 1.0 then rising cleanly after a real low.
        let values: [Double] = [1.1, 0.95, 1.05, 0.98, 1.02, 0, 0.5, 2, 2, 0.9, 1.1]
        let samples = values.enumerated().map { DataPoint(Double($0.offset), $0.element) }
        let noisy = ScopeTrigger.triggers(in: samples, mode: .risingEdge(level: 1))
        let clean = ScopeTrigger.triggers(in: samples, mode: .risingEdge(level: 1, hysteresis: 0.5))
        #expect(noisy.count == 4)
        #expect(clean.map(\.index) == [7])
    }

    @Test func fallingLevelAndHoldoffModes() {
        let samples = sine(count: 400, sampleRate: 100, frequency: 1)
        #expect(ScopeTrigger.triggers(in: samples, mode: .fallingEdge(level: 0)).count == 4)
        // Level: fires when the signal first reaches the level in each cycle.
        let level = ScopeTrigger.triggers(in: samples, mode: .level(0.9))
        #expect(level.count == 4)
        #expect(level.allSatisfy { samples[$0.index].y >= 0.9 })
        #expect(ScopeTrigger.triggers(in: samples, mode: .level(0.9), holdoff: 1.5).count == 2)
        #expect(ScopeTrigger.first(in: samples, mode: .level(2)) == nil)
    }

    @Test func captureRetimesTheWindowAroundTheTrigger() throws {
        let samples = sine(count: 1_000, sampleRate: 1_000, frequency: 10, phase: -1)
        let capture = try #require(ScopeTrigger.capture(samples, mode: .risingEdge(level: 0), pre: 0.01, post: 0.02))
        #expect(capture.points.allSatisfy { $0.x >= -0.01 - 1e-12 && $0.x <= 0.02 + 1e-12 })
        #expect(capture.points.count >= 29 && capture.points.count <= 31)
        let nearest = try #require(capture.points.min { abs($0.x) < abs($1.x) })
        #expect(abs(nearest.y) < 0.07, "The signal is at the level at t = 0")
    }
}

/// Deterministic generator for test data.
struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
