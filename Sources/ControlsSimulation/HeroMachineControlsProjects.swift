import Foundation

public enum ElectricalDrawingDiscipline: String, Codable, CaseIterable, Sendable {
    case power, control, plcIO, network, safety, instrumentation, pneumatics, panelLayout
}

public struct HeroElectricalDrawing: Identifiable, Codable, Equatable, Sendable {
    public var id: String { sheetNumber }
    public var sheetNumber: String
    public var title: String
    public var discipline: ElectricalDrawingDiscipline
    public var zones: [String]
    public var referencedTags: [String]
    public var description: String
}

public enum PLCModulePurpose: String, Codable, CaseIterable, Sendable {
    case controller, ethernetBridge, digitalInput, digitalOutput, analogInput, analogOutput, safetyInput, safetyOutput, motion, specialty
}

public struct PLCHardwareModule: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(rack)-\(slot)" }
    public var rack: String
    public var slot: Int
    public var family: String
    public var catalog: String
    public var purpose: PLCModulePurpose
    public var channelCount: Int
    public var description: String
}

public struct PLCRackConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: String { rackName }
    public var rackName: String
    public var location: String
    public var chassisFamily: String
    public var adapterCatalog: String?
    public var networkAddress: String?
    public var modules: [PLCHardwareModule]
}

public enum ProjectIOSignalType: String, Codable, CaseIterable, Sendable {
    case digital24VDC, digital120VAC, analog4to20mA, analog0to10V, thermocouple, rtd, pulse, encoder, safetyDualChannel, networkProduced, networkConsumed
}

public enum ProjectIODirection: String, Codable, CaseIterable, Sendable { case input, output }

public struct ProjectIOPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var address: String
    public var direction: ProjectIODirection
    public var signalType: ProjectIOSignalType
    public var fieldDevice: String
    public var rack: String
    public var slot: Int
    public var channel: Int
    public var description: String
    public var engineeringRange: String?
}

public struct EtherNetIPNode: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var deviceType: String
    public var catalogFamily: String
    public var ipAddress: String
    public var parent: String?
    public var rpiMilliseconds: Int?
    public var role: String
}

public struct SafetyNetworkConfiguration: Codable, Equatable, Sendable {
    public var safetyController: String
    public var safetyNetwork: String
    public var inputDevices: [String]
    public var outputDevices: [String]
    public var zones: [String]
    public var resetStrategy: String
    public var restartInterlock: String
}

public struct DriveParameter: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var value: String
    public var purpose: String
}

public struct ProjectDriveConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var driveFamily: String
    public var motor: String
    public var networkNode: String
    public var controlMode: String
    public var parameters: [DriveParameter]
}

public struct ProjectInstrument: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var kind: String
    public var processRange: String
    public var signal: ProjectIOSignalType
    public var ioTag: String
    public var failBehavior: String
    public var calibrationPoints: [Double]
}

public struct PneumaticBranch: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var source: String
    public var manifold: String
    public var valve: String
    public var actuator: String
    public var feedback: [String]
    public var normalState: String
}

public struct PIDProjectConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var processVariable: String
    public var controlledVariable: String
    public var setpointTag: String
    public var outputTag: String
    public var engineeringRange: String
    public var gains: String
    public var updatePeriodMilliseconds: Int
    public var strategy: String
}

public enum ProjectAlarmPriority: String, Codable, CaseIterable, Sendable { case advisory, warning, high, critical }
public struct ProjectAlarmDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var priority: ProjectAlarmPriority
    public var condition: String
    public var message: String
    public var delaySeconds: Double
    public var latching: Bool
    public var response: String
}

public struct LadderRoutineDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(program).\(routine)" }
    public var task: String
    public var program: String
    public var routine: String
    public var purpose: String
    public var rungSummaries: [String]
    public var primaryTags: [String]
}

public struct HeroMachineControlsProject: Identifiable, Codable, Equatable, Sendable {
    public var id: String { machine.rawValue }
    public var machine: PlayableMachineKind
    public var projectNumber: String
    public var projectTitle: String
    public var controllerName: String
    public var controllerFamily: String
    public var firmwareMajor: Int
    public var drawings: [HeroElectricalDrawing]
    public var racks: [PLCRackConfiguration]
    public var ioPoints: [ProjectIOPoint]
    public var ethernetNodes: [EtherNetIPNode]
    public var safety: SafetyNetworkConfiguration
    public var drives: [ProjectDriveConfiguration]
    public var instruments: [ProjectInstrument]
    public var pneumatics: [PneumaticBranch]
    public var pidLoops: [PIDProjectConfiguration]
    public var alarms: [ProjectAlarmDefinition]
    public var ladderRoutines: [LadderRoutineDefinition]

    public var configuredModuleCount: Int { racks.reduce(0) { $0 + $1.modules.count } }
    public var remoteRackCount: Int { racks.filter { $0.adapterCatalog != nil }.count }
    public var ioCount: Int { ioPoints.count }
}

private struct MachineControlsSeed {
    var number: String
    var title: String
    var cpu: String
    var remoteAreas: [String]
    var discreteInputs: [(String,String)]
    var discreteOutputs: [(String,String)]
    var analogInputs: [(String,String,String)]
    var analogOutputs: [(String,String,String)]
    var drives: [(String,String,String,String)]
    var safetyInputs: [String]
    var pneumaticBranches: [(String,String,String)]
    var pids: [(String,String,String,String)]
    var specialNetworkNodes: [(String,String)]
    var alarmThemes: [(String,ProjectAlarmPriority,String)]
    var routineThemes: [(String,String)]
}

public enum HeroMachineControlsProjectCatalog {
    public static let all: [HeroMachineControlsProject] = PlayableMachineKind.allCases.map(build)

    public static func project(for machine: PlayableMachineKind) -> HeroMachineControlsProject {
        all.first { $0.machine == machine }!
    }

    private static func build(_ machine: PlayableMachineKind) -> HeroMachineControlsProject {
        let s = seed(machine)
        let controller = "PLC-\(s.number)"
        let mainRack = mainChassis(controller: controller, cpu: s.cpu, hasAnalog: !s.analogInputs.isEmpty || !s.analogOutputs.isEmpty)
        let remoteRacks = s.remoteAreas.enumerated().map { idx, area in remoteRack(machine: machine, index: idx + 1, area: area, hasAnalog: idx == 0 && (!s.analogInputs.isEmpty || !s.analogOutputs.isEmpty)) }
        let racks = [mainRack] + remoteRacks
        let io = makeIO(seed:s, racks:racks)
        let instruments = makeInstruments(seed:s, io:io)
        let drives = makeDrives(seed:s)
        let nodes = makeNetwork(seed:s, controller:controller, remoteRacks:remoteRacks, drives:drives)
        let safety = makeSafety(seed:s)
        let pneumatics = s.pneumaticBranches.map { PneumaticBranch(tag:$0.0,source:"Plant Air 80 psi",manifold:"VM-01",valve:$0.1,actuator:$0.2,feedback:["\($0.0)_EXT","\($0.0)_RET"],normalState:"de-energized safe state") }
        let pids = s.pids.map { PIDProjectConfiguration(tag:$0.0,processVariable:$0.1,controlledVariable:$0.2,setpointTag:"\($0.0)_SP",outputTag:$0.3,engineeringRange:rangeForPV($0.1),gains:defaultGains(machine:machine, tag:$0.0),updatePeriodMilliseconds:100,strategy:pidStrategy(machine:machine, tag:$0.0)) }
        let alarms = makeAlarms(seed:s)
        let routines = makeRoutines(seed:s, drives:drives, pids:pids)
        let drawings = makeDrawings(seed:s, io:io, drives:drives, pids:pids, pneumatics:pneumatics)
        return .init(machine:machine,projectNumber:s.number,projectTitle:s.title,controllerName:controller,controllerFamily:s.cpu,firmwareMajor:35,drawings:drawings,racks:racks,ioPoints:io,ethernetNodes:nodes,safety:safety,drives:drives,instruments:instruments,pneumatics:pneumatics,pidLoops:pids,alarms:alarms,ladderRoutines:routines)
    }

