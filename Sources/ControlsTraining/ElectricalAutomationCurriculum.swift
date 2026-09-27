import Foundation

public enum ElectricalSkillLevel: Int, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case apprentice = 1, technician, controlsTechnician, automationTechnician, advancedTroubleshooter
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .apprentice: "Apprentice"
        case .technician: "Technician"
        case .controlsTechnician: "Controls Technician"
        case .automationTechnician: "Automation Technician"
        case .advancedTroubleshooter: "Advanced Troubleshooter"
        }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}


public enum ElectricalExperienceTier: Int, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case apprentice = 1, journeyman, advanced, expert, master
    public var id:Int { rawValue }
    public var title:String {
        switch self { case .apprentice: "Apprentice"; case .journeyman: "Journeyman"; case .advanced: "Advanced"; case .expert: "Expert"; case .master: "Master" }
    }
    public var subtitle:String {
        switch self {
        case .apprentice: "Build safe fundamentals, components, prints, meter habits, and basic wiring."
        case .journeyman: "Wire and troubleshoot real industrial I/O, starters, instruments, and field circuits."
        case .advanced: "Integrate PLC I/O, drives, analog systems, permissives, interlocks, and layered diagnostics."
        case .expert: "Diagnose automation, networks, intermittent faults, waveform evidence, and complex machine interactions."
        case .master: "Prove difficult multi-layer failures, condition-monitor assets, and make reliability-level decisions."
        }
    }
    public static func <(lhs:Self,rhs:Self)->Bool { lhs.rawValue < rhs.rawValue }
}

public extension ElectricalSkillLevel {
    var experienceTier:ElectricalExperienceTier {
        switch self {
        case .apprentice: .apprentice
        case .technician: .journeyman
        case .controlsTechnician: .advanced
        case .automationTechnician: .expert
        case .advancedTroubleshooter: .master
        }
    }
}

public enum ElectricalChapter: Int, Codable, CaseIterable, Sendable, Identifiable {
    case fundamentals = 1, components, schematics, industrialWiring, plcIO, motorControls, instrumentation, automation, networks, supervisoryDiagnostics
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .fundamentals: "Electrical Fundamentals"
        case .components: "Industrial Components"
        case .schematics: "Schematics & Prints"
        case .industrialWiring: "Industrial Wiring"
        case .plcIO: "PLC I/O Wiring"
        case .motorControls: "Motor Controls & Drives"
        case .instrumentation: "Instrumentation & Analog"
        case .automation: "Controls & Automation"
        case .networks: "Industrial Networks"
        case .supervisoryDiagnostics: "HMI, SCADA, Historian & Diagnostics"
        }
    }
    public var subtitle: String {
        switch self {
        case .fundamentals: "Voltage, current, resistance, power, AC/DC, grounding, measurement and safe reasoning."
        case .components: "Recognize, select and reason about the devices inside real industrial panels."
        case .schematics: "Trace power and control across pages, references, terminals and device tags."
        case .industrialWiring: "Wire discrete, analog and temperature devices with correct commons, shields and polarity."
        case .plcIO: "Connect field devices to local and remote I/O and map the physical circuit into controller tags."
        case .motorControls: "Starters, overloads, reversing circuits, VFDs, soft starters and motor feedback."
        case .instrumentation: "4–20 mA, 0–10 V, RTD, thermocouple, scaling, isolation, failure modes and calibration."
        case .automation: "Permissives, interlocks, modes, sequences, alarms, fail-safe behavior and machine architecture."
        case .networks: "EtherNet/IP, IP/subnet fundamentals, remote I/O, Modbus, serial links and communication evidence."
        case .supervisoryDiagnostics: "HMI/SCADA/historian data paths and layered troubleshooting from field device to stored evidence."
        }
    }
}

public enum ElectricalLessonKind: String, Codable, Sendable {
    case concept, calculation, wiring, schematicTrace, meterLab, ioMapping, motorLab, analogLab, networkLab, faultLab, capstone
}

public struct ElectricalLesson: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var chapter: ElectricalChapter
    public var level: ElectricalSkillLevel
    public var title: String
    public var minutes: Int
    public var summary: String
    public var objectives: [String]
    public var procedure: [String]
    public var checkpoints: [String]
    public var fieldNotes: [String]
    public var kind: ElectricalLessonKind
}

public enum ElectricalFaultDomain: String, Codable, CaseIterable, Sendable {
    case power = "Power"
    case fieldDevice = "Field Device"
    case wiring = "Wiring"
    case io = "I/O"
    case plcLogic = "PLC Logic"
    case motorDrive = "Motor / Drive"
    case analog = "Analog / Instrumentation"
    case network = "Network"
    case hmi = "HMI / SCADA"
    case historian = "Historian"
}

public struct ElectricalFaultScenario: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var level: ElectricalSkillLevel
    public var symptom: String
    public var machine: String
    public var domain: ElectricalFaultDomain
    public var injectedFault: String
    public var firstEvidence: [String]
    public var usefulTests: [String]
    public var distractors: [String]
    public var rootCause: String
    public var proofOfRepair: String
}

public enum SignalLayer: String, Codable, CaseIterable, Sendable, Identifiable {
    case power = "Power Source"
    case device = "Field Device"
    case terminal = "Terminal / Cable"
    case ioChannel = "I/O Channel"
    case controllerTag = "PLC Tag"
    case ladder = "Ladder Logic"
    case command = "Output / Command"
    case network = "Network"
    case hmi = "HMI / SCADA"
    case historian = "Historian"
    public var id: String { rawValue }
}

public struct SignalTraceNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var layer: SignalLayer
    public var label: String
    public var expected: String
    public var diagnosticQuestion: String
}

public struct SignalTrace: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var nodes: [SignalTraceNode]
}

