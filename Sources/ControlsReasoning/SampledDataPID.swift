import Foundation

public enum PIDAntiWindupMode: String, Codable, Sendable {
    case none
    case conditionalIntegration
    case backCalculation

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .conditionalIntegration: return "Conditional integration"
        case .backCalculation: return "Back-calculation"
        }
    }
}


public struct ActuatorNonlinearitySettings: Equatable, Sendable {
    public let stictionBreakaway: Double
    public let deadband: Double
    public let backlash: Double
    public let hysteresisWidth: Double

    public init(stictionBreakaway: Double = 0, deadband: Double = 0, backlash: Double = 0, hysteresisWidth: Double = 0) {
        self.stictionBreakaway = max(0, stictionBreakaway)
        self.deadband = max(0, deadband)
        self.backlash = max(0, backlash)
        self.hysteresisWidth = max(0, hysteresisWidth)
    }

    public static let ideal = ActuatorNonlinearitySettings()
}

public struct SampledPIDExecutionSettings: Equatable, Sendable {
    public let controller: PIDControllerSettings
    public let taskPeriodMilliseconds: Double
    public let outputMinimum: Double
    public let outputMaximum: Double
    public let antiWindupMode: PIDAntiWindupMode
    public let backCalculationGainPerSecond: Double
    public let actuatorRateLimitPerSecond: Double?
    public let actuatorNonlinearity: ActuatorNonlinearitySettings

    public init(
        controller: PIDControllerSettings,
        taskPeriodMilliseconds: Double,
        outputMinimum: Double = 0,
        outputMaximum: Double = 100,
        antiWindupMode: PIDAntiWindupMode = .conditionalIntegration,
        backCalculationGainPerSecond: Double = 4,
        actuatorRateLimitPerSecond: Double? = nil,
        actuatorNonlinearity: ActuatorNonlinearitySettings = .ideal
    ) {
        self.controller = controller
        self.taskPeriodMilliseconds = max(0.1, taskPeriodMilliseconds)
        self.outputMinimum = min(outputMinimum, outputMaximum)
        self.outputMaximum = max(outputMinimum, outputMaximum)
        self.antiWindupMode = antiWindupMode
        self.backCalculationGainPerSecond = max(0, backCalculationGainPerSecond)
        self.actuatorRateLimitPerSecond = actuatorRateLimitPerSecond.map { max(0, $0) }
        self.actuatorNonlinearity = actuatorNonlinearity
    }
}

public struct SampledPIDScenario: Equatable, Sendable {
    public let initialProcessValue: Double
    public let initialOutput: Double
    public let setpointBeforeStep: Double
    public let setpointAfterStep: Double
    public let stepTimeMilliseconds: Double
    public let durationMilliseconds: Double

    public init(
        initialProcessValue: Double = 0,
        initialOutput: Double = 0,
        setpointBeforeStep: Double = 0,
        setpointAfterStep: Double = 1,
        stepTimeMilliseconds: Double = 0,
        durationMilliseconds: Double = 3_000
    ) {
        self.initialProcessValue = initialProcessValue
        self.initialOutput = initialOutput
        self.setpointBeforeStep = setpointBeforeStep
        self.setpointAfterStep = setpointAfterStep
        self.stepTimeMilliseconds = max(0, stepTimeMilliseconds)
        self.durationMilliseconds = max(1, durationMilliseconds)
    }
}

public struct SampledPIDPoint: Identifiable, Equatable, Sendable {
    public var id: Double { timeMilliseconds }
    public let timeMilliseconds: Double
    public let setpoint: Double
    public let processValue: Double
    public let error: Double
    public let proportionalTerm: Double
    public let integralTerm: Double
    public let derivativeTerm: Double
    public let unconstrainedOutput: Double
    public let controllerOutput: Double
    public let actuatorOutput: Double
    public let saturated: Bool
    public let rateLimited: Bool
    public let actuatorStuck: Bool
    public let breakaway: Bool
    public let backlashLimited: Bool
    public let deadbandLimited: Bool
    public let hysteresisActive: Bool
}

