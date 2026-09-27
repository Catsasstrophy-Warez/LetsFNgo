import Foundation

// MARK: - Advanced electrical troubleshooting physics

public enum TroubleshootingDifficulty: String, Codable, CaseIterable, Sendable {
    case apprentice, technician, seniorTechnician, controlsTechnician, commissioningTechnician, expertNightmare
}

public enum AdvancedElectricalFaultKind: String, Codable, CaseIterable, Sendable {
    case blownFuse, downstreamShort, looseHighResistanceTerminal, missingNeutral, missingDCCommon
    case floatingCommon, groundLoop, shieldGroundFault, controlTransformerFailure, powerSupplySag
    case phaseLoss, phaseRotationReversed, phaseVoltageImbalance, contactorPoleFailure, motorWindingFault, singlePhasing
    case overloadTrip, incorrectOverloadSetting, outputChannelFailure, inputChannelFailure
    case safetyChannelOpen, safetyDiscrepancy, edmFeedbackFailure, stoActive, resetCircuitFailure
    case vibrationIntermittentOpen, positionDependentCableOpen, heatSensitiveFailure, moistureLeakage
    case noisySensor, intermittentNetworkDrop, marginal24VSupply, contactFailsUnderLoad
    case wrongFuseReplacement, jumperLeftInstalled, swappedWires, wrongTerminalLanding, wrongSensorPolarity
    case wrongTransmitterRange, wrongSensorWireCount, defaultedVFDParameters, wrongPLCChannelAssignment
    case undocumentedTemporaryRepair, drawingFieldMismatch, corrodedConnection, failedSolenoidCoil
    case weldedRelay, stuckContactor, mechanicalOverload
}

public enum ElectricalEvidenceType: String, Codable, CaseIterable, Sendable {
    case visualInspection, voltage, voltageDrop, resistance, continuity, clampCurrent, phaseVoltage
    case phaseCurrent, loopCurrent, frequency, capacitance, diode, loZVoltage, plcStatus, driveStatus
    case historian, flightRecorder, drawingReview, operatorInterview, thermalClue, mechanicalCheck
}

public struct ElectricalSignature: Codable, Equatable, Sendable {
    public var deviceTag: String
    public var nominalVoltage: Double
    public var nominalCurrent: Double
    public var nominalResistance: Double?
    public var frequencyHz: Double?
    public var phases: Int
    public var tolerancePercent: Double
    public init(deviceTag: String, nominalVoltage: Double, nominalCurrent: Double, nominalResistance: Double? = nil, frequencyHz: Double? = nil, phases: Int = 1, tolerancePercent: Double = 10) {
        self.deviceTag = deviceTag; self.nominalVoltage = nominalVoltage; self.nominalCurrent = nominalCurrent
        self.nominalResistance = nominalResistance; self.frequencyHz = frequencyHz; self.phases = phases; self.tolerancePercent = tolerancePercent
    }
}

public struct ElectricalFaultInstance: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var kind: AdvancedElectricalFaultKind
    public var deviceTag: String
    public var location: String
    public var severity: Double
    public var intermittentDutyCycle: Double?
    public var triggerTemperatureC: Double?
    public var triggerPosition: Double?
    public var addedResistanceOhms: Double?
    public var hiddenFromLearner: Bool
    public var drawingDisagreesWithField: Bool
    public init(id: String = UUID().uuidString, kind: AdvancedElectricalFaultKind, deviceTag: String, location: String, severity: Double = 1, intermittentDutyCycle: Double? = nil, triggerTemperatureC: Double? = nil, triggerPosition: Double? = nil, addedResistanceOhms: Double? = nil, hiddenFromLearner: Bool = true, drawingDisagreesWithField: Bool = false) {
        self.id=id; self.kind=kind; self.deviceTag=deviceTag; self.location=location; self.severity=severity
        self.intermittentDutyCycle=intermittentDutyCycle; self.triggerTemperatureC=triggerTemperatureC
        self.triggerPosition=triggerPosition; self.addedResistanceOhms=addedResistanceOhms
        self.hiddenFromLearner=hiddenFromLearner; self.drawingDisagreesWithField=drawingDisagreesWithField
    }
}

