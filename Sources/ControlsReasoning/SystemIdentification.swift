import Foundation
import ControlsPLC

public enum IdentifiedPlantModelKind: String, Codable, Sendable, CaseIterable {
    case firstOrderPlusDeadTime
    case underdampedSecondOrder

    public var displayName: String {
        switch self {
        case .firstOrderPlusDeadTime: return "First-order + dead time"
        case .underdampedSecondOrder: return "Underdamped second-order"
        }
    }
}

public enum PlantModelPreference: String, Codable, Sendable {
    case automatic
    case firstOrderPlusDeadTime
    case underdampedSecondOrder
}

public enum IdentifiedParameter: String, Codable, Sendable, CaseIterable {
    case processGain
    case deadTimeMilliseconds
    case timeConstantMilliseconds
    case dampingRatio
    case naturalFrequencyRadiansPerSecond

    public var displayName: String {
        switch self {
        case .processGain: return "Process gain K"
        case .deadTimeMilliseconds: return "Dead time L"
        case .timeConstantMilliseconds: return "Time constant τ"
        case .dampingRatio: return "Damping ζ"
        case .naturalFrequencyRadiansPerSecond: return "Natural frequency ωn"
        }
    }
}

public struct SystemIdentificationDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let response: DynamicResponseDefinition
    public let preference: PlantModelPreference

    public init(id: String? = nil, name: String? = nil, response: DynamicResponseDefinition, preference: PlantModelPreference = .automatic) {
        self.id = id ?? "sysid|\(response.id)"
        self.name = name ?? response.name
        self.response = response
        self.preference = preference
    }
}

public struct IdentifiedPlantFit: Equatable, Sendable {
    public let modelKind: IdentifiedPlantModelKind
    public let processGain: Double
    public let deadTimeMilliseconds: Double
    public let timeConstantMilliseconds: Double?
    public let dampingRatio: Double?
    public let naturalFrequencyRadiansPerSecond: Double?
    public let normalizedRMSE: Double
    public let sampleCount: Int

    public var fitQuality: String {
        if normalizedRMSE <= 0.05 { return "Strong fit" }
        if normalizedRMSE <= 0.12 { return "Usable fit" }
        if normalizedRMSE <= 0.22 { return "Weak fit" }
        return "Poor fit"
    }

    public func value(_ parameter: IdentifiedParameter) -> Double? {
        switch parameter {
        case .processGain: return processGain
        case .deadTimeMilliseconds: return deadTimeMilliseconds
        case .timeConstantMilliseconds: return timeConstantMilliseconds
        case .dampingRatio: return dampingRatio
        case .naturalFrequencyRadiansPerSecond: return naturalFrequencyRadiansPerSecond
        }
    }
}

public struct IdentifiedParameterEnvelope: Identifiable, Equatable, Sendable {
    public var id: String { parameter.rawValue }
    public let parameter: IdentifiedParameter
    public let mean: Double
    public let sigma: Double
    public let lower: Double
    public let upper: Double
    public let trendPerCycle: Double
    public let trendRSquared: Double
}

public struct SystemIdentificationSignature: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: SystemIdentificationDefinition
    public let modelKind: IdentifiedPlantModelKind
    public let sampleCount: Int
    public let meanNormalizedRMSE: Double
    public let parameters: [IdentifiedParameterEnvelope]

    public func envelope(_ parameter: IdentifiedParameter) -> IdentifiedParameterEnvelope? {
        parameters.first { $0.parameter == parameter }
    }
}

public struct SystemIdentificationModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let signatures: [SystemIdentificationSignature]
}

public enum PlantParameterAssessmentStatus: String, Codable, Sendable {
    case healthy
    case emergingChange
    case changedPlantDynamics
    case insufficientData

    public var displayName: String {
        switch self {
        case .healthy: return "Plant dynamics healthy"
        case .emergingChange: return "Emerging plant-model drift"
        case .changedPlantDynamics: return "Plant dynamics changed"
        case .insufficientData: return "Insufficient identification evidence"
        }
    }
}

public struct PlantParameterFinding: Identifiable, Equatable, Sendable {
    public var id: String { "\(signatureID)|\(parameter.rawValue)" }
    public let signatureID: String
    public let parameter: IdentifiedParameter
    public let observed: Double
    public let expected: Double
    public let standardizedDeviation: Double
    public let abnormal: Bool
    public let explanation: String
}

