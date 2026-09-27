import Foundation
import ControlsPLC

public struct PhaseShapeFeature: Identifiable, Equatable, Sendable {
    public var id: String { "\(target)|\(layer.rawValue)" }
    public let target: String
    public let layer: FlightSignalLayer
    public let displayName: String
    public let unit: String?

    public init(target: String, layer: FlightSignalLayer, displayName: String? = nil, unit: String? = nil) {
        self.target = target
        self.layer = layer
        self.displayName = displayName ?? target
        self.unit = unit
    }
}

public struct PhaseShapeEnvelopePoint: Identifiable, Equatable, Sendable {
    public var id: String { String(format: "%.4f", phaseFraction) }
    public let phaseFraction: Double
    public let sampleCount: Int
    public let mean: Double
    public let standardDeviation: Double
    public let lower: Double
    public let upper: Double
}

public struct PhaseShapeEnvelope: Identifiable, Equatable, Sendable {
    public var id: String { "\(regionID)|\(feature.id)" }
    public let regionID: String
    public let regionName: String
    public let feature: PhaseShapeFeature
    public let points: [PhaseShapeEnvelopePoint]
}

public struct PhaseDwellTrend: Identifiable, Equatable, Sendable {
    public var id: String { regionID }
    public let regionID: String
    public let regionName: String
    public let sampleCount: Int
    public let slopeMillisecondsPerCycle: Double
    public let rSquared: Double
    public let firstMilliseconds: Double
    public let lastMilliseconds: Double

    public var isProgressivelyStretching: Bool {
        slopeMillisecondsPerCycle >= 1.0 && rSquared >= 0.60 && lastMilliseconds > firstMilliseconds
    }
}

public struct PhaseWarpedTrajectoryModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let phaseBins: Int
    public let baseTrajectoryModel: WithinCycleTrajectoryModel
    public let shapeFeatures: [PhaseShapeFeature]
    public let shapeEnvelopes: [PhaseShapeEnvelope]
    public let dwellTrends: [PhaseDwellTrend]
    public let meanCycleDurationMilliseconds: Double

    public func envelope(regionID: String, featureID: String) -> PhaseShapeEnvelope? {
        shapeEnvelopes.first { $0.regionID == regionID && $0.feature.id == featureID }
    }
}

public struct LocalizedPhaseDeviation: Identifiable, Equatable, Sendable {
    public var id: String { "\(regionID)|\(feature.id)|\(Int(round(phaseFraction * 1000)))" }
    public let regionID: String
    public let regionName: String
    public let feature: PhaseShapeFeature
    public let phaseFraction: Double
    public let observed: Double
    public let expectedMean: Double
    public let zScore: Double
    public let relativeMilliseconds: Int64
    public let explanation: String
}

public enum PhaseWarpedAssessmentStatus: String, Codable, Sendable {
    case normal
    case localizedDeviation
    case insufficientData

    public var displayName: String {
        switch self {
        case .normal: return "Phase-aligned shape normal"
        case .localizedDeviation: return "Localized trajectory-shape deviation"
        case .insufficientData: return "Insufficient phase-aligned data"
        }
    }
}

public struct PhaseWarpedTrajectoryAssessment: Equatable, Sendable {
    public let status: PhaseWarpedAssessmentStatus
    public let cycleDurationMilliseconds: Int64
    public let durationScale: Double
    public let deviations: [LocalizedPhaseDeviation]
    public let summary: String

    public var earliestDeviation: LocalizedPhaseDeviation? {
        deviations.min {
            if $0.relativeMilliseconds != $1.relativeMilliseconds { return $0.relativeMilliseconds < $1.relativeMilliseconds }
            return $0.phaseFraction < $1.phaseFraction
        }
    }
}

