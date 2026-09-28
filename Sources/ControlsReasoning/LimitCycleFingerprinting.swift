import Foundation

public enum LimitCycleRootCause: String, Codable, Sendable {
    case noSustainedLimitCycle
    case linearInstability
    case aggressiveTuning
    case stictionDriven
    case deadbandHunting
    case backlashOrHysteresis
    case saturationDriven
    case actuatorRateLimited
    case processOscillation
    case indeterminate

    public var displayName: String {
        switch self {
        case .noSustainedLimitCycle: return "No sustained limit cycle"
        case .linearInstability: return "Linear instability"
        case .aggressiveTuning: return "Overly aggressive tuning"
        case .stictionDriven: return "Stiction-driven limit cycle"
        case .deadbandHunting: return "Deadband-induced hunting"
        case .backlashOrHysteresis: return "Backlash / hysteresis cycling"
        case .saturationDriven: return "Saturation-driven cycling"
        case .actuatorRateLimited: return "Rate-limit-driven cycling"
        case .processOscillation: return "Process-origin oscillation"
        case .indeterminate: return "Indeterminate oscillation"
        }
    }
}

public enum LimitCycleConfidence: String, Codable, Sendable {
    case low
    case medium
    case high

    public var displayName: String { rawValue.capitalized }
}

public struct LimitCycleFingerprint: Equatable, Sendable {
    public let cycleCount: Int
    public let meanPeriodMilliseconds: Double?
    public let periodCoefficientOfVariation: Double?
    public let meanProcessAmplitude: Double?
    public let amplitudeCoefficientOfVariation: Double?
    public let commandToPositionLagFraction: Double?
    public let integralSawtoothScore: Double
    public let breakawayPhaseFraction: Double?
    public let breakawayCount: Int
    public let saturationFraction: Double
    public let stuckFraction: Double
    public let deadbandFraction: Double
    public let backlashFraction: Double
    public let hysteresisFraction: Double
    public let rateLimitFraction: Double
    public let periodicityScore: Double
    public let sustained: Bool
}

public struct LimitCycleAssessment: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: SampledPIDDefinition
    public let fingerprint: LimitCycleFingerprint
    public let rootCause: LimitCycleRootCause
    public let confidence: LimitCycleConfidence
    public let evidence: [String]
    public let summary: String
}

public struct LimitCycleReport: Equatable, Sendable {
    public let assessments: [LimitCycleAssessment]
    public let summary: String
}

public struct LimitCycleOperatingObservation: Equatable, Sendable {
    public let label: String
    public let setpoint: Double
    public let load: Double?
    public let simulation: SampledPIDSimulation

    public init(label: String, setpoint: Double, load: Double? = nil, simulation: SampledPIDSimulation) {
        self.label = label
        self.setpoint = setpoint
        self.load = load
        self.simulation = simulation
    }
}

public struct LimitCycleConditionDependence: Equatable, Sendable {
    public let amplitudeSetpointCorrelation: Double?
    public let amplitudeLoadCorrelation: Double?
    public let amplitudeRangeRatio: Double?
    public let interpretation: String
}

public enum LimitCycleFingerprintAnalyzer {
    public static func assess(report: SampledPIDReport) -> LimitCycleReport {
        let assessments = report.assessments.map { item -> LimitCycleAssessment in
            let fingerprint = fingerprint(simulation: item.simulation)
            let rootCause = classify(simulation: item.simulation, fingerprint: fingerprint)
            let confidence = confidence(for: fingerprint, cause: rootCause)
            let evidence = explain(simulation: item.simulation, fingerprint: fingerprint, cause: rootCause)
            let summary = summary(for: rootCause, fingerprint: fingerprint)
            return .init(definition: item.definition, fingerprint: fingerprint, rootCause: rootCause, confidence: confidence, evidence: evidence, summary: summary)
        }
        let reportSummary: String
        if assessments.isEmpty {
            reportSummary = "No sampled PID simulations were available for limit-cycle fingerprinting."
        } else if let strongest = assessments.max(by: { causeRank($0.rootCause) < causeRank($1.rootCause) }) {
            reportSummary = "Fingerprinting evaluated \(assessments.count) loop(s). Strongest oscillation diagnosis: \(strongest.definition.name) — \(strongest.rootCause.displayName)."
        } else {
            reportSummary = "Fingerprinting evaluated \(assessments.count) loop(s)."
        }
        return .init(assessments: assessments, summary: reportSummary)
    }

