import Foundation

public struct SpectralSignalSample: Equatable, Sendable {
    public let timeMilliseconds: Double
    public let value: Double

    public init(timeMilliseconds: Double, value: Double) {
        self.timeMilliseconds = timeMilliseconds
        self.value = value
    }
}

public struct SpectralPeak: Identifiable, Equatable, Sendable {
    public var id: String { String(format: "%.6f", frequencyHz) }
    public let frequencyHz: Double
    public let amplitude: Double
    public let powerFraction: Double
    public let phaseRadians: Double
}

public enum SpectralOscillationKind: String, Codable, Sendable {
    case insufficientEvidence
    case noStrongPeriodicity
    case singleFrequencyLimitCycle
    case mechanicalResonance
    case interactingLoops
    case periodicDisturbance
    case beating
    case operatingStateFrequencyShift
    case broadbandOrComplex

    public var displayName: String {
        switch self {
        case .insufficientEvidence: return "Insufficient spectral evidence"
        case .noStrongPeriodicity: return "No strong periodic component"
        case .singleFrequencyLimitCycle: return "Clean single-frequency limit cycle"
        case .mechanicalResonance: return "Mechanical resonance candidate"
        case .interactingLoops: return "Interacting control loops candidate"
        case .periodicDisturbance: return "Periodic process disturbance candidate"
        case .beating: return "Two-frequency beating"
        case .operatingStateFrequencyShift: return "Operating-state frequency shift"
        case .broadbandOrComplex: return "Broadband / complex oscillation"
        }
    }
}

public enum SpectralConfidence: String, Codable, Sendable {
    case low, medium, high
    public var displayName: String { rawValue.capitalized }
}

public struct SpectralFingerprint: Equatable, Sendable {
    public let sampleIntervalMilliseconds: Double
    public let analyzedDurationMilliseconds: Double
    public let nyquistHz: Double
    public let dominantFrequencyHz: Double?
    public let dominantPeriodMilliseconds: Double?
    public let dominantPowerFraction: Double
    public let spectralConcentration: Double
    public let spectralEntropy: Double
    public let peaks: [SpectralPeak]
    public let beatFrequencyHz: Double?
    public let beatPeriodMilliseconds: Double?
}

public struct CrossSpectralRelationship: Equatable, Sendable {
    public let dominantFrequencyHz: Double?
    public let phaseDifferenceRadians: Double?
    public let phaseDifferenceFractionOfCycle: Double?
    public let coherenceProxy: Double
}

public struct SpectralContextObservation: Equatable, Sendable {
    public let label: String
    public let operatingValue: Double
    public let samples: [SpectralSignalSample]

    public init(label: String, operatingValue: Double, samples: [SpectralSignalSample]) {
        self.label = label
        self.operatingValue = operatingValue
        self.samples = samples
    }
}

public struct SpectralOperatingDependence: Equatable, Sendable {
    public let observations: Int
    public let frequencyOperatingCorrelation: Double?
    public let frequencyRangeRatio: Double?
    public let shiftsWithOperatingState: Bool
    public let interpretation: String
}

public struct SpectralAssessment: Equatable, Sendable {
    public let kind: SpectralOscillationKind
    public let confidence: SpectralConfidence
    public let fingerprint: SpectralFingerprint
    public let crossSignal: CrossSpectralRelationship?
    public let evidence: [String]
    public let summary: String
}

public enum SpectralOscillationAnalyzer {
    public static func samples(from simulation: SampledPIDSimulation, keyPath: KeyPath<SampledPIDPoint, Double> = \.processValue) -> [SpectralSignalSample] {
        simulation.points.map { .init(timeMilliseconds: $0.timeMilliseconds, value: $0[keyPath: keyPath]) }
    }