public enum PhaseWarpedTrajectoryAnalyzer {
    /// Learns waveform shape inside each learned state after normalizing every state to 0...100% phase.
    /// Real dwell time is retained separately so time warping cannot hide a progressively stretching phase.
    public static func buildModel(
        name: String = "Phase-warped trajectory model",
        cycles: [KnownGoodCycle],
        baseTrajectoryModel: WithinCycleTrajectoryModel,
        shapeFeatures: [PhaseShapeFeature],
        phaseBins: Int = 25,
        minimumCycles: Int = 6
    ) -> PhaseWarpedTrajectoryModel? {
        guard cycles.count >= minimumCycles, phaseBins >= 8, !shapeFeatures.isEmpty else { return nil }
        let trajectories = cycles.map {
            WithinCycleStateTrajectoryAnalyzer.trajectory(for: $0, model: baseTrajectoryModel.operatingStateModel, samplingIntervalMilliseconds: baseTrajectoryModel.samplingIntervalMilliseconds)
        }
        guard trajectories.filter({ !$0.segments.isEmpty }).count >= minimumCycles else { return nil }

        var envelopes: [PhaseShapeEnvelope] = []
        let regionIDs = baseTrajectoryModel.dominantPath.isEmpty
            ? baseTrajectoryModel.operatingStateModel.regions.map(\.id)
            : baseTrajectoryModel.dominantPath

        for regionID in regionIDs {
            guard let region = baseTrajectoryModel.operatingStateModel.region(id: regionID) else { continue }
            for feature in shapeFeatures {
                var valuesByBin = Array(repeating: [Double](), count: phaseBins)
                for (index, cycle) in cycles.enumerated() {
                    guard index < trajectories.count,
                          let segment = firstSegment(regionID: regionID, in: trajectories[index].segments) else { continue }
                    for bin in 0..<phaseBins {
                        let phase = Double(bin) / Double(phaseBins - 1)
                        let relative = phaseTime(segment: segment, phase: phase)
                        let absolute = cycle.anchorMilliseconds + relative
                        if let value = interpolatedNumeric(feature: feature, cycle: cycle, at: absolute) {
                            valuesByBin[bin].append(value)
                        }
                    }
                }
                let points = valuesByBin.enumerated().compactMap { bin, values -> PhaseShapeEnvelopePoint? in
                    guard values.count >= minimumCycles else { return nil }
                    let phase = Double(bin) / Double(phaseBins - 1)
                    return envelopePoint(phase: phase, values: values)
                }
                if points.count == phaseBins {
                    envelopes.append(PhaseShapeEnvelope(regionID: regionID, regionName: region.name, feature: feature, points: points))
                }
            }
        }

        var dwellTrends: [PhaseDwellTrend] = []
        for regionID in regionIDs {
            guard let region = baseTrajectoryModel.operatingStateModel.region(id: regionID) else { continue }
            let values: [Double] = trajectories.compactMap { trajectory in
                firstSegment(regionID: regionID, in: trajectory.segments).map { Double($0.durationMilliseconds) }
            }
            guard values.count >= minimumCycles else { continue }
            let regression = linearRegression(values)
            dwellTrends.append(PhaseDwellTrend(
                regionID: regionID,
                regionName: region.name,
                sampleCount: values.count,
                slopeMillisecondsPerCycle: regression.slope,
                rSquared: regression.rSquared,
                firstMilliseconds: values.first ?? 0,
                lastMilliseconds: values.last ?? 0
            ))
        }

        guard !envelopes.isEmpty else { return nil }
        let durations = zip(cycles, trajectories).compactMap { cycle, trajectory -> Double? in
            guard let first = trajectory.segments.first, let last = trajectory.segments.last else { return nil }
            return Double(last.endRelativeMilliseconds - first.startRelativeMilliseconds + baseTrajectoryModel.samplingIntervalMilliseconds)
        }
        let meanDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        return PhaseWarpedTrajectoryModel(
            name: name,
            cycleCount: cycles.count,
            phaseBins: phaseBins,
            baseTrajectoryModel: baseTrajectoryModel,
            shapeFeatures: shapeFeatures,
            shapeEnvelopes: envelopes,
            dwellTrends: dwellTrends,
            meanCycleDurationMilliseconds: meanDuration
        )
    }

