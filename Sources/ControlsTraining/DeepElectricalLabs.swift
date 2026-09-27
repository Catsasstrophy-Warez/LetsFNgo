import Foundation

// MARK: - Interactive schematic construction

public enum SchematicComponentKind: String, Codable, CaseIterable, Sendable {
    case powerSource, fuse, disconnect, pushbuttonNO, pushbuttonNC, relayCoil, relayContactNO, relayContactNC
    case contactorCoil, overloadNC, motor, sensorPNP, sensorNPN, terminal, plcInput, plcOutput, analogTransmitter, analogInput
}

public struct SchematicPort: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var label: String
    public var isSource: Bool
    public init(id: String, label: String, isSource: Bool) { self.id = id; self.label = label; self.isSource = isSource }
}

public struct SchematicComponent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: SchematicComponentKind
    public var tag: String
    public var label: String
    public var ports: [SchematicPort]
    public var energized: Bool
    public init(id: String, kind: SchematicComponentKind, tag: String, label: String, ports: [SchematicPort], energized: Bool = false) {
        self.id = id; self.kind = kind; self.tag = tag; self.label = label; self.ports = ports; self.energized = energized
    }
}

public struct SchematicWire: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var fromComponentID: String
    public var fromPortID: String
    public var toComponentID: String
    public var toPortID: String
    public var wireNumber: String
    public var conductorState: WireState
    public init(id: String, fromComponentID: String, fromPortID: String, toComponentID: String, toPortID: String, wireNumber: String, conductorState: WireState = .deenergized) {
        self.id = id; self.fromComponentID = fromComponentID; self.fromPortID = fromPortID; self.toComponentID = toComponentID; self.toPortID = toPortID; self.wireNumber = wireNumber; self.conductorState = conductorState
    }
}

public enum WireState: String, Codable, CaseIterable, Sendable { case energized, deenergized, open, shorted, floating, forced }

public struct SchematicBuildChallenge: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var objective: String
    public var requiredKinds: [SchematicComponentKind]
    public var requiredTags: [String]
    public var successRules: [String]
    public var faultVariants: [String]
}

public struct SchematicWorkbench: Codable, Equatable, Sendable {
    public var components: [SchematicComponent] = []
    public var wires: [SchematicWire] = []
    public init() {}
    public mutating func add(_ component: SchematicComponent) { if !components.contains(where: { $0.id == component.id }) { components.append(component) } }
    public mutating func connect(_ wire: SchematicWire) { if !wires.contains(where: { $0.id == wire.id }) { wires.append(wire) } }
    public mutating func removeComponent(id: String) { components.removeAll { $0.id == id }; wires.removeAll { $0.fromComponentID == id || $0.toComponentID == id } }
    public func validate(_ challenge: SchematicBuildChallenge) -> [String] {
        var issues: [String] = []
        for kind in challenge.requiredKinds where !components.contains(where: { $0.kind == kind }) { issues.append("Missing required component: \(kind.rawValue)") }
        for tag in challenge.requiredTags where !components.contains(where: { $0.tag == tag }) { issues.append("Missing required tag: \(tag)") }
        if wires.isEmpty { issues.append("No conductors have been connected.") }
        let duplicateNumbers = Dictionary(grouping: wires, by: \.wireNumber).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !duplicateNumbers.isEmpty { issues.append("Duplicate wire numbers detected: \(duplicateNumbers.keys.sorted().joined(separator: ", "))") }
        return issues
    }
}

// MARK: - Virtual meter and live conductor state

