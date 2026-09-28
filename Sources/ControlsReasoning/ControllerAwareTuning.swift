import Foundation

public enum PIDControllerForm: String, Codable, Sendable {
    case parallelContinuous

    public var displayName: String { "Parallel continuous PID" }
}

public struct PIDControllerSettings: Equatable, Sendable {
    public let proportionalGain: Double
    public let integralGainPerSecond: Double
    public let derivativeGainSeconds: Double
    public let derivativeFilterTimeConstantSeconds: Double
    public let form: PIDControllerForm

    public init(
        proportionalGain: Double,
        integralGainPerSecond: Double = 0,
        derivativeGainSeconds: Double = 0,
        derivativeFilterTimeConstantSeconds: Double = 0,
        form: PIDControllerForm = .parallelContinuous
    ) {
        self.proportionalGain = proportionalGain
        self.integralGainPerSecond = integralGainPerSecond
        self.derivativeGainSeconds = derivativeGainSeconds
        self.derivativeFilterTimeConstantSeconds = max(0, derivativeFilterTimeConstantSeconds)
        self.form = form
    }
}

public struct ControllerAwareTuningDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let systemIdentificationSignatureID: String
    public let controller: PIDControllerSettings

    public init(id: String? = nil, name: String, systemIdentificationSignatureID: String, controller: PIDControllerSettings) {
        self.id = id ?? "pid-stability|\(systemIdentificationSignatureID)"
        self.name = name
        self.systemIdentificationSignatureID = systemIdentificationSignatureID
        self.controller = controller
    }
}

public enum ClosedLoopRobustness: String, Codable, Sendable {
    case conservative
    case balanced
    case aggressive
    case oscillationProne
    case unstable
    case indeterminate

    public var displayName: String {
        switch self {
        case .conservative: return "Conservative / robust"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        case .oscillationProne: return "Oscillation-prone"
        case .unstable: return "Unstable estimate"
        case .indeterminate: return "Indeterminate"
        }
    }
}

public struct StabilityMarginEstimate: Equatable, Sendable {
    public let gainCrossoverRadiansPerSecond: Double?
    public let phaseMarginDegrees: Double?
    public let phaseCrossoverRadiansPerSecond: Double?
    public let gainMarginDecibels: Double?
    public let delayPhaseAtGainCrossoverDegrees: Double?
    public let robustness: ClosedLoopRobustness

    public var gainCrossoverHertz: Double? { gainCrossoverRadiansPerSecond.map { $0 / (2 * .pi) } }
}

public enum TuningVulnerability: String, Codable, Sendable {
    case robustToObservedChange
    case reducedMargin
    case nearOscillation
    case crossedInstabilityBoundary
    case indeterminate

    public var displayName: String {
        switch self {
        case .robustToObservedChange: return "Robust to observed plant change"
        case .reducedMargin: return "Stability margin reduced"
        case .nearOscillation: return "Near oscillatory boundary"
        case .crossedInstabilityBoundary: return "Plant change crossed stability boundary"
        case .indeterminate: return "Indeterminate vulnerability"
        }
    }
}

public struct ControllerAwareTuningAssessment: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: ControllerAwareTuningDefinition
    public let healthyPlant: IdentifiedPlantFit
    public let currentPlant: IdentifiedPlantFit
    public let healthyMargins: StabilityMarginEstimate
    public let currentMargins: StabilityMarginEstimate
    public let vulnerability: TuningVulnerability
    public let phaseMarginChangeDegrees: Double?
    public let gainMarginChangeDecibels: Double?
    public let additionalDeadTimePhaseLossDegrees: Double?
    public let interpretations: [String]
    public let summary: String
}

public struct ControllerAwareTuningReport: Equatable, Sendable {
    public let assessments: [ControllerAwareTuningAssessment]
    public let summary: String
}