    public static func fingerprint(simulation: SampledPIDSimulation) -> LimitCycleFingerprint {
        let points = simulation.points
        guard points.count >= 8 else {
            return .init(cycleCount: 0, meanPeriodMilliseconds: nil, periodCoefficientOfVariation: nil, meanProcessAmplitude: nil, amplitudeCoefficientOfVariation: nil, commandToPositionLagFraction: nil, integralSawtoothScore: 0, breakawayPhaseFraction: nil, breakawayCount: 0, saturationFraction: 0, stuckFraction: 0, deadbandFraction: 0, backlashFraction: 0, hysteresisFraction: 0, rateLimitFraction: 0, periodicityScore: 0, sustained: false)
        }

        let startTime = simulation.scenario.stepTimeMilliseconds + max(0, simulation.scenario.durationMilliseconds - simulation.scenario.stepTimeMilliseconds) * 0.20
        let window = points.filter { $0.timeMilliseconds >= startTime }
        guard window.count >= 8 else {
            return fingerprintFromShortWindow(simulation: simulation, points: window)
        }

        let stepMagnitude = abs(simulation.scenario.setpointAfterStep - simulation.scenario.setpointBeforeStep)
        let epsilon = max(1e-5, stepMagnitude * 0.002)
        var positiveCrossings: [Int] = []
        for i in 1..<window.count {
            let previous = window[i - 1].error
            let current = window[i].error
            if previous <= 0 && current > 0 && (abs(previous) > epsilon || abs(current) > epsilon) {
                positiveCrossings.append(i)
            }
        }

        var periods: [Double] = []
        var amplitudes: [Double] = []
        if positiveCrossings.count >= 2 {
            for pairIndex in 1..<positiveCrossings.count {
                let lo = positiveCrossings[pairIndex - 1]
                let hi = positiveCrossings[pairIndex]
                guard hi > lo else { continue }
                let segment = Array(window[lo...hi])
                periods.append(window[hi].timeMilliseconds - window[lo].timeMilliseconds)
                if let minPV = segment.map(\.processValue).min(), let maxPV = segment.map(\.processValue).max() {
                    amplitudes.append((maxPV - minPV) * 0.5)
                }
            }
        }

        let periodStats = stats(periods)
        let amplitudeStats = stats(amplitudes)
        let periodCV = coefficientOfVariation(periods)
        let amplitudeCV = coefficientOfVariation(amplitudes)
        let regularity = max(0, min(1, 1 - 0.5 * min(periodCV ?? 1, 1) - 0.5 * min(amplitudeCV ?? 1, 1)))
        let meaningfulAmplitude = (amplitudeStats.mean ?? 0) > max(stepMagnitude * 0.005, 1e-5)
        let sustained = periods.count >= 2 && meaningfulAmplitude && regularity >= 0.45

        let commandLag = normalizedLagFraction(points: window, periodMilliseconds: periodStats.mean)
        let integralSawtooth = sawtoothScore(points: window)
        let breakawayPhase = meanBreakawayPhase(points: window, crossings: positiveCrossings)

        let n = Double(max(window.count, 1))
        return .init(
            cycleCount: periods.count,
            meanPeriodMilliseconds: periodStats.mean,
            periodCoefficientOfVariation: periodCV,
            meanProcessAmplitude: amplitudeStats.mean,
            amplitudeCoefficientOfVariation: amplitudeCV,
            commandToPositionLagFraction: commandLag,
            integralSawtoothScore: integralSawtooth,
            breakawayPhaseFraction: breakawayPhase,
            breakawayCount: window.filter(\.breakaway).count,
            saturationFraction: Double(window.filter(\.saturated).count) / n,
            stuckFraction: Double(window.filter(\.actuatorStuck).count) / n,
            deadbandFraction: Double(window.filter(\.deadbandLimited).count) / n,
            backlashFraction: Double(window.filter(\.backlashLimited).count) / n,
            hysteresisFraction: Double(window.filter(\.hysteresisActive).count) / n,
            rateLimitFraction: Double(window.filter(\.rateLimited).count) / n,
            periodicityScore: regularity,
            sustained: sustained
        )
    }