public enum MeterMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case dcVolts = "V DC", acVolts = "V AC", ohms = "Ω", continuity = "Continuity", dcMilliamps = "mA DC"
    public var id: String { rawValue }
}
public enum ProbeReference: String, Codable, CaseIterable, Sendable { case dcCommon, neutral, ground, phase, arbitraryNode }
public struct ElectricalNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var dcVoltage: Double?
    public var acVoltage: Double?
    public var connectedGroup: String
    public var currentMilliamps: Double?
    public var safeToProbe: Bool
}
public struct MeterReading: Codable, Equatable, Sendable {
    public var display: String
    public var numericValue: Double?
    public var unit: String
    public var interpretation: String
    public var safetyWarning: String?
}
public enum VirtualMeter {
    public static func measure(mode: MeterMode, red: ElectricalNode, black: ElectricalNode) -> MeterReading {
        if !red.safeToProbe || !black.safeToProbe {
            return .init(display: "LOCKOUT", numericValue: nil, unit: "", interpretation: "This training point is intentionally blocked until the scenario establishes an electrically safe measurement condition.", safetyWarning: "Unsafe measurement configuration")
        }
        switch mode {
        case .dcVolts:
            guard let r = red.dcVoltage, let b = black.dcVoltage else { return unavailable("DC voltage unavailable at one probe point") }
            let v = r - b; return reading(v, unit: "V DC", interpretation: abs(v) < 1 ? "Little potential difference exists between these points." : "A DC potential difference is present.")
        case .acVolts:
            guard let r = red.acVoltage, let b = black.acVoltage else { return unavailable("AC voltage unavailable at one probe point") }
            let v = abs(r - b); return reading(v, unit: "V AC", interpretation: v < 1 ? "Little AC potential difference exists." : "An AC potential difference is present.")
        case .ohms:
            if (red.dcVoltage ?? 0) != 0 || (black.dcVoltage ?? 0) != 0 || (red.acVoltage ?? 0) != 0 || (black.acVoltage ?? 0) != 0 {
                return .init(display: "⚠︎", numericValue: nil, unit: "Ω", interpretation: "Resistance mode must not be used on an energized teaching circuit.", safetyWarning: "De-energize and verify before resistance testing")
            }
            let same = red.connectedGroup == black.connectedGroup
            return .init(display: same ? "0.3" : "OL", numericValue: same ? 0.3 : nil, unit: "Ω", interpretation: same ? "A continuous low-resistance path exists." : "The path is open or isolated.", safetyWarning: nil)
        case .continuity:
            if (red.dcVoltage ?? 0) != 0 || (black.dcVoltage ?? 0) != 0 { return .init(display: "⚠︎", numericValue: nil, unit: "", interpretation: "Continuity mode requested on an energized circuit.", safetyWarning: "De-energize first") }
            let same = red.connectedGroup == black.connectedGroup
            return .init(display: same ? "BEEP" : "OPEN", numericValue: same ? 1 : 0, unit: "", interpretation: same ? "Continuity proven between the probes." : "No continuity between the probes.", safetyWarning: nil)
        case .dcMilliamps:
            guard let ma = red.currentMilliamps else { return unavailable("Current measurement requires the meter to be inserted in the modeled loop") }
            return reading(ma, unit: "mA DC", interpretation: "Loop current at the red probe insertion point.")
        }
    }
    private static func reading(_ value: Double, unit: String, interpretation: String) -> MeterReading { .init(display: String(format: "%.2f", value), numericValue: value, unit: unit, interpretation: interpretation, safetyWarning: nil) }
    private static func unavailable(_ reason: String) -> MeterReading { .init(display: "----", numericValue: nil, unit: "", interpretation: reason, safetyWarning: nil) }
}

// MARK: - Panel building

public enum PanelPartKind: String, Codable, CaseIterable, Sendable { case enclosure, disconnect, breaker, fuseHolder, powerSupply, terminalBlock, groundBar, plcRack, managedSwitch, relay, contactor, overload, vfd, wireDuct, dinRail }
public struct PanelPart: Identifiable, Codable, Equatable, Sendable { public let id: String; public var kind: PanelPartKind; public var tag: String; public var x: Int; public var y: Int; public var width: Int; public var height: Int; public var heatWatts: Double }
public struct PanelBuildChallenge: Identifiable, Codable, Equatable, Sendable { public let id: String; public var title: String; public var requiredParts: [PanelPartKind]; public var requirements: [String]; public var maxHeatWatts: Double }
public enum PanelValidator {
    public static func validate(parts: [PanelPart], challenge: PanelBuildChallenge) -> [String] {
        var issues: [String] = []
        for kind in challenge.requiredParts where !parts.contains(where: { $0.kind == kind }) { issues.append("Missing \(kind.rawValue)") }
        if parts.reduce(0, { $0 + $1.heatWatts }) > challenge.maxHeatWatts { issues.append("Modeled panel heat exceeds challenge limit") }
        let tags = parts.map(\.tag).filter { !$0.isEmpty }; if Set(tags).count != tags.count { issues.append("Duplicate device tags") }
        for i in parts.indices { for j in parts.indices where j > i { if overlaps(parts[i], parts[j]) { issues.append("\(parts[i].tag) overlaps \(parts[j].tag)") } } }
        return issues
    }
    private static func overlaps(_ a: PanelPart, _ b: PanelPart) -> Bool { a.x < b.x+b.width && a.x+a.width > b.x && a.y < b.y+b.height && a.y+a.height > b.y }
}