public struct SystemIdentificationAssessment: Equatable, Sendable {
    public let status: PlantParameterAssessmentStatus
    public let fits: [String: IdentifiedPlantFit]
    public let findings: [PlantParameterFinding]
    public let interpretations: [String]
    public let summary: String
    public var abnormalFindings: [PlantParameterFinding] { findings.filter(\.abnormal) }
}

public struct RegionalSystemIdentificationModel: Identifiable, Equatable, Sendable {
    public var id: String { mode.id }
    public let mode: OperatingModeDefinition
    public let cycleCount: Int
    public let model: SystemIdentificationModel
}

public struct RegionalSystemIdentificationLibrary: Equatable, Sendable {
    public let name: String
    public let models: [RegionalSystemIdentificationModel]
}

public struct RegionalSystemIdentificationAssessment: Equatable, Sendable {
    public let selectedModeName: String?
    public let assessment: SystemIdentificationAssessment?
    public let summary: String
}

public enum SystemIdentificationAnalyzer {
    public static func buildModel(
        name: String = "Identified plant dynamics",
        cycles: [KnownGoodCycle],
        definitions: [SystemIdentificationDefinition],
        minimumCycles: Int = 6
    ) -> SystemIdentificationModel? {
        guard cycles.count >= minimumCycles, !definitions.isEmpty else { return nil }
        var signatures: [SystemIdentificationSignature] = []
        for definition in definitions {
            let fits = cycles.compactMap { fit(definition, cycle: $0) }
            guard fits.count >= minimumCycles else { continue }
            let dominantKind = fits.reduce(into: [IdentifiedPlantModelKind: Int]()) { $0[$1.modelKind, default: 0] += 1 }
                .max { $0.value < $1.value }?.key ?? .firstOrderPlusDeadTime
            let selected = fits.filter { $0.modelKind == dominantKind }
            guard selected.count >= minimumCycles else { continue }
            var envelopes: [IdentifiedParameterEnvelope] = []
            for parameter in IdentifiedParameter.allCases {
                let values = selected.compactMap { $0.value(parameter) }
                guard values.count >= minimumCycles else { continue }
                let s = robustStats(values)
                let trend = linearRegression(values)
                envelopes.append(.init(parameter: parameter, mean: s.mean, sigma: s.sigma, lower: s.lower, upper: s.upper, trendPerCycle: trend.slope, trendRSquared: trend.rSquared))
            }
            let rmse = selected.map(\.normalizedRMSE).reduce(0,+) / Double(selected.count)
            signatures.append(.init(definition: definition, modelKind: dominantKind, sampleCount: selected.count, meanNormalizedRMSE: rmse, parameters: envelopes))
        }
        guard !signatures.isEmpty else { return nil }
        return .init(name: name, cycleCount: cycles.count, signatures: signatures)
    }

    public static func assess(
        cycle: KnownGoodCycle,
        against model: SystemIdentificationModel,
        warningZ: Double = 2.0,
        anomalyZ: Double = 3.0
    ) -> SystemIdentificationAssessment {
        var fits: [String: IdentifiedPlantFit] = [:]
        var findings: [PlantParameterFinding] = []
        var interpretations: [String] = []
        for signature in model.signatures {
            guard let current = fit(signature.definition, cycle: cycle) else { continue }
            fits[signature.id] = current
            for envelope in signature.parameters {
                guard let observed = current.value(envelope.parameter) else { continue }
                let z = (observed - envelope.mean) / max(envelope.sigma, parameterFloor(envelope.parameter))
                findings.append(.init(
                    signatureID: signature.id,
                    parameter: envelope.parameter,
                    observed: observed,
                    expected: envelope.mean,
                    standardizedDeviation: z,
                    abnormal: abs(z) >= warningZ,
                    explanation: "\(signature.definition.name): \(envelope.parameter.displayName) is \(format(envelope.parameter, observed)) versus healthy \(format(envelope.parameter, envelope.mean)), z \(String(format: "%+.2f", z)). Fit: \(current.fitQuality), NRMSE \(String(format: "%.3f", current.normalizedRMSE))."
                ))
            }
            interpretations.append(contentsOf: interpret(signature: signature, current: current, findings: findings.filter { $0.signatureID == signature.id }))
        }
        guard !findings.isEmpty else {
            return .init(status: .insufficientData, fits: fits, findings: [], interpretations: [], summary: "The current capture does not contain enough excitation/response evidence for a defensible plant-model fit.")
        }
        let maxZ = findings.map { abs($0.standardizedDeviation) }.max() ?? 0
        let trending = model.signatures.flatMap(\.parameters).contains { abs($0.trendPerCycle) > parameterFloor($0.parameter) * 0.10 && $0.trendRSquared >= 0.60 }
        let status: PlantParameterAssessmentStatus = maxZ >= anomalyZ ? .changedPlantDynamics : (maxZ >= warningZ || trending ? .emergingChange : .healthy)
        let summary: String
        switch status {
        case .healthy: summary = "The fitted plant parameters remain consistent with the learned healthy dynamics."
        case .emergingChange: summary = "The identified plant model is beginning to drift even though conventional response metrics may still look acceptable."
        case .changedPlantDynamics: summary = "The fitted plant dynamics differ materially from the healthy population. Use the parameter changes to distinguish gain, delay, speed, and damping changes."
        case .insufficientData: summary = "Insufficient identification evidence."
        }
        return .init(status: status, fits: fits, findings: findings.sorted { abs($0.standardizedDeviation) > abs($1.standardizedDeviation) }, interpretations: Array(Set(interpretations)).sorted(), summary: summary)
    }