public enum SampledLoopIssue: String, Codable, Sendable {
    case linearInstability
    case samplingTooSlow
    case integralWindup
    case outputSaturation
    case actuatorRateLimit
    case stiction
    case deadband
    case backlash
    case hysteresis
    case noDominantNonlinearity
    case indeterminate

    public var displayName: String {
        switch self {
        case .linearInstability: return "Linear stability problem"
        case .samplingTooSlow: return "PID task period too slow"
        case .integralWindup: return "Integral windup"
        case .outputSaturation: return "Output saturation"
        case .actuatorRateLimit: return "Actuator rate limiting"
        case .stiction: return "Valve stiction / breakaway"
        case .deadband: return "Actuator deadband"
        case .backlash: return "Mechanical backlash"
        case .hysteresis: return "Actuator hysteresis"
        case .noDominantNonlinearity: return "No dominant sampled/nonlinear issue"
        case .indeterminate: return "Indeterminate"
        }
    }
}

public struct SampledLoopDiagnostics: Equatable, Sendable {
    public let dominantIssue: SampledLoopIssue
    public let linearMargins: StabilityMarginEstimate
    public let taskPeriodMilliseconds: Double
    public let samplesPerDominantTimeConstant: Double?
    public let samplesPerGainCrossoverCycle: Double?
    public let saturationFraction: Double
    public let rateLimitFraction: Double
    public let stuckFraction: Double
    public let breakawayCount: Int
    public let backlashFraction: Double
    public let deadbandFraction: Double
    public let hysteresisFraction: Double
    public let limitCycleReversals: Int
    public let peakIntegralMagnitude: Double
    public let peakProcessValue: Double
    public let finalAbsoluteError: Double
    public let interpretations: [String]
    public let summary: String
}

public struct SampledPIDSimulation: Equatable, Sendable {
    public let settings: SampledPIDExecutionSettings
    public let plant: IdentifiedPlantFit
    public let scenario: SampledPIDScenario
    public let points: [SampledPIDPoint]
    public let diagnostics: SampledLoopDiagnostics
}


public struct SampledPIDDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let systemIdentificationSignatureID: String
    public let settings: SampledPIDExecutionSettings
    public let scenario: SampledPIDScenario

    public init(id: String? = nil, name: String, systemIdentificationSignatureID: String, settings: SampledPIDExecutionSettings, scenario: SampledPIDScenario = .init()) {
        self.id = id ?? "sampled-pid|\(systemIdentificationSignatureID)|\(name)"
        self.name = name
        self.systemIdentificationSignatureID = systemIdentificationSignatureID
        self.settings = settings
        self.scenario = scenario
    }
}

public struct SampledPIDAssessment: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: SampledPIDDefinition
    public let simulation: SampledPIDSimulation
}

public struct SampledPIDReport: Equatable, Sendable {
    public let assessments: [SampledPIDAssessment]
    public let summary: String
}

public enum SampledDataPIDAnalyzer {
    public static func assess(current: SystemIdentificationAssessment, definitions: [SampledPIDDefinition]) -> SampledPIDReport {
        var assessments: [SampledPIDAssessment] = []
        for definition in definitions {
            guard let plant = current.fits[definition.systemIdentificationSignatureID] else { continue }
            let simulation = simulate(settings: definition.settings, plant: plant, scenario: definition.scenario)
            assessments.append(.init(definition: definition, simulation: simulation))
        }
        let summary: String
        if assessments.isEmpty {
            summary = "No sampled PID definition had a matching identified current plant."
        } else if let worst = assessments.max(by: { issueRank($0.simulation.diagnostics.dominantIssue) < issueRank($1.simulation.diagnostics.dominantIssue) }) {
            summary = "Simulated \(assessments.count) sampled loop(s). Most concerning: \(worst.definition.name) — \(worst.simulation.diagnostics.dominantIssue.displayName)."
        } else {
            summary = "Simulated \(assessments.count) sampled loop(s)."
        }
        return .init(assessments: assessments, summary: summary)
    }