// MARK: - Simulated ControlLogix-style rack wiring

public enum RackModuleKind: String, Codable, CaseIterable, Sendable { case controller, ethernetBridge, digitalInput24VDC, digitalOutput24VDC, analogInput, analogOutput, safetyInput, safetyOutput }
public enum FieldSignalKind: String, Codable, CaseIterable, Sendable { case dryContact, pnp24V, npn24V, sourcedOutput, sinkingOutput, current4to20mA, voltage0to10V, rtd, thermocouple }
public struct RackModule: Identifiable, Codable, Equatable, Sendable { public let id: String; public var slot: Int; public var catalogLabel: String; public var kind: RackModuleKind; public var channelCount: Int }
public struct IOChannelAssignment: Identifiable, Codable, Equatable, Sendable { public let id: String; public var moduleID: String; public var channel: Int; public var signal: FieldSignalKind; public var tag: String; public var fieldDevice: String; public var commonGroup: String }
public struct ControlLogixRack: Codable, Equatable, Sendable {
    public var modules: [RackModule]; public var assignments: [IOChannelAssignment]
    public init(modules: [RackModule] = [], assignments: [IOChannelAssignment] = []) { self.modules = modules; self.assignments = assignments }
    public func validate() -> [String] {
        var issues:[String] = []
        let slots = modules.map(\.slot); if Set(slots).count != slots.count { issues.append("Two modules occupy the same chassis slot") }
        for a in assignments {
            guard let m = modules.first(where: { $0.id == a.moduleID }) else { issues.append("\(a.tag) points to a missing module"); continue }
            if a.channel < 0 || a.channel >= m.channelCount { issues.append("\(a.tag) uses an invalid channel") }
            let compatible: Bool
            switch (m.kind, a.signal) {
            case (.digitalInput24VDC, .dryContact), (.digitalInput24VDC, .pnp24V), (.digitalInput24VDC, .npn24V), (.digitalOutput24VDC, .sourcedOutput), (.digitalOutput24VDC, .sinkingOutput), (.analogInput, .current4to20mA), (.analogInput, .voltage0to10V), (.analogInput, .rtd), (.analogInput, .thermocouple), (.analogOutput, .current4to20mA), (.analogOutput, .voltage0to10V): compatible = true
            default: compatible = false
            }
            if !compatible { issues.append("\(a.tag) signal type is incompatible with slot \(m.slot) module") }
        }
        let channelKeys = assignments.map { "\($0.moduleID):\($0.channel)" }; if Set(channelKeys).count != channelKeys.count { issues.append("Multiple field devices are assigned to one I/O channel") }
        return issues
    }
}

// MARK: - VFD commissioning

public enum VFDParameterKey: String, Codable, CaseIterable, Sendable { case motorVoltage, motorFLA, motorFrequency, motorRPM, accelSeconds, decelSeconds, minHz, maxHz, commandSource, speedReference, stopMode, overloadClass }
public struct VFDParameter: Identifiable, Codable, Equatable, Sendable { public let id: String; public var key: VFDParameterKey; public var value: String; public var expected: String; public var rationale: String }
public struct VFDCommissioningSession: Codable, Equatable, Sendable {
    public var parameters: [VFDParameter]
    public var rotationVerified = false
    public var uncoupledBumpTestComplete = false
    public var loadedRunComplete = false
    public var faultHistoryReviewed = false
    public init(parameters: [VFDParameter]) { self.parameters = parameters }
    public var mismatches: [VFDParameter] { parameters.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != $0.expected.lowercased() } }
    public var isCommissioned: Bool { mismatches.isEmpty && rotationVerified && uncoupledBumpTestComplete && loadedRunComplete && faultHistoryReviewed }
}

// MARK: - Calibration labs

