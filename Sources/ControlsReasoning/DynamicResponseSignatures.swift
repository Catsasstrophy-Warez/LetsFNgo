import Foundation
import ControlsPLC

public enum DynamicResponseMetric: String, Codable, Sendable, CaseIterable {
    case deadTimeMilliseconds
    case riseTimeMilliseconds
    case gain
    case overshootFraction
    case settlingTimeMilliseconds
    case dampingRatio

    public var displayName: String {
        switch self {
        case .deadTimeMilliseconds: return "Dead time"
        case .riseTimeMilliseconds: return "Rise time"
        case .gain: return "Static gain"
        case .overshootFraction: return "Overshoot"
        case .settlingTimeMilliseconds: return "Settling time"
        case .dampingRatio: return "Damping ratio"
        }
    }
}

public struct DynamicResponseDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let command: LagSignalReference
    public let response: LagSignalReference
    public let commandResultingValue: TagValue
    public let relationshipBasis: LagRelationshipBasis
    public let responseWindowMilliseconds: Int64
    public let settlingToleranceFraction: Double

    public init(
        id: String? = nil,
        name: String? = nil,
        command: LagSignalReference,
        response: LagSignalReference,
        commandResultingValue: TagValue,
        relationshipBasis: LagRelationshipBasis = .authoredCausalPath,
        responseWindowMilliseconds: Int64 = 2_000,
        settlingToleranceFraction: Double = 0.05
    ) {
        self.id = id ?? "dynamic|\(command.id)->\(response.id)"
        self.name = name ?? "\(command.displayName) → \(response.displayName)"
        self.command = command
        self.response = response
        self.commandResultingValue = commandResultingValue
        self.relationshipBasis = relationshipBasis
        self.responseWindowMilliseconds = max(100, responseWindowMilliseconds)
        self.settlingToleranceFraction = max(0.01, min(0.20, settlingToleranceFraction))
    }
}

public struct DynamicResponseMeasurement: Equatable, Sendable {
    public let commandMilliseconds: Int64
    public let baseline: Double
    public let finalValue: Double
    public let deadTimeMilliseconds: Double
    public let riseTimeMilliseconds: Double
    public let gain: Double
    public let overshootFraction: Double
    public let settlingTimeMilliseconds: Double
    public let dampingRatio: Double?
}

public struct DynamicMetricEnvelope: Identifiable, Equatable, Sendable {
    public var id: String { metric.rawValue }
    public let metric: DynamicResponseMetric
    public let mean: Double
    public let sigma: Double
    public let lower: Double
    public let upper: Double
    public let trendPerCycle: Double
    public let trendRSquared: Double
}

public struct DynamicResponseSignature: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: DynamicResponseDefinition
    public let sampleCount: Int
    public let metrics: [DynamicMetricEnvelope]

    public func envelope(_ metric: DynamicResponseMetric) -> DynamicMetricEnvelope? { metrics.first { $0.metric == metric } }
}

public struct DynamicResponseModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let signatures: [DynamicResponseSignature]
}

public enum DynamicResponseAssessmentStatus: String, Codable, Sendable {
    case healthy
    case emergingDegradation
    case degradedResponse
    case insufficientData

    public var displayName: String {
        switch self {
        case .healthy: return "Healthy dynamic response"
        case .emergingDegradation: return "Emerging response degradation"
        case .degradedResponse: return "Degraded dynamic response"
        case .insufficientData: return "Insufficient response evidence"
        }
    }
}

public struct DynamicMetricFinding: Identifiable, Equatable, Sendable {
    public var id: String { "\(signatureID)|\(metric.rawValue)" }
    public let signatureID: String
    public let metric: DynamicResponseMetric
    public let observed: Double
    public let expected: Double
    public let standardizedDeviation: Double
    public let abnormal: Bool
    public let explanation: String
}

public struct DynamicResponseAssessment: Equatable, Sendable {
    public let status: DynamicResponseAssessmentStatus
    public let findings: [DynamicMetricFinding]
    public let summary: String
    public var abnormalFindings: [DynamicMetricFinding] { findings.filter(\.abnormal) }
}

public enum DynamicResponseAnalyzer {
    public static func buildModel(
        name: String = "Dynamic response model",
        cycles: [KnownGoodCycle],
        definitions: [DynamicResponseDefinition],
        minimumCycles: Int = 6
    ) -> DynamicResponseModel? {
        guard cycles.count >= minimumCycles, !definitions.isEmpty else { return nil }
        var signatures: [DynamicResponseSignature] = []
        for definition in definitions {
            let measured = cycles.compactMap { measure(definition, cycle: $0) }
            guard measured.count >= minimumCycles else { continue }
            var envelopes: [DynamicMetricEnvelope] = []
            for metric in DynamicResponseMetric.allCases {
                let values = measured.compactMap { value(metric, from: $0) }
                guard values.count >= minimumCycles else { continue }
                let stats = robustStats(values)
                let trend = linearRegression(values)
                envelopes.append(DynamicMetricEnvelope(metric: metric, mean: stats.mean, sigma: stats.sigma, lower: stats.lower, upper: stats.upper, trendPerCycle: trend.slope, trendRSquared: trend.rSquared))
            }
            if !envelopes.isEmpty {
                signatures.append(DynamicResponseSignature(definition: definition, sampleCount: measured.count, metrics: envelopes))
            }
        }
        guard !signatures.isEmpty else { return nil }
        return DynamicResponseModel(name: name, cycleCount: cycles.count, signatures: signatures)
    }