public struct ElectricalProgressProfile: Codable, Equatable, Sendable {
    public private(set) var completedLessons: Set<String> = []
    public private(set) var solvedFaults: Set<String> = []
    public init() {}
    public mutating func completeLesson(_ id: String) { completedLessons.insert(id) }
    public mutating func solveFault(_ id: String) { solvedFaults.insert(id) }
    public func isComplete(_ id: String) -> Bool { completedLessons.contains(id) }
    public var completionFraction: Double {
        guard !ElectricalAutomationCatalog.lessons.isEmpty else { return 0 }
        return Double(completedLessons.count) / Double(ElectricalAutomationCatalog.lessons.count)
    }
    public var rank: ElectricalSkillLevel {
        let p = completionFraction
        if p >= 0.9 && solvedFaults.count >= 16 { return .advancedTroubleshooter }
        if p >= 0.7 && solvedFaults.count >= 10 { return .automationTechnician }
        if p >= 0.45 && solvedFaults.count >= 6 { return .controlsTechnician }
        if p >= 0.2 && solvedFaults.count >= 2 { return .technician }
        return .apprentice
    }
    public func isUnlocked(_ lesson: ElectricalLesson) -> Bool {
        if lesson.level == .apprentice { return true }
        let previous = ElectricalSkillLevel(rawValue: lesson.level.rawValue - 1) ?? .apprentice
        let prerequisiteLessons = ElectricalAutomationCatalog.lessons.filter { $0.level == previous }
        guard !prerequisiteLessons.isEmpty else { return true }
        let completed = prerequisiteLessons.filter { completedLessons.contains($0.id) }.count
        return Double(completed) / Double(prerequisiteLessons.count) >= 0.6
    }
}

public struct OhmsLawResult: Equatable, Sendable {
    public var voltage: Double
    public var current: Double
    public var resistance: Double
    public var power: Double { voltage * current }
}

public enum ElectricalCalculator {
    public static func fromVoltageResistance(voltage: Double, resistance: Double) -> OhmsLawResult? {
        guard resistance > 0, voltage.isFinite, resistance.isFinite else { return nil }
        return .init(voltage: voltage, current: voltage / resistance, resistance: resistance)
    }
    public static func fromVoltageCurrent(voltage: Double, current: Double) -> OhmsLawResult? {
        guard current != 0, voltage.isFinite, current.isFinite else { return nil }
        return .init(voltage: voltage, current: current, resistance: voltage / current)
    }
    public static func scale(raw: Double, rawLow: Double, rawHigh: Double, euLow: Double, euHigh: Double) -> Double? {
        guard rawHigh != rawLow else { return nil }
        return euLow + ((raw - rawLow) / (rawHigh - rawLow)) * (euHigh - euLow)
    }
    public static func milliampToPercent(_ milliamps: Double) -> Double { ((milliamps - 4) / 16) * 100 }
}

public enum ElectricalAutomationCatalog {
    private static func lesson(_ id: String, _ chapter: ElectricalChapter, _ level: ElectricalSkillLevel, _ title: String, _ minutes: Int, _ summary: String, _ kind: ElectricalLessonKind, _ objectives: [String], _ procedure: [String], _ checkpoints: [String], _ notes: [String] = []) -> ElectricalLesson {
        .init(id: id, chapter: chapter, level: level, title: title, minutes: minutes, summary: summary, objectives: objectives, procedure: procedure, checkpoints: checkpoints, fieldNotes: notes, kind: kind)
    }

