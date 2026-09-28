import Foundation

/// Window functions applied before an FFT to reduce spectral leakage.
public enum WindowFunction: String, Codable, Sendable, Hashable, CaseIterable {
    case rectangular
    case hann

    /// The window's `count` coefficients (periodic form, suited to spectra).
    public func coefficients(_ count: Int) -> [Double] {
        switch self {
        case .rectangular:
            return [Double](repeating: 1, count: count)
        case .hann:
            guard count > 1 else { return [Double](repeating: 1, count: count) }
            return (0..<count).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(count)) }
        }
    }
}

/// A single-sided amplitude spectrum of a real signal.
///
/// Magnitudes are amplitude-corrected for the window's coherent gain, so a
/// sine of amplitude A centred on a bin reads A there. `magnitudesDB` is
/// 20·log10(amplitude / reference), floored at `floorDB`.
public struct Spectrum: Codable, Sendable, Hashable {
    public var sampleRate: Double
    /// FFT length after zero padding (a power of two).
    public var fftLength: Int
    /// Number of real samples analysed.
    public var sampleCount: Int
    public var window: WindowFunction
    /// Frequency of each bin, 0 ... sampleRate / 2.
    public var frequencies: [Double]
    public var amplitudes: [Double]
    public var magnitudesDB: [Double]
    public var reference: Double

    public var binSpacing: Double { sampleRate / Double(fftLength) }

    /// Index and frequency of the largest non-DC bin.
    public var peak: (bin: Int, frequency: Double, amplitude: Double)? {
        guard amplitudes.count > 1 else { return nil }
        var best = 1
        for index in 1..<amplitudes.count where amplitudes[index] > amplitudes[best] {
            best = index
        }
        return (best, frequencies[best], amplitudes[best])
    }

    /// Analyses `samples` taken at `sampleRate` Hz. The mean is kept (DC shows
    /// in bin 0). Input is zero-padded to the next power of two.
    public static func analyze(
        _ samples: [Double], sampleRate: Double, window: WindowFunction = .hann, reference: Double = 1, floorDB: Double = -200
    ) throws -> Spectrum {
        guard !samples.isEmpty else { throw VisualizationError.emptyInput }
        guard sampleRate > 0, sampleRate.isFinite else { throw VisualizationError.invalidParameter("sampleRate") }
        guard reference > 0 else { throw VisualizationError.invalidParameter("reference") }

        let count = samples.count
        var length = 1
        while length < count { length <<= 1 }
        length = max(length, 2)

        let coefficients = window.coefficients(count)
        let coherentGain = coefficients.reduce(0, +)
        var real = [Double](repeating: 0, count: length)
        var imaginary = [Double](repeating: 0, count: length)
        for index in 0..<count {
            real[index] = samples[index] * coefficients[index]
        }
        FFT.transform(real: &real, imaginary: &imaginary)

        let bins = length / 2 + 1
        var amplitudes = [Double](repeating: 0, count: bins)
        for k in 0..<bins {
            let magnitude = (real[k] * real[k] + imaginary[k] * imaginary[k]).squareRoot()
            // Single-sided: double every bin except DC and Nyquist.
            let scale = (k == 0 || k == length / 2) ? 1.0 : 2.0
            amplitudes[k] = scale * magnitude / coherentGain
        }
        let decibels = amplitudes.map { amplitude in
            amplitude > 0 ? max(floorDB, 20 * log10(amplitude / reference)) : floorDB
        }
        let frequencies = (0..<bins).map { Double($0) * sampleRate / Double(length) }
        return Spectrum(
            sampleRate: sampleRate, fftLength: length, sampleCount: count, window: window, frequencies: frequencies,
            amplitudes: amplitudes, magnitudesDB: decibels, reference: reference
        )
    }
}

/// In-place iterative radix-2 Cooley–Tukey FFT.
public enum FFT {
    /// Forward transform. Both arrays must have the same power-of-two length.
    public static func transform(real: inout [Double], imaginary: inout [Double]) {
        let n = real.count
        precondition(n == imaginary.count && n > 0 && n & (n - 1) == 0, "FFT length must be a power of two")
        guard n > 1 else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }

        var size = 2
        while size <= n {
            let half = size / 2
            let angle = -2 * Double.pi / Double(size)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            var start = 0
            while start < n {
                var wReal = 1.0
                var wImaginary = 0.0
                for k in 0..<half {
                    let even = start + k
                    let odd = even + half
                    let tReal = wReal * real[odd] - wImaginary * imaginary[odd]
                    let tImaginary = wReal * imaginary[odd] + wImaginary * real[odd]
                    real[odd] = real[even] - tReal
                    imaginary[odd] = imaginary[even] - tImaginary
                    real[even] += tReal
                    imaginary[even] += tImaginary
                    let nextReal = wReal * stepReal - wImaginary * stepImaginary
                    wImaginary = wReal * stepImaginary + wImaginary * stepReal
                    wReal = nextReal
                }
                start += size
            }
            size <<= 1
        }
    }
}