public enum CalibrationInstrumentKind: String, Codable, CaseIterable, Sendable { case pressureTransmitter, flowTransmitter, levelTransmitter, temperatureTransmitter, valvePositioner }
public struct CalibrationPoint: Identifiable, Codable, Equatable, Sendable { public let id: String; public var appliedPercent: Double; public var expectedMilliamps: Double; public var observedMilliamps: Double }
public struct CalibrationResult: Codable, Equatable, Sendable { public var zeroErrorPercent: Double; public var spanErrorPercent: Double; public var maxAbsoluteErrorPercent: Double; public var passed: Bool; public var recommendation: String }
public enum CalibrationAnalyzer {
    public static func analyze(points: [CalibrationPoint], tolerancePercent: Double = 0.5) -> CalibrationResult? {
        guard let zero = points.min(by: {$0.appliedPercent < $1.appliedPercent}), let span = points.max(by: {$0.appliedPercent < $1.appliedPercent}), !points.isEmpty else { return nil }
        func percentError(_ p: CalibrationPoint) -> Double { (p.observedMilliamps - p.expectedMilliamps) / 16.0 * 100.0 }
        let z = percentError(zero), s = percentError(span)
        let maxErr = points.map { abs(percentError($0)) }.max() ?? 0
        let passed = maxErr <= tolerancePercent
        let recommendation: String
        if passed { recommendation = "As-found calibration is within tolerance. Document results and return to service." }
        else if abs(z) > tolerancePercent && abs(s-z) <= tolerancePercent { recommendation = "Predominantly zero offset. Perform zero trim, then repeat the full up/down check." }
        else if abs(s-z) > tolerancePercent { recommendation = "Span/nonlinearity is significant. Perform span adjustment or investigate sensor/process connection before accepting calibration." }
        else { recommendation = "Out of tolerance. Adjust and repeat the complete calibration cycle." }
        return .init(zeroErrorPercent: z, spanErrorPercent: s, maxAbsoluteErrorPercent: maxErr, passed: passed, recommendation: recommendation)
    }
}

// MARK: - Multi-fault electrical hero machines

public enum HeroMachineEvidenceKind: String, Codable, CaseIterable, Sendable { case meter, ioLED, plcTag, driveStatus, networkDiagnostic, hmiAlarm, historianTrend, physicalInspection }
public struct HeroMachineFault: Identifiable, Codable, Equatable, Sendable { public let id:String; public var title:String; public var domain:ElectricalFaultDomain; public var effect:String; public var evidence:[HeroMachineEvidenceKind]; public var repair:String }
public struct ElectricalHeroMachine: Identifiable, Codable, Equatable, Sendable { public let id:String; public var title:String; public var description:String; public var nominalSequence:[String]; public var faults:[HeroMachineFault]; public var capstoneMission:String }
public struct HeroMachineAttempt: Codable, Equatable, Sendable {
    public var machineID:String; public var activeFaultIDs:Set<String>; public var foundFaultIDs:Set<String> = []; public var measurements:Int = 0; public var unnecessaryActions:Int = 0
    public var solved:Bool { !activeFaultIDs.isEmpty && activeFaultIDs.isSubset(of: foundFaultIDs) }
    public var diagnosticEfficiency:Double { let total = max(1, measurements + unnecessaryActions); return Double(foundFaultIDs.count) / Double(total) }
}

// MARK: - Electrical certifications

public enum ElectricalCertificationDomain: String, Codable, CaseIterable, Sendable { case knowledge, schematicBuild, meterUse, panelBuild, ioWiring, driveCommissioning, calibration, troubleshooting, proofOfRepair }
public struct ElectricalCertificationRubric: Codable, Equatable, Sendable { public var domain:ElectricalCertificationDomain; public var weight:Double; public var minimumScore:Double; public var critical:Bool }
public struct ElectricalCertification: Identifiable, Codable, Equatable, Sendable { public let id:String; public var chapter:ElectricalChapter; public var title:String; public var timeLimitMinutes:Int; public var rubrics:[ElectricalCertificationRubric]; public var requiredLabIDs:[String] }
public struct ElectricalCertificationScore: Codable, Equatable, Sendable {
    public var certificationID:String; public var domainScores:[ElectricalCertificationDomain:Double]; public var safetyViolation:Bool
    public func result(for certification:ElectricalCertification) -> ElectricalCertificationResult {
        if safetyViolation { return .init(passed:false, weightedScore:0, failedDomains:[.meterUse], reason:"Critical safety violation") }
        var totalWeight=0.0, weighted=0.0; var failed:[ElectricalCertificationDomain]=[]
        for rubric in certification.rubrics { let score = domainScores[rubric.domain] ?? 0; totalWeight += rubric.weight; weighted += score*rubric.weight; if score < rubric.minimumScore { failed.append(rubric.domain) } }
        let overall = totalWeight > 0 ? weighted/totalWeight : 0
        let criticalFailure = certification.rubrics.contains { $0.critical && (domainScores[$0.domain] ?? 0) < $0.minimumScore }
        return .init(passed: overall >= 80 && !criticalFailure && failed.isEmpty, weightedScore: overall, failedDomains: failed, reason: failed.isEmpty && overall >= 80 ? "Certification standard met" : "Remediation required before retest")
    }
}
public struct ElectricalCertificationResult: Codable, Equatable, Sendable { public var passed:Bool; public var weightedScore:Double; public var failedDomains:[ElectricalCertificationDomain]; public var reason:String }