    public static func assess(
        cycle: KnownGoodCycle,
        against model: PhaseWarpedTrajectoryModel,
        zThreshold: Double = 3.0,
        consecutiveBins: Int = 2
    ) -> PhaseWarpedTrajectoryAssessment {
        let trajectory = WithinCycleStateTrajectoryAnalyzer.trajectory(
            for: cycle,
            model: model.baseTrajectoryModel.operatingStateModel,
            samplingIntervalMilliseconds: model.baseTrajectoryModel.samplingIntervalMilliseconds
        )
        guard let first = trajectory.segments.first, let last = trajectory.segments.last, !model.shapeEnvelopes.isEmpty else {
            return PhaseWarpedTrajectoryAssessment(status: .insufficientData, cycleDurationMilliseconds: 0, durationScale: 0, deviations: [], summary: "The capture does not contain enough state-aligned waveform data for phase-warped shape comparison.")
        }
        let duration = last.endRelativeMilliseconds - first.startRelativeMilliseconds + model.baseTrajectoryModel.samplingIntervalMilliseconds
        let scale = model.meanCycleDurationMilliseconds > 0 ? Double(duration) / model.meanCycleDurationMilliseconds : 1
        var deviations: [LocalizedPhaseDeviation] = []

        for envelope in model.shapeEnvelopes {
            guard let segment = firstSegment(regionID: envelope.regionID, in: trajectory.segments) else { continue }
            var run: [(PhaseShapeEnvelopePoint, Double, Double, Int64)] = []
            func flushRun() {
                guard run.count >= max(1, consecutiveBins), let firstBad = run.first else { run.removeAll(); return }
                let point = firstBad.0
                let observed = firstBad.1
                let z = firstBad.2
                let relative = firstBad.3
                let percent = Int(round(point.phaseFraction * 100))
                deviations.append(LocalizedPhaseDeviation(
                    regionID: envelope.regionID,
                    regionName: envelope.regionName,
                    feature: envelope.feature,
                    phaseFraction: point.phaseFraction,
                    observed: observed,
                    expectedMean: point.mean,
                    zScore: z,
                    relativeMilliseconds: relative,
                    explanation: "\(envelope.feature.displayName) first departed from the learned \(envelope.regionName) shape near \(percent)% phase progress (z \(String(format: "%+.2f", z))). Phase alignment removes harmless overall speed differences; this is a localized shape change."
                ))
                run.removeAll()
            }

            for point in envelope.points {
                // Learned state boundaries can move by a sample or two when the entire cycle runs
                // faster/slower. Do not turn boundary-placement jitter into a waveform-shape alarm.
                // Shape comparison focuses on the interior of the phase; entry/dwell models own
                // the transition timing itself.
                if point.phaseFraction < 0.08 || point.phaseFraction > 0.92 {
                    flushRun()
                    continue
                }
                let relative = phaseTime(segment: segment, phase: point.phaseFraction)
                let absolute = cycle.anchorMilliseconds + relative
                guard let observed = interpolatedNumeric(feature: envelope.feature, cycle: cycle, at: absolute) else {
                    flushRun(); continue
                }
                let sigma = max(point.standardDeviation, max(abs(point.mean) * 0.005, 1e-6))
                let z = (observed - point.mean) / sigma
                if abs(z) >= zThreshold {
                    run.append((point, observed, z, relative))
                } else {
                    flushRun()
                }
            }
            flushRun()
        }

        deviations.sort {
            if $0.relativeMilliseconds != $1.relativeMilliseconds { return $0.relativeMilliseconds < $1.relativeMilliseconds }
            return $0.phaseFraction < $1.phaseFraction
        }
        let status: PhaseWarpedAssessmentStatus = deviations.isEmpty ? .normal : .localizedDeviation
        let summary: String
        if let earliest = deviations.first {
            summary = "Phase-warped comparison found \(deviations.count) localized shape deviation\(deviations.count == 1 ? "" : "s"). Earliest: \(earliest.feature.displayName) in \(earliest.regionName) near \(Int(round(earliest.phaseFraction * 100)))% phase progress. Overall cycle duration was \(String(format: "%.2f×", scale)) the learned mean, but speed normalization did not explain this local shape change."
        } else {
            summary = "The cycle shape remains inside the learned phase-normalized envelopes. Overall duration was \(String(format: "%.2f×", scale)) the healthy mean; proportional speed variation was treated as timing warp rather than degradation."
        }
        return PhaseWarpedTrajectoryAssessment(status: status, cycleDurationMilliseconds: duration, durationScale: scale, deviations: deviations, summary: summary)
    }