    private static func mainChassis(controller:String,cpu:String,hasAnalog:Bool)->PLCRackConfiguration {
        var modules:[PLCHardwareModule] = [
            .init(rack:"LOCAL",slot:0,family:"ControlLogix 5580",catalog:cpu,purpose:.controller,channelCount:0,description:"Main controller"),
            .init(rack:"LOCAL",slot:1,family:"ControlLogix EtherNet/IP",catalog:"1756-EN2TR",purpose:.ethernetBridge,channelCount:0,description:"Plant EtherNet/IP bridge"),
            .init(rack:"LOCAL",slot:2,family:"ControlLogix Digital",catalog:"1756-IB16",purpose:.digitalInput,channelCount:16,description:"Local 24 VDC inputs"),
            .init(rack:"LOCAL",slot:3,family:"ControlLogix Digital",catalog:"1756-OB16E",purpose:.digitalOutput,channelCount:16,description:"Local protected 24 VDC outputs"),
            .init(rack:"LOCAL",slot:4,family:"ControlLogix Safety",catalog:"1756-IB16S",purpose:.safetyInput,channelCount:16,description:"Dual-channel safety inputs"),
            .init(rack:"LOCAL",slot:5,family:"ControlLogix Safety",catalog:"1756-OBV8S",purpose:.safetyOutput,channelCount:8,description:"Safety outputs")
        ]
        if hasAnalog { modules.append(.init(rack:"LOCAL",slot:6,family:"ControlLogix Analog",catalog:"1756-IF8I",purpose:.analogInput,channelCount:8,description:"Isolated analog input")) }
        return .init(rackName:"LOCAL",location:"Main Control Panel",chassisFamily:"1756-A10",adapterCatalog:nil,networkAddress:nil,modules:modules)
    }

    private static func remoteRack(machine:PlayableMachineKind,index:Int,area:String,hasAnalog:Bool)->PLCRackConfiguration {
        let rack="RIO\(index)"
        var modules:[PLCHardwareModule] = [
            .init(rack:rack,slot:0,family:"Compact 5000 EtherNet/IP",catalog:"5069-AENTR",purpose:.ethernetBridge,channelCount:0,description:"Remote rack adapter"),
            .init(rack:rack,slot:1,family:"Compact 5000 Digital",catalog:"5069-IB16",purpose:.digitalInput,channelCount:16,description:"Field 24 VDC inputs"),
            .init(rack:rack,slot:2,family:"Compact 5000 Digital",catalog:"5069-OB16",purpose:.digitalOutput,channelCount:16,description:"Field 24 VDC outputs")
        ]
        if hasAnalog { modules += [
            .init(rack:rack,slot:3,family:"Compact 5000 Analog",catalog:"5069-IF8",purpose:.analogInput,channelCount:8,description:"Field analog inputs"),
            .init(rack:rack,slot:4,family:"Compact 5000 Analog",catalog:"5069-OF8",purpose:.analogOutput,channelCount:8,description:"Field analog outputs")
        ] }
        if [.servoConveyor,.asrsCrane,.roboticPalletizer,.injectionMoldingCell].contains(machine) {
            modules.append(.init(rack:rack,slot:modules.count,family:"Compact 5000 Safety",catalog:"5069-IB8S",purpose:.safetyInput,channelCount:8,description:"Remote safety input"))
        }
        return .init(rackName:rack,location:area,chassisFamily:"5069 Compact 5000",adapterCatalog:"5069-AENTR",networkAddress:"10.\(machineIndex(machine)+10).\(index).20",modules:modules)
    }

    private static func makeIO(seed s:MachineControlsSeed,racks:[PLCRackConfiguration])->[ProjectIOPoint] {
        let remote=racks.dropFirst().first?.rackName ?? "LOCAL"
        var result:[ProjectIOPoint]=[]
        for (i,p) in s.discreteInputs.enumerated() { result.append(.init(tag:p.0,address:"\(remote):1:I.Data[\(i)]",direction:.input,signalType:.digital24VDC,fieldDevice:p.1,rack:remote,slot:1,channel:i,description:p.1,engineeringRange:nil)) }
        for (i,p) in s.discreteOutputs.enumerated() { result.append(.init(tag:p.0,address:"\(remote):2:O.Data[\(i)]",direction:.output,signalType:.digital24VDC,fieldDevice:p.1,rack:remote,slot:2,channel:i,description:p.1,engineeringRange:nil)) }
        for (i,p) in s.analogInputs.enumerated() { result.append(.init(tag:p.0,address:"\(remote):3:I.Ch\(i)Data",direction:.input,signalType:signalType(for:p.2),fieldDevice:p.1,rack:remote,slot:3,channel:i,description:p.1,engineeringRange:p.2)) }
        for (i,p) in s.analogOutputs.enumerated() { result.append(.init(tag:p.0,address:"\(remote):4:O.Ch\(i)Data",direction:.output,signalType:.analog4to20mA,fieldDevice:p.1,rack:remote,slot:4,channel:i,description:p.1,engineeringRange:p.2)) }
        for (i,tag) in s.safetyInputs.enumerated() { result.append(.init(tag:tag,address:"LOCAL:4:I.SafetyData[\(i)]",direction:.input,signalType:.safetyDualChannel,fieldDevice:tag,rack:"LOCAL",slot:4,channel:i,description:"Safety input — \(tag)",engineeringRange:nil)) }
        return result
    }

    private static func makeInstruments(seed s:MachineControlsSeed,io:[ProjectIOPoint])->[ProjectInstrument] {
        s.analogInputs.enumerated().map { i,p in .init(tag:p.1,kind:instrumentKind(p.0),processRange:p.2,signal:signalType(for:p.2),ioTag:p.0,failBehavior:i.isMultiple(of:2) ? "fail-low / bad quality":"fail-high / bad quality",calibrationPoints:[0,25,50,75,100]) }
    }

    private static func makeDrives(seed s:MachineControlsSeed)->[ProjectDriveConfiguration] {
        s.drives.enumerated().map { idx,d in
            let servo=d.1.lowercased().contains("servo")
            return .init(tag:d.0,driveFamily:servo ? "Kinetix 5700":"PowerFlex 755",motor:d.2,networkNode:d.0,controlMode:servo ? "CIP Motion position/velocity":"EtherNet/IP speed reference",parameters:[
                .init(name:"Motor NP Volts",value:servo ? "460 V":"480 V",purpose:"motor model"),
                .init(name:"Motor NP FLA",value:d.3,purpose:"overload protection"),
                .init(name:"Accel Time",value:servo ? "0.30 s":"3.0 s",purpose:"mechanical acceleration"),
                .init(name:"Decel Time",value:servo ? "0.30 s":"4.0 s",purpose:"controlled stopping"),
                .init(name:"Command Source",value:"EtherNet/IP",purpose:"PLC ownership"),
                .init(name:"Fault Action",value:idx.isMultiple(of:2) ? "Coast":"Ramp",purpose:"machine-specific safe response")
            ])
        }
    }