// MARK: - Authored deep lab catalog

public enum DeepElectricalLabCatalog {
    public static let schematicChallenges:[SchematicBuildChallenge] = [
        .init(id:"seal-in-starter", title:"Three-wire seal-in starter", objective:"Build a STOP/START seal-in circuit with overload protection and a maintained contactor coil.", requiredKinds:[.powerSource,.pushbuttonNC,.pushbuttonNO,.relayContactNO,.contactorCoil,.overloadNC], requiredTags:["STOP","START","M1","OL1"], successRules:["STOP and overload are fail-safe series contacts","M1 auxiliary contact seals around START","Wire numbers are unique"], faultVariants:["Open STOP conductor","Welded auxiliary contact","Overload contact open"]),
        .init(id:"pnp-plc-input", title:"PNP sensor to PLC input", objective:"Construct a complete 24 VDC sourcing sensor circuit into a digital input module.", requiredKinds:[.powerSource,.sensorPNP,.terminal,.plcInput], requiredTags:["PE203","TB12","DI_07"], successRules:["Sensor brown to +24 VDC","blue to DC common","black signal reaches input channel","input common returns correctly"], faultVariants:["Open common","wrong sensor type","signal landed one channel off"]),
        .init(id:"analog-loop", title:"Two-wire 4–20 mA loop", objective:"Build a powered transmitter loop through field terminals into an analog input.", requiredKinds:[.powerSource,.analogTransmitter,.terminal,.analogInput], requiredTags:["PT301","TB30","AI_02"], successRules:["Loop is series connected","polarity is correct","shield treatment matches the scenario"], faultVariants:["Reversed polarity","open terminal","shield bonded at both ends"])
    ]

    public static let panelChallenges:[PanelBuildChallenge] = [
        .init(id:"packaging-panel", title:"Packaging cell main panel", requiredParts:[.enclosure,.disconnect,.breaker,.powerSupply,.groundBar,.plcRack,.managedSwitch,.terminalBlock,.wireDuct,.dinRail], requirements:["Separate noisy power from low-level analog wiring","Provide serviceable wire duct routes","Maintain unique device tags","Keep heat-producing devices spaced"], maxHeatWatts:180),
        .init(id:"drive-panel", title:"Conveyor VFD panel", requiredParts:[.enclosure,.disconnect,.breaker,.vfd,.terminalBlock,.groundBar,.wireDuct,.dinRail], requirements:["Route motor leads away from analog/network","Provide grounding path","Preserve cooling clearances"], maxHeatWatts:260)
    ]

    public static let defaultRack = ControlLogixRack(modules:[
        .init(id:"m0",slot:0,catalogLabel:"1756-L8x style controller",kind:.controller,channelCount:0),
        .init(id:"m1",slot:1,catalogLabel:"EtherNet/IP bridge",kind:.ethernetBridge,channelCount:0),
        .init(id:"m2",slot:2,catalogLabel:"16-point 24 VDC DI",kind:.digitalInput24VDC,channelCount:16),
        .init(id:"m3",slot:3,catalogLabel:"16-point 24 VDC DO",kind:.digitalOutput24VDC,channelCount:16),
        .init(id:"m4",slot:4,catalogLabel:"8-channel analog input",kind:.analogInput,channelCount:8)
    ], assignments:[])