    public static func buildRegionalLibrary(
        name: String = "Operating-region plant models",
        cycles: [KnownGoodCycle],
        modeDefinitions: [OperatingModeDefinition],
        definitions: [SystemIdentificationDefinition],
        minimumCyclesPerMode: Int = 6
    ) -> RegionalSystemIdentificationLibrary {
        let models = modeDefinitions.compactMap { mode -> RegionalSystemIdentificationModel? in
            let subset = cycles.filter { OperatingModeHealthAnalyzer.matchingModes(for: $0, definitions: modeDefinitions).map(\.id) == [mode.id] }
            guard let m = buildModel(name: "\(mode.name) plant dynamics", cycles: subset, definitions: definitions, minimumCycles: minimumCyclesPerMode) else { return nil }
            return .init(mode: mode, cycleCount: subset.count, model: m)
        }
        return .init(name: name, models: models)
    }

    public static func assessRegional(cycle: KnownGoodCycle, library: RegionalSystemIdentificationLibrary, modeDefinitions: [OperatingModeDefinition]) -> RegionalSystemIdentificationAssessment {
        let matches = OperatingModeHealthAnalyzer.matchingModes(for: cycle, definitions: modeDefinitions)
        guard matches.count == 1 else {
            let why = matches.isEmpty ? "No learned operating mode matches this cycle." : "Multiple operating modes match this cycle."
            return .init(selectedModeName: nil, assessment: nil, summary: "\(why) Do not force-fit plant dynamics to an unrelated region.")
        }
        let mode = matches[0]
        guard let model = library.models.first(where: { $0.mode.id == mode.id }) else {
            return .init(selectedModeName: mode.name, assessment: nil, summary: "\(mode.name) is identified, but it does not yet have enough healthy excitation cycles for a plant model.")
        }
        let assessment = assess(cycle: cycle, against: model.model)
        return .init(selectedModeName: mode.name, assessment: assessment, summary: "Operating region: \(mode.name). \(assessment.summary)")
    }

    public static func fit(_ definition: SystemIdentificationDefinition, cycle: KnownGoodCycle) -> IdentifiedPlantFit? {
        guard let data = responseData(definition.response, cycle: cycle) else { return nil }
        let fopdt = fitFOPDT(data)
        let second = fitSecondOrder(data)
        switch definition.preference {
        case .firstOrderPlusDeadTime: return fopdt
        case .underdampedSecondOrder: return second
        case .automatic:
            guard let f = fopdt else { return second }
            guard let s = second else { return f }
            let improvement = (f.normalizedRMSE - s.normalizedRMSE) / max(f.normalizedRMSE, 1e-9)
            let hasOvershoot = data.overshootFraction >= 0.03
            return hasOvershoot && improvement >= 0.12 ? s : f
        }
    }

    private struct ResponseData {
        let times: [Double]
        let values: [Double]
        let baseline: Double
        let deltaU: Double
        let final: Double
        let deadEstimate: Double
        let tauEstimate: Double
        let overshootFraction: Double
    }