    private static func makeNetwork(seed s:MachineControlsSeed,controller:String,remoteRacks:[PLCRackConfiguration],drives:[ProjectDriveConfiguration])->[EtherNetIPNode] {
        var nodes:[EtherNetIPNode] = [
            .init(name:controller,deviceType:"Controller",catalogFamily:s.cpu,ipAddress:"10.10.0.10",parent:"SW-CORE",rpiMilliseconds:nil,role:"machine controller"),
            .init(name:"SW-CORE",deviceType:"Managed switch",catalogFamily:"Stratix 5700",ipAddress:"10.10.0.2",parent:nil,rpiMilliseconds:nil,role:"machine cell network")
        ]
        for rack in remoteRacks { nodes.append(.init(name:rack.rackName,deviceType:"Remote I/O",catalogFamily:rack.adapterCatalog ?? "5069-AENTR",ipAddress:rack.networkAddress ?? "0.0.0.0",parent:"SW-CORE",rpiMilliseconds:20,role:rack.location)) }
        for (i,d) in drives.enumerated() { nodes.append(.init(name:d.tag,deviceType:d.driveFamily.contains("Kinetix") ? "Servo drive":"VFD",catalogFamily:d.driveFamily,ipAddress:"10.10.10.\(40+i)",parent:"SW-CORE",rpiMilliseconds:d.driveFamily.contains("Kinetix") ? 2:20,role:d.motor)) }
        for (i,n) in s.specialNetworkNodes.enumerated() { nodes.append(.init(name:n.0,deviceType:n.1,catalogFamily:n.1,ipAddress:"10.10.20.\(50+i)",parent:"SW-CORE",rpiMilliseconds:20,role:"machine-specific EtherNet/IP device")) }
        return nodes
    }

    private static func makeSafety(seed s:MachineControlsSeed)->SafetyNetworkConfiguration {
        .init(safetyController:"GuardLogix integrated safety",safetyNetwork:"CIP Safety",inputDevices:s.safetyInputs,outputDevices:["STO_A","STO_B","SAFE_AIR_DUMP"],zones:Array(Set(s.remoteAreas.map { $0.uppercased() })).sorted(),resetStrategy:"manual monitored reset outside hazard zone",restartInterlock:"Safety reset restores permission only; normal PLC sequence must issue restart")
    }

    private static func makeAlarms(seed s:MachineControlsSeed)->[ProjectAlarmDefinition] {
        var alarms:[ProjectAlarmDefinition] = s.alarmThemes.map { a in ProjectAlarmDefinition(tag:a.0,priority:a.1,condition:a.2,message:"\(a.0.replacingOccurrences(of:"_",with:" ")) — investigate \(a.2)",delaySeconds:a.1 == .critical ? 0.25:2,latching:a.1 == .critical,response:a.1 == .critical ? "stop affected equipment, preserve first-out evidence":"operator acknowledge and troubleshoot") }
        alarms.append(ProjectAlarmDefinition(tag:"COMM_RIO_LOSS",priority:ProjectAlarmPriority.high,condition:"remote rack connection not running",message:"Remote I/O connection lost",delaySeconds:1,latching:false,response:"check switch port, cable, adapter power and connection diagnostics"))
        return alarms
    }

    private static func makeRoutines(seed s:MachineControlsSeed,drives:[ProjectDriveConfiguration],pids:[PIDProjectConfiguration])->[LadderRoutineDefinition] {
        var routines:[LadderRoutineDefinition] = [
            .init(task:"Continuous",program:"MAIN",routine:"R00_IO_Conditioning",purpose:"Map raw module data to named machine tags",rungSummaries:["Copy digital input image into debounced field tags","Scale raw analog channels into engineering units","Generate channel quality bits from module connection/status"],primaryTags:Array(s.discreteInputs.prefix(4).map{$0.0}) + Array(s.analogInputs.prefix(2).map{$0.0})),
            .init(task:"Continuous",program:"MAIN",routine:"R10_Permissives",purpose:"Build safety, process and equipment permissives",rungSummaries:["Safety_OK requires all safety zones healthy","Machine_Permissive combines safety, utilities and communications","Each actuator gets explicit permissive and interlock reason bits"],primaryTags:s.safetyInputs + ["Machine_Permissive"]),
            .init(task:"Continuous",program:"MAIN",routine:"R20_Sequence",purpose:"Machine-specific operating sequence",rungSummaries:s.routineThemes.map{"\($0.0): \($0.1)"},primaryTags:s.routineThemes.map{$0.0})
        ]
        if !drives.isEmpty { routines.append(.init(task:"Continuous",program:"MOTION_DRIVES",routine:"R30_DriveControl",purpose:"Networked drive command/status handling",rungSummaries:drives.map{"\($0.tag): verify ready/permissive, issue command, compare run feedback and speed"},primaryTags:drives.map{$0.tag})) }
        if !pids.isEmpty { routines.append(.init(task:"Periodic_100ms",program:"PROCESS",routine:"R40_PID",purpose:"Closed-loop process control",rungSummaries:pids.map{"\($0.tag): \($0.processVariable) → \($0.outputTag), \($0.strategy)"},primaryTags:pids.flatMap{[$0.processVariable,$0.setpointTag,$0.outputTag]})) }
        routines.append(.init(task:"Continuous",program:"MAIN",routine:"R90_AlarmsDiagnostics",purpose:"First-out alarms and maintenance diagnostics",rungSummaries:["Capture first-out trip cause before sequence reset","Alarm PLC/device communications separately from process faults","Expose permissive blocker bits to HMI and Flight Recorder"],primaryTags:["FirstOutCode","Machine_Permissive","COMM_RIO_LOSS"]))
        return routines
    }

    private static func makeDrawings(seed s:MachineControlsSeed,io:[ProjectIOPoint],drives:[ProjectDriveConfiguration],pids:[PIDProjectConfiguration],pneumatics:[PneumaticBranch])->[HeroElectricalDrawing] {
        let base=s.number
        return [
            .init(sheetNumber:"E-\(base)-101",title:"One-Line and Control Power",discipline:.power,zones:["A1","A2","B1","B2"],referencedTags:drives.map{$0.tag},description:"480 VAC distribution, 24 VDC control power, branch protection and drive feeders for \(s.title)."),
            .init(sheetNumber:"E-\(base)-201",title:"Safety and Hardwired Control",discipline:.safety,zones:["A1","A3","B2","C4"],referencedTags:s.safetyInputs,description:"Dual-channel safety devices, STO outputs, monitored reset and hardwired permissive interfaces."),
            .init(sheetNumber:"E-\(base)-301",title:"PLC Rack and Field I/O",discipline:.plcIO,zones:["A1","B2","C3","D4"],referencedTags:io.map{$0.tag},description:"Chassis slots, remote rack channels, field terminals and named I/O assignments."),
            .init(sheetNumber:"E-\(base)-401",title:"EtherNet/IP Device Tree",discipline:.network,zones:["A1","A2","B1","B2"],referencedTags:drives.map{$0.tag}+s.specialNetworkNodes.map{$0.0},description:"Managed switch topology, remote I/O, drives and machine-specific EtherNet/IP nodes."),
            .init(sheetNumber:"E-\(base)-501",title:"Instrumentation and Process Loops",discipline:.instrumentation,zones:["A1","B2","C3","D4"],referencedTags:s.analogInputs.map{$0.1}+pids.map{$0.tag},description:"Instrument power, analog loops, shielding, scaling ranges and PID loop references."),
            .init(sheetNumber:"E-\(base)-601",title:"Pneumatic / Actuator Interfaces",discipline:.pneumatics,zones:["A1","B2","C3"],referencedTags:pneumatics.map{$0.tag},description:pneumatics.isEmpty ? "Actuator interface reference; this machine has no primary pneumatic branch in the authored controls package.":"Valve manifold, air preparation, solenoid coils, cylinders and end-of-stroke feedback."),
            .init(sheetNumber:"E-\(base)-701",title:"Panel Layout and Terminal Plan",discipline:.panelLayout,zones:["A1","B2","C3","D4"],referencedTags:["LOCAL","RIO1"],description:"Backplate footprint, DIN rails, wire duct, terminal strips and field cable landing plan.")
        ]
    }

