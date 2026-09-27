import Foundation
import ControlsPLC

public enum LagSignatureKind: String, Codable, Sendable {
    case phaseLeadLag
    case propagationDelay

    public var displayName: String {
        switch self {
        case .phaseLeadLag: return "Phase lead / lag"
        case .propagationDelay: return "Propagation delay"
        }
    }
}

public enum LagRelationshipBasis: String, Codable, Sendable {
    case learnedCorrelation
    case authoredCausalPath

    public var displayName: String {
        switch self {
        case .learnedCorrelation: return "Learned timing correlation"
        case .authoredCausalPath: return "Authored / recorded causal path"
        }
    }
}

public struct LagSignalReference: Identifiable, Equatable, Sendable {
    public var id: String { "\(target)|\(layer.rawValue)" }
    public let target: String
    public let layer: FlightSignalLayer
    public let displayName: String

    public init(target: String, layer: FlightSignalLayer, displayName: String? = nil) {
        self.target = target
        self.layer = layer
        self.displayName = displayName ?? target
    }
}

public struct CrossSignalLagDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: LagSignatureKind
    public let upstream: LagSignalReference
    public let downstream: LagSignalReference
    public let regionID: String?
    public let upstreamResultingValue: TagValue?
    public let downstreamResultingValue: TagValue?
    public let relationshipBasis: LagRelationshipBasis
    public let maximumPhaseLagFraction: Double

    public init(
        id: String? = nil,
        name: String? = nil,
        kind: LagSignatureKind,
        upstream: LagSignalReference,
        downstream: LagSignalReference,
        regionID: String? = nil,
        upstreamResultingValue: TagValue? = nil,
        downstreamResultingValue: TagValue? = nil,
        relationshipBasis: LagRelationshipBasis = .learnedCorrelation,
        maximumPhaseLagFraction: Double = 0.25
    ) {
        self.id = id ?? "\(kind.rawValue)|\(upstream.id)->\(downstream.id)|\(regionID ?? "cycle")"
        self.name = name ?? "\(upstream.displayName) → \(downstream.displayName)"
        self.kind = kind
        self.upstream = upstream
        self.downstream = downstream
        self.regionID = regionID
        self.upstreamResultingValue = upstreamResultingValue
        self.downstreamResultingValue = downstreamResultingValue
        self.relationshipBasis = relationshipBasis
        self.maximumPhaseLagFraction = max(0.01, min(0.49, maximumPhaseLagFraction))
    }
}

public struct LagSignatureEnvelope: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: CrossSignalLagDefinition
    public let sampleCount: Int
    /// Positive means the downstream signal follows the upstream signal.
    public let meanLagMilliseconds: Double?
    /// Positive means the downstream signal follows the upstream signal in normalized phase.
    public let meanLagPhaseFraction: Double?
    public let standardDeviationMilliseconds: Double?
    public let standardDeviationPhaseFraction: Double?
    public let lowerMilliseconds: Double?
    public let upperMilliseconds: Double?
    public let lowerPhaseFraction: Double?
    public let upperPhaseFraction: Double?
    public let meanCorrelation: Double?
    public let lagTrendPerCycle: Double
    public let lagTrendRSquared: Double

    public var isProgressivelyDesynchronizing: Bool {
        abs(lagTrendPerCycle) > 0.002 && lagTrendRSquared >= 0.60
    }
}

public struct CrossSignalLagModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let baseTrajectoryModel: WithinCycleTrajectoryModel
    public let definitions: [CrossSignalLagDefinition]
    public let envelopes: [LagSignatureEnvelope]

    public func envelope(id: String) -> LagSignatureEnvelope? { envelopes.first { $0.id == id } }
}

public enum LagSignatureAssessmentStatus: String, Codable, Sendable {
    case synchronized
    case emergingDesynchronization
    case anomalousLag
    case insufficientData

    public var displayName: String {
        switch self {
        case .synchronized: return "Signals synchronized"
        case .emergingDesynchronization: return "Emerging synchronization drift"
        case .anomalousLag: return "Abnormal propagation / phase lag"
        case .insufficientData: return "Insufficient lag evidence"
        }
    }
}

public struct LagSignatureFinding: Identifiable, Equatable, Sendable {
    public var id: String { envelope.id }
    public let envelope: LagSignatureEnvelope
    public let observedLagMilliseconds: Double?
    public let observedLagPhaseFraction: Double?
    public let observedCorrelation: Double?
    public let standardizedDeviation: Double
    public let abnormal: Bool
    public let explanation: String
}