    public static let lessons: [ElectricalLesson] = [
        lesson("ef-voltage-current", .fundamentals, .apprentice, "Voltage, Current, Resistance & Power", 30, "Build a physical mental model of what electrical quantities mean and how they relate.", .calculation,
               ["Use Ohm's law", "Calculate electrical power", "Predict what changes when resistance changes"],
               ["Identify the source, load and return path in a simple DC circuit.", "Calculate current from source voltage and load resistance.", "Calculate load power and compare it with the device rating.", "Open and short the teaching circuit and predict the meter readings before revealing them."],
               ["Solve V=24 V, R=240 Ω without guessing.", "Explain why an open circuit can have voltage but no load current."]),
        lesson("ef-ac-dc", .fundamentals, .apprentice, "AC, DC & Industrial Voltage Systems", 30, "Separate 24 VDC control power from common AC distribution and three-phase motor power.", .concept,
               ["Distinguish AC from DC", "Recognize common industrial control and motor voltages", "Follow power conversion through transformers and power supplies"],
               ["Trace incoming plant power to a control transformer or DC supply.", "Label line, neutral, phase conductors and 24 VDC +/common in teaching examples.", "Match common loads to appropriate power domains."],
               ["Do not confuse DC common with protective earth.", "Identify which side of a power supply should feed a PLC input circuit."]),
        lesson("ef-grounding", .fundamentals, .technician, "Grounding, Bonding, Commons & Reference", 35, "Learn why PE, neutral, signal common and shield/drain conductors have different jobs.", .wiring,
               ["Separate protective grounding from circuit reference", "Recognize common ground-loop paths", "Reason about shield termination"],
               ["Trace protective earth through an enclosure.", "Identify DC common and analog reference conductors.", "Compare single-point and accidental multi-point shield connections."],
               ["Explain why a machine can run while still being wired poorly.", "Find the unintended current path in a ground-loop example."]),
        lesson("ef-meter", .fundamentals, .technician, "Using a Meter Without Lying to Yourself", 40, "Measure voltage, resistance and continuity with correct reference points and circuit state.", .meterLab,
               ["Choose measurement mode", "Choose useful reference points", "Interpret phantom or misleading readings"],
               ["Predict the reading before placing probes.", "Measure source-to-common, device-to-common and across the load.", "De-energize the teaching circuit before resistance/continuity checks.", "Compare a high-impedance voltage reading with a loaded diagnostic test."],
               ["State what the measurement actually proves.", "Avoid declaring a conductor healthy from one ambiguous reading."],
               ["Training content should reinforce site procedures, PPE, qualified-person requirements and manufacturer documentation for real energized work."]),

        lesson("ec-protection", .components, .apprentice, "Disconnects, Breakers & Fuses", 30, "Understand isolation, branch protection and why a protective device opening is a symptom to investigate.", .concept,
               ["Recognize common protective devices", "Trace protected branches", "Separate overload protection from control logic"],
               ["Follow a branch from disconnect through fuse/breaker to load.", "Identify what remains energized when a control branch opens.", "Diagnose three example blown-fuse symptoms without simply replacing the fuse."],
               ["Identify the protected conductor and downstream loads.", "Name evidence needed before re-energizing a faulted teaching circuit."]),
        lesson("ec-relays", .components, .apprentice, "Relays, Contactors & Overloads", 35, "Connect coil state to NO/NC auxiliary contacts and motor power poles.", .wiring,
               ["Read coil/contact cross references", "Explain contactor vs overload roles", "Use auxiliaries for feedback and interlocks"],
               ["Energize a relay coil and observe every linked contact.", "Trace a contactor coil through permissives.", "Trip an overload and follow both its power and auxiliary effects."],
               ["Predict each contact state when the coil is de-energized.", "Distinguish commanded run from proven contactor state."]),
        lesson("ec-sensors", .components, .technician, "Industrial Sensors & Switches", 40, "Choose and diagnose proxes, photoeyes, limit switches, pressure switches and level devices.", .wiring,
               ["Recognize sensing technologies", "Interpret NO/NC behavior", "Choose fail-aware signal conventions"],
               ["Match sensors to machine conditions.", "Wire representative 2-wire and 3-wire devices.", "Introduce alignment, contamination and target-distance faults."],
               ["Explain why an LED on a sensor does not prove the PLC sees the signal.", "Identify what to check between sensor output and input tag."]),
        lesson("ec-panels", .components, .controlsTechnician, "Inside the Control Panel", 45, "Read a panel as a system: power distribution, terminals, PLC, network, drives and field cables.", .schematicTrace,
               ["Identify panel zones", "Trace energy and information flow", "Use device tags to move between layout and schematic"],
               ["Walk from incoming disconnect to each control-power branch.", "Locate PLC racks, I/O, relays, drives, terminals and network hardware.", "Trace one field sensor cable from gland to PLC channel."],
               ["Account for every conversion between power, signal and software.", "Locate the likely measurement points for a dead-input symptom."]),

        lesson("es-symbols", .schematics, .apprentice, "Electrical Symbols & Ladder-Style Control Prints", 35, "Read contacts, coils, switches, terminals and references as a circuit rather than isolated icons.", .schematicTrace,
               ["Recognize common symbols", "Read left-to-right control logic", "Determine normal state"],
               ["Identify source rails and loads.", "Mark device contacts by normal state.", "Trace a simple start/stop circuit before simulating it."],
               ["Explain what 'normal' means for an electrical symbol.", "Predict whether the coil energizes for four switch combinations."]),
        lesson("es-crossrefs", .schematics, .technician, "Wire Numbers, Device Tags & Cross References", 40, "Follow a real circuit when it disappears to another page, terminal strip or device location.", .schematicTrace,
               ["Use wire numbers", "Use cross references", "Relate schematic and panel layout"],
               ["Trace one conductor across three drawing pages.", "Find every auxiliary contact belonging to one relay.", "Map a terminal number to its field cable destination."],
               ["Complete the trace without inventing continuity.", "Identify exactly where the field and panel wiring meet."]),
        lesson("es-power-control", .schematics, .controlsTechnician, "Power Diagrams vs Control Diagrams", 40, "Relate three-phase power switching to the lower-energy circuit that commands it.", .schematicTrace,
               ["Separate power and control paths", "Correlate contactor coil to main poles", "Trace feedback back into PLC"],
               ["Trace motor power through disconnect, protection, contactor and overload.", "Trace the contactor coil control circuit.", "Trace auxiliary feedback into a PLC input."],
               ["Explain how the PLC can command a motor that never receives power.", "Identify evidence that differentiates control failure from power-path failure."]),
        lesson("es-pid", .schematics, .automationTechnician, "P&IDs and Controls Drawings Together", 45, "Bridge process intent, instrument tags, loop diagrams and PLC/HMI implementation.", .schematicTrace,
               ["Read basic P&ID relationships", "Connect instrument loop tags to I/O", "Trace process cause and control effect"],
               ["Select one pressure loop on a teaching P&ID.", "Find the transmitter wiring and analog input.", "Find the PLC tag, control calculation and final element.", "Trace the HMI faceplate and historian point back to the same process variable."],
               ["Describe the whole loop in one coherent signal chain.", "Name which drawing answers each troubleshooting question."]),

        lesson("iw-no-nc", .industrialWiring, .apprentice, "NO/NC Contacts & Fail-Aware Wiring", 30, "Understand physical contact state and why normally-closed circuits often reveal broken conductors.", .wiring,
               ["Wire NO and NC devices", "Predict de-energized states", "Recognize fail-aware circuits"],
               ["Build equivalent NO and NC input examples.", "Open a conductor in each circuit.", "Compare the PLC-visible result and diagnostic ambiguity."],
               ["Predict signal state after loss of field power.", "Explain what the circuit can and cannot detect."]),
        lesson("iw-pnp-npn", .industrialWiring, .technician, "PNP, NPN, Sourcing & Sinking", 45, "Make current direction visible so 3-wire sensor and input-card compatibility stops being memorization.", .wiring,
               ["Trace current path", "Identify sourcing vs sinking behavior", "Match sensor output to module input"],
               ["Draw the current path for a PNP sensor turning on.", "Draw the current path for an NPN sensor turning on.", "Wire each to a compatible teaching input and intentionally create one mismatch."],
               ["State which device supplies current and which receives it.", "Diagnose a sensor LED ON / PLC input OFF mismatch."]),
        lesson("iw-shields", .industrialWiring, .controlsTechnician, "Shielding, Segregation & Noise", 45, "See how routing, shield/drain handling and reference choices affect low-level signals.", .analogLab,
               ["Recognize noisy routing", "Use shield/drain intentionally", "Separate power and instrumentation wiring"],
               ["Compare clean and noise-coupled analog traces.", "Change shield termination in the teaching model.", "Move a signal cable beside a simulated VFD motor lead and observe noise susceptibility."],
               ["Choose a corrective action based on evidence.", "Avoid treating software filtering as the first cure for a wiring problem."]),
        lesson("iw-terminals", .industrialWiring, .controlsTechnician, "Terminal Blocks, Field Cables & Panel Boundaries", 40, "Treat terminals as diagnostic boundaries, not decorative connectors.", .wiring,
               ["Read terminal plans", "Use terminals as isolation points", "Trace multi-conductor field cables"],
               ["Map cable conductors to terminal numbers.", "Lift a teaching terminal to isolate field from panel.", "Use before/after measurements to localize an open conductor."],
               ["Narrow the fault to field cable, terminal, or panel wiring.", "Restore conductor identification after repair."]),

        lesson("io-discrete-input", .plcIO, .apprentice, "Discrete Input Circuits", 40, "Trace a 24 VDC field switch all the way into a controller-visible Boolean tag.", .ioMapping,
               ["Wire field input circuits", "Identify module common/reference", "Map channel to tag"],
               ["Wire source, switch/sensor, terminal and input channel.", "Verify the module indicator.", "Map the channel into an I/O list and controller alias."],
               ["Differentiate field voltage, module LED and PLC tag evidence.", "Find where the chain breaks in three injected faults."]),
        lesson("io-discrete-output", .plcIO, .technician, "Discrete Outputs, Loads & Interposing Relays", 45, "Command real loads while respecting output type, load current, flyback and isolation needs.", .ioMapping,
               ["Wire output circuits", "Use interposing relays", "Trace output command to load feedback"],
               ["Wire a PLC output to a pilot load.", "Insert an interposing relay for a larger/isolated load.", "Compare command tag, module LED, relay coil and load state."],
               ["Diagnose output LED ON / load OFF.", "Explain why software force state alone does not prove field wiring."]),
        lesson("io-analog-modules", .plcIO, .controlsTechnician, "Analog I/O Modules & Channel Configuration", 50, "Connect transmitters and commands while keeping raw values, engineering units and channel diagnostics separate.", .analogLab,
               ["Wire analog channels", "Choose current vs voltage mode", "Preserve raw and scaled values"],
               ["Wire a 2-wire 4–20 mA transmitter loop.", "Configure the teaching channel mode.", "Observe raw counts/current, engineering conversion and status bits."],
               ["Detect an open-loop failure.", "Prove whether bad engineering units originate in field signal, configuration or PLC scaling."]),
        lesson("io-remote", .plcIO, .automationTechnician, "Remote I/O from Wire to Tag", 55, "Connect field wiring to remote modules and include network update behavior in the signal chain.", .ioMapping,
               ["Trace remote I/O path", "Understand update timing", "Separate module health from network health"],
               ["Map a remote sensor to rack/slot/channel and controller data.", "Change the physical signal between update boundaries.", "Introduce an adapter/network fault and compare diagnostics."],
               ["Explain why a healthy sensor may produce stale controller data.", "Identify the layer that owns each status indicator."]),

        lesson("mc-starter", .motorControls, .technician, "Three-Phase Motor Starter", 45, "Build and diagnose the classic contactor/overload motor circuit.", .motorLab,
               ["Trace motor power", "Trace coil control", "Use overload and auxiliary feedback"],
               ["Trace all three power phases.", "Run the contactor coil through permissives.", "Trip the overload and observe power plus control feedback."],
               ["Differentiate command, contactor pickup and motor-running proof.", "Find a single-phasing teaching fault from evidence."]),
        lesson("mc-reversing", .motorControls, .controlsTechnician, "Forward / Reverse Control", 45, "Prevent simultaneous direction commands with electrical and software interlocking.", .motorLab,
               ["Understand phase reversal concept", "Build mutual interlocks", "Handle direction transitions"],
               ["Trace forward and reverse contactor paths.", "Add normally-closed opposing auxiliaries.", "Add PLC logic interlocks and transition delay."],
               ["Prove both directions cannot energize together.", "Diagnose a welded auxiliary/contact feedback inconsistency."]),
        lesson("mc-vfd", .motorControls, .automationTechnician, "VFD Control, Speed Reference & Feedback", 60, "Treat a VFD as power converter, command interface, feedback source and diagnostic device.", .motorLab,
               ["Map run/stop authority", "Scale speed command", "Interpret ready/running/fault feedback", "Separate drive and motor faults"],
               ["Trace line power and motor output.", "Select teaching command ownership: terminals or network.", "Scale a speed reference.", "Inject overtemperature, permissive and network-command faults."],
               ["Explain command vs actual speed mismatch.", "Identify whether PLC, network, drive or motor evidence owns the failure."]),
        lesson("mc-softstarter", .motorControls, .automationTechnician, "Soft Starters, Bypass & Reduced-Stress Starting", 45, "Understand where soft starters fit and what changes during start, run and fault states.", .motorLab,
               ["Contrast starter, soft starter and VFD", "Trace bypass logic", "Use device status feedback"],
               ["Walk through a start sequence.", "Observe current/torque teaching trends.", "Inject a failed bypass feedback condition."],
               ["Choose the correct device for three application examples.", "Prove the machine reached its intended run state."]),

        lesson("ai-420", .instrumentation, .technician, "4–20 mA Loops", 45, "Make loop current, loop power and live-zero diagnostics concrete.", .analogLab,
               ["Wire 2-wire loops", "Convert mA to percent", "Recognize underrange/open-loop evidence"],
               ["Build a powered transmitter loop.", "Set 4, 12 and 20 mA and calculate percent.", "Open the loop and observe channel diagnostics."],
               ["12 mA maps to 50% for an ideal 4–20 mA span.", "Differentiate a legitimate process zero from loss of signal where configuration supports it."]),
        lesson("ai-voltage", .instrumentation, .controlsTechnician, "0–10 V, Reference Errors & Loading", 40, "Understand why voltage signals behave differently from current loops.", .analogLab,
               ["Wire voltage references", "Recognize common/reference problems", "Diagnose loading and drop"],
               ["Wire source, reference and analog input.", "Introduce a reference offset.", "Compare measured source voltage with module-terminal voltage."],
               ["Localize the error using reference-aware measurements.", "Explain why adding a random ground can worsen the problem."]),
        lesson("ai-temp", .instrumentation, .automationTechnician, "RTDs, Thermocouples & Temperature Inputs", 50, "Separate resistance-based and thermoelectric temperature measurement methods.", .analogLab,
               ["Distinguish RTD and thermocouple principles", "Recognize lead/extension-wire concerns", "Use channel diagnostics"],
               ["Compare 2-, 3- and conceptual 4-wire RTD compensation.", "Trace a thermocouple circuit with correct extension concept.", "Inject open-sensor and wrong-type configuration faults."],
               ["Identify whether error follows wiring or configuration.", "Explain why ordinary copper substitutions can matter in thermocouple circuits."]),
        lesson("ai-calibration", .instrumentation, .advancedTroubleshooter, "Calibration, As-Found / As-Left & Loop Proof", 60, "Prove an instrument loop quantitatively instead of turning trim adjustments until the number looks right.", .analogLab,
               ["Perform zero/span reasoning", "Separate sensor, transmitter, input and scaling error", "Document proof"],
               ["Record an as-found five-point teaching check.", "Determine which layer introduces error.", "Apply a simulated correction only at the responsible layer.", "Record as-left values and acceptance evidence."],
               ["Do not calibrate around a PLC scaling defect.", "Produce evidence that distinguishes calibration from repair."]),

        lesson("ca-permissives", .automation, .controlsTechnician, "Permissives, Interlocks & Trips", 45, "Use precise meanings so run authorization, active prevention and protective trip behavior remain readable.", .faultLab,
               ["Separate permissive/interlock/trip concepts", "Build diagnostic reason bits", "Design reset behavior"],
               ["Create a run-permissive summary.", "Expose individual failed reasons.", "Inject each condition and observe command/status behavior."],
               ["The operator can see why equipment will not start.", "A cleared trip does not silently restart unsafe equipment."]),
        lesson("ca-modes", .automation, .controlsTechnician, "Hand / Off / Auto, Local / Remote & Command Ownership", 50, "Prevent competing command sources from fighting each other.", .faultLab,
               ["Define command authority", "Design bumpless mode transitions conceptually", "Keep safety/permissives common to all modes"],
               ["Define ownership for each mode.", "Route every mode through common permissives.", "Switch authority while a command is active and inspect resulting state."],
               ["Only one source owns the command at a time.", "Local/manual operation cannot bypass required protective logic."]),
        lesson("ca-sequences", .automation, .automationTechnician, "Sequences & State Machines", 60, "Represent machine progression explicitly so troubleshooting has a current state, expected transition and timeout reason.", .faultLab,
               ["Define states", "Define transition conditions", "Add timeout/fault evidence"],
               ["Build Idle, Starting, Running, Stopping and Faulted states.", "Attach entry/exit conditions.", "Freeze a transition by removing one field confirmation."],
               ["Identify the exact missing transition condition.", "Recover without skipping required machine states."]),
        lesson("ca-failsafe", .automation, .advancedTroubleshooter, "Fail-Safe Intent, Diagnostics & Degraded Modes", 60, "Reason explicitly about loss of power, signal, network and device capability.", .faultLab,
               ["Define safe state", "Separate detected from undetected failures", "Design degraded behavior intentionally"],
               ["List failure modes for one machine function.", "Mark whether each is detectable.", "Define controller response and operator evidence.", "Test loss-of-signal and stale-network scenarios."],
               ["Safe behavior is defined before failure injection.", "No single status bit is treated as proof of the entire physical function."],
               ["Functional-safety design and validation require applicable standards, manufacturer requirements and qualified engineering; this trainer teaches diagnostic reasoning, not safety certification."]),

        lesson("nw-ip", .networks, .controlsTechnician, "IP Addressing, Subnets & Switch Fundamentals", 45, "Develop enough Ethernet literacy to separate address, link and application-layer problems.", .networkLab,
               ["Read IPv4 addresses and masks", "Determine same-subnet examples", "Interpret basic link evidence"],
               ["Classify address pairs as same/different subnet in teaching examples.", "Trace controller-to-remote-I/O through a switch.", "Inject duplicate/wrong-subnet conceptual faults."],
               ["Do not call every communication failure 'the network'.", "Name the lowest layer of evidence that is already proven healthy."]),
        lesson("nw-enip", .networks, .automationTechnician, "EtherNet/IP, Connections & Remote I/O", 55, "Understand cyclic I/O as an owned connection with update behavior and diagnostics.", .networkLab,
               ["Separate Ethernet from EtherNet/IP", "Understand cyclic I/O concept", "Reason about update period and stale data"],
               ["Observe a remote I/O value change across an update boundary.", "Drop the teaching connection.", "Compare field device, module, adapter and controller evidence."],
               ["Identify stale-data risk.", "Localize the fault without changing PLC logic first."]),
        lesson("nw-modbus", .networks, .automationTechnician, "Modbus TCP / RTU Data Mapping", 55, "Treat Modbus as explicit data mapping with address/type/endian details that must be verified.", .networkLab,
               ["Understand client/server and serial concepts", "Map registers to values", "Recognize word-order/type errors"],
               ["Map several teaching registers.", "Decode a 32-bit value from two 16-bit words.", "Introduce offset and word-order mistakes."],
               ["Differentiate communications success from data-interpretation correctness.", "Document the register contract explicitly."]),
        lesson("nw-diagnostics", .networks, .advancedTroubleshooter, "Network Troubleshooting by Layer", 60, "Work from power/link through addressing, connection health and application data instead of reboot roulette.", .networkLab,
               ["Use layered evidence", "Differentiate intermittent from hard faults", "Correlate network events with machine symptoms"],
               ["Start from a machine symptom.", "Check device power and link evidence.", "Check addressing/connection diagnostics.", "Compare timestamps with PLC event data and historian trends."],
               ["Reach a narrow root cause with minimal disruptive actions.", "State what each test ruled in or ruled out."]),

        lesson("sd-hmi", .supervisoryDiagnostics, .automationTechnician, "HMI / SCADA Commands, Status & Alarms", 50, "Design the supervisory interface as a data contract instead of a second control program.", .faultLab,
               ["Separate command and status", "Expose permissive reasons", "Design actionable alarms"],
               ["Map an operator command to PLC-owned logic.", "Display actual state separately from requested state.", "Add alarm cause, state and reset evidence."],
               ["HMI command does not directly bypass PLC permissives.", "Operator can distinguish requested, commanded and proven state."]),
        lesson("sd-historian", .supervisoryDiagnostics, .automationTechnician, "Historian, Trends, Quality & Time", 50, "Use history as evidence while respecting sample period, timestamp and quality.", .faultLab,
               ["Choose useful points", "Match collection rate to phenomenon", "Interpret quality and gaps"],
               ["Create a point plan for process, command, feedback and fault state.", "Compare a short transient with a slower collection interval.", "Introduce bad-quality/stale samples."],
               ["Do not infer an event never happened merely because a slow historian missed it.", "Use controller flight-recorder evidence for scan-level transients."]),
        lesson("sd-layered", .supervisoryDiagnostics, .advancedTroubleshooter, "Layered Troubleshooting: Device to Historian", 75, "Diagnose one symptom across every electrical, controller and supervisory layer.", .capstone,
               ["Choose the next best test", "Track evidence confidence", "Separate symptom location from root-cause location"],
               ["Start with 'Conveyor 4 intermittently stops.'", "Inspect timeline and command/feedback states.", "Trace the implicated signal back through ladder, input tag, I/O, terminals and field device.", "Compare HMI and historian timestamps against controller-local evidence."],
               ["Find the injected layer without shotgun replacement.", "Prove the repair under the original triggering condition."]),
        lesson("sd-capstone", .supervisoryDiagnostics, .advancedTroubleshooter, "Capstone: Commission a Networked Machine Cell", 90, "Commission and troubleshoot a complete cell spanning power, sensors, motors, analog instrumentation, PLC logic, networked I/O, HMI and historian.", .capstone,
               ["Commission systematically", "Build an I/O checkout record", "Prove modes and interlocks", "Diagnose multi-layer faults"],
               ["Verify power/control-power architecture.", "Perform point-to-point I/O checkout.", "Commission motor/VFD and analog loops.", "Verify PLC sequence and command ownership.", "Verify remote I/O/network health.", "Verify HMI alarms/status and historian evidence.", "Run a multi-fault acceptance challenge."],
               ["No point is accepted solely from software indication.", "Every machine function has command, feedback and failure evidence.", "Final proof recreates production-like conditions."])
    ]