    public static func assessRegional(current: RegionalSystemIdentificationAssessment, definitions: [SampledPIDDefinition]) -> SampledPIDReport {
        guard let modeName = current.selectedModeName, let assessment = current.assessment else {
            return .init(assessments: [], summary: "Operating regime unresolved; sampled PID behavior was not simulated against the wrong plant model.")
        }
        let report = assess(current: assessment, definitions: definitions)
        return .init(assessments: report.assessments, summary: "Operating regime: \(modeName). \(report.summary)")
    }

    public static func simulate(
        settings: SampledPIDExecutionSettings,
        plant: IdentifiedPlantFit,
        scenario: SampledPIDScenario = .init()
    ) -> SampledPIDSimulation {
        let dt = settings.taskPeriodMilliseconds / 1000.0
        let count = max(2, Int(ceil(scenario.durationMilliseconds / settings.taskPeriodMilliseconds)) + 1)
        let delaySteps = max(0, Int(round(plant.deadTimeMilliseconds / settings.taskPeriodMilliseconds)))
        var delayLine = Array(repeating: scenario.initialOutput, count: delaySteps + 1)
        var processValue = scenario.initialProcessValue
        var velocity = 0.0
        var integral = 0.0
        var previousError = scenario.setpointBeforeStep - processValue
        var filteredDerivative = 0.0
        var actuatorOutput = clamp(scenario.initialOutput, settings.outputMinimum, settings.outputMaximum)
        var lastControllerOutput = actuatorOutput
        var lastDirection = 0.0
        var backlashRemaining = 0.0
        var points: [SampledPIDPoint] = []
        points.reserveCapacity(count)

        for index in 0..<count {
            let timeMs = Double(index) * settings.taskPeriodMilliseconds
            let setpoint = timeMs >= scenario.stepTimeMilliseconds ? scenario.setpointAfterStep : scenario.setpointBeforeStep
            let error = setpoint - processValue
            let p = settings.controller.proportionalGain * error
            let rawDerivative = index == 0 ? 0 : settings.controller.derivativeGainSeconds * (error - previousError) / dt
            let d: Double
            if settings.controller.derivativeFilterTimeConstantSeconds > 0 {
                let alpha = dt / (settings.controller.derivativeFilterTimeConstantSeconds + dt)
                filteredDerivative += alpha * (rawDerivative - filteredDerivative)
                d = filteredDerivative
            } else {
                d = rawDerivative
            }

            let candidateIntegral = integral + settings.controller.integralGainPerSecond * error * dt
            let candidateRaw = p + candidateIntegral + d
            let candidateClamped = clamp(candidateRaw, settings.outputMinimum, settings.outputMaximum)
            let candidateSaturated = abs(candidateRaw - candidateClamped) > 1e-10

            switch settings.antiWindupMode {
            case .none:
                integral = candidateIntegral
            case .conditionalIntegration:
                let drivesFurtherHigh = candidateRaw > settings.outputMaximum && error > 0
                let drivesFurtherLow = candidateRaw < settings.outputMinimum && error < 0
                if !(candidateSaturated && (drivesFurtherHigh || drivesFurtherLow)) {
                    integral = candidateIntegral
                }
            case .backCalculation:
                integral = candidateIntegral + settings.backCalculationGainPerSecond * (candidateClamped - candidateRaw) * dt
            }

            let raw = p + integral + d
            let controllerOutput = clamp(raw, settings.outputMinimum, settings.outputMaximum)
            let saturated = abs(raw - controllerOutput) > 1e-10
            let nl = settings.actuatorNonlinearity
            let commandDelta = controllerOutput - lastControllerOutput
            let direction = commandDelta == 0 ? lastDirection : (commandDelta > 0 ? 1.0 : -1.0)
            if direction != 0 && lastDirection != 0 && direction != lastDirection {
                backlashRemaining = nl.backlash
            }

            var nonlinearTarget = controllerOutput
            var backlashLimited = false
            if backlashRemaining > 0 && direction != 0 {
                let consume = min(abs(commandDelta), backlashRemaining)
                backlashRemaining -= consume
                if backlashRemaining > 1e-10 {
                    nonlinearTarget = actuatorOutput
                    backlashLimited = true
                }
            }

            let gap = nonlinearTarget - actuatorOutput
            let deadbandLimited = nl.deadband > 0 && abs(gap) <= nl.deadband
            let stictionStuck = nl.stictionBreakaway > 0 && abs(gap) < nl.stictionBreakaway
            var breakaway = false
            if deadbandLimited || stictionStuck || backlashLimited {
                nonlinearTarget = actuatorOutput
            } else if nl.stictionBreakaway > 0 && abs(gap) >= nl.stictionBreakaway {
                breakaway = true
            }

            let hysteresisActive = nl.hysteresisWidth > 0 && direction != 0
            if hysteresisActive {
                nonlinearTarget -= direction * nl.hysteresisWidth * 0.5
            }

            let rateLimitedOutput: Double
            let rateLimited: Bool
            if let rate = settings.actuatorRateLimitPerSecond, rate > 0 {
                let maxDelta = rate * dt
                let desiredDelta = nonlinearTarget - actuatorOutput
                let appliedDelta = clamp(desiredDelta, -maxDelta, maxDelta)
                rateLimitedOutput = actuatorOutput + appliedDelta
                rateLimited = abs(appliedDelta - desiredDelta) > 1e-10
            } else {
                rateLimitedOutput = nonlinearTarget
                rateLimited = false
            }
            actuatorOutput = clamp(rateLimitedOutput, settings.outputMinimum, settings.outputMaximum)
            if direction != 0 { lastDirection = direction }
            lastControllerOutput = controllerOutput

            points.append(.init(
                timeMilliseconds: timeMs,
                setpoint: setpoint,
                processValue: processValue,
                error: error,
                proportionalTerm: p,
                integralTerm: integral,
                derivativeTerm: d,
                unconstrainedOutput: raw,
                controllerOutput: controllerOutput,
                actuatorOutput: actuatorOutput,
                saturated: saturated,
                rateLimited: rateLimited,
                actuatorStuck: stictionStuck,
                breakaway: breakaway,
                backlashLimited: backlashLimited,
                deadbandLimited: deadbandLimited,
                hysteresisActive: hysteresisActive
            ))

            delayLine.append(actuatorOutput)
            let delayedOutput = delayLine.removeFirst()
            advancePlant(plant, input: delayedOutput, dt: dt, processValue: &processValue, velocity: &velocity)
            previousError = error
        }

        let diagnostics = diagnose(settings: settings, plant: plant, scenario: scenario, points: points)
        return .init(settings: settings, plant: plant, scenario: scenario, points: points, diagnostics: diagnostics)
    }