public struct AdvancedMeterConfiguration: Codable, Equatable, Sendable {
    public enum Function: String, Codable, CaseIterable, Sendable {
        case voltsDC, voltsAC, loZAC, loZDC, ohms, continuity, milliampsDC, clampAmpsAC, clampAmpsDC
        case diode, capacitance, frequency, phaseRotation
    }
    public enum LeadJack: String, Codable, CaseIterable, Sendable { case common, voltsOhms, milliamp, amp }
    public var function: Function
    public var redLeadJack: LeadJack
    public var blackLeadJack: LeadJack
    public var autorange: Bool
    public var manualRange: Double?
    public var inputImpedanceMegohms: Double
    public init(function: Function = .voltsDC, redLeadJack: LeadJack = .voltsOhms, blackLeadJack: LeadJack = .common, autorange: Bool = true, manualRange: Double? = nil, inputImpedanceMegohms: Double = 10) {
        self.function=function; self.redLeadJack=redLeadJack; self.blackLeadJack=blackLeadJack
        self.autorange=autorange; self.manualRange=manualRange; self.inputImpedanceMegohms=inputImpedanceMegohms
    }
}

public struct AdvancedElectricalNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var dcPotential: Double?
    public var acPotentialRMS: Double?
    public var sourceImpedanceOhms: Double
    public var energized: Bool
    public var categoryContext: String
    public init(id: String, label: String, dcPotential: Double? = nil, acPotentialRMS: Double? = nil, sourceImpedanceOhms: Double = 0.05, energized: Bool = false, categoryContext: String = "training") {
        self.id=id; self.label=label; self.dcPotential=dcPotential; self.acPotentialRMS=acPotentialRMS
        self.sourceImpedanceOhms=sourceImpedanceOhms; self.energized=energized; self.categoryContext=categoryContext
    }
}

public struct AdvancedMeterResult: Codable, Equatable, Sendable {
    public var display: String
    public var value: Double?
    public var unit: String
    public var interpretation: String
    public var proceduralWarning: String?
    public var evidenceType: ElectricalEvidenceType
}

public enum AdvancedMeterPhysics {
    public static func voltage(red: AdvancedElectricalNode, black: AdvancedElectricalNode, configuration: AdvancedMeterConfiguration, loadCurrentAmps: Double = 0, ghostCouplingVolts: Double = 0) -> AdvancedMeterResult {
        let dc = (red.dcPotential ?? 0) - (black.dcPotential ?? 0)
        let ac = abs((red.acPotentialRMS ?? 0) - (black.acPotentialRMS ?? 0))
        let isLoZ = configuration.function == .loZAC || configuration.function == .loZDC
        let base = (configuration.function == .voltsAC || configuration.function == .loZAC) ? ac : dc
        let sourceR = red.sourceImpedanceOhms + black.sourceImpedanceOhms
        let drop = loadCurrentAmps * sourceR
        let ghost = isLoZ ? ghostCouplingVolts * 0.03 : ghostCouplingVolts
        let measured = max(0, abs(base) - abs(drop)) + ghost
        let warning: String?
        if configuration.redLeadJack == .milliamp || configuration.redLeadJack == .amp {
            warning = "Meter lead is in a current jack while voltage is selected. The simulator blocks the hazardous configuration."
        } else { warning = nil }
        return .init(display: String(format: "%.2f", measured), value: measured, unit: configuration.function == .voltsAC || configuration.function == .loZAC ? "V AC" : "V DC", interpretation: isLoZ && ghostCouplingVolts > 1 ? "Low-impedance mode collapses most modeled capacitive/ghost voltage." : "Potential difference measured at the selected test points.", proceduralWarning: warning, evidenceType: isLoZ ? .loZVoltage : .voltage)
    }