public enum ControllerAwareTuningAnalyzer {
    private typealias FrequencyPoint = (w: Double, magnitude: Double, phase: Double)
    public static func assess(
        current: SystemIdentificationAssessment,
        healthyModel: SystemIdentificationModel,
        definitions: [ControllerAwareTuningDefinition]
    ) -> ControllerAwareTuningReport {
        var assessments: [ControllerAwareTuningAssessment] = []
        for definition in definitions {
            guard let signature = healthyModel.signatures.first(where: { $0.id == definition.systemIdentificationSignatureID }),
                  let currentFit = current.fits[signature.id],
                  let healthyFit = representativeFit(signature) else { continue }

            let healthyMargins = margins(controller: definition.controller, plant: healthyFit)
            let currentMargins = margins(controller: definition.controller, plant: currentFit)
            let pmChange = delta(currentMargins.phaseMarginDegrees, healthyMargins.phaseMarginDegrees)
            let gmChange = delta(currentMargins.gainMarginDecibels, healthyMargins.gainMarginDecibels)
            let extraDelayPhaseLoss: Double? = {
                guard let wc = currentMargins.gainCrossoverRadiansPerSecond else { return nil }
                let deltaL = (currentFit.deadTimeMilliseconds - healthyFit.deadTimeMilliseconds) / 1000.0
                return -(wc * deltaL) * 180 / .pi
            }()
            let vulnerability = classifyVulnerability(healthy: healthyMargins, current: currentMargins, phaseMarginChange: pmChange)
            let interpretations = explain(
                controller: definition.controller,
                healthyPlant: healthyFit,
                currentPlant: currentFit,
                healthy: healthyMargins,
                current: currentMargins,
                phaseMarginChange: pmChange,
                extraDelayPhaseLoss: extraDelayPhaseLoss
            )
            let summary = makeSummary(name: definition.name, healthy: healthyMargins, current: currentMargins, vulnerability: vulnerability, phaseMarginChange: pmChange)
            assessments.append(.init(
                definition: definition,
                healthyPlant: healthyFit,
                currentPlant: currentFit,
                healthyMargins: healthyMargins,
                currentMargins: currentMargins,
                vulnerability: vulnerability,
                phaseMarginChangeDegrees: pmChange,
                gainMarginChangeDecibels: gmChange,
                additionalDeadTimePhaseLossDegrees: extraDelayPhaseLoss,
                interpretations: interpretations,
                summary: summary
            ))
        }
        let summary: String
        if assessments.isEmpty {
            summary = "No controller/plant pairs had enough identified-plant evidence for stability analysis."
        } else if let worst = assessments.max(by: { vulnerabilityRank($0.vulnerability) < vulnerabilityRank($1.vulnerability) }) {
            summary = "Analyzed \(assessments.count) controller/plant pair(s). Most concerning: \(worst.definition.name) — \(worst.vulnerability.displayName)."
        } else {
            summary = "Analyzed \(assessments.count) controller/plant pair(s)."
        }
        return .init(assessments: assessments, summary: summary)
    }

    public static func assessRegional(
        current: RegionalSystemIdentificationAssessment,
        library: RegionalSystemIdentificationLibrary,
        definitions: [ControllerAwareTuningDefinition]
    ) -> ControllerAwareTuningReport {
        guard let modeName = current.selectedModeName,
              let currentAssessment = current.assessment,
              let regional = library.models.first(where: { $0.mode.name == modeName }) else {
            return .init(assessments: [], summary: "Operating regime unresolved; controller-aware stability was not compared against the wrong plant model.")
        }
        let report = assess(current: currentAssessment, healthyModel: regional.model, definitions: definitions)
        return .init(assessments: report.assessments, summary: "Operating regime: \(modeName). \(report.summary)")
    }