    public static func conditionDependence(_ observations: [LimitCycleOperatingObservation]) -> LimitCycleConditionDependence {
        let rows = observations.compactMap { obs -> (setpoint: Double, load: Double?, amplitude: Double)? in
            guard let amplitude = fingerprint(simulation: obs.simulation).meanProcessAmplitude else { return nil }
            return (obs.setpoint, obs.load, amplitude)
        }
        let setpointCorrelation = correlation(rows.map { ($0.setpoint, $0.amplitude) })
        let loadRows = rows.compactMap { row -> (Double, Double)? in row.load.map { ($0, row.amplitude) } }
        let loadCorrelation = correlation(loadRows)
        let amplitudes = rows.map(\.amplitude)
        let ratio: Double? = {
            guard let minV = amplitudes.min(), let maxV = amplitudes.max(), maxV > 1e-9 else { return nil }
            return minV <= 1e-9 ? nil : maxV / minV
        }()
        var messages: [String] = []
        if let c = setpointCorrelation, abs(c) >= 0.65 { messages.append(String(format: "oscillation amplitude changes strongly with setpoint (r %.2f)", c)) }
        if let c = loadCorrelation, abs(c) >= 0.65 { messages.append(String(format: "oscillation amplitude changes strongly with load (r %.2f)", c)) }
        if messages.isEmpty { messages.append("no strong amplitude dependence on the supplied setpoint/load observations was established") }
        return .init(amplitudeSetpointCorrelation: setpointCorrelation, amplitudeLoadCorrelation: loadCorrelation, amplitudeRangeRatio: ratio, interpretation: messages.joined(separator: "; ").capitalized + ".")
    }

    private static func classify(simulation: SampledPIDSimulation, fingerprint f: LimitCycleFingerprint) -> LimitCycleRootCause {
        let d = simulation.diagnostics
        if d.linearMargins.robustness == .unstable { return .linearInstability }
        guard f.sustained else { return .noSustainedLimitCycle }
        if f.stuckFraction > 0.05 && f.breakawayCount >= 2 && f.integralSawtoothScore > 0.20 { return .stictionDriven }
        if f.saturationFraction > 0.15 { return .saturationDriven }
        if f.deadbandFraction > 0.06 { return .deadbandHunting }
        if f.backlashFraction > 0.04 || (f.hysteresisFraction > 0.20 && d.limitCycleReversals >= 2) { return .backlashOrHysteresis }
        if f.rateLimitFraction > 0.15 { return .actuatorRateLimited }
        if d.linearMargins.robustness == .aggressive || d.linearMargins.robustness == .oscillationProne { return .aggressiveTuning }
        if simulation.plant.modelKind == .underdampedSecondOrder, (simulation.plant.dampingRatio ?? 1) < 0.45 { return .processOscillation }
        return .indeterminate
    }

    private static func confidence(for f: LimitCycleFingerprint, cause: LimitCycleRootCause) -> LimitCycleConfidence {
        if cause == .noSustainedLimitCycle { return f.cycleCount == 0 ? .high : .medium }
        let evidenceStrength = f.periodicityScore + min(Double(f.cycleCount) / 4.0, 1)
        if evidenceStrength >= 1.55 { return .high }
        if evidenceStrength >= 0.95 { return .medium }
        return .low
    }