    private static func firstSegment(regionID: String, in segments: [TrajectoryStateSegment]) -> TrajectoryStateSegment? {
        segments.first { $0.regionID == regionID }
    }

    private static func phaseTime(segment: TrajectoryStateSegment, phase: Double) -> Int64 {
        let span = max(Int64(0), segment.endRelativeMilliseconds - segment.startRelativeMilliseconds)
        return segment.startRelativeMilliseconds + Int64(round(Double(span) * max(0, min(1, phase))))
    }

    private static func interpolatedNumeric(feature: PhaseShapeFeature, cycle: KnownGoodCycle, at milliseconds: Int64) -> Double? {
        let samples = cycle.signalSamples
            .filter { $0.target == feature.target && $0.layer == feature.layer }
            .sorted { $0.milliseconds < $1.milliseconds }
        guard !samples.isEmpty else { return nil }
        if milliseconds <= samples[0].milliseconds { return numeric(samples[0].value) }
        if milliseconds >= samples[samples.count - 1].milliseconds { return numeric(samples[samples.count - 1].value) }
        guard let upperIndex = samples.firstIndex(where: { $0.milliseconds >= milliseconds }), upperIndex > 0 else { return nil }
        let lower = samples[upperIndex - 1], upper = samples[upperIndex]
        guard let a = numeric(lower.value), let b = numeric(upper.value) else { return nil }
        if upper.milliseconds == lower.milliseconds { return b }
        let fraction = Double(milliseconds - lower.milliseconds) / Double(upper.milliseconds - lower.milliseconds)
        return a + (b - a) * fraction
    }

    private static func numeric(_ value: TagValue) -> Double? {
        switch value {
        case let .bool(v): return v ? 1 : 0
        case let .dint(v): return Double(v)
        case let .real(v): return v
        case let .timer(v): return Double(v.ACC)
        case let .counter(v): return Double(v.ACC)
        }
    }

    private static func envelopePoint(phase: Double, values: [Double]) -> PhaseShapeEnvelopePoint {
        let sorted = values.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let variance = sorted.count > 1 ? sorted.reduce(0) { $0 + pow($1 - mean, 2) } / Double(sorted.count - 1) : 0
        let sigma = sqrt(max(variance, 0))
        let median = percentile(sorted, 0.5)
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let robustSigma = max(percentile(deviations, 0.5) * 1.4826, sigma, max(abs(mean) * 0.002, 1e-6))
        let low = min(percentile(sorted, 0.05), median - 3.0 * robustSigma)
        let high = max(percentile(sorted, 0.95), median + 3.0 * robustSigma)
        return PhaseShapeEnvelopePoint(phaseFraction: phase, sampleCount: sorted.count, mean: mean, standardDeviation: robustSigma, lower: low, upper: high)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let x = max(0, min(1, p)) * Double(sorted.count - 1)
        let lo = Int(floor(x)), hi = Int(ceil(x))
        if lo == hi { return sorted[lo] }
        let fraction = x - Double(lo)
        return sorted[lo] * (1 - fraction) + sorted[hi] * fraction
    }

    private static func linearRegression(_ values: [Double]) -> (slope: Double, rSquared: Double) {
        guard values.count >= 2 else { return (0, 0) }
        let n = Double(values.count)
        let xs = values.indices.map(Double.init)
        let meanX = xs.reduce(0, +) / n
        let meanY = values.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        let sxy = zip(xs, values).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let slope = sxx > 0 ? sxy / sxx : 0
        let intercept = meanY - slope * meanX
        let ssTotal = values.reduce(0) { $0 + pow($1 - meanY, 2) }
        let ssResidual = zip(xs, values).reduce(0) { $0 + pow($1.1 - (intercept + slope * $1.0), 2) }
        let r2 = ssTotal > 1e-12 ? max(0, min(1, 1 - ssResidual / ssTotal)) : 0
        return (slope, r2)
    }
}