    public static func lessons(in chapter: ElectricalChapter) -> [ElectricalLesson] { lessons.filter { $0.chapter == chapter } }
    public static func lessons(in tier: ElectricalExperienceTier) -> [ElectricalLesson] { lessons.filter { $0.level.experienceTier == tier } }
    public static func lessons(in tier: ElectricalExperienceTier, chapter: ElectricalChapter) -> [ElectricalLesson] { lessons.filter { $0.level.experienceTier == tier && $0.chapter == chapter } }
    public static func lesson(_ id: String) -> ElectricalLesson? { lessons.first { $0.id == id } }

    public static let traces: [SignalTrace] = [
        SignalTrace(id: "photoeye-conveyor", title: "Photoeye → Conveyor Logic → HMI", nodes: [
            .init(id:"p1", layer:.power, label:"24 VDC control supply", expected:"Nominal control voltage", diagnosticQuestion:"Is field power actually present under load?"),
            .init(id:"p2", layer:.device, label:"PE203 photoeye", expected:"Output changes with target", diagnosticQuestion:"Does the sensor itself detect the target?"),
            .init(id:"p3", layer:.terminal, label:"TB3-17 / cable C203", expected:"Signal reaches panel", diagnosticQuestion:"Does the state survive the field cable and terminals?"),
            .init(id:"p4", layer:.ioChannel, label:"Remote DI channel 5", expected:"Channel indicator follows field signal", diagnosticQuestion:"Does the I/O electronics see it?"),
            .init(id:"p5", layer:.controllerTag, label:"PE203", expected:"BOOL follows input update", diagnosticQuestion:"Is controller data fresh and mapped correctly?"),
            .init(id:"p6", layer:.ladder, label:"Jam / accumulation logic", expected:"Expected rung truth", diagnosticQuestion:"How is the signal interpreted?"),
            .init(id:"p7", layer:.hmi, label:"Conveyor diagnostics faceplate", expected:"Status mirrors PLC-owned state", diagnosticQuestion:"Is the display stale or merely reporting the PLC state?"),
            .init(id:"p8", layer:.historian, label:"PE203 / ConveyorState history", expected:"Timestamped evidence with quality", diagnosticQuestion:"Did collection timing capture the event?")
        ]),
        SignalTrace(id: "pressure-vfd", title: "Pressure Transmitter → PLC → VFD", nodes: [
            .init(id:"v1", layer:.power, label:"Loop supply", expected:"Sufficient loop voltage", diagnosticQuestion:"Can the transmitter drive the loop?"),
            .init(id:"v2", layer:.device, label:"PT101 transmitter", expected:"4–20 mA proportional to pressure", diagnosticQuestion:"Does local/loop current agree with process?"),
            .init(id:"v3", layer:.terminal, label:"Analog shielded pair", expected:"Current reaches AI without unintended path", diagnosticQuestion:"Is wiring/reference/noise changing the signal?"),
            .init(id:"v4", layer:.ioChannel, label:"AI channel", expected:"Healthy channel/current value", diagnosticQuestion:"Is channel mode/configuration correct?"),
            .init(id:"v5", layer:.controllerTag, label:"PressureRaw → PressurePV", expected:"Correct engineering scaling", diagnosticQuestion:"Is the physical signal correct but software scaling wrong?"),
            .init(id:"v6", layer:.ladder, label:"Pressure control / limits", expected:"SpeedCmdPct follows control intent", diagnosticQuestion:"Are permissives or limits modifying the command?"),
            .init(id:"v7", layer:.command, label:"VFD speed reference", expected:"Command arrives at drive", diagnosticQuestion:"Does drive command source agree with PLC intent?"),
            .init(id:"v8", layer:.network, label:"Drive status connection", expected:"Fresh ready/running/fault feedback", diagnosticQuestion:"Is feedback stale or connection faulted?"),
            .init(id:"v9", layer:.hmi, label:"Pump faceplate", expected:"PV/SP/CV/status are distinct", diagnosticQuestion:"Is the operator seeing command or actual feedback?"),
            .init(id:"v10", layer:.historian, label:"Pressure / speed / fault trend", expected:"Coherent timestamps and quality", diagnosticQuestion:"Can the recorded trend reconstruct cause before effect?")
        ])
    ]