    public static func diagnose(
        settings: SampledPIDExecutionSettings,
        plant: IdentifiedPlantFit,
        scenario: SampledPIDScenario,
        points: [SampledPIDPoint]
    ) -> SampledLoopDiagnostics {
        let margins = ControllerAwareTuningAnalyzer.margins(controller: settings.controller, plant: plant)
        guard !points.isEmpty else {
            return .init(dominantIssue: .indeterminate, linearMargins: margins, taskPeriodMilliseconds: settings.taskPeriodMilliseconds, samplesPerDominantTimeConstant: nil, samplesPerGainCrossoverCycle: nil, saturationFraction: 0, rateLimitFraction: 0, stuckFraction: 0, breakawayCount: 0, backlashFraction: 0, deadbandFraction: 0, hysteresisFraction: 0, limitCycleReversals: 0, peakIntegralMagnitude: 0, peakProcessValue: scenario.initialProcessValue, finalAbsoluteError: .infinity, interpretations: ["No sampled closed-loop points were available."], summary: "Sampled-data diagnosis is indeterminate.")
        }

        let saturationFraction = Double(points.filter(\.saturated).count) / Double(points.count)
        let rateLimitFraction = Double(points.filter(\.rateLimited).count) / Double(points.count)
        let stuckFraction = Double(points.filter(\.actuatorStuck).count) / Double(points.count)
        let breakawayCount = points.filter(\.breakaway).count
        let backlashFraction = Double(points.filter(\.backlashLimited).count) / Double(points.count)
        let deadbandFraction = Double(points.filter(\.deadbandLimited).count) / Double(points.count)
        let hysteresisFraction = Double(points.filter(\.hysteresisActive).count) / Double(points.count)
        var limitCycleReversals = 0
        var lastErrorSign = 0
        for point in points {
            let sign = point.error > 1e-4 ? 1 : (point.error < -1e-4 ? -1 : 0)
            if sign != 0 && lastErrorSign != 0 && sign != lastErrorSign { limitCycleReversals += 1 }
            if sign != 0 { lastErrorSign = sign }
        }
        let peakIntegral = points.map { abs($0.integralTerm) }.max() ?? 0
        let peakPV = points.map(\.processValue).max() ?? scenario.initialProcessValue
        let finalError = abs(points.last?.error ?? 0)
        let samplesPerTau = plant.timeConstantMilliseconds.map { $0 / settings.taskPeriodMilliseconds }
        let samplesPerCycle = margins.gainCrossoverRadiansPerSecond.map { wc in
            (2 * Double.pi / wc) / (settings.taskPeriodMilliseconds / 1000.0)
        }
        let outputSpan = max(settings.outputMaximum - settings.outputMinimum, 1e-9)
        let substantialWindup = settings.antiWindupMode == .none && saturationFraction > 0.08 && peakIntegral > outputSpan * 0.45
        let slowSampling = (samplesPerTau.map { $0 < 5 } ?? false) || (samplesPerCycle.map { $0 < 10 } ?? false)

        let issue: SampledLoopIssue
        if margins.robustness == .unstable {
            issue = .linearInstability
        } else if slowSampling {
            issue = .samplingTooSlow
        } else if substantialWindup {
            issue = .integralWindup
        } else if stuckFraction > 0.08 && breakawayCount >= 2 {
            issue = .stiction
        } else if backlashFraction > 0.05 {
            issue = .backlash
        } else if deadbandFraction > 0.08 {
            issue = .deadband
        } else if hysteresisFraction > 0.20 && limitCycleReversals >= 2 {
            issue = .hysteresis
        } else if rateLimitFraction > 0.12 {
            issue = .actuatorRateLimit
        } else if saturationFraction > 0.12 {
            issue = .outputSaturation
        } else {
            issue = .noDominantNonlinearity
        }

        var notes: [String] = []
        if margins.robustness == .unstable {
            notes.append("The continuous linear controller/plant estimate is already unstable or beyond the estimated stability boundary. Saturation may limit amplitude, but it is not the initiating explanation.")
        } else {
            notes.append("The continuous linear controller/plant estimate remains \(margins.robustness.displayName.lowercased()); nonlinear and sampled-data effects can therefore be examined separately rather than blamed on linear instability by default.")
        }
        if let samplesPerTau {
            notes.append(String(format: "PID executes %.1f times per identified plant time constant.", samplesPerTau))
        }
        if let samplesPerCycle {
            notes.append(String(format: "PID executes %.1f times per estimated gain-crossover cycle.", samplesPerCycle))
        }
        if slowSampling {
            notes.append("The PID task period is coarse relative to the identified plant dynamics. Discrete updates can add effective delay and phase loss even when the continuous-time tuning calculation looks acceptable.")
        }
        if saturationFraction > 0.01 {
            notes.append(String(format: "Controller demand was output-limited for %.0f%% of sampled execution points.", saturationFraction * 100))
        }
        if substantialWindup {
            notes.append("Integral state continued accumulating while the output was saturated. Stored correction can keep the actuator driven after the process error reverses; this is integral windup, not proof of a fundamentally unstable linear loop.")
        } else if settings.antiWindupMode != .none && saturationFraction > 0.01 {
            notes.append("Anti-windup is enabled, so saturation is present without unrestricted integral accumulation. This helps separate output authority limits from integral windup.")
        }
        if stuckFraction > 0.01 {
            notes.append(String(format: "Actuator remained motionless across %.0f%% of sampled points while controller demand continued changing; %d breakaway event(s) followed accumulated command displacement.", stuckFraction * 100, breakawayCount))
        }
        if backlashFraction > 0.01 { notes.append(String(format: "Direction reversals consumed mechanical lost motion across %.0f%% of sampled points, a backlash signature.", backlashFraction * 100)) }
        if deadbandFraction > 0.01 { notes.append(String(format: "Controller changes fell inside the actuator deadband across %.0f%% of sampled points, so command movement did not produce stem movement.", deadbandFraction * 100)) }
        if hysteresisFraction > 0.01 { notes.append(String(format: "Direction-dependent actuator offset was active across %.0f%% of sampled points; %d error reversals indicate path-dependent hysteresis can sustain a limit cycle.", hysteresisFraction * 100, limitCycleReversals)) }
        if rateLimitFraction > 0.01 {
            notes.append(String(format: "The actuator could not follow the controller output at %.0f%% of sampled points because of its configured slew-rate limit.", rateLimitFraction * 100))
        }

        let summary: String
        switch issue {
        case .linearInstability:
            summary = "Linear stability is the primary concern before nonlinear limits are considered."
        case .samplingTooSlow:
            summary = "The continuous loop may be stable, but the PLC PID task period is too coarse for the identified plant dynamics."
        case .integralWindup:
            summary = "The linear loop is not the main problem; saturation with unrestricted integral accumulation is producing windup."
        case .outputSaturation:
            summary = "The linear loop is not the main problem; demanded control effort exceeds the configured output range."
        case .actuatorRateLimit:
            summary = "The controller output is feasible, but the actuator cannot move fast enough to follow it."
        case .stiction:
            summary = "The linear loop is stable, but the actuator repeatedly sticks, stores controller correction, then breaks free and jumps, creating a stiction-driven limit-cycle signature."
        case .deadband:
            summary = "Small controller movements are being swallowed by actuator deadband before physical motion begins."
        case .backlash:
            summary = "Direction reversals contain lost motion before the actuator responds, consistent with mechanical backlash."
        case .hysteresis:
            summary = "The actuator follows different command paths depending on direction, producing a hysteresis-driven cycling signature."
        case .noDominantNonlinearity:
            summary = "No dominant saturation, windup, rate-limit, or sampling problem was identified in this scenario."
        case .indeterminate:
            summary = "Sampled-data diagnosis is indeterminate."
        }

        return .init(
            dominantIssue: issue,
            linearMargins: margins,
            taskPeriodMilliseconds: settings.taskPeriodMilliseconds,
            samplesPerDominantTimeConstant: samplesPerTau,
            samplesPerGainCrossoverCycle: samplesPerCycle,
            saturationFraction: saturationFraction,
            rateLimitFraction: rateLimitFraction,
            stuckFraction: stuckFraction,
            breakawayCount: breakawayCount,
            backlashFraction: backlashFraction,
            deadbandFraction: deadbandFraction,
            hysteresisFraction: hysteresisFraction,
            limitCycleReversals: limitCycleReversals,
            peakIntegralMagnitude: peakIntegral,
            peakProcessValue: peakPV,
            finalAbsoluteError: finalError,
            interpretations: notes,
            summary: summary
        )
    }

    private static func issueRank(_ issue: SampledLoopIssue) -> Int {
        switch issue {
        case .noDominantNonlinearity: return 0
        case .indeterminate: return 1
        case .outputSaturation: return 2
        case .actuatorRateLimit: return 3
        case .deadband, .hysteresis: return 4
        case .backlash: return 5
        case .stiction: return 6
        case .integralWindup: return 7
        case .samplingTooSlow: return 8
        case .linearInstability: return 9
        }
    }

    private static func advancePlant(_ plant: IdentifiedPlantFit, input: Double, dt: Double, processValue: inout Double, velocity: inout Double) {
        switch plant.modelKind {
        case .firstOrderPlusDeadTime:
            let tau = max((plant.timeConstantMilliseconds ?? 1) / 1000.0, 1e-6)
            processValue += dt * ((plant.processGain * input - processValue) / tau)
        case .underdampedSecondOrder:
            let wn = max(plant.naturalFrequencyRadiansPerSecond ?? 1, 1e-6)
            let zeta = max(plant.dampingRatio ?? 0.7, 1e-6)
            let acceleration = plant.processGain * wn * wn * input - 2 * zeta * wn * velocity - wn * wn * processValue
            velocity += acceleration * dt
            processValue += velocity * dt
        }
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