    private static func explain(simulation: SampledPIDSimulation, fingerprint f: LimitCycleFingerprint, cause: LimitCycleRootCause) -> [String] {
        var evidence: [String] = []
        if let p = f.meanPeriodMilliseconds { evidence.append(String(format: "Detected %d repeat cycle(s) with mean period %.0f ms and periodicity score %.2f.", f.cycleCount, p, f.periodicityScore)) }
        if let a = f.meanProcessAmplitude { evidence.append(String(format: "Mean process oscillation amplitude is %.3f; amplitude CV is %.2f.", a, f.amplitudeCoefficientOfVariation ?? 0)) }
        if let lag = f.commandToPositionLagFraction { evidence.append(String(format: "Controller-command to actuator-position lag is approximately %.0f%% of the oscillation period.", lag * 100)) }
        if f.integralSawtoothScore > 0.05 { evidence.append(String(format: "Integral sawtooth score is %.2f, measuring repeated integral ramp/reversal structure.", f.integralSawtoothScore)) }
        if f.breakawayCount > 0 { evidence.append(String(format: "%d breakaway event(s) occur in the fingerprint window; mean breakaway phase is %.0f%% of a cycle.", f.breakawayCount, (f.breakawayPhaseFraction ?? 0) * 100)) }
        switch cause {
        case .linearInstability:
            evidence.append("The linearized controller/plant pair is already beyond the estimated stability boundary, so nonlinear cycling is secondary evidence rather than the initiating explanation.")
        case .stictionDriven:
            evidence.append("Repeated command-without-motion intervals, integral ramping, and breakaway events line up with the repeating cycle. This is the characteristic stick-build-release pattern of stiction.")
        case .deadbandHunting:
            evidence.append("Small command reversals are repeatedly swallowed by deadband before actuator motion resumes, producing hunting around the target without stiction-style breakaway events.")
        case .backlashOrHysteresis:
            evidence.append("Cycling is tied to direction-dependent lost motion or path dependence, which is more consistent with backlash/hysteresis than a pure tuning problem.")
        case .saturationDriven:
            evidence.append(String(format: "The controller is saturated for %.0f%% of the fingerprint window, making output authority a dominant part of the repeating cycle.", f.saturationFraction * 100))
        case .actuatorRateLimited:
            evidence.append(String(format: "The actuator is slew limited for %.0f%% of the fingerprint window, so the physical element cannot follow the controller's cyclic demand.", f.rateLimitFraction * 100))
        case .aggressiveTuning:
            evidence.append("No dominant actuator nonlinearity is required to explain the cycle, while the linear robustness estimate is aggressive/oscillation-prone. Controller tuning is therefore the stronger hypothesis.")
        case .processOscillation:
            evidence.append("The actuator path is comparatively clean while the identified plant itself is lightly damped, supporting a process-origin oscillation hypothesis rather than a valve nonlinearity diagnosis.")
        case .noSustainedLimitCycle:
            evidence.append("The trace does not contain enough repeatable cycles with consistent period and amplitude to call the behavior a sustained limit cycle.")
        case .indeterminate:
            evidence.append("A repeatable oscillation is present, but the available actuator, saturation, plant, and tuning evidence does not uniquely identify its cause.")
        }
        return evidence
    }

    private static func summary(for cause: LimitCycleRootCause, fingerprint f: LimitCycleFingerprint) -> String {
        if cause == .noSustainedLimitCycle { return "No sustained periodic fingerprint was established; avoid assigning a nonlinear root cause from a single ugly transient." }
        return "Automatic fingerprinting classifies the repeating behavior as \(cause.displayName.lowercased()) with \(f.cycleCount) measured cycle interval(s)."
    }

    private static func fingerprintFromShortWindow(simulation: SampledPIDSimulation, points: [SampledPIDPoint]) -> LimitCycleFingerprint {
        let n = Double(max(points.count, 1))
        return .init(cycleCount: 0, meanPeriodMilliseconds: nil, periodCoefficientOfVariation: nil, meanProcessAmplitude: nil, amplitudeCoefficientOfVariation: nil, commandToPositionLagFraction: nil, integralSawtoothScore: sawtoothScore(points: points), breakawayPhaseFraction: nil, breakawayCount: points.filter(\.breakaway).count, saturationFraction: Double(points.filter(\.saturated).count) / n, stuckFraction: Double(points.filter(\.actuatorStuck).count) / n, deadbandFraction: Double(points.filter(\.deadbandLimited).count) / n, backlashFraction: Double(points.filter(\.backlashLimited).count) / n, hysteresisFraction: Double(points.filter(\.hysteresisActive).count) / n, rateLimitFraction: Double(points.filter(\.rateLimited).count) / n, periodicityScore: 0, sustained: false)
    }