    public static func voltageDrop(sourceVolts: Double, loadCurrentAmps: Double, connectionResistanceOhms: Double) -> AdvancedMeterResult {
        let drop = abs(loadCurrentAmps * connectionResistanceOhms)
        return .init(display: String(format: "%.2f", drop), value: drop, unit: "V", interpretation: drop > sourceVolts * 0.10 ? "Excessive modeled voltage drop under load. A high-resistance connection is strongly indicated." : "Modeled connection drop is within the training threshold.", proceduralWarning: nil, evidenceType: .voltageDrop)
    }

    public static func threePhase(lineToLineVolts: [Double], phaseCurrents: [Double]) -> (voltageImbalancePercent: Double, currentImbalancePercent: Double, phaseLoss: Bool) {
        func imbalance(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let avg = values.reduce(0,+) / Double(values.count)
            guard avg > 0 else { return 100 }
            return values.map { abs($0-avg) }.max()! / avg * 100
        }
        return (imbalance(lineToLineVolts), imbalance(phaseCurrents), lineToLineVolts.contains(where: { $0 < 0.5 * (lineToLineVolts.max() ?? 0) }) || phaseCurrents.contains(where: { $0 < 0.1 * (phaseCurrents.max() ?? 0) }))
    }
}

// MARK: - Diagnostic reasoning

public enum HypothesisState: String, Codable, Sendable { case possible, supported, unlikely, eliminated, proven }

public struct DiagnosticHypothesis: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var state: HypothesisState
    public var supportingEvidenceIDs: [String]
    public var contradictingEvidenceIDs: [String]
    public init(id: String = UUID().uuidString, title: String, state: HypothesisState = .possible, supportingEvidenceIDs: [String] = [], contradictingEvidenceIDs: [String] = []) {
        self.id=id; self.title=title; self.state=state; self.supportingEvidenceIDs=supportingEvidenceIDs; self.contradictingEvidenceIDs=contradictingEvidenceIDs
    }
}

public struct DiagnosticEvidence: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var type: ElectricalEvidenceType
    public var testPoint: String
    public var result: String
    public var elapsedSeconds: Double
    public var discriminatingPower: Double
    public init(id: String = UUID().uuidString, type: ElectricalEvidenceType, testPoint: String, result: String, elapsedSeconds: Double, discriminatingPower: Double) {
        self.id=id; self.type=type; self.testPoint=testPoint; self.result=result; self.elapsedSeconds=elapsedSeconds; self.discriminatingPower=discriminatingPower
    }
}

public struct DiagnosticReasoningSession: Codable, Equatable, Sendable {
    public var symptom: String
    public var hypotheses: [DiagnosticHypothesis]
    public var evidence: [DiagnosticEvidence]
    public var elapsedSeconds: Double
    public var randomTests: Int
    public var unsafeAttempts: Int
    public var rootCauseProven: Bool
    public var repairVerified: Bool
    public var regressionVerified: Bool
    public init(symptom: String, hypotheses: [String]) {
        self.symptom=symptom; self.hypotheses=hypotheses.map { .init(title:$0) }; evidence=[]; elapsedSeconds=0; randomTests=0; unsafeAttempts=0; rootCauseProven=false; repairVerified=false; regressionVerified=false
    }
    public mutating func record(_ item: DiagnosticEvidence, supports: [String] = [], eliminates: [String] = [], wasRandom: Bool = false) {
        evidence.append(item); elapsedSeconds += item.elapsedSeconds; if wasRandom { randomTests += 1 }
        for i in hypotheses.indices {
            if eliminates.contains(hypotheses[i].title) { hypotheses[i].state = .eliminated; hypotheses[i].contradictingEvidenceIDs.append(item.id) }
            if supports.contains(hypotheses[i].title) && hypotheses[i].state != .eliminated { hypotheses[i].state = .supported; hypotheses[i].supportingEvidenceIDs.append(item.id) }
        }
    }
    public mutating func prove(_ title: String) {
        for i in hypotheses.indices { hypotheses[i].state = hypotheses[i].title == title ? .proven : (hypotheses[i].state == .possible ? .unlikely : hypotheses[i].state) }
        rootCauseProven = true
    }
    public var score: Double {
        var value = 100.0
        value -= min(30, Double(randomTests) * 3)
        value -= min(30, Double(unsafeAttempts) * 10)
        value -= min(20, elapsedSeconds / 180)
        if !rootCauseProven { value -= 20 }
        if !repairVerified { value -= 10 }
        if !regressionVerified { value -= 10 }
        let evidenceBonus = min(10, evidence.reduce(0) { $0 + $1.discriminatingPower })
        return max(0, min(100, value + evidenceBonus))
    }
}