    private static func signalType(for range:String)->ProjectIOSignalType {
        let r=range.lowercased(); if r.contains("thermocouple") || r.contains("°c tc") { return .thermocouple }; if r.contains("rtd") { return .rtd }; if r.contains("0-10") { return .analog0to10V }; return .analog4to20mA
    }
    private static func instrumentKind(_ tag:String)->String { let t=tag.uppercased(); if t.contains("TEMP")||t.hasPrefix("TT") { return "temperature transmitter" }; if t.contains("FLOW")||t.hasPrefix("FT") { return "flow transmitter" }; if t.contains("LEVEL")||t.hasPrefix("LT") { return "level transmitter" }; if t.contains("PH") { return "pH transmitter" }; if t.contains("COND") { return "conductivity transmitter" }; if t.contains("PRESS")||t.hasPrefix("PT") { return "pressure transmitter" }; return "process transmitter" }
    private static func rangeForPV(_ tag:String)->String { tag.uppercased().contains("TEMP") ? "0…250 °C" : tag.uppercased().contains("PRESS") ? "0…150 psi" : "0…100 %" }
    private static func defaultGains(machine:PlayableMachineKind,tag:String)->String { switch machine { case .industrialOven,.injectionMoldingCell,.htstPasteurizer:"Kp 2.4, Ki 0.12/s, Kd 4.0 s"; case .pressureSkid,.pumpStation,.chilledWaterPlant:"Kp 1.8, Ki 0.25/s, Kd 0.2 s"; default:"Kp 1.2, Ki 0.15/s, Kd 0.0 s" } }
    private static func pidStrategy(machine:PlayableMachineKind,tag:String)->String { switch machine { case .cleanroomPressureSystem,.dataCenterCooling,.bioreactor:"cascade / supervisory with output limiting"; case .boilerSteamPlant:"cross-limited permissive-aware control"; case .htstPasteurizer:"divert-safe temperature control"; default:"PID with bumpless manual/auto and output limits" } }
    private static func machineIndex(_ machine:PlayableMachineKind)->Int { PlayableMachineKind.allCases.firstIndex(of:machine) ?? 0 }