    public static func margins(controller: PIDControllerSettings, plant: IdentifiedPlantFit) -> StabilityMarginEstimate {
        let frequencies = logarithmicGrid(min: 0.001, max: 10_000, count: 4000)
        var points: [FrequencyPoint] = []
        points.reserveCapacity(frequencies.count)
        var previousWrapped: Double?
        var previousUnwrapped: Double?
        for w in frequencies {
            let loop = controllerFrequencyResponse(controller, w: w) * plantFrequencyResponse(plant, w: w)
            let magnitude = loop.magnitude
            let wrapped = loop.phase
            let unwrapped: Double
            if let pw = previousWrapped, let pu = previousUnwrapped {
                var delta = wrapped - pw
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                unwrapped = pu + delta
            } else {
                unwrapped = wrapped
            }
            points.append((w, magnitude, unwrapped))
            previousWrapped = wrapped
            previousUnwrapped = unwrapped
        }

        let gainCross = crossing(points, target: 1.0, value: { $0.magnitude }, logarithmicValue: true)
        let phaseMargin: Double? = gainCross.map { cross in
            180 + interpolatePhase(points, at: cross) * 180 / .pi
        }
        let phaseCross = phaseCrossing(points, target: -.pi)
        let gainMarginDB: Double? = phaseCross.map { cross in
            let mag = interpolateMagnitude(points, at: cross)
            return -20 * log10(max(mag, 1e-12))
        }
        let delayPhase: Double? = gainCross.map { wc in
            -(wc * plant.deadTimeMilliseconds / 1000.0) * 180 / .pi
        }
        let robustness = classifyMargins(phaseMargin: phaseMargin, gainMarginDB: gainMarginDB)
        return .init(
            gainCrossoverRadiansPerSecond: gainCross,
            phaseMarginDegrees: phaseMargin,
            phaseCrossoverRadiansPerSecond: phaseCross,
            gainMarginDecibels: gainMarginDB,
            delayPhaseAtGainCrossoverDegrees: delayPhase,
            robustness: robustness
        )
    }

    private static func representativeFit(_ signature: SystemIdentificationSignature) -> IdentifiedPlantFit? {
        guard let k = signature.envelope(.processGain)?.mean,
              let l = signature.envelope(.deadTimeMilliseconds)?.mean else { return nil }
        switch signature.modelKind {
        case .firstOrderPlusDeadTime:
            guard let tau = signature.envelope(.timeConstantMilliseconds)?.mean else { return nil }
            return .init(modelKind: .firstOrderPlusDeadTime, processGain: k, deadTimeMilliseconds: l, timeConstantMilliseconds: tau, dampingRatio: nil, naturalFrequencyRadiansPerSecond: nil, normalizedRMSE: signature.meanNormalizedRMSE, sampleCount: signature.sampleCount)
        case .underdampedSecondOrder:
            guard let zeta = signature.envelope(.dampingRatio)?.mean,
                  let wn = signature.envelope(.naturalFrequencyRadiansPerSecond)?.mean else { return nil }
            return .init(modelKind: .underdampedSecondOrder, processGain: k, deadTimeMilliseconds: l, timeConstantMilliseconds: nil, dampingRatio: zeta, naturalFrequencyRadiansPerSecond: wn, normalizedRMSE: signature.meanNormalizedRMSE, sampleCount: signature.sampleCount)
        }
    }

    private static func classifyMargins(phaseMargin: Double?, gainMarginDB: Double?) -> ClosedLoopRobustness {
        guard let pm = phaseMargin else { return .indeterminate }
        if pm <= 0 || (gainMarginDB.map { $0 <= 0 } ?? false) { return .unstable }
        if pm < 30 || (gainMarginDB.map { $0 < 6 } ?? false) { return .oscillationProne }
        if pm < 45 || (gainMarginDB.map { $0 < 9 } ?? false) { return .aggressive }
        if pm > 70 && (gainMarginDB.map { $0 > 12 } ?? true) { return .conservative }
        return .balanced
    }

    private static func classifyVulnerability(healthy: StabilityMarginEstimate, current: StabilityMarginEstimate, phaseMarginChange: Double?) -> TuningVulnerability {
        if current.robustness == .unstable && healthy.robustness != .unstable { return .crossedInstabilityBoundary }
        if current.robustness == .oscillationProne || (current.phaseMarginDegrees.map { $0 < 30 } ?? false) { return .nearOscillation }
        if let change = phaseMarginChange, change <= -12 { return .reducedMargin }
        if healthy.robustness == .indeterminate || current.robustness == .indeterminate { return .indeterminate }
        return .robustToObservedChange
    }