public struct CrossSignalLagAssessment: Equatable, Sendable {
    public let status: LagSignatureAssessmentStatus
    public let findings: [LagSignatureFinding]
    public let summary: String

    public var abnormalFindings: [LagSignatureFinding] { findings.filter(\.abnormal) }
}

public enum CrossSignalLagAnalyzer {
    public static func buildModel(
        name: String = "Cross-signal phase-lag model",
        cycles: [KnownGoodCycle],
        baseTrajectoryModel: WithinCycleTrajectoryModel,
        definitions: [CrossSignalLagDefinition],
        phaseBins: Int = 51,
        minimumCycles: Int = 6
    ) -> CrossSignalLagModel? {
        guard cycles.count >= minimumCycles, definitions.count > 0, phaseBins >= 21 else { return nil }
        var envelopes: [LagSignatureEnvelope] = []

        for definition in definitions {
            var msValues: [Double] = []
            var phaseValues: [Double] = []
            var correlations: [Double] = []

            for cycle in cycles {
                guard let measurement = measure(definition, cycle: cycle, base: baseTrajectoryModel, phaseBins: phaseBins) else { continue }
                if let v = measurement.milliseconds { msValues.append(v) }
                if let v = measurement.phaseFraction { phaseValues.append(v) }
                if let v = measurement.correlation { correlations.append(v) }
            }

            let n = max(msValues.count, phaseValues.count)
            guard n >= minimumCycles else { continue }
            let msStats = msValues.isEmpty ? nil : robustStats(msValues)
            let phaseStats = phaseValues.isEmpty ? nil : robustStats(phaseValues)
            let trendSource = !phaseValues.isEmpty ? phaseValues : msValues
            let trend = linearRegression(trendSource)
            envelopes.append(LagSignatureEnvelope(
                definition: definition,
                sampleCount: n,
                meanLagMilliseconds: msStats?.mean,
                meanLagPhaseFraction: phaseStats?.mean,
                standardDeviationMilliseconds: msStats?.sigma,
                standardDeviationPhaseFraction: phaseStats?.sigma,
                lowerMilliseconds: msStats?.lower,
                upperMilliseconds: msStats?.upper,
                lowerPhaseFraction: phaseStats?.lower,
                upperPhaseFraction: phaseStats?.upper,
                meanCorrelation: correlations.isEmpty ? nil : correlations.reduce(0, +) / Double(correlations.count),
                lagTrendPerCycle: trend.slope,
                lagTrendRSquared: trend.rSquared
            ))
        }
        guard !envelopes.isEmpty else { return nil }
        return CrossSignalLagModel(name: name, cycleCount: cycles.count, baseTrajectoryModel: baseTrajectoryModel, definitions: definitions, envelopes: envelopes)
    }