    private static func seed(_ m:PlayableMachineKind)->MachineControlsSeed {
        switch m {
        case .packagingCell: return .init(number:"PKG01",title:"Packaging Cell Controls Project",cpu:"1756-L83E",remoteAreas:["Infeed Conveyor","Case Transfer"],discreteInputs:[("PE_Infeed","PE101 infeed photoeye"),("PE_Transfer","PE203 transfer photoeye"),("GuardClosed","GS101 guard switch"),("OL_Conv","OL101 conveyor overload")],discreteOutputs:[("Conv_Run","M101 conveyor run"),("Stopper_Ext","YV101 stopper solenoid"),("Reject_Ext","YV102 reject solenoid")],analogInputs:[("AirPressure","PT101 air pressure","0-150 psi")],analogOutputs:[],drives:[("VFD101","VFD conveyor","M101","4.2 A")],safetyInputs:["EStop101","Guard101_A","Guard101_B"],pneumaticBranches:[("CY101","YV101","Case stopper"),("CY102","YV102","Reject gate")],pids:[],specialNetworkNodes:[("HMI101","PanelView Plus")],alarmThemes:[("CASE_JAM",.high,"PE203 blocked > 3 s"),("LOW_AIR",.warning,"AirPressure < 70 psi")],routineThemes:[("Step_Load","wait for infeed case"),("Step_Transfer","run conveyor until PE203"),("Step_Release","pulse stopper and verify clear")])
        case .pressureSkid: return .init(number:"PRS01",title:"Pressure and Flow Skid Controls Project",cpu:"1756-L85E",remoteAreas:["Pump Skid"],discreteInputs:[("PumpReady","P101 VFD ready"),("ValveOpenFB","FV101 open feedback")],discreteOutputs:[("PumpRunCmd","P101 run command")],analogInputs:[("PressurePV","PT101 suction/discharge pressure","0-150 psi"),("FlowPV","FT101 process flow","0-250 gpm")],analogOutputs:[("ValveCmd","FV101 valve command","0-100 %")],drives:[("VFD101","VFD pump","P101","18.0 A")],safetyInputs:["EStop101","LowLevelTrip"],pneumaticBranches:[("FV101","I/P-101","Control valve")],pids:[("PIC101","PressurePV","ValveCmd","ValveCmd"),("FIC101","FlowPV","PumpSpeedCmd","PumpSpeedCmd")],specialNetworkNodes:[("HMI101","PanelView Plus")],alarmThemes:[("PRESS_HIHI",.critical,"PressurePV > 140 psi"),("FLOW_LOW",.high,"FlowPV < 30 gpm while running")],routineThemes:[("Skid_Start","prove suction and valve permissives"),("Pressure_Control","enable PIC101 after pump proof"),("Skid_Stop","ramp pump and close valve")])
        case .servoConveyor: return .init(number:"SRV01",title:"Servo Conveyor Controls Project",cpu:"1756-L85ES",remoteAreas:["Index Conveyor","Guard Zone"],discreteInputs:[("PartAtNest","PE301 nest sensor"),("BrakeFB","BRK301 brake feedback")],discreteOutputs:[("BrakeRelease","YV301 servo brake release")],analogInputs:[("BeltTension","LT301 belt tension load cell","0-500 lbf")],analogOutputs:[],drives:[("K5700_X","servo axis","M301","7.5 A")],safetyInputs:["EStop301","Gate301_A","Gate301_B","STO301_FB"],pneumaticBranches:[("BRK301","YV301","Pneumatic brake")],pids:[],specialNetworkNodes:[("ENC301","Absolute encoder")],alarmThemes:[("AXIS_FOLLOW_ERR",.critical,"position following error > limit"),("BELT_TENSION_HI",.warning,"BeltTension > 425 lbf")],routineThemes:[("Home_Axis","establish absolute position and brake state"),("Index_Move","execute indexed motion profile"),("Nest_Verify","compare commanded and actual position with part sensor")])
        case .pumpStation: return .init(number:"PMP01",title:"Duplex Pump Station Controls Project",cpu:"1756-L83E",remoteAreas:["Wet Well","Pump MCC"],discreteInputs:[("P1Ready","Pump 1 ready"),("P2Ready","Pump 2 ready"),("HHFloat","High-high float")],discreteOutputs:[("P1Run","Pump 1 command"),("P2Run","Pump 2 command")],analogInputs:[("WetWellLevel","LT401 wet-well level","0-20 ft"),("DischargePress","PT401 discharge pressure","0-100 psi")],analogOutputs:[],drives:[("VFD401","VFD pump","P401","32 A"),("VFD402","VFD pump","P402","32 A")],safetyInputs:["EStop401","DryWellFlood"],pneumaticBranches:[],pids:[("LIC401","WetWellLevel","LeadPumpSpeed","LeadPumpSpeed")],specialNetworkNodes:[("RTU401","Telemetry gateway")],alarmThemes:[("LEVEL_HIHI",.critical,"WetWellLevel > 18 ft"),("PUMP_FAIL_START",.high,"run command without run feedback")],routineThemes:[("LeadLag","rotate lead pump by runtime"),("Level_Control","stage lag pump on high level"),("Emergency_Pump","HHFloat overrides normal staging")])
        case .airHandlingUnit: return .init(number:"AHU01",title:"Air Handling Unit Controls Project",cpu:"1756-L82E",remoteAreas:["AHU Supply Section"],discreteInputs:[("SFanProof","supply fan proof"),("FreezeStat","freezestat")],discreteOutputs:[("SFanEnable","supply fan enable")],analogInputs:[("SAT","TT501 supply-air temperature","-20-120 °F"),("DuctSP","PT501 duct static pressure","0-5 inH2O")],analogOutputs:[("CHWValve","CV501 chilled-water valve","0-100 %"),("OADamper","DM501 outside-air damper","0-100 %")],drives:[("VFD501","VFD supply fan","M501","22 A")],safetyInputs:["Smoke501","EStop501"],pneumaticBranches:[],pids:[("TIC501","SAT","CHWValve","CHWValve"),("PIC501","DuctSP","FanSpeed","FanSpeed")],specialNetworkNodes:[("BAS501","BAS EtherNet/IP gateway")],alarmThemes:[("FREEZE_TRIP",.critical,"FreezeStat false"),("STATIC_LOW",.warning,"DuctSP below setpoint with fan at high speed")],routineThemes:[("AHU_Enable","prove smoke/freezestat and occupancy"),("Economizer","position OA damper from mode"),("Fan_Static","control fan speed from duct pressure")])
        case .batchMixingTank: return .init(number:"BAT01",title:"Batch Mixing Tank Controls Project",cpu:"1756-L83E",remoteAreas:["Tank Deck"],discreteInputs:[("LidClosed","tank lid switch"),("AgitatorReady","agitator drive ready")],discreteOutputs:[("InletValve","XV601 inlet valve"),("DrainValve","XV602 drain valve")],analogInputs:[("TankLevel","LT601 tank level","0-100 %"),("BatchWeight","WT601 load cells","0-5000 lb")],analogOutputs:[],drives:[("VFD601","VFD agitator","M601","14 A")],safetyInputs:["EStop601","LidInterlock601"],pneumaticBranches:[("XV601","YV601","Inlet valve"),("XV602","YV602","Drain valve")],pids:[],specialNetworkNodes:[("Scale601","EtherNet/IP weigh transmitter")],alarmThemes:[("BATCH_OVERWEIGHT",.critical,"BatchWeight > recipe max"),("AGITATOR_OVERLOAD",.high,"drive current above limit")],routineThemes:[("Charge","open recipe inlet valves to target weight"),("Mix","run agitator for recipe time/speed"),("Discharge","open drain after mix complete")])
        case .industrialOven: return .init(number:"OVN01",title:"Industrial Oven Controls Project",cpu:"1756-L84ES",remoteAreas:["Oven Heater Panel","Exhaust Section"],discreteInputs:[("AirflowProof","exhaust airflow switch"),("DoorClosed","oven door limit")],discreteOutputs:[("HeatEnable","heater contactor enable")],analogInputs:[("ZoneTemp","TT701 zone thermocouple","0-500 °C thermocouple"),("ExhaustTemp","TT702 exhaust thermocouple","0-500 °C thermocouple")],analogOutputs:[("HeatDemand","HTR701 power controller demand","0-100 %")],drives:[("VFD701","VFD circulation fan","M701","12 A")],safetyInputs:["EStop701","Door701_A","Door701_B","AirflowTrip701"],pneumaticBranches:[],pids:[("TIC701","ZoneTemp","HeatDemand","HeatDemand")],specialNetworkNodes:[("SCR701","EtherNet/IP heater power controller")],alarmThemes:[("OVERTEMP",.critical,"ZoneTemp > 450 °C"),("AIRFLOW_LOSS",.critical,"HeatEnable and not AirflowProof")],routineThemes:[("PrePurge","run circulation/exhaust before heat enable"),("Heat_Control","enable TIC701 only with airflow proof"),("CoolDown","hold fans on after heat removal")])
        case .roboticPalletizer: return .init(number:"RBT01",title:"Robotic Palletizer Controls Project",cpu:"1756-L84ES",remoteAreas:["Robot Fence","End Effector"],discreteInputs:[("CaseReady","case at pick sensor"),("PalletReady","pallet present")],discreteOutputs:[("VacuumOn","vacuum ejector command")],analogInputs:[("VacuumLevel","PT801 vacuum transmitter","-15-0 psi")],analogOutputs:[],drives:[],safetyInputs:["EStop801","Gate801_A","Gate801_B","RobotSafeMove"],pneumaticBranches:[("VAC801","YV801","Vacuum gripper")],pids:[],specialNetworkNodes:[("ROBOT801","Robot controller"),("VM801","EtherNet/IP valve manifold")],alarmThemes:[("VACUUM_LOW",.high,"VacuumLevel > -5 psi during pick"),("ROBOT_NOT_READY",.high,"robot interface not auto-ready")],routineThemes:[("Handshake","exchange ready/busy/complete with robot"),("Pick_Request","present case pick request"),("Place_Confirm","verify pallet index and robot complete")])
        case .wastewaterLiftStation: return .init(number:"WWL01",title:"Wastewater Lift Station Controls Project",cpu:"1756-L82E",remoteAreas:["Wet Well","Pump Gallery"],discreteInputs:[("P1RunFB","pump 1 run feedback"),("P2RunFB","pump 2 run feedback"),("HHFloat","independent high-high float")],discreteOutputs:[("P1Enable","pump 1 enable"),("P2Enable","pump 2 enable")],analogInputs:[("LevelPV","LT901 ultrasonic level","0-25 ft"),("HeaderPress","PT901 header pressure","0-80 psi")],analogOutputs:[],drives:[("VFD901","VFD pump","P901","28 A"),("VFD902","VFD pump","P902","28 A")],safetyInputs:["EStop901","GasAlarm901"],pneumaticBranches:[],pids:[("LIC901","LevelPV","LeadPumpSpeed","LeadPumpSpeed")],specialNetworkNodes:[("SCADA901","Radio/SCADA gateway")],alarmThemes:[("LEVEL_HH",.critical,"LevelPV > 23 ft"),("PUMP_SHORT_CYCLE",.warning,"starts per hour above threshold")],routineThemes:[("LeadLag","rotate pumps by starts/runtime"),("WetWell_Control","stage pumps from level bands"),("Fallback_Float","run both pumps from HH float on transmitter failure")])
        case .refrigerationRack: return .init(number:"REF01",title:"Refrigeration Rack Controls Project",cpu:"1756-L83E",remoteAreas:["Compressor Rack","Condenser"],discreteInputs:[("Comp1Ready","compressor 1 ready"),("OilProof","oil differential proof")],discreteOutputs:[("LiquidSolenoid","LSV1001 liquid solenoid")],analogInputs:[("SuctionPress","PT1001 suction pressure","0-150 psi"),("DischargePress","PT1002 discharge pressure","0-500 psi"),("DischargeTemp","TT1001 discharge temp","0-250 °F")],analogOutputs:[],drives:[("VFD1001","VFD lead compressor","M1001","48 A")],safetyInputs:["EStop1001","HighPressCutout"],pneumaticBranches:[],pids:[("PIC1001","SuctionPress","CompressorCapacity","CompressorCapacity")],specialNetworkNodes:[("EPR1001","Electronic pressure regulator")],alarmThemes:[("HEAD_PRESS_HI",.critical,"DischargePress > 425 psi"),("OIL_PROOF_LOSS",.critical,"compressor running without OilProof")],routineThemes:[("Rack_Stage","stage compressors from suction pressure"),("Condenser_Control","modulate condenser capacity"),("Defrost_Interlock","coordinate solenoids with defrost state")])
        case .boilerSteamPlant: return .init(number:"BLR01",title:"Boiler and Steam Plant Controls Project",cpu:"1756-L85ES",remoteAreas:["Burner Front","Boiler Drum"],discreteInputs:[("FlameProof","flame scanner proof"),("GasPressOK","gas pressure permissive")],discreteOutputs:[("PilotValve","PV1101 pilot valve"),("MainFuelValve","FV1101 fuel safety valve")],analogInputs:[("SteamPress","PT1101 steam pressure","0-250 psi"),("O2PV","AT1101 flue O2","0-21 %")],analogOutputs:[("FuelCmd","FCV1101 fuel valve","0-100 %"),("AirCmd","FD1101 forced-draft damper","0-100 %")],drives:[("VFD1101","VFD forced-draft fan","M1101","36 A")],safetyInputs:["EStop1101","LowWaterCutout","HighSteamPressure","FlameFail"],pneumaticBranches:[],pids:[("PIC1101","SteamPress","FuelCmd","FuelCmd"),("AIC1101","O2PV","AirCmd","AirCmd")],specialNetworkNodes:[("BMS1101","Burner management interface")],alarmThemes:[("FLAME_FAIL",.critical,"fuel demand with no FlameProof"),("LOW_WATER",.critical,"LowWaterCutout active")],routineThemes:[("Purge","prove airflow for purge time"),("Ignition","pilot trial then main flame proof"),("CrossLimit","cross-limit fuel and air demand")])
        case .cncCoolantCell: return .init(number:"CNC01",title:"CNC Coolant Cell Controls Project",cpu:"1756-L82E",remoteAreas:["Coolant Skid"],discreteInputs:[("MachineDemand","CNC coolant request"),("FilterDPHigh","filter DP switch")],discreteOutputs:[("CoolantEnable","coolant enable")],analogInputs:[("FlowPV","FT1201 coolant flow","0-100 gpm"),("PressurePV","PT1201 coolant pressure","0-150 psi")],analogOutputs:[],drives:[("VFD1201","VFD coolant pump","P1201","16 A")],safetyInputs:["EStop1201"],pneumaticBranches:[],pids:[("PIC1201","PressurePV","PumpSpeed","PumpSpeed")],specialNetworkNodes:[("CNC1201","CNC machine interface")],alarmThemes:[("COOLANT_FLOW_LOW",.high,"FlowPV below minimum with demand"),("FILTER_DP_HIGH",.warning,"FilterDPHigh true")],routineThemes:[("Demand_Interface","accept CNC coolant request"),("Pressure_Control","run PIC1201 while demand active"),("Flush_Cycle","periodic filter flush sequence")])
        case .cleanroomPressureSystem: return .init(number:"CLN01",title:"Cleanroom Pressure Controls Project",cpu:"1756-L83E",remoteAreas:["Cleanroom AHU","Room Pressure Nodes"],discreteInputs:[("Door101","airlock door status"),("FanProof","supply fan proof")],discreteOutputs:[("FanEnable","supply fan enable")],analogInputs:[("RoomDP","PDT1301 room differential pressure","-0.25-0.25 inH2O"),("SupplyFlow","FT1301 supply airflow","0-5000 cfm")],analogOutputs:[("DamperCmd","DM1301 VAV damper","0-100 %")],drives:[("VFD1301","VFD supply fan","M1301","20 A")],safetyInputs:["Smoke1301","EStop1301"],pneumaticBranches:[],pids:[("PIC1301","RoomDP","DamperCmd","DamperCmd")],specialNetworkNodes:[("EMS1301","Environmental monitoring system")],alarmThemes:[("ROOM_DP_LOW",.high,"RoomDP below validated limit"),("DOOR_INTERLOCK",.warning,"airlock doors simultaneously open")],routineThemes:[("Pressure_Mode","select occupied/unoccupied setpoints"),("Door_Compensation","temporarily bias flow on door transition"),("Pressure_PID","hold room cascade pressure")])
        case .asrsCrane: return .init(number:"ASR01",title:"AS/RS Crane Controls Project",cpu:"1756-L85ES",remoteAreas:["Crane Carriage","Aisle Safety"],discreteInputs:[("LoadPresent","load-on-fork sensor"),("ForkHome","fork home limit")],discreteOutputs:[("BrakeRelease","travel brake release")],analogInputs:[("LoadWeight","WT1401 carriage load","0-3000 lb")],analogOutputs:[],drives:[("K5700_X","servo travel axis","M1401","11 A"),("K5700_Y","servo lift axis","M1402","18 A")],safetyInputs:["EStop1401","AisleGate_A","AisleGate_B","SafeSpeed1401"],pneumaticBranches:[("BRK1401","YV1401","Travel brake")],pids:[],specialNetworkNodes:[("ENC1401","absolute position encoder"),("WCS1401","warehouse control gateway")],alarmThemes:[("POSITION_MISMATCH",.critical,"commanded bay differs from absolute position"),("LOAD_OVERWEIGHT",.high,"LoadWeight > 2800 lb")],routineThemes:[("Mission_Queue","accept/store retrieval mission"),("Travel_Move","coordinate X axis to aisle position"),("Lift_Move","coordinate Y axis and fork interlocks")])
        case .bottlingLine: return .init(number:"BOT01",title:"Bottling and Filling Line Controls Project",cpu:"1756-L85E",remoteAreas:["Filler","Capper","Reject Station"],discreteInputs:[("BottleInfeed","PE1501 bottle sensor"),("CapPresent","PE1502 cap sensor")],discreteOutputs:[("FillValve","YV1501 fill valve"),("RejectValve","YV1502 reject")],analogInputs:[("FillFlow","FT1501 product flow","0-100 lpm")],analogOutputs:[],drives:[("VFD1501","VFD filler conveyor","M1501","9 A")],safetyInputs:["EStop1501","Guard1501_A","Guard1501_B"],pneumaticBranches:[("FILL1501","YV1501","Fill valve"),("REJ1501","YV1502","Reject cylinder")],pids:[],specialNetworkNodes:[("VM1501","EtherNet/IP valve manifold"),("VISION1501","Vision inspector")],alarmThemes:[("FILL_SHORT",.high,"measured fill below recipe tolerance"),("CAP_MISSING",.warning,"CapPresent false at cap verification")],routineThemes:[("Pitch_Control","track bottle pitch from encoder/sensors"),("Fill_Window","open fill valve for recipe window"),("Inspect_Reject","correlate vision result to reject station")])
        case .cipSkid: return .init(number:"CIP01",title:"CIP Cleaning Skid Controls Project",cpu:"1756-L83E",remoteAreas:["CIP Skid"],discreteInputs:[("ReturnValveFB","return valve feedback"),("TankLow","CIP tank low switch")],discreteOutputs:[("RouteValve","XV1601 route valve")],analogInputs:[("ConductivityPV","AIT1601 conductivity","0-200 mS/cm"),("TempPV","TT1601 return temperature","0-100 °C"),("FlowPV","FT1601 return flow","0-400 gpm")],analogOutputs:[],drives:[("VFD1601","VFD CIP supply pump","P1601","40 A")],safetyInputs:["EStop1601"],pneumaticBranches:[("XV1601","YV1601","Route valve")],pids:[("TIC1601","TempPV","SteamValveCmd","SteamValveCmd")],specialNetworkNodes:[("VALVE1601","Sanitary valve manifold")],alarmThemes:[("COND_NOT_REACHED",.high,"ConductivityPV below recipe target"),("CIP_TEMP_LOW",.high,"TempPV below validated cleaning temperature")],routineThemes:[("Recipe_Steps","advance rinse/wash/rinse sequence"),("Route_Proof","verify valve path before pump"),("Chemical_EndPoint","use conductivity to detect phase transition")])
        case .compressedAirPlant: return .init(number:"AIR01",title:"Compressed Air Plant Controls Project",cpu:"1756-L83E",remoteAreas:["Compressor Room","Dryer Header"],discreteInputs:[("C1Ready","compressor 1 ready"),("DryerAlarm","dryer common alarm")],discreteOutputs:[("C1Enable","compressor 1 enable")],analogInputs:[("HeaderPress","PT1701 header pressure","0-175 psi"),("DewPoint","TT1701 pressure dew point","-100-50 °F")],analogOutputs:[],drives:[("VFD1701","VFD trim compressor","M1701","85 A")],safetyInputs:["EStop1701"],pneumaticBranches:[],pids:[("PIC1701","HeaderPress","TrimSpeed","TrimSpeed")],specialNetworkNodes:[("SEQ1701","Compressor sequencer"),("DRY1701","Dryer controller")],alarmThemes:[("HEADER_PRESS_LOW",.high,"HeaderPress < 90 psi"),("DEWPOINT_HIGH",.warning,"DewPoint above specification")],routineThemes:[("Compressor_Sequence","base-load/trim compressor selection"),("Pressure_Trim","control trim speed from header pressure"),("Unload_Protect","avoid short cycling and surge")])
        case .reverseOsmosisPlant: return .init(number:"RO01",title:"Reverse Osmosis Plant Controls Project",cpu:"1756-L84E",remoteAreas:["High Pressure Skid","Membrane Array"],discreteInputs:[("FeedPermissive","feed water permissive"),("HPPumpReady","high-pressure pump ready")],discreteOutputs:[("FlushValve","XV1801 flush valve")],analogInputs:[("FeedPress","PT1801 feed pressure","0-100 psi"),("ROPress","PT1802 membrane pressure","0-600 psi"),("PermeateFlow","FT1801 permeate flow","0-250 gpm"),("Conductivity","AIT1801 permeate conductivity","0-1000 uS/cm")],analogOutputs:[("RejectValveCmd","CV1801 reject valve","0-100 %")],drives:[("VFD1801","VFD high-pressure pump","P1801","75 A")],safetyInputs:["EStop1801","LowFeedPressureTrip"],pneumaticBranches:[("XV1801","YV1801","Flush valve")],pids:[("PIC1801","ROPress","RejectValveCmd","RejectValveCmd")],specialNetworkNodes:[("ANALYZER1801","Water quality analyzer")],alarmThemes:[("RO_PRESS_HI",.critical,"ROPress > 560 psi"),("PERMEATE_QUALITY",.high,"Conductivity above product specification")],routineThemes:[("PreFlush","open flush route before HP pump"),("Pressurize","ramp pump and reject valve"),("Production","qualify permeate before product diversion")])
        case .dataCenterCooling: return .init(number:"DCC01",title:"Data Center Cooling Loop Controls Project",cpu:"1756-L83E",remoteAreas:["CRAH Gallery","CHW Header"],discreteInputs:[("CRAH1Proof","CRAH fan proof"),("LeakDetect","floor leak detection")],discreteOutputs:[("CRAH1Enable","CRAH enable")],analogInputs:[("SupplyTemp","TT1901 supply water temp","35-60 °F"),("RackTemp","TT1902 rack inlet temp","55-95 °F"),("LoopDP","PDT1901 loop differential pressure","0-30 psi")],analogOutputs:[("CHWValve","CV1901 chilled-water valve","0-100 %")],drives:[("VFD1901","VFD CRAH fan","M1901","15 A")],safetyInputs:["EStop1901","LeakDetectSafety"],pneumaticBranches:[],pids:[("TIC1901","RackTemp","CHWValve","CHWValve"),("PIC1901","LoopDP","FanSpeed","FanSpeed")],specialNetworkNodes:[("BMS1901","Data center BMS gateway")],alarmThemes:[("RACK_TEMP_HIGH",.critical,"RackTemp > 85 °F"),("LEAK_DETECTED",.critical,"LeakDetect active")],routineThemes:[("Capacity_Stage","enable CRAH units from thermal load"),("Valve_Control","regulate rack inlet temperature"),("Failover","start standby cooling on proof loss")])
        case .parcelSortation: return .init(number:"SRT01",title:"Parcel Sortation Controls Project",cpu:"1756-L85E",remoteAreas:["Induction","Sorter Spine","Chutes"],discreteInputs:[("ParcelDetect","PE2001 induction photoeye"),("ChuteFull","LS2001 chute full")],discreteOutputs:[("DiverterFire","YV2001 diverter")],analogInputs:[],analogOutputs:[],drives:[("VFD2001","VFD sorter belt","M2001","25 A")],safetyInputs:["EStop2001","PullCord2001_A","PullCord2001_B"],pneumaticBranches:[("DIV2001","YV2001","High-speed diverter")],pids:[],specialNetworkNodes:[("ENC2001","High-speed encoder"),("SCN2001","Barcode scanner array")],alarmThemes:[("TRACK_LOST",.high,"parcel tracking ID loses encoder correlation"),("CHUTE_FULL",.warning,"ChuteFull true")],routineThemes:[("Induct_Track","create parcel tracking record"),("Encoder_Shift","advance parcel position from encoder"),("Diverter_Schedule","fire chute output at calculated offset")])
        case .automotivePaintBooth: return .init(number:"PNT01",title:"Automotive Paint Booth Controls Project",cpu:"1756-L84ES",remoteAreas:["Booth Supply","Exhaust Plenum"],discreteInputs:[("ConveyorProof","body conveyor proof"),("FireSystemOK","fire suppression healthy")],discreteOutputs:[("BoothEnable","booth process enable")],analogInputs:[("BoothDP","PDT2101 booth differential pressure","-1.0-1.0 inH2O"),("AirflowPV","FT2101 exhaust airflow","0-50000 cfm")],analogOutputs:[("ExhaustDamper","DM2101 exhaust damper","0-100 %")],drives:[("VFD2101","VFD exhaust fan","M2101","60 A")],safetyInputs:["EStop2101","FireTrip2101","Door2101_A","Door2101_B"],pneumaticBranches:[],pids:[("PIC2101","BoothDP","ExhaustDamper","ExhaustDamper")],specialNetworkNodes:[("LEL2101","LEL monitor")],alarmThemes:[("AIRFLOW_LOW",.critical,"AirflowPV below safe spray threshold"),("LEL_HIGH",.critical,"LEL concentration high")],routineThemes:[("Booth_Purge","establish ventilation before spray enable"),("Pressure_Balance","control supply/exhaust balance"),("Spray_Interlock","allow paint only with airflow/fire permissives")])
        case .injectionMoldingCell: return .init(number:"IMC01",title:"Injection Molding Cell Controls Project",cpu:"1756-L85ES",remoteAreas:["Mold Machine","Robot Interface"],discreteInputs:[("MoldClosed","mold closed proof"),("EjectHome","ejector home")],discreteOutputs:[("HeaterEnable","heater contactor enable")],analogInputs:[("BarrelTemp1","TC2201 barrel zone 1","0-400 °C thermocouple"),("HydPressure","PT2201 hydraulic pressure","0-3000 psi")],analogOutputs:[("HeaterDemand1","SCR2201 heater demand","0-100 %")],drives:[("K5700_INJ","servo injection axis","M2201","24 A")],safetyInputs:["EStop2201","Gate2201_A","Gate2201_B","MoldSafe2201"],pneumaticBranches:[],pids:[("TIC2201","BarrelTemp1","HeaterDemand1","HeaterDemand1")],specialNetworkNodes:[("ROBOT2201","Part-removal robot")],alarmThemes:[("BARREL_OVERTEMP",.critical,"BarrelTemp1 > 390 °C"),("MOLD_NOT_CLOSED",.critical,"injection request without MoldClosed")],routineThemes:[("Clamp","close and prove mold"),("Inject","execute servo injection profile"),("Cool_Eject","time cooling then eject and robot handoff")])
        case .crusherConveyor: return .init(number:"CRU01",title:"Crusher and Mining Conveyor Controls Project",cpu:"1756-L84ES",remoteAreas:["Crusher MCC","Transfer Tower","Tail Pulley"],discreteInputs:[("ZeroSpeed","ZS2301 zero-speed switch"),("ChutePlug","LS2301 chute plug switch")],discreteOutputs:[("CrusherEnable","crusher enable")],analogInputs:[("BeltLoad","WT2301 belt scale","0-1000 tph"),("MotorCurrent","IT2301 crusher current","0-300 A")],analogOutputs:[],drives:[("VFD2301","VFD feed conveyor","M2301","95 A")],safetyInputs:["EStop2301","PullCord2301_A","PullCord2301_B"],pneumaticBranches:[],pids:[],specialNetworkNodes:[("MCC2301","Intelligent motor protection relay")],alarmThemes:[("BELT_ZERO_SPEED",.critical,"run command with ZeroSpeed"),("CHUTE_PLUG",.high,"ChutePlug active")],routineThemes:[("Start_Sequence","start downstream-to-upstream with proof"),("Load_Shed","reduce feed when crusher current high"),("Trip_Sequence","stop upstream immediately on chute/zero-speed trip")])
        case .grainElevator: return .init(number:"GRN01",title:"Grain Elevator Controls Project",cpu:"1756-L83E",remoteAreas:["Boot Section","Head House"],discreteInputs:[("BucketSpeed","ZS2401 speed switch"),("BeltAlign","BS2401 belt alignment switch")],discreteOutputs:[("ElevatorRun","elevator motor starter")],analogInputs:[("BearingTemp","TT2401 head bearing temp","0-250 °F"),("VibrationPV","VT2401 bearing vibration","0-1 in/s")],analogOutputs:[],drives:[],safetyInputs:["EStop2401","PullCord2401"],pneumaticBranches:[],pids:[],specialNetworkNodes:[("MPR2401","Motor protection relay")],alarmThemes:[("BEARING_TEMP_HI",.critical,"BearingTemp > 190 °F"),("BELT_MISALIGN",.critical,"BeltAlign false")],routineThemes:[("PreStart","prove downstream path and speed devices"),("Run_Proof","verify bucket speed after starter"),("Bearing_Protect","trip on bearing temp/vibration limits")])
        case .htstPasteurizer: return .init(number:"HTST1",title:"HTST Pasteurizer Controls Project",cpu:"1756-L84ES",remoteAreas:["Timing Pump","Divert Valve Station"],discreteInputs:[("FDV_Flow","flow-diversion valve forward proof"),("FDV_Divert","flow-diversion valve divert proof")],discreteOutputs:[("FDV_Cmd","flow-diversion valve command")],analogInputs:[("LegalTemp","TT2501 legal pasteurization temp","0-200 °F"),("FlowRate","FT2501 product flow","0-100 gpm")],analogOutputs:[("SteamValve","CV2501 hot-water steam valve","0-100 %")],drives:[("VFD2501","VFD timing pump","P2501","12 A")],safetyInputs:["EStop2501","LegalTempTrip"],pneumaticBranches:[("FDV2501","YV2501","Flow-diversion valve")],pids:[("TIC2501","LegalTemp","SteamValve","SteamValve")],specialNetworkNodes:[("REC2501","Regulatory chart recorder")],alarmThemes:[("LEGAL_TEMP_LOW",.critical,"LegalTemp below pasteurization limit"),("FDV_NOT_DIVERT",.critical,"unsafe temperature without divert proof")],routineThemes:[("Forward_Permit","legal temp and timing conditions allow forward flow"),("Divert_Safe","force divert on any legal condition failure"),("Timing_Pump","lock maximum flow to holding-tube residence time")])
        case .bioreactor: return .init(number:"BIO01",title:"Bioreactor Controls Project",cpu:"1756-L85E",remoteAreas:["Bioreactor Skid","Gas Panel"],discreteInputs:[("AgitatorReady","agitator VFD ready"),("FoamSwitch","foam switch")],discreteOutputs:[("AntifoamValve","YV2601 antifoam valve")],analogInputs:[("DOPV","AIT2601 dissolved oxygen","0-100 %sat"),("pHPV","AIT2602 pH","0-14 pH"),("TempPV","TT2601 reactor temp","0-80 °C")],analogOutputs:[("AirValve","FCV2601 air mass-flow valve","0-100 %"),("AcidBaseCmd","CV2602 pH reagent valve","0-100 %")],drives:[("VFD2601","VFD agitator","M2601","10 A")],safetyInputs:["EStop2601","VesselPressureTrip"],pneumaticBranches:[("AF2601","YV2601","Antifoam dosing valve")],pids:[("DOIC2601","DOPV","AirValve","AirValve"),("PHIC2601","pHPV","AcidBaseCmd","AcidBaseCmd"),("TIC2601","TempPV","JacketValve","JacketValve")],specialNetworkNodes:[("GAS2601","Gas mass-flow controller")],alarmThemes:[("DO_LOW",.high,"DOPV below recipe minimum"),("PH_OUT_OF_RANGE",.critical,"pHPV outside validated range")],routineThemes:[("Recipe_Phase","execute inoculation/growth/harvest phases"),("DO_Cascade","cascade DO demand to air then agitation"),("Aseptic_Hold","hold safe state on pressure/sterility interlock")])
        case .chilledWaterPlant: return .init(number:"CHW01",title:"Central Chilled Water Plant Controls Project",cpu:"1756-L85E",remoteAreas:["Primary Pumps","Secondary Header","Cooling Towers"],discreteInputs:[("CH1Ready","chiller 1 ready"),("P1Proof","pump 1 proof")],discreteOutputs:[("CH1Enable","chiller 1 enable")],analogInputs:[("SupplyTemp","TT2701 CHW supply temp","35-60 °F"),("ReturnTemp","TT2702 CHW return temp","40-80 °F"),("HeaderDP","PDT2701 secondary DP","0-50 psi")],analogOutputs:[("BypassValve","CV2701 bypass valve","0-100 %")],drives:[("VFD2701","VFD secondary pump","P2701","70 A"),("VFD2702","VFD cooling tower fan","M2702","30 A")],safetyInputs:["EStop2701"],pneumaticBranches:[],pids:[("PIC2701","HeaderDP","PumpSpeed","PumpSpeed"),("TIC2701","SupplyTemp","TowerSpeed","TowerSpeed")],specialNetworkNodes:[("CHILLER2701","Chiller controller"),("BTU2701","BTU meter")],alarmThemes:[("CHW_TEMP_HIGH",.high,"SupplyTemp above setpoint"),("HEADER_DP_LOW",.high,"HeaderDP below critical distribution limit")],routineThemes:[("Plant_Stage","stage chillers by load and runtime"),("Pump_DP","control secondary pumps to DP"),("Tower_Optimize","control condenser/tower sequence")])
        case .batteryFormationLine: return .init(number:"BATF1",title:"Battery Formation and Test Line Controls Project",cpu:"1756-L85ES",remoteAreas:["Formation Fixtures","Thermal Chamber","Unload"],discreteInputs:[("FixtureClosed","fixture clamp closed"),("CellPresent","cell present")],discreteOutputs:[("MainContactor","K2801 formation contactor"),("FixtureClamp","YV2801 clamp")],analogInputs:[("CellVoltage","VT2801 cell voltage","0-6 V 4-20mA"),("ChargeCurrent","IT2801 formation current","0-500 A"),("CellTemp","TT2801 cell temperature","0-100 °C")],analogOutputs:[],drives:[("VFD2801","VFD unload conveyor","M2801","6 A")],safetyInputs:["EStop2801","Door2801_A","Door2801_B","HVInterlock2801"],pneumaticBranches:[("CLP2801","YV2801","Fixture clamp")],pids:[],specialNetworkNodes:[("TEST2801","Formation power supply"),("DAQ2801","High-resolution DAQ")],alarmThemes:[("CELL_OVERVOLT",.critical,"CellVoltage above recipe limit"),("CELL_OVERTEMP",.critical,"CellTemp above recipe limit")],routineThemes:[("Fixture_Load","verify cell identity and clamp"),("Formation_Profile","handshake charge/discharge recipe with power supply"),("Quality_Gate","compare voltage/current/temp trace to acceptance envelope")])
        }
    }
}