    public static let vfdParameters:[VFDParameter] = [
        .init(id:"v",key:.motorVoltage,value:"",expected:"460",rationale:"Match the motor nameplate voltage."),
        .init(id:"fla",key:.motorFLA,value:"",expected:"3.2",rationale:"Nameplate full-load current supports motor overload protection."),
        .init(id:"hz",key:.motorFrequency,value:"",expected:"60",rationale:"Set base frequency from the nameplate."),
        .init(id:"rpm",key:.motorRPM,value:"",expected:"1765",rationale:"Nameplate RPM helps establish slip/model behavior."),
        .init(id:"acc",key:.accelSeconds,value:"",expected:"3.0",rationale:"Acceleration must match the mechanical load and process."),
        .init(id:"dec",key:.decelSeconds,value:"",expected:"4.0",rationale:"Avoid nuisance overvoltage while meeting stopping needs."),
        .init(id:"min",key:.minHz,value:"",expected:"10",rationale:"Prevent operation below the process-approved minimum speed."),
        .init(id:"max",key:.maxHz,value:"",expected:"60",rationale:"Do not exceed the approved motor/process maximum."),
        .init(id:"cmd",key:.commandSource,value:"",expected:"EtherNet/IP",rationale:"PLC owns run command in this scenario."),
        .init(id:"ref",key:.speedReference,value:"",expected:"EtherNet/IP",rationale:"PLC owns speed reference in this scenario."),
        .init(id:"stop",key:.stopMode,value:"",expected:"Ramp",rationale:"Normal process stops use controlled ramp-down."),
        .init(id:"ol",key:.overloadClass,value:"",expected:"10",rationale:"Match the modeled motor/load protection requirement.")
    ]

    public static let calibrationLabs:[(id:String,title:String,kind:CalibrationInstrumentKind,range:String,points:[CalibrationPoint])] = [
        ("pt-zero-shift","Pressure transmitter zero shift",.pressureTransmitter,"0–150 psi",[
            .init(id:"0",appliedPercent:0,expectedMilliamps:4,observedMilliamps:4.32),.init(id:"25",appliedPercent:25,expectedMilliamps:8,observedMilliamps:8.31),.init(id:"50",appliedPercent:50,expectedMilliamps:12,observedMilliamps:12.33),.init(id:"75",appliedPercent:75,expectedMilliamps:16,observedMilliamps:16.31),.init(id:"100",appliedPercent:100,expectedMilliamps:20,observedMilliamps:20.32)]),
        ("ft-span-error","Flow transmitter span error",.flowTransmitter,"0–500 gpm",[
            .init(id:"0",appliedPercent:0,expectedMilliamps:4,observedMilliamps:4.02),.init(id:"25",appliedPercent:25,expectedMilliamps:8,observedMilliamps:8.18),.init(id:"50",appliedPercent:50,expectedMilliamps:12,observedMilliamps:12.36),.init(id:"75",appliedPercent:75,expectedMilliamps:16,observedMilliamps:16.55),.init(id:"100",appliedPercent:100,expectedMilliamps:20,observedMilliamps:20.74)])
    ]