    private static func explain(controller: PIDControllerSettings, healthyPlant: IdentifiedPlantFit, currentPlant: IdentifiedPlantFit, healthy: StabilityMarginEstimate, current: StabilityMarginEstimate, phaseMarginChange: Double?, extraDelayPhaseLoss: Double?) -> [String] {
        var notes: [String] = []
        if let h = healthy.phaseMarginDegrees, let c = current.phaseMarginDegrees {
            notes.append("With the same PID gains, estimated phase margin changed from \(String(format: "%.1f", h))° to \(String(format: "%.1f", c))°. The controller did not change; the plant did.")
        }
        let deltaL = currentPlant.deadTimeMilliseconds - healthyPlant.deadTimeMilliseconds
        if deltaL > max(5, healthyPlant.deadTimeMilliseconds * 0.1) {
            let loss = extraDelayPhaseLoss.map { " (about \(String(format: "%.1f", abs($0)))° extra phase lag near crossover)" } ?? ""
            notes.append("Dead time increased by \(String(format: "%.0f", deltaL)) ms\(loss). Delay consumes phase margin without changing the PID gains.")
        }
        if let hTau = healthyPlant.timeConstantMilliseconds, let cTau = currentPlant.timeConstantMilliseconds, cTau > hTau * 1.2 {
            notes.append("Plant time constant increased from \(String(format: "%.0f", hTau)) to \(String(format: "%.0f", cTau)) ms. The process is slower, so tuning that once felt crisp may become sluggish or interact differently with integral action.")
        }
        if currentPlant.processGain > healthyPlant.processGain * 1.2 {
            notes.append("Process gain increased while controller gain stayed fixed. Effective loop gain is higher, which can make the same tuning more aggressive.")
        } else if currentPlant.processGain < healthyPlant.processGain * 0.8 {
            notes.append("Process gain decreased while controller gain stayed fixed. The loop may become slower or integral action may have to work harder to remove error.")
        }
        if let hz = healthyPlant.dampingRatio, let cz = currentPlant.dampingRatio, cz < hz - 0.15 {
            notes.append("Identified plant damping fell from ζ \(String(format: "%.2f", hz)) to \(String(format: "%.2f", cz)). Lower plant damping can make aggressive controller settings more oscillatory.")
        }
        if controller.integralGainPerSecond > 0, current.robustness == .oscillationProne || current.robustness == .unstable {
            notes.append("Integral action continues accumulating correction while the plant responds. With reduced margin, that stored correction can amplify overshoot and oscillation; this is a tuning-risk explanation, not proof of integral windup.")
        }
        if let change = phaseMarginChange, change > -5 {
            notes.append("Observed plant change has not materially consumed estimated phase margin under this model; avoid retuning solely because one plant parameter moved.")
        }
        return notes
    }

    private static func makeSummary(name: String, healthy: StabilityMarginEstimate, current: StabilityMarginEstimate, vulnerability: TuningVulnerability, phaseMarginChange: Double?) -> String {
        let h = healthy.phaseMarginDegrees.map { String(format: "%.1f°", $0) } ?? "unknown"
        let c = current.phaseMarginDegrees.map { String(format: "%.1f°", $0) } ?? "unknown"
        let d = phaseMarginChange.map { " (\(String(format: "%+.1f°", $0)))" } ?? ""
        return "\(name): phase margin \(h) → \(c)\(d). \(vulnerability.displayName)."
    }

    private static func vulnerabilityRank(_ value: TuningVulnerability) -> Int {
        switch value {
        case .robustToObservedChange: return 0
        case .indeterminate: return 1
        case .reducedMargin: return 2
        case .nearOscillation: return 3
        case .crossedInstabilityBoundary: return 4
        }
    }