    public static func fingerprint(samples raw: [SpectralSignalSample], maximumPeaks: Int = 5) -> SpectralFingerprint {
        guard raw.count >= 32 else { return emptyFingerprint(samples: raw) }
        let samples = resampleUniform(raw)
        guard samples.count >= 32 else { return emptyFingerprint(samples: samples) }

        let dtMs = median(samples.indices.dropFirst().map { samples[$0].timeMilliseconds - samples[$0 - 1].timeMilliseconds }) ?? 0
        guard dtMs > 0 else { return emptyFingerprint(samples: samples) }
        let dt = dtMs / 1000
        let values = detrend(samples.map(\.value))
        let n = values.count
        let windowed = values.enumerated().map { index, value -> Double in
            let w = n > 1 ? 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(n - 1)) : 1
            return value * w
        }
        let maxBin = n / 2
        var bins: [(k: Int, frequency: Double, amplitude: Double, power: Double, phase: Double)] = []
        bins.reserveCapacity(maxBin)
        for k in 1...maxBin {
            var re = 0.0
            var im = 0.0
            for t in 0..<n {
                let angle = -2 * Double.pi * Double(k * t) / Double(n)
                re += windowed[t] * cos(angle)
                im += windowed[t] * sin(angle)
            }
            let amplitude = 2 * hypot(re, im) / Double(n)
            bins.append((k, Double(k) / (Double(n) * dt), amplitude, re * re + im * im, atan2(im, re)))
        }
        let totalPower = max(bins.reduce(0) { $0 + $1.power }, 1e-18)
        let localPeaks = bins.indices.filter { i in
            let p = bins[i].power
            let left = i == 0 ? -Double.infinity : bins[i - 1].power
            let right = i == bins.count - 1 ? -Double.infinity : bins[i + 1].power
            return p >= left && p >= right
        }
        let sortedPeaks = localPeaks.map { bins[$0] }.sorted { $0.power > $1.power }
        let significant = sortedPeaks.prefix(maximumPeaks).map {
            SpectralPeak(frequencyHz: $0.frequency, amplitude: $0.amplitude, powerFraction: $0.power / totalPower, phaseRadians: $0.phase)
        }
        let dominant = significant.first
        let concentration = significant.prefix(3).reduce(0) { $0 + $1.powerFraction }
        let probabilities = bins.map { max(0, $0.power / totalPower) }.filter { $0 > 0 }
        let entropyRaw = -probabilities.reduce(0) { $0 + $1 * log($1) }
        let entropy = probabilities.count > 1 ? entropyRaw / log(Double(probabilities.count)) : 0
        let beat: Double? = {
            guard significant.count >= 2 else { return nil }
            let f1 = significant[0].frequencyHz, f2 = significant[1].frequencyHz
            let difference = abs(f1 - f2)
            guard difference > 0, significant[1].powerFraction >= 0.08 else { return nil }
            return difference
        }()
        return .init(
            sampleIntervalMilliseconds: dtMs,
            analyzedDurationMilliseconds: samples.last!.timeMilliseconds - samples.first!.timeMilliseconds,
            nyquistHz: 0.5 / dt,
            dominantFrequencyHz: dominant?.frequencyHz,
            dominantPeriodMilliseconds: dominant.map { 1000 / $0.frequencyHz },
            dominantPowerFraction: dominant?.powerFraction ?? 0,
            spectralConcentration: concentration,
            spectralEntropy: entropy,
            peaks: significant,
            beatFrequencyHz: beat,
            beatPeriodMilliseconds: beat.map { 1000 / $0 }
        )
    }

    public static func crossSpectralRelationship(primary: [SpectralSignalSample], secondary: [SpectralSignalSample]) -> CrossSpectralRelationship {
        let a = resampleUniform(primary)
        let b = resampleUniform(secondary)
        let n = min(a.count, b.count)
        guard n >= 32 else { return .init(dominantFrequencyHz: nil, phaseDifferenceRadians: nil, phaseDifferenceFractionOfCycle: nil, coherenceProxy: 0) }
        let fa = fingerprint(samples: Array(a.prefix(n)))
        guard let f = fa.dominantFrequencyHz, f > 0 else { return .init(dominantFrequencyHz: nil, phaseDifferenceRadians: nil, phaseDifferenceFractionOfCycle: nil, coherenceProxy: 0) }
        let dt = fa.sampleIntervalMilliseconds / 1000
        let k = max(1, min(n / 2, Int((f * Double(n) * dt).rounded())))
        func coefficient(_ values: [Double]) -> (Double, Double) {
            let x = detrend(values)
            var re = 0.0, im = 0.0
            for t in 0..<n {
                let angle = -2 * Double.pi * Double(k * t) / Double(n)
                re += x[t] * cos(angle); im += x[t] * sin(angle)
            }
            return (re, im)
        }
        let ca = coefficient(Array(a.prefix(n)).map(\.value))
        let cb = coefficient(Array(b.prefix(n)).map(\.value))
        let phaseA = atan2(ca.1, ca.0), phaseB = atan2(cb.1, cb.0)
        var delta = phaseB - phaseA
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let ampA = hypot(ca.0, ca.1), ampB = hypot(cb.0, cb.1)
        let totalA = sqrt(detrend(Array(a.prefix(n)).map(\.value)).reduce(0) { $0 + $1 * $1 })
        let totalB = sqrt(detrend(Array(b.prefix(n)).map(\.value)).reduce(0) { $0 + $1 * $1 })
        let coherence = min(1, (ampA / max(totalA, 1e-9)) * (ampB / max(totalB, 1e-9)) / Double(n) * 2)
        return .init(dominantFrequencyHz: f, phaseDifferenceRadians: delta, phaseDifferenceFractionOfCycle: delta / (2 * .pi), coherenceProxy: coherence)
    }

    public static func assess(
        primary: [SpectralSignalSample],
        secondary: [SpectralSignalSample]? = nil,
        limitCycle: LimitCycleFingerprint? = nil,
        knownPeriodicDisturbanceHz: Double? = nil,
        mechanicalSpeedHz: Double? = nil,
        secondaryLoopFrequencyHz: Double? = nil
    ) -> SpectralAssessment {
        let fp = fingerprint(samples: primary)
        guard primary.count >= 32, let dominant = fp.dominantFrequencyHz else {
            return .init(kind: .insufficientEvidence, confidence: .low, fingerprint: fp, crossSignal: nil, evidence: ["At least 32 time-aligned samples are required for a meaningful spectral fingerprint."], summary: "Insufficient evidence for spectral oscillation analysis.")
        }
        let cross = secondary.map { crossSpectralRelationship(primary: primary, secondary: $0) }
        var evidence: [String] = [String(format: "Dominant component %.3f Hz contains %.0f%% of non-DC spectral power.", dominant, fp.dominantPowerFraction * 100)]
        if fp.spectralEntropy > 0.72 { evidence.append(String(format: "Normalized spectral entropy %.2f indicates broad or complex frequency content.", fp.spectralEntropy)) }

        func close(_ a: Double, _ b: Double, tolerance: Double = 0.08) -> Bool { abs(a - b) <= max(abs(b) * tolerance, 0.01) }
        let kind: SpectralOscillationKind
        let confidence: SpectralConfidence
        if fp.dominantPowerFraction < 0.18 {
            kind = .noStrongPeriodicity; confidence = .medium
        } else if let disturbance = knownPeriodicDisturbanceHz, close(dominant, disturbance) {
            kind = .periodicDisturbance; confidence = fp.dominantPowerFraction > 0.45 ? .high : .medium
            evidence.append(String(format: "Dominant frequency matches the authored periodic disturbance %.3f Hz.", disturbance))
        } else if let mechanical = mechanicalSpeedHz, (close(dominant, mechanical) || close(dominant, 2 * mechanical) || close(dominant, 3 * mechanical)) {
            kind = .mechanicalResonance; confidence = .high
            evidence.append(String(format: "Dominant frequency aligns with shaft/mechanical speed or a low-order harmonic of %.3f Hz.", mechanical))
        } else if let loop = secondaryLoopFrequencyHz, fp.peaks.contains(where: { close($0.frequencyHz, loop) }) && fp.peaks.count >= 2 {
            kind = .interactingLoops; confidence = .medium
            evidence.append(String(format: "A significant spectral peak aligns with a second control-loop frequency near %.3f Hz.", loop))
        } else if fp.peaks.count >= 2,
                  fp.peaks[1].powerFraction >= 0.12,
                  let beat = fp.beatFrequencyHz,
                  beat / max(dominant, fp.peaks[1].frequencyHz) <= 0.35 {
            kind = .beating; confidence = .high
            evidence.append(String(format: "Two strong nearby components create an expected beat envelope near %.3f Hz (%.0f ms).", beat, 1000 / beat))
        } else if let limitCycle, limitCycle.sustained, fp.dominantPowerFraction >= 0.45, fp.spectralEntropy <= 0.60 {
            kind = .singleFrequencyLimitCycle; confidence = .high
            evidence.append("The time-domain detector independently confirmed a sustained repeatable limit cycle.")
        } else if fp.spectralEntropy >= 0.70 {
            kind = .broadbandOrComplex; confidence = .medium
        } else {
            kind = .singleFrequencyLimitCycle; confidence = fp.dominantPowerFraction >= 0.55 ? .high : .medium
        }
        if let cross, let phase = cross.phaseDifferenceFractionOfCycle {
            evidence.append(String(format: "Secondary signal phase differs by %.1f%% of a cycle at the dominant frequency.", phase * 100))
        }
        return .init(kind: kind, confidence: confidence, fingerprint: fp, crossSignal: cross, evidence: evidence, summary: "Spectral analysis favors \(kind.displayName.lowercased()) with \(confidence.displayName.lowercased()) confidence; use this as mechanism evidence, not root-cause proof by itself.")
    }

    public static func operatingDependence(_ observations: [SpectralContextObservation]) -> SpectralOperatingDependence {
        let rows = observations.compactMap { obs -> (Double, Double)? in
            guard let f = fingerprint(samples: obs.samples).dominantFrequencyHz else { return nil }
            return (obs.operatingValue, f)
        }
        let corr = correlation(rows)
        let frequencies = rows.map(\.1)
        let ratio: Double? = {
            guard let lo = frequencies.min(), let hi = frequencies.max(), lo > 1e-9 else { return nil }
            return hi / lo
        }()
        let shifts = rows.count >= 3 && ((corr.map { abs($0) >= 0.65 } ?? false) || (ratio.map { $0 >= 1.20 } ?? false))
        let interpretation: String
        if shifts {
            interpretation = String(format: "Dominant oscillation frequency changes materially with operating state%@. Treat a fixed resonance/limit-cycle assumption cautiously.", corr.map { String(format: " (r %.2f)", $0) } ?? "")
        } else {
            interpretation = "No strong operating-state frequency shift was established from the supplied observations."
        }
        return .init(observations: rows.count, frequencyOperatingCorrelation: corr, frequencyRangeRatio: ratio, shiftsWithOperatingState: shifts, interpretation: interpretation)
    }

    private static func emptyFingerprint(samples: [SpectralSignalSample]) -> SpectralFingerprint {
        let duration = samples.count >= 2 ? samples.last!.timeMilliseconds - samples.first!.timeMilliseconds : 0
        return .init(sampleIntervalMilliseconds: 0, analyzedDurationMilliseconds: duration, nyquistHz: 0, dominantFrequencyHz: nil, dominantPeriodMilliseconds: nil, dominantPowerFraction: 0, spectralConcentration: 0, spectralEntropy: 0, peaks: [], beatFrequencyHz: nil, beatPeriodMilliseconds: nil)
    }

    private static func resampleUniform(_ raw: [SpectralSignalSample]) -> [SpectralSignalSample] {
        let sorted = raw.sorted { $0.timeMilliseconds < $1.timeMilliseconds }
        guard sorted.count >= 3 else { return sorted }
        let diffs = sorted.indices.dropFirst().map { sorted[$0].timeMilliseconds - sorted[$0 - 1].timeMilliseconds }.filter { $0 > 0 }
        guard let dt = median(diffs), dt > 0 else { return sorted }
        let start = sorted.first!.timeMilliseconds, end = sorted.last!.timeMilliseconds
        let count = Int(floor((end - start) / dt)) + 1
        var result: [SpectralSignalSample] = []
        result.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let t = start + Double(i) * dt
            while j + 1 < sorted.count && sorted[j + 1].timeMilliseconds < t { j += 1 }
            if j + 1 >= sorted.count { result.append(.init(timeMilliseconds: t, value: sorted[j].value)); continue }
            let a = sorted[j], b = sorted[j + 1]
            let alpha = b.timeMilliseconds > a.timeMilliseconds ? (t - a.timeMilliseconds) / (b.timeMilliseconds - a.timeMilliseconds) : 0
            result.append(.init(timeMilliseconds: t, value: a.value + alpha * (b.value - a.value)))
        }
        return result
    }

    private static func detrend(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let n = Double(values.count)
        let xMean = (n - 1) / 2
        let yMean = values.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, y) in values.enumerated() {
            let x = Double(i) - xMean
            num += x * (y - yMean); den += x * x
        }
        let slope = den > 0 ? num / den : 0
        return values.enumerated().map { i, y in y - (yMean + slope * (Double(i) - xMean)) }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted(), m = v.count / 2
        return v.count.isMultiple(of: 2) ? 0.5 * (v[m - 1] + v[m]) : v[m]
    }

    private static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 3 else { return nil }
        let mx = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let my = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        var num = 0.0, dx = 0.0, dy = 0.0
        for (x, y) in pairs { let a = x - mx, b = y - my; num += a * b; dx += a * a; dy += b * b }
        guard dx > 0, dy > 0 else { return nil }
        return num / sqrt(dx * dy)
    }
}