    public static let heroMachines:[ElectricalHeroMachine] = [
        .init(id:"pack-cell-electrical",title:"Packaging Cell: Dark Conveyor",description:"A discrete packaging cell combining 24 VDC sensors, remote I/O, contactors, VFD conveyor and safety permissives.",nominalSequence:["Product enters PE203","PLC advances state","VFD run command energizes","Conveyor proves speed","Exit sensor completes transfer"],faults:[
            .init(id:"pc-open-pe",title:"Intermittent PE203 signal conductor",domain:.wiring,effect:"Input flickers during vibration",evidence:[.meter,.ioLED,.plcTag,.historianTrend,.physicalInspection],repair:"Reterminate the loose conductor and prove stability through repeated cycles."),
            .init(id:"pc-vfd-source",title:"VFD command source changed to keypad",domain:.motorDrive,effect:"PLC run command is true but drive ignores it",evidence:[.plcTag,.driveStatus,.hmiAlarm],repair:"Restore the approved network command source and verify commanded starts/stops."),
            .init(id:"pc-rio-drop",title:"Remote I/O network dropout",domain:.network,effect:"Several unrelated field signals freeze together",evidence:[.networkDiagnostic,.plcTag,.hmiAlarm,.historianTrend],repair:"Correct the physical/network fault and prove connection stability under production load.")
        ],capstoneMission:"Diagnose two simultaneous faults with the fewest high-information tests, repair both, then prove ten consecutive healthy cycles."),
        .init(id:"pressure-skid-electrical",title:"Pressure Skid: Lying Process",description:"An analog pressure/flow skid with transmitters, remote analog I/O, PID control and a VFD pump.",nominalSequence:["Pressure request accepted","Pump accelerates","PT301 feedback rises","PID settles","Historian records stable response"],faults:[
            .init(id:"ps-loop-open",title:"4–20 mA loop intermittent open",domain:.analog,effect:"Pressure intermittently falls to underrange",evidence:[.meter,.plcTag,.historianTrend,.physicalInspection],repair:"Repair the loop termination and verify current at multiple applied pressures."),
            .init(id:"ps-scale",title:"Analog scaling mismatch",domain:.plcLogic,effect:"Raw current is correct but engineering units are wrong",evidence:[.meter,.plcTag,.hmiAlarm],repair:"Correct scaling bounds and verify 0/25/50/75/100% points."),
            .init(id:"ps-shield",title:"Improper shield bonding",domain:.wiring,effect:"Noise increases when pump VFD runs",evidence:[.meter,.historianTrend,.physicalInspection],repair:"Restore approved shield/ground practice and compare noise before/after at identical load.")
        ],capstoneMission:"Separate an instrumentation fault from a control fault and an EMI-related fault using synchronized electrical and trend evidence."),
        .init(id:"servo-cell-electrical",title:"Servo Cell: Ghost Interlock",description:"A motion cell with safety I/O, encoder/servo network, contactors, cabinet power and machine interlocks.",nominalSequence:["Safety chain healthy","Servo enable accepted","Axis homes","Transfer executes","Position prove completes"],faults:[
            .init(id:"sv-24dip",title:"24 VDC supply sag during brake release",domain:.power,effect:"Multiple low-voltage devices reset together",evidence:[.meter,.ioLED,.driveStatus,.historianTrend],repair:"Correct the overloaded/failed supply path and prove minimum voltage during dynamic load."),
            .init(id:"sv-safe",title:"Safety input discrepancy",domain:.io,effect:"Safety ready never proves despite healthy standard input",evidence:[.ioLED,.plcTag,.physicalInspection],repair:"Correct the safety-channel discrepancy using the scenario's verified safe maintenance process."),
            .init(id:"sv-net",title:"Motion network connector intermittency",domain:.network,effect:"Axis drops connection during high vibration moves",evidence:[.networkDiagnostic,.driveStatus,.historianTrend,.physicalInspection],repair:"Repair connector/cable integrity and stress-test the original motion profile.")
        ],capstoneMission:"Diagnose a power-quality fault plus one independent interlock/network fault without replacing healthy modules.")
    ]

    public static let certifications:[ElectricalCertification] = ElectricalChapter.allCases.map { chapter in
        let domains:[ElectricalCertificationDomain]
        switch chapter {
        case .fundamentals: domains=[.knowledge,.meterUse,.proofOfRepair]
        case .components: domains=[.knowledge,.panelBuild,.meterUse]
        case .schematics: domains=[.schematicBuild,.meterUse,.troubleshooting]
        case .industrialWiring: domains=[.schematicBuild,.meterUse,.panelBuild,.proofOfRepair]
        case .plcIO: domains=[.ioWiring,.meterUse,.troubleshooting,.proofOfRepair]
        case .motorControls: domains=[.schematicBuild,.driveCommissioning,.meterUse,.proofOfRepair]
        case .instrumentation: domains=[.calibration,.meterUse,.troubleshooting,.proofOfRepair]
        case .automation: domains=[.knowledge,.ioWiring,.troubleshooting,.proofOfRepair]
        case .networks: domains=[.knowledge,.troubleshooting,.proofOfRepair]
        case .supervisoryDiagnostics: domains=[.troubleshooting,.proofOfRepair,.knowledge]
        }
        return .init(id:"elec-cert-\(chapter.rawValue)",chapter:chapter,title:"Chapter \(chapter.rawValue) Certification: \(chapter.title)",timeLimitMinutes:45,rubrics:domains.map { .init(domain:$0,weight:1.0,minimumScore:$0 == .proofOfRepair ? 85:80,critical:$0 == .meterUse || $0 == .proofOfRepair) },requiredLabIDs:[])
    }
}