// MARK: - Procedural fault generation

public struct ElectricalPathElement: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case source, protection, terminal, conductor, contact, ioChannel, interposingDevice, load, common, shield, ground }
    public let id: String
    public var kind: Kind
    public var tag: String
    public var nominalVoltage: Double
    public init(id: String, kind: Kind, tag: String, nominalVoltage: Double) { self.id=id; self.kind=kind; self.tag=tag; self.nominalVoltage=nominalVoltage }
}

public struct GeneratedElectricalTroubleshootingScenario: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var seed: UInt64
    public var difficulty: TroubleshootingDifficulty
    public var symptom: String
    public var path: [ElectricalPathElement]
    public var faults: [ElectricalFaultInstance]
    public var misleadingClues: [String]
    public var suggestedTestPoints: [String]
    public var expectedProof: [String]
}

public enum ProceduralElectricalFaultGenerator {
    public static func generate(seed: UInt64, difficulty: TroubleshootingDifficulty, path: [ElectricalPathElement]) -> GeneratedElectricalTroubleshootingScenario {
        var rng = SeededElectricalRNG(state: seed == 0 ? 1 : seed)
        let faultCount: Int
        switch difficulty {
        case .apprentice, .technician: faultCount = 1
        case .seniorTechnician, .controlsTechnician, .commissioningTechnician: faultCount = rng.int(2) + 1
        case .expertNightmare: faultCount = 2 + rng.int(2)
        }
        let eligible = path.filter { $0.kind != .source }
        var faults:[ElectricalFaultInstance] = []
        let kinds = AdvancedElectricalFaultKind.allCases
        for n in 0..<faultCount where !eligible.isEmpty {
            let element = eligible[rng.int(eligible.count)]
            let kind = kinds[(rng.int(kinds.count) + n) % kinds.count]
            faults.append(.init(id:"F\(seed)-\(n)", kind:kind, deviceTag:element.tag, location:element.id, severity:0.55 + rng.double()*0.45, intermittentDutyCycle: difficulty == .expertNightmare ? 0.25 + rng.double()*0.5 : nil, addedResistanceOhms: kind == .looseHighResistanceTerminal || kind == .corrodedConnection ? 1 + rng.double()*12 : nil, drawingDisagreesWithField: kind == .drawingFieldMismatch || kind == .wrongTerminalLanding))
        }
        let misleading = difficulty == .expertNightmare || difficulty == .seniorTechnician ? ["Operator says reset fixed it yesterday.", "Previous shift suspected the PLC, but did not prove it."] : []
        let hints = difficulty == .apprentice ? path.prefix(3).map(\.tag) : []
        return .init(id:"GEN-\(seed)-\(difficulty.rawValue)", seed:seed, difficulty:difficulty, symptom:symptom(for:faults.first?.kind), path:path, faults:faults, misleadingClues:misleading, suggestedTestPoints:hints, expectedProof:["Identify the working/not-working boundary.", "Prove the root cause with a discriminating measurement.", "Repair the cause, not only the symptom.", "Retest the complete function and watch for regression."])
    }
    private static func symptom(for kind: AdvancedElectricalFaultKind?) -> String {
        guard let kind else { return "Machine function unavailable." }
        switch kind {
        case .phaseLoss, .singlePhasing, .motorWindingFault, .mechanicalOverload, .overloadTrip: return "Motor will not run normally or trips under load."
        case .wrongTransmitterRange, .groundLoop, .shieldGroundFault, .noisySensor: return "Process value is unstable or disagrees with the field."
        case .safetyChannelOpen, .safetyDiscrepancy, .edmFeedbackFailure, .stoActive, .resetCircuitFailure: return "Machine will not achieve safety ready."
        case .intermittentNetworkDrop, .vibrationIntermittentOpen, .positionDependentCableOpen, .heatSensitiveFailure: return "Machine stops intermittently and often recovers."
        default: return "Command is present, but the expected field device does not respond."
        }
    }
}