    public static let faultScenarios: [ElectricalFaultScenario] = [
        .init(id:"f01", title:"Dead 24 VDC Branch", level:.apprentice, symptom:"Several sensors are dark and multiple inputs are false.", machine:"Packaging Conveyor", domain:.power, injectedFault:"Open control-power branch fuse", firstEvidence:["PLC remains powered", "Affected field devices share one branch"], usefulTests:["Measure branch source and load side", "Trace fuse/terminal distribution"], distractors:["Rewrite PLC logic", "Replace every sensor"], rootCause:"Open branch protection feeding the affected devices", proofOfRepair:"Branch voltage restored and every affected input passes point-to-point checkout."),
        .init(id:"f02", title:"Sensor LED On, PLC Input Off", level:.apprentice, symptom:"Photoeye detects cartons locally but PLC tag never changes.", machine:"Case Conveyor", domain:.wiring, injectedFault:"Open signal conductor between field terminal and input module", firstEvidence:["Sensor output LED changes", "Input LED stays off"], usefulTests:["Measure sensor output to common", "Measure same signal at panel terminal and module"], distractors:["Change timer preset"], rootCause:"Open signal conductor", proofOfRepair:"Sensor, terminal, module LED and PLC tag transition together."),
        .init(id:"f03", title:"Wrong PNP/NPN Match", level:.technician, symptom:"New prox LED changes but input channel never asserts.", machine:"Pallet Stop", domain:.io, injectedFault:"NPN sensor connected to sourcing-style teaching input circuit", firstEvidence:["Correct field power", "Sensor output changes relative to its intended reference"], usefulTests:["Draw current path", "Compare module input/common topology"], distractors:["Force the PLC input"], rootCause:"Incompatible sourcing/sinking circuit", proofOfRepair:"Current path is valid and input channel follows the prox."),
        .init(id:"f04", title:"Loose Terminal Intermittent", level:.technician, symptom:"Conveyor stops only during vibration-heavy production.", machine:"Conveyor 4", domain:.wiring, injectedFault:"High-resistance/intermittent field terminal", firstEvidence:["Short input dropouts precede stop", "Sensor alignment remains stable"], usefulTests:["Flight-recorder input timeline", "Terminal/cable disturbance in de-energized teaching model"], distractors:["Increase debounce until symptom disappears"], rootCause:"Intermittent terminal connection", proofOfRepair:"No dropout during repeated vibration-condition test; physical connection passes inspection/check."),
        .init(id:"f05", title:"Output LED On, Solenoid Off", level:.technician, symptom:"PLC commands valve and output LED lights, but cylinder does not move.", machine:"Reject Station", domain:.wiring, injectedFault:"Open load return conductor", firstEvidence:["PLC command true", "Output channel LED on"], usefulTests:["Measure across solenoid coil", "Measure each coil side to reference"], distractors:["Edit sequence logic"], rootCause:"Open solenoid return", proofOfRepair:"Rated control voltage appears across coil when commanded and valve feedback confirms motion."),
        .init(id:"f06", title:"Welded Contactor Feedback", level:.controlsTechnician, symptom:"Motor feedback remains on after run command drops.", machine:"Transfer Conveyor", domain:.motorDrive, injectedFault:"Contactor main pole/auxiliary inconsistency teaching fault", firstEvidence:["Command false", "Feedback remains true"], usefulTests:["Compare coil voltage, auxiliary feedback and load state", "Inspect contactor teaching model"], distractors:["Invert feedback bit in PLC"], rootCause:"Contactor hardware does not follow command", proofOfRepair:"Command, coil, auxiliary and motor state transition coherently through multiple cycles."),
        .init(id:"f07", title:"Blown Motor Branch Fuse", level:.controlsTechnician, symptom:"Contactor pulls in but motor does not accelerate normally.", machine:"Mixer", domain:.power, injectedFault:"One teaching phase branch open", firstEvidence:["Coil/control circuit healthy", "Power-path evidence asymmetric"], usefulTests:["Compare phase-to-phase power-path measurements in safe teaching simulator", "Inspect branch protection"], distractors:["Increase VFD speed reference"], rootCause:"Open motor power phase/branch", proofOfRepair:"Balanced power-path simulation and normal motor-run feedback."),
        .init(id:"f08", title:"4–20 mA Open Loop", level:.controlsTechnician, symptom:"Pressure PV suddenly falls below valid range and channel diagnostic changes.", machine:"Pump Skid", domain:.analog, injectedFault:"Open transmitter loop conductor", firstEvidence:["Channel current underrange", "Process did not physically collapse"], usefulTests:["Read channel diagnostic", "Check loop current path"], distractors:["Rescale 0 mA to zero pressure"], rootCause:"Open current loop", proofOfRepair:"Loop current returns to valid range and known-pressure checks scale correctly."),
        .init(id:"f09", title:"Analog Scaling Error", level:.controlsTechnician, symptom:"Field calibrator and module raw value are correct but HMI pressure is 25% high.", machine:"Pump Skid", domain:.plcLogic, injectedFault:"Incorrect engineering high endpoint in scaling", firstEvidence:["Physical mA is correct", "Raw input tracks mA"], usefulTests:["Calculate expected engineering value", "Inspect scale endpoints"], distractors:["Calibrate transmitter to match HMI"], rootCause:"PLC scaling configuration", proofOfRepair:"Multiple known mA points map to correct engineering values without changing transmitter calibration."),
        .init(id:"f10", title:"Ground Loop / Noise", level:.automationTechnician, symptom:"Analog PV becomes noisy when a nearby VFD runs.", machine:"Web Handling Line", domain:.analog, injectedFault:"Unintended multi-point shield/reference path", firstEvidence:["Noise correlates with drive operation", "Transmitter local output is stable"], usefulTests:["Compare signal at source and input", "Inspect shield/reference topology"], distractors:["Add excessive software filtering first"], rootCause:"Wiring/reference noise coupling", proofOfRepair:"PV remains stable across VFD operating range with correct wiring topology."),
        .init(id:"f11", title:"VFD Command Source Mismatch", level:.automationTechnician, symptom:"PLC speed command changes but drive remains at local keypad setpoint.", machine:"Exhaust Fan", domain:.motorDrive, injectedFault:"Drive command/reference ownership set to local source", firstEvidence:["PLC command calculation correct", "Drive display indicates local/reference source"], usefulTests:["Compare selected command source", "Check drive received/reference values"], distractors:["Rewrite PID"], rootCause:"Drive configured for different command authority", proofOfRepair:"Drive follows intended PLC command source and local/remote transitions are verified."),
        .init(id:"f12", title:"Remote I/O Stale Data", level:.automationTechnician, symptom:"Field input LED changes at remote rack but controller tag freezes.", machine:"Palletizer", domain:.network, injectedFault:"Remote I/O connection loss", firstEvidence:["Field/module indication healthy", "Controller connection diagnostic unhealthy"], usefulTests:["Check adapter/link/connection evidence", "Compare update timestamp/status"], distractors:["Replace photoeye"], rootCause:"Remote I/O communication path", proofOfRepair:"Connection is healthy and controller tag resumes cyclic updates."),
        .init(id:"f13", title:"Duplicate IP Conceptual Fault", level:.automationTechnician, symptom:"Intermittent device communication appears after replacement hardware is connected.", machine:"Filler Cell", domain:.network, injectedFault:"Duplicate address in teaching network", firstEvidence:["Physical links are up", "Communication ownership alternates/intermittently fails"], usefulTests:["Inventory configured addresses", "Isolate teaching devices to identify collision"], distractors:["Change every RPI"], rootCause:"Duplicate IP address", proofOfRepair:"Unique documented addressing and stable connections across restart tests."),
        .init(id:"f14", title:"Modbus Word Order", level:.automationTechnician, symptom:"Communication succeeds but energy value is absurd.", machine:"Utility Meter", domain:.network, injectedFault:"32-bit float words decoded in wrong order", firstEvidence:["Transaction succeeds", "Individual registers change plausibly"], usefulTests:["Compare documented data type/register order", "Decode both candidate word orders"], distractors:["Replace Ethernet switch"], rootCause:"Data interpretation/word-order mismatch", proofOfRepair:"Known reference value decodes correctly across several operating points."),
        .init(id:"f15", title:"HMI Command Works Only Sometimes", level:.advancedTroubleshooter, symptom:"Operator start request appears but equipment sometimes refuses to run.", machine:"Pump Skid", domain:.hmi, injectedFault:"Healthy PLC permissive intentionally false; HMI lacks reason display", firstEvidence:["Command reaches PLC", "Run permissive summary false"], usefulTests:["Inspect individual permissive reasons", "Compare command vs actual state"], distractors:["Increase HMI button hold time"], rootCause:"Machine condition blocks start; supervisory diagnostics are inadequate", proofOfRepair:"Underlying condition corrected and HMI exposes the failed permissive rather than masking it."),
        .init(id:"f16", title:"Historian Misses Short Trip", level:.advancedTroubleshooter, symptom:"Operators report a trip but trend shows no fault state.", machine:"High-Speed Conveyor", domain:.historian, injectedFault:"Fault pulse shorter than historian collection interval", firstEvidence:["Controller flight recorder captured pulse", "Historian samples straddle event"], usefulTests:["Compare timestamps and collection rates", "Inspect point sampling/exception behavior conceptually"], distractors:["Conclude operator report is false"], rootCause:"Evidence system temporal resolution", proofOfRepair:"Use appropriate event/collection strategy and confirm a repeat transient is captured by the intended evidence source."),
        .init(id:"f17", title:"Sequence Waiting on Hidden Feedback", level:.advancedTroubleshooter, symptom:"Machine remains in Starting with no obvious alarm.", machine:"Cartoner", domain:.plcLogic, injectedFault:"One transition confirmation never becomes true", firstEvidence:["State is stable", "Command outputs are present"], usefulTests:["Inspect transition reason bits", "Trace missing feedback to field"], distractors:["Force next state"], rootCause:"Missing transition confirmation", proofOfRepair:"Physical feedback is restored and sequence advances normally without forcing state."),
        .init(id:"f18", title:"Two Faults, One Symptom", level:.advancedTroubleshooter, symptom:"Pump cannot maintain pressure and reports intermittent communication warnings.", machine:"Networked Pump Skid", domain:.analog, injectedFault:"Biased pressure signal plus intermittent drive-status network dropout", firstEvidence:["Pressure control error persists even while network healthy", "Drive status gaps do not align with every pressure deviation"], usefulTests:["Separate PV quality from drive feedback timeline", "Inject known analog reference"], distractors:["Assume one fault explains all evidence"], rootCause:"Two independent faults: measurement bias and network intermittency", proofOfRepair:"Analog loop passes known-value checks and drive connection remains healthy through stress test.")
    ]
}