    public static func assess(
        cycle: KnownGoodCycle,
        against model: CrossSignalLagModel,
        phaseBins: Int = 51,
        warningZ: Double = 2.0,
        anomalyZ: Double = 3.0
    ) -> CrossSignalLagAssessment {
        var findings: [LagSignatureFinding] = []
        for envelope in model.envelopes {
            guard let measured = measure(envelope.definition, cycle: cycle, base: model.baseTrajectoryModel, phaseBins: phaseBins) else { continue }
            let z: Double
            if let observed = measured.phaseFraction, let mean = envelope.meanLagPhaseFraction, let sigma = envelope.standardDeviationPhaseFraction {
                z = (observed - mean) / max(sigma, 0.005)
            } else if let observed = measured.milliseconds, let mean = envelope.meanLagMilliseconds, let sigma = envelope.standardDeviationMilliseconds {
                z = (observed - mean) / max(sigma, 1.0)
            } else {
                continue
            }
            let abnormal = abs(z) >= warningZ
            let basisText = envelope.definition.relationshipBasis == .authoredCausalPath
                ? "The relationship is backed by an authored/recorded causal path."
                : "This is a learned timing relationship; timing correlation alone does not prove causality."
            let lagText: String
            if let phase = measured.phaseFraction {
                lagText = String(format: "%+.1f%% phase", phase * 100)
            } else if let ms = measured.milliseconds {
                lagText = String(format: "%+.1f ms", ms)
            } else { lagText = "unresolved" }
            findings.append(LagSignatureFinding(
                envelope: envelope,
                observedLagMilliseconds: measured.milliseconds,
                observedLagPhaseFraction: measured.phaseFraction,
                observedCorrelation: measured.correlation,
                standardizedDeviation: z,
                abnormal: abnormal,
                explanation: "\(envelope.definition.name) measured \(lagText), z \(String(format: "%+.2f", z)) relative to healthy synchronization. \(basisText)"
            ))
        }

        guard !findings.isEmpty else {
            return CrossSignalLagAssessment(status: .insufficientData, findings: [], summary: "The cycle does not contain enough paired signal evidence to evaluate learned synchronization signatures.")
        }
        let maxZ = findings.map { abs($0.standardizedDeviation) }.max() ?? 0
        let drifting = model.envelopes.contains(where: \.isProgressivelyDesynchronizing)
        let status: LagSignatureAssessmentStatus
        if maxZ >= anomalyZ { status = .anomalousLag }
        else if maxZ >= warningZ || drifting { status = .emergingDesynchronization }
        else { status = .synchronized }
        let summary: String
        switch status {
        case .synchronized:
            summary = "Cross-signal timing remains inside the learned healthy synchronization signatures. Individual waveform health and inter-signal propagation timing agree."
        case .emergingDesynchronization:
            summary = "The machine is beginning to fall out of its learned synchronization pattern. At least one lead/lag relationship is drifting before a large standalone waveform anomaly is required."
        case .anomalousLag:
            let worst = findings.max { abs($0.standardizedDeviation) < abs($1.standardizedDeviation) }
            summary = "An abnormal cross-signal lag was detected. \(worst?.explanation ?? "")"
        case .insufficientData:
            summary = "Insufficient paired evidence for lag assessment."
        }
        return CrossSignalLagAssessment(status: status, findings: findings.sorted { abs($0.standardizedDeviation) > abs($1.standardizedDeviation) }, summary: summary)
    }

    private struct Measurement {
        let milliseconds: Double?
        let phaseFraction: Double?
        let correlation: Double?
    }

    private static func measure(_ definition: CrossSignalLagDefinition, cycle: KnownGoodCycle, base: WithinCycleTrajectoryModel, phaseBins: Int) -> Measurement? {
        switch definition.kind {
        case .propagationDelay:
            guard let a = transitionTime(signal: definition.upstream, resultingValue: definition.upstreamResultingValue, cycle: cycle),
                  let b = transitionTime(signal: definition.downstream, resultingValue: definition.downstreamResultingValue, cycle: cycle), b >= a else { return nil }
            return Measurement(milliseconds: Double(b - a), phaseFraction: nil, correlation: nil)
        case .phaseLeadLag:
            let trajectory = WithinCycleStateTrajectoryAnalyzer.trajectory(for: cycle, model: base.operatingStateModel, samplingIntervalMilliseconds: base.samplingIntervalMilliseconds)
            let segment: TrajectoryStateSegment?
            if let regionID = definition.regionID { segment = trajectory.segments.first { $0.regionID == regionID } }
            else { segment = trajectory.segments.first }
            guard let segment else { return nil }
            let span = max(Int64(1), segment.endRelativeMilliseconds - segment.startRelativeMilliseconds)
            let xs = normalizedSignal(definition.upstream, cycle: cycle, segment: segment, bins: phaseBins)
            let ys = normalizedSignal(definition.downstream, cycle: cycle, segment: segment, bins: phaseBins)
            guard xs.count == phaseBins, ys.count == phaseBins else { return nil }
            let maxShift = max(1, min(phaseBins / 2 - 1, Int(round(definition.maximumPhaseLagFraction * Double(phaseBins - 1)))))
            var best: (shift: Int, correlation: Double)?
            for shift in -maxShift...maxShift {
                var a: [Double] = [], b: [Double] = []
                for i in 0..<phaseBins {
                    let j = i + shift
                    guard j >= 0, j < phaseBins else { continue }
                    a.append(xs[i]); b.append(ys[j])
                }
                guard a.count >= 8, let r = pearson(a, b) else { continue }
                if best == nil || r > best!.correlation { best = (shift, r) }
            }
            guard let best else { return nil }
            let phase = Double(best.shift) / Double(phaseBins - 1)
            return Measurement(milliseconds: phase * Double(span), phaseFraction: phase, correlation: best.correlation)
        }
    }