    private static func responseData(_ definition: DynamicResponseDefinition, cycle: KnownGoodCycle) -> ResponseData? {
        let commands = cycle.signalSamples.filter { $0.target == definition.command.target && $0.layer == definition.command.layer }.sorted { $0.milliseconds < $1.milliseconds }
        guard commands.count >= 2 else { return nil }
        var event: (index: Int, time: Int64)?
        for i in 1..<commands.count where commands[i].value != commands[i - 1].value && commands[i].value == definition.commandResultingValue { event = (i, commands[i].milliseconds); break }
        guard let event, let before = numeric(commands[event.index - 1].value), let after = numeric(commands[event.index].value), abs(after - before) > 1e-9 else { return nil }
        let t0 = event.time
        let response = cycle.signalSamples.filter { $0.target == definition.response.target && $0.layer == definition.response.layer }.sorted { $0.milliseconds < $1.milliseconds }
        let pre = response.filter { $0.milliseconds <= t0 }.suffix(4).compactMap { numeric($0.value) }
        let post = response.filter { $0.milliseconds >= t0 && $0.milliseconds <= t0 + definition.responseWindowMilliseconds }.compactMap { s -> (Double, Double)? in numeric(s.value).map { (Double(s.milliseconds - t0), $0) } }
        guard !pre.isEmpty, post.count >= 8 else { return nil }
        let baseline = pre.reduce(0,+) / Double(pre.count)
        let tailN = max(3, min(8, post.count / 5))
        let final = post.suffix(tailN).map(\.1).reduce(0,+) / Double(tailN)
        let dy = final - baseline
        guard abs(dy) > 1e-8 else { return nil }
        let dir = dy >= 0 ? 1.0 : -1.0
        let dead = post.first(where: { dir * ($0.1 - baseline) >= abs(dy) * 0.01 })?.0 ?? 0
        let t632 = post.first(where: { dir * ($0.1 - baseline) >= abs(dy) * 0.632 })?.0 ?? max(dead + 1, post.last!.0 * 0.5)
        let peak = dir > 0 ? post.map(\.1).max()! : post.map(\.1).min()!
        let os = max(0, dir * (peak - final) / abs(dy))
        return .init(times: post.map(\.0), values: post.map(\.1), baseline: baseline, deltaU: after - before, final: final, deadEstimate: dead, tauEstimate: max(1, t632 - dead), overshootFraction: os)
    }

    private static func fitFOPDT(_ d: ResponseData) -> IdentifiedPlantFit? {
        let K0 = (d.final - d.baseline) / d.deltaU
        let maxT = d.times.last ?? 1000
        var best: (err: Double, L: Double, tau: Double)?
        let sampleStep = zip(d.times.dropFirst(), d.times).map { $0.0 - $0.1 }.filter { $0 > 0 }.min() ?? 10
        // `deadEstimate` is the first 1% response sample, so remove the small first-order
        // rise contribution before fitting. Keep the L search narrow to reduce the classic
        // L/τ identifiability trade-off in production traces.
        let lCenter = max(0, d.deadEstimate - 0.01005 * d.tauEstimate)
        let lSpan = max(2, min(sampleStep, maxT * 0.02))
        let tauCenter = max(5, d.tauEstimate)
        for li in 0...8 {
            let L = max(0, lCenter - lSpan + 2*lSpan*Double(li)/8.0)
            for ti in 0...28 {
                let scale = 0.35 + 1.9 * Double(ti)/28.0
                let tau = max(2, tauCenter * scale)
                let err = sse(times: d.times, values: d.values) { t in
                    if t <= L { return d.baseline }
                    return d.baseline + K0 * d.deltaU * (1 - exp(-(t - L)/tau))
                }
                if best == nil || err < best!.err { best = (err,L,tau) }
            }
        }
        guard let best else { return nil }
        let nrmse = normalizedRMSE(sse: best.err, values: d.values, baseline: d.baseline, final: d.final)
        return .init(modelKind: .firstOrderPlusDeadTime, processGain: K0, deadTimeMilliseconds: best.L, timeConstantMilliseconds: best.tau, dampingRatio: nil, naturalFrequencyRadiansPerSecond: nil, normalizedRMSE: nrmse, sampleCount: d.values.count)
    }