    private static func sawtoothScore(points: [SampledPIDPoint]) -> Double {
        guard points.count >= 4 else { return 0 }
        var derivativeSigns: [Int] = []
        for i in 1..<points.count {
            let delta = points[i].integralTerm - points[i - 1].integralTerm
            if abs(delta) > 1e-8 { derivativeSigns.append(delta > 0 ? 1 : -1) }
        }
        guard derivativeSigns.count >= 3 else { return 0 }
        var reversals = 0
        for i in 1..<derivativeSigns.count where derivativeSigns[i] != derivativeSigns[i - 1] { reversals += 1 }
        let reversalDensity = Double(reversals) / Double(max(derivativeSigns.count - 1, 1))
        let integralRange = (points.map(\.integralTerm).max() ?? 0) - (points.map(\.integralTerm).min() ?? 0)
        let outputSpan = max((points.map(\.controllerOutput).max() ?? 0) - (points.map(\.controllerOutput).min() ?? 0), 1e-9)
        let normalizedRange = min(abs(integralRange) / outputSpan, 1)
        return min(1, normalizedRange * 0.65 + min(reversalDensity * 8, 1) * 0.35)
    }

    private static func meanBreakawayPhase(points: [SampledPIDPoint], crossings: [Int]) -> Double? {
        guard crossings.count >= 2 else { return nil }
        var phases: [Double] = []
        for i in 1..<crossings.count {
            let lo = crossings[i - 1], hi = crossings[i]
            guard hi > lo else { continue }
            for index in lo...hi where points[index].breakaway {
                phases.append(Double(index - lo) / Double(hi - lo))
            }
        }
        return phases.isEmpty ? nil : phases.reduce(0,+) / Double(phases.count)
    }

    private static func normalizedLagFraction(points: [SampledPIDPoint], periodMilliseconds: Double?) -> Double? {
        guard points.count >= 12, let periodMilliseconds, periodMilliseconds > 0 else { return nil }
        let dt = max(points[1].timeMilliseconds - points[0].timeMilliseconds, 1e-9)
        let maxLag = min(points.count / 3, max(1, Int((periodMilliseconds / dt) * 0.45)))
        let x = center(points.map(\.controllerOutput))
        let y = center(points.map(\.actuatorOutput))
        guard energy(x) > 1e-12, energy(y) > 1e-12 else { return nil }
        var bestLag = 0
        var best = -Double.infinity
        for lag in 0...maxLag {
            let count = x.count - lag
            guard count > 4 else { continue }
            var numerator = 0.0, ex = 0.0, ey = 0.0
            for i in 0..<count {
                let a = x[i], b = y[i + lag]
                numerator += a * b; ex += a * a; ey += b * b
            }
            let score = numerator / max(sqrt(ex * ey), 1e-12)
            if score > best { best = score; bestLag = lag }
        }
        return min(1, Double(bestLag) * dt / periodMilliseconds)
    }

    private static func stats(_ values: [Double]) -> (mean: Double?, std: Double?) {
        guard !values.isEmpty else { return (nil, nil) }
        let mean = values.reduce(0,+) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0,+) / Double(max(values.count - 1, 1))
        return (mean, sqrt(max(variance, 0)))
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double? {
        let s = stats(values)
        guard let mean = s.mean, let std = s.std, abs(mean) > 1e-12 else { return nil }
        return abs(std / mean)
    }

    private static func center(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let mean = values.reduce(0,+) / Double(values.count)
        return values.map { $0 - mean }
    }

    private static func energy(_ values: [Double]) -> Double { values.map { $0 * $0 }.reduce(0,+) }

    private static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 3 else { return nil }
        let xs = pairs.map { $0.0 }, ys = pairs.map { $0.1 }
        let mx = xs.reduce(0,+) / Double(xs.count), my = ys.reduce(0,+) / Double(ys.count)
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in pairs.indices {
            let a = xs[i] - mx, b = ys[i] - my
            num += a * b; dx += a * a; dy += b * b
        }
        guard dx > 1e-12, dy > 1e-12 else { return nil }
        return num / sqrt(dx * dy)
    }

    private static func causeRank(_ cause: LimitCycleRootCause) -> Int {
        switch cause {
        case .noSustainedLimitCycle: return 0
        case .indeterminate: return 1
        case .processOscillation: return 2
        case .actuatorRateLimited: return 3
        case .backlashOrHysteresis: return 4
        case .deadbandHunting: return 5
        case .saturationDriven: return 6
        case .stictionDriven: return 7
        case .aggressiveTuning: return 8
        case .linearInstability: return 9
        }
    }
}