    public static func assess(
        cycle: KnownGoodCycle,
        against model: DynamicResponseModel,
        warningZ: Double = 2.0,
        anomalyZ: Double = 3.0
    ) -> DynamicResponseAssessment {
        var findings: [DynamicMetricFinding] = []
        for signature in model.signatures {
            guard let measurement = measure(signature.definition, cycle: cycle) else { continue }
            for envelope in signature.metrics {
                guard let observed = value(envelope.metric, from: measurement) else { continue }
                let z = (observed - envelope.mean) / max(envelope.sigma, metricFloor(envelope.metric))
                let abnormal = abs(z) >= warningZ
                let basis = signature.definition.relationshipBasis == .authoredCausalPath
                    ? "This command/response relationship is causally authored or recorded."
                    : "This is a learned response relationship; correlation alone does not prove causality."
                findings.append(DynamicMetricFinding(
                    signatureID: signature.id,
                    metric: envelope.metric,
                    observed: observed,
                    expected: envelope.mean,
                    standardizedDeviation: z,
                    abnormal: abnormal,
                    explanation: "\(signature.definition.name): \(envelope.metric.displayName) measured \(format(envelope.metric, observed)) versus healthy \(format(envelope.metric, envelope.mean)), z \(String(format: "%+.2f", z)). \(basis)"
                ))
            }
        }
        guard !findings.isEmpty else {
            return DynamicResponseAssessment(status: .insufficientData, findings: [], summary: "The cycle does not contain enough command/response data to calculate a dynamic response signature.")
        }
        let maxZ = findings.map { abs($0.standardizedDeviation) }.max() ?? 0
        let trending = model.signatures.flatMap(\.metrics).contains { abs($0.trendPerCycle) > metricFloor($0.metric) * 0.10 && $0.trendRSquared >= 0.60 }
        let status: DynamicResponseAssessmentStatus
        if maxZ >= anomalyZ { status = .degradedResponse }
        else if maxZ >= warningZ || trending { status = .emergingDegradation }
        else { status = .healthy }
        let worst = findings.max { abs($0.standardizedDeviation) < abs($1.standardizedDeviation) }
        let summary: String
        switch status {
        case .healthy: summary = "Command-to-response dynamics remain inside the learned healthy signature."
        case .emergingDegradation: summary = "The response is beginning to depart from its learned dynamic signature even though the command may still arrive on time."
        case .degradedResponse: summary = "The command-to-response dynamics are materially different from the healthy population; inspect strength, speed, overshoot, and settling separately."
        case .insufficientData: summary = "Insufficient dynamic-response evidence."
        }
        return DynamicResponseAssessment(status: status, findings: findings.sorted { abs($0.standardizedDeviation) > abs($1.standardizedDeviation) }, summary: summary + (worst.map { " Strongest deviation: \($0.metric.displayName)." } ?? ""))
    }