    private static func normalizedSignal(_ signal: LagSignalReference, cycle: KnownGoodCycle, segment: TrajectoryStateSegment, bins: Int) -> [Double] {
        let span = max(Int64(0), segment.endRelativeMilliseconds - segment.startRelativeMilliseconds)
        return (0..<bins).compactMap { bin in
            let phase = Double(bin) / Double(bins - 1)
            let relative = segment.startRelativeMilliseconds + Int64(round(Double(span) * phase))
            return interpolatedNumeric(signal: signal, cycle: cycle, at: cycle.anchorMilliseconds + relative)
        }
    }

    private static func transitionTime(signal: LagSignalReference, resultingValue: TagValue?, cycle: KnownGoodCycle) -> Int64? {
        let samples = cycle.signalSamples.filter { $0.target == signal.target && $0.layer == signal.layer }.sorted { $0.milliseconds < $1.milliseconds }
        guard samples.count >= 2 else { return nil }
        for i in 1..<samples.count where samples[i].value != samples[i - 1].value {
            if resultingValue == nil || samples[i].value == resultingValue { return samples[i].milliseconds }
        }
        return nil
    }

    private static func interpolatedNumeric(signal: LagSignalReference, cycle: KnownGoodCycle, at milliseconds: Int64) -> Double? {
        let samples = cycle.signalSamples.filter { $0.target == signal.target && $0.layer == signal.layer }.sorted { $0.milliseconds < $1.milliseconds }
        guard !samples.isEmpty else { return nil }
        if milliseconds <= samples[0].milliseconds { return numeric(samples[0].value) }
        if milliseconds >= samples.last!.milliseconds { return numeric(samples.last!.value) }
        guard let upperIndex = samples.firstIndex(where: { $0.milliseconds >= milliseconds }), upperIndex > 0 else { return nil }
        let lower = samples[upperIndex - 1], upper = samples[upperIndex]
        guard let a = numeric(lower.value), let b = numeric(upper.value) else { return nil }
        if upper.milliseconds == lower.milliseconds { return b }
        let f = Double(milliseconds - lower.milliseconds) / Double(upper.milliseconds - lower.milliseconds)
        return a + (b - a) * f
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

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count >= 3 else { return nil }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        let da = a.map { $0 - ma }, db = b.map { $0 - mb }
        let denom = sqrt(da.reduce(0) { $0 + $1 * $1 } * db.reduce(0) { $0 + $1 * $1 })
        guard denom > 1e-12 else { return nil }
        return zip(da, db).reduce(0) { $0 + $1.0 * $1.1 } / denom
    }

    private static func robustStats(_ values: [Double]) -> (mean: Double, sigma: Double, lower: Double, upper: Double) {
        let sorted = values.sorted(), mean = sorted.reduce(0, +) / Double(sorted.count)
        let median = percentile(sorted, 0.5)
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let madSigma = percentile(deviations, 0.5) * 1.4826
        let variance = sorted.count > 1 ? sorted.reduce(0) { $0 + pow($1 - mean, 2) } / Double(sorted.count - 1) : 0
        let sigma = max(madSigma, sqrt(max(0, variance)), max(abs(mean) * 0.02, 1e-6))
        return (mean, sigma, median - 3 * sigma, median + 3 * sigma)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let x = max(0, min(1, p)) * Double(sorted.count - 1)
        let lo = Int(floor(x)), hi = Int(ceil(x))
        if lo == hi { return sorted[lo] }
        let f = x - Double(lo)
        return sorted[lo] * (1 - f) + sorted[hi] * f
    }

    private static func linearRegression(_ values: [Double]) -> (slope: Double, rSquared: Double) {
        guard values.count >= 2 else { return (0, 0) }
        let xs = values.indices.map(Double.init), n = Double(values.count)
        let mx = xs.reduce(0, +) / n, my = values.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        let sxy = zip(xs, values).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let slope = sxx > 0 ? sxy / sxx : 0, intercept = my - slope * mx
        let total = values.reduce(0) { $0 + pow($1 - my, 2) }
        let residual = zip(xs, values).reduce(0) { $0 + pow($1.1 - (intercept + slope * $1.0), 2) }
        return (slope, total > 1e-12 ? max(0, min(1, 1 - residual / total)) : 0)
    }
}