    private static func delta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }

    private struct Complex {
        var re: Double
        var im: Double
        static func +(lhs: Complex, rhs: Complex) -> Complex { .init(re: lhs.re + rhs.re, im: lhs.im + rhs.im) }
        static func *(lhs: Complex, rhs: Complex) -> Complex { .init(re: lhs.re * rhs.re - lhs.im * rhs.im, im: lhs.re * rhs.im + lhs.im * rhs.re) }
        static func /(lhs: Complex, rhs: Complex) -> Complex {
            let d = rhs.re * rhs.re + rhs.im * rhs.im
            return .init(re: (lhs.re * rhs.re + lhs.im * rhs.im) / d, im: (lhs.im * rhs.re - lhs.re * rhs.im) / d)
        }
        var magnitude: Double { hypot(re, im) }
        var phase: Double { atan2(im, re) }
    }

    private static func controllerFrequencyResponse(_ c: PIDControllerSettings, w: Double) -> Complex {
        var result = Complex(re: c.proportionalGain, im: 0)
        if c.integralGainPerSecond != 0 {
            result = result + Complex(re: 0, im: -c.integralGainPerSecond / w)
        }
        if c.derivativeGainSeconds != 0 {
            let derivative = Complex(re: 0, im: c.derivativeGainSeconds * w)
            if c.derivativeFilterTimeConstantSeconds > 0 {
                result = result + derivative / Complex(re: 1, im: w * c.derivativeFilterTimeConstantSeconds)
            } else {
                result = result + derivative
            }
        }
        return result
    }

    private static func plantFrequencyResponse(_ plant: IdentifiedPlantFit, w: Double) -> Complex {
        let delaySeconds = plant.deadTimeMilliseconds / 1000.0
        let delay = Complex(re: cos(-w * delaySeconds), im: sin(-w * delaySeconds))
        switch plant.modelKind {
        case .firstOrderPlusDeadTime:
            let tau = max(plant.timeConstantMilliseconds ?? 1, 0.001) / 1000.0
            let firstOrder = Complex(re: plant.processGain, im: 0) / Complex(re: 1, im: w * tau)
            return firstOrder * delay
        case .underdampedSecondOrder:
            let wn = max(plant.naturalFrequencyRadiansPerSecond ?? 1, 1e-6)
            let zeta = max(plant.dampingRatio ?? 0.7, 1e-6)
            let denominator = Complex(re: wn * wn - w * w, im: 2 * zeta * wn * w)
            let secondOrder = Complex(re: plant.processGain * wn * wn, im: 0) / denominator
            return secondOrder * delay
        }
    }

    private static func logarithmicGrid(min: Double, max: Double, count: Int) -> [Double] {
        let a = log10(min), b = log10(max)
        return (0..<count).map { i in pow(10, a + (b - a) * Double(i) / Double(count - 1)) }
    }

    private static func crossing(_ points: [FrequencyPoint], target: Double, value: (FrequencyPoint) -> Double, logarithmicValue: Bool) -> Double? {
        guard points.count > 1 else { return nil }
        for i in 1..<points.count {
            let a = value(points[i - 1]), b = value(points[i])
            if (a - target) == 0 { return points[i - 1].w }
            if (a - target) * (b - target) <= 0 {
                let va = logarithmicValue ? log(max(a, 1e-30)) : a
                let vb = logarithmicValue ? log(max(b, 1e-30)) : b
                let vt = logarithmicValue ? log(max(target, 1e-30)) : target
                let fraction = abs(vb - va) < 1e-12 ? 0 : (vt - va) / (vb - va)
                let lwa = log(points[i - 1].w), lwb = log(points[i].w)
                return exp(lwa + fraction * (lwb - lwa))
            }
        }
        return nil
    }

    private static func phaseCrossing(_ points: [FrequencyPoint], target: Double) -> Double? {
        guard points.count > 1 else { return nil }
        for i in 1..<points.count {
            let a = points[i - 1].phase, b = points[i].phase
            if (a - target) * (b - target) <= 0 && a != b {
                let f = (target - a) / (b - a)
                return exp(log(points[i - 1].w) + f * (log(points[i].w) - log(points[i - 1].w)))
            }
        }
        return nil
    }

    private static func interpolatePhase(_ points: [FrequencyPoint], at w: Double) -> Double {
        interpolate(points, at: w, value: { $0.phase })
    }

    private static func interpolateMagnitude(_ points: [FrequencyPoint], at w: Double) -> Double {
        exp(interpolate(points, at: w, value: { log(max($0.magnitude, 1e-30)) }))
    }

    private static func interpolate(_ points: [FrequencyPoint], at w: Double, value: (FrequencyPoint) -> Double) -> Double {
        if w <= points[0].w { return value(points[0]) }
        for i in 1..<points.count where w <= points[i].w {
            let a = points[i - 1], b = points[i]
            let f = (log(w) - log(a.w)) / (log(b.w) - log(a.w))
            return value(a) + f * (value(b) - value(a))
        }
        return value(points.last!)
    }
}