    public static func measure(_ definition: DynamicResponseDefinition, cycle: KnownGoodCycle) -> DynamicResponseMeasurement? {
        let commands = cycle.signalSamples.filter { $0.target == definition.command.target && $0.layer == definition.command.layer }.sorted { $0.milliseconds < $1.milliseconds }
        guard commands.count >= 2 else { return nil }
        var commandTime: Int64?
        for i in 1..<commands.count where commands[i].value != commands[i - 1].value && commands[i].value == definition.commandResultingValue {
            commandTime = commands[i].milliseconds; break
        }
        guard let t0 = commandTime else { return nil }
        let allResponses = cycle.signalSamples.filter { $0.target == definition.response.target && $0.layer == definition.response.layer }.sorted { $0.milliseconds < $1.milliseconds }
        let pre = allResponses.filter { $0.milliseconds <= t0 }.suffix(3).compactMap { numeric($0.value) }
        let post = allResponses.filter { $0.milliseconds >= t0 && $0.milliseconds <= t0 + definition.responseWindowMilliseconds }.compactMap { sample -> (Int64, Double)? in
            numeric(sample.value).map { (sample.milliseconds, $0) }
        }
        guard !pre.isEmpty, post.count >= 5 else { return nil }
        let baseline = pre.reduce(0,+) / Double(pre.count)
        let tailCount = max(2, min(5, post.count / 4))
        let final = post.suffix(tailCount).map(\.1).reduce(0,+) / Double(tailCount)
        let delta = final - baseline
        guard abs(delta) > 1e-9 else { return nil }
        let direction = delta >= 0 ? 1.0 : -1.0
        func fraction(_ sample: (Int64, Double)) -> Double { ((sample.1 - baseline) / delta) }
        guard let five = post.first(where: { direction * ($0.1 - baseline) >= abs(delta) * 0.005 }),
              let ten = post.first(where: { fraction($0) >= 0.10 }),
              let ninety = post.first(where: { fraction($0) >= 0.90 }) else { return nil }
        let peak = direction > 0 ? post.map(\.1).max()! : post.map(\.1).min()!
        let overshoot = max(0, direction * (peak - final) / abs(delta))
        let tol = max(abs(delta) * definition.settlingToleranceFraction, 1e-9)
        var settling: Int64? = nil
        for i in 0..<post.count {
            if post[i...].allSatisfy({ abs($0.1 - final) <= tol }) { settling = post[i].0; break }
        }
        let damping: Double?
        if overshoot > 0.0001 && overshoot < 1.0 {
            let lnM = log(overshoot)
            damping = -lnM / sqrt(Double.pi * Double.pi + lnM * lnM)
        } else { damping = overshoot <= 0.0001 ? 1.0 : nil }
        return DynamicResponseMeasurement(
            commandMilliseconds: t0,
            baseline: baseline,
            finalValue: final,
            deadTimeMilliseconds: Double(five.0 - t0),
            riseTimeMilliseconds: Double(ninety.0 - ten.0),
            gain: delta,
            overshootFraction: overshoot,
            settlingTimeMilliseconds: Double((settling ?? post.last!.0) - t0),
            dampingRatio: damping
        )
    }

    private static func value(_ metric: DynamicResponseMetric, from m: DynamicResponseMeasurement) -> Double? {
        switch metric {
        case .deadTimeMilliseconds: return m.deadTimeMilliseconds
        case .riseTimeMilliseconds: return m.riseTimeMilliseconds
        case .gain: return m.gain
        case .overshootFraction: return m.overshootFraction
        case .settlingTimeMilliseconds: return m.settlingTimeMilliseconds
        case .dampingRatio: return m.dampingRatio
        }
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
    private static func metricFloor(_ metric: DynamicResponseMetric) -> Double {
        switch metric {
        case .deadTimeMilliseconds, .riseTimeMilliseconds, .settlingTimeMilliseconds: return 2.0
        case .gain: return 0.02
        case .overshootFraction: return 0.01
        case .dampingRatio: return 0.02
        }
    }
    private static func format(_ metric: DynamicResponseMetric, _ value: Double) -> String {
        switch metric {
        case .deadTimeMilliseconds, .riseTimeMilliseconds, .settlingTimeMilliseconds: return String(format: "%.0f ms", value)
        case .gain: return String(format: "%.3f", value)
        case .overshootFraction: return String(format: "%.1f%%", value * 100)
        case .dampingRatio: return String(format: "ζ %.2f", value)
        }
    }
    private static func robustStats(_ values: [Double]) -> (mean: Double, sigma: Double, lower: Double, upper: Double) {
        let sorted = values.sorted(), mean = sorted.reduce(0,+) / Double(sorted.count)
        let median = percentile(sorted, 0.5)
        let mad = percentile(sorted.map { abs($0 - median) }.sorted(), 0.5) * 1.4826
        let variance = sorted.count > 1 ? sorted.reduce(0) { $0 + pow($1 - mean, 2) } / Double(sorted.count - 1) : 0
        let sigma = max(mad, sqrt(max(0, variance)), max(abs(mean) * 0.01, 1e-6))
        return (mean, sigma, mean - 3*sigma, mean + 3*sigma)
    }
    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let x = max(0,min(1,q)) * Double(values.count - 1), lo = Int(floor(x)), hi = Int(ceil(x))
        if lo == hi { return values[lo] }
        let f = x - Double(lo); return values[lo] + (values[hi] - values[lo]) * f
    }
    private static func linearRegression(_ y: [Double]) -> (slope: Double, rSquared: Double) {
        guard y.count >= 2 else { return (0,0) }
        let n = Double(y.count), mx = Double(y.count - 1)/2.0, my = y.reduce(0,+)/n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (i,v) in y.enumerated() { let dx = Double(i)-mx, dy = v-my; sxx += dx*dx; sxy += dx*dy; syy += dy*dy }
        guard sxx > 0 else { return (0,0) }
        let slope = sxy/sxx
        let r2 = syy > 1e-12 ? min(1,max(0,(sxy*sxy)/(sxx*syy))) : 0
        return (slope,r2)
    }
}