public struct SeededElectricalRNG: Sendable {
    public var state: UInt64
    public mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    public mutating func int(_ upper: Int) -> Int { guard upper > 0 else { return 0 }; return Int(next() % UInt64(upper)) }
    public mutating func double() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Authored practicum catalog

public struct ElectricalTroubleshootingPracticum: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var operatorCall: String
    public var difficulty: TroubleshootingDifficulty
    public var initialHypotheses: [String]
    public var faults: [ElectricalFaultInstance]
    public var availableEvidence: [ElectricalEvidenceType]
    public var drawingRevision: String
    public var fieldRevision: String
    public var successCriteria: [String]
}

public enum ElectricalTroubleshootingPracticumCatalog {
    public static let motorNoStart = ElectricalTroubleshootingPracticum(
        id:"ETP-MOTOR-001", title:"Conveyor 3 Will Not Start",
        operatorCall:"Conveyor 3 stopped twice this morning. Reset brought it back the first time. Now it will not run.",
        difficulty:.technician,
        initialHypotheses:["Power","Safety","PLC logic","Output module","Field wiring","Contactor","Overload","Motor","Mechanical load"],
        faults:[.init(kind:.looseHighResistanceTerminal, deviceTag:"M103", location:"TB3-17", severity:0.8, addedResistanceOhms:7.5)],
        availableEvidence:[.visualInspection,.voltage,.voltageDrop,.clampCurrent,.plcStatus,.driveStatus,.operatorInterview],
        drawingRevision:"AS-BUILT Rev C", fieldRevision:"Field modified after Rev C",
        successCriteria:["Use loaded voltage-drop testing to isolate TB3-17.", "Do not condemn the PLC from an energized output LED alone.", "Repair and torque/verify the modeled connection.", "Run a regression cycle under load."]
    )
    public static let analogGhost = ElectricalTroubleshootingPracticum(
        id:"ETP-ANALOG-002", title:"Pressure That Lies",
        operatorCall:"Pressure looks normal at the gauge, but the PLC value wanders whenever the large drive runs.",
        difficulty:.controlsTechnician,
        initialHypotheses:["Transmitter","Analog module","Loop power","Shielding","Ground loop","Scaling","Process"],
        faults:[.init(kind:.shieldGroundFault, deviceTag:"PT1802", location:"JB18-SHIELD", severity:0.7)],
        availableEvidence:[.loopCurrent,.voltage,.loZVoltage,.plcStatus,.historian,.drawingReview,.visualInspection],
        drawingRevision:"IFC Rev F", fieldRevision:"Shield bonded at both ends",
        successCriteria:["Correlate disturbance with drive operation.", "Prove field loop versus PLC scaling.", "Identify improper shield/reference condition.", "Verify stable loop after correction."]
    )
    public static let threePhase = ElectricalTroubleshootingPracticum(
        id:"ETP-3PH-003", title:"The Motor That Hums",
        operatorCall:"Pump sounds wrong, current is high, and it trips after a short run.",
        difficulty:.seniorTechnician,
        initialHypotheses:["Phase loss","Voltage imbalance","Mechanical load","Motor winding","Contactor pole","Overload setting","VFD"],
        faults:[.init(kind:.contactorPoleFailure, deviceTag:"MCC-K207", location:"L2/T2 pole", severity:1)],
        availableEvidence:[.phaseVoltage,.phaseCurrent,.clampCurrent,.visualInspection,.thermalClue,.mechanicalCheck],
        drawingRevision:"AS-BUILT Rev B", fieldRevision:"Matches drawing",
        successCriteria:["Compare all three phase-to-phase voltages and phase currents.", "Separate supply, contactor, motor and mechanical possibilities.", "Prove the failed pole.", "Verify balanced current after repair."]
    )
    public static let safety = ElectricalTroubleshootingPracticum(
        id:"ETP-SAFE-004", title:"Safe But Not Ready",
        operatorCall:"All guards look closed, but the cell will not reset after a normal stop.",
        difficulty:.controlsTechnician,
        initialHypotheses:["E-stop channel","Guard channel","Safety PLC","EDM feedback","STO","Reset circuit","Contactor feedback"],
        faults:[.init(kind:.edmFeedbackFailure, deviceTag:"K1-AUX", location:"Safety EDM return", severity:1)],
        availableEvidence:[.visualInspection,.voltage,.plcStatus,.drawingReview,.flightRecorder],
        drawingRevision:"AS-BUILT Rev D", fieldRevision:"Matches drawing",
        successCriteria:["Distinguish safe input state from achieved output/EDM state.", "Trace both safety channels and feedback.", "Do not bypass the modeled safety function.", "Prove reset and repeated safe stopping."]
    )
    public static let previousTech = ElectricalTroubleshootingPracticum(
        id:"ETP-COMM-005", title:"It Worked Before the Shutdown",
        operatorCall:"The skid was rewired during shutdown. The PLC program is unchanged, but the valve command now drives the wrong device.",
        difficulty:.commissioningTechnician,
        initialHypotheses:["PLC channel assignment","Swapped wires","Terminal landing","Drawing revision","Output module","Valve"],
        faults:[.init(kind:.swappedWires, deviceTag:"XV402/XV403", location:"TB4-22/TB4-23", severity:1, drawingDisagreesWithField:true)],
        availableEvidence:[.drawingReview,.visualInspection,.voltage,.plcStatus,.operatorInterview],
        drawingRevision:"IFC Rev G", fieldRevision:"Unrecorded shutdown redline",
        successCriteria:["Compare field point-to-point wiring with the issued drawing.", "Identify both swapped conductors.", "Correct the field wiring and create a redline discrepancy.", "Function-test both valves."]
    )
    public static let nightmare = ElectricalTroubleshootingPracticum(
        id:"ETP-X-006", title:"Nightmare: Three Symptoms, Two Faults",
        operatorCall:"Line stopped twice, the prox flickered once, and maintenance thinks the PLC output card is dying.",
        difficulty:.expertNightmare,
        initialHypotheses:["24 V supply","PLC output","Loose terminal","Network","Prox sensor","Contactor","Mechanical jam","Unrelated symptom"],
        faults:[
            .init(kind:.vibrationIntermittentOpen, deviceTag:"PE311", location:"drag-chain conductor 311", severity:0.7, intermittentDutyCycle:0.35),
            .init(kind:.corrodedConnection, deviceTag:"K311", location:"TB7-09", severity:0.65, addedResistanceOhms:5.2)
        ],
        availableEvidence:ElectricalEvidenceType.allCases,
        drawingRevision:"AS-BUILT Rev H", fieldRevision:"One undocumented temporary repair",
        successCriteria:["Do not assume all symptoms share one cause.", "Use Flight Recorder to separate input dropout from output failure.", "Find the intermittent conductor and loaded voltage drop.", "Permanently repair both faults and monitor regression."]
    )
    public static let all:[ElectricalTroubleshootingPracticum] = [motorNoStart,analogGhost,threePhase,safety,previousTech,nightmare]
}