public struct SpectralLoopAssessment: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: SampledPIDDefinition
    public let assessment: SpectralAssessment
}

public struct SpectralOscillationReport: Equatable, Sendable {
    public let assessments: [SpectralLoopAssessment]
    public let summary: String
}

public extension SpectralOscillationAnalyzer {
    static func assess(sampledPIDReport: SampledPIDReport, limitCycleReport: LimitCycleReport? = nil) -> SpectralOscillationReport {
        let byID = Dictionary(uniqueKeysWithValues: (limitCycleReport?.assessments ?? []).map { ($0.definition.id, $0.fingerprint) })
        let assessments = sampledPIDReport.assessments.map { item -> SpectralLoopAssessment in
            let primary = samples(from: item.simulation, keyPath: \.processValue)
            let secondary = samples(from: item.simulation, keyPath: \.actuatorOutput)
            let result = assess(primary: primary, secondary: secondary, limitCycle: byID[item.definition.id])
            return .init(definition: item.definition, assessment: result)
        }
        let strongest = assessments.max { ($0.assessment.fingerprint.dominantPowerFraction) < ($1.assessment.fingerprint.dominantPowerFraction) }
        let summary = strongest.map { "Spectral analysis evaluated \(assessments.count) loop(s). Strongest periodic structure: \($0.definition.name) — \($0.assessment.kind.displayName)." } ?? "No sampled PID loops were available for spectral analysis."
        return .init(assessments: assessments, summary: summary)
    }
}