    private static func fitSecondOrder(_ d: ResponseData) -> IdentifiedPlantFit? {
        let K0 = (d.final - d.baseline) / d.deltaU
        let maxT = d.times.last ?? 1000
        let lCenter = max(0, d.deadEstimate)
        let lSpan = max(15, min(60, maxT * 0.10))
        let zEstimate: Double = {
            let m = d.overshootFraction
            guard m > 0.001 && m < 0.95 else { return 0.7 }
            let x = log(m)
            return max(0.08, min(0.95, -x / sqrt(Double.pi * Double.pi + x*x)))
        }()
        let tauSeconds = max(0.01, d.tauEstimate / 1000.0)
        let wnEstimate = max(0.2, min(80, 1.8 / tauSeconds))
        var best: (err: Double, L: Double, z: Double, wn: Double)?
        for li in 0...12 {
            let L = max(0, lCenter - lSpan + 2*lSpan*Double(li)/12.0)
            for zi in 0...16 {
                let z = max(0.05, min(0.95, zEstimate * (0.55 + 0.9*Double(zi)/16.0)))
                let root = sqrt(max(1e-9, 1 - z*z))
                for wi in 0...18 {
                    let wn = max(0.15, wnEstimate * (0.35 + 1.8*Double(wi)/18.0))
                    let err = sse(times: d.times, values: d.values) { tms in
                        if tms <= L { return d.baseline }
                        let t = (tms - L) / 1000.0
                        let wd = wn * root
                        let phi = acos(z)
                        let normalized = 1 - exp(-z*wn*t) / root * sin(wd*t + phi)
                        return d.baseline + K0 * d.deltaU * normalized
                    }
                    if best == nil || err < best!.err { best = (err,L,z,wn) }
                }
            }
        }
        guard let best else { return nil }
        let nrmse = normalizedRMSE(sse: best.err, values: d.values, baseline: d.baseline, final: d.final)
        return .init(modelKind: .underdampedSecondOrder, processGain: K0, deadTimeMilliseconds: best.L, timeConstantMilliseconds: nil, dampingRatio: best.z, naturalFrequencyRadiansPerSecond: best.wn, normalizedRMSE: nrmse, sampleCount: d.values.count)
    }

    private static func interpret(signature: SystemIdentificationSignature, current: IdentifiedPlantFit, findings: [PlantParameterFinding]) -> [String] {
        func finding(_ p: IdentifiedParameter) -> PlantParameterFinding? { findings.first { $0.parameter == p } }
        var out: [String] = []
        if let f = finding(.timeConstantMilliseconds), f.standardizedDeviation >= 2 {
            out.append("\(signature.definition.name): τ increased while fitting remained \(current.fitQuality.lowercased()). The plant is responding more sluggishly; investigate added mechanical/process resistance, restricted flow, or changed load before retuning the controller.")
        }
        if let f = finding(.processGain), f.standardizedDeviation <= -2 {
            out.append("\(signature.definition.name): process gain K fell. The same command now produces less response; check actuator authority, supply limits, leakage, restriction, or saturation before assuming a tuning problem.")
        }
        if let f = finding(.deadTimeMilliseconds), f.standardizedDeviation >= 2 {
            out.append("\(signature.definition.name): dead time L increased. Extra transport/communication/actuation delay reduces available tuning margin and can make an otherwise unchanged controller feel more aggressive.")
        }
        if let f = finding(.dampingRatio), f.standardizedDeviation <= -2 {
            out.append("\(signature.definition.name): damping ζ decreased. The plant is more oscillatory/less damped; verify mechanical compliance, process interaction, and loop tuning rather than treating overshoot as a simple timing fault.")
        }
        if let f = finding(.naturalFrequencyRadiansPerSecond), abs(f.standardizedDeviation) >= 2 {
            out.append("\(signature.definition.name): natural frequency shifted. The plant's dominant dynamic timescale changed, which can alter stability margin even if static gain remains similar.")
        }
        if current.normalizedRMSE > 0.22 {
            out.append("\(signature.definition.name): the fitted linear model is poor. Nonlinearity such as saturation, stiction, changing operating point, or insufficient excitation may be present; do not over-interpret the fitted parameters.")
        }
        return out
    }

    private static func sse(times: [Double], values: [Double], predictor: (Double) -> Double) -> Double {
        zip(times, values).reduce(0) { acc, pair in let e = pair.1 - predictor(pair.0); return acc + e*e }
    }
    private static func normalizedRMSE(sse: Double, values: [Double], baseline: Double, final: Double) -> Double {
        sqrt(sse / Double(max(1, values.count))) / max(abs(final - baseline), 1e-9)
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
    private static func parameterFloor(_ parameter: IdentifiedParameter) -> Double {
        switch parameter {
        case .processGain: return 0.02
        case .deadTimeMilliseconds, .timeConstantMilliseconds: return 2.0
        case .dampingRatio: return 0.02
        case .naturalFrequencyRadiansPerSecond: return 0.05
        }
    }
    private static func format(_ parameter: IdentifiedParameter, _ value: Double) -> String {
        switch parameter {
        case .processGain: return String(format: "K %.3f", value)
        case .deadTimeMilliseconds: return String(format: "L %.0f ms", value)
        case .timeConstantMilliseconds: return String(format: "τ %.0f ms", value)
        case .dampingRatio: return String(format: "ζ %.2f", value)
        case .naturalFrequencyRadiansPerSecond: return String(format: "ωn %.2f rad/s", value)
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
