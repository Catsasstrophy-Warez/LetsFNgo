import Foundation

public enum IndustrialComponentKind: String, Codable, CaseIterable, Sendable {
    case controller, localDigitalInput, localDigitalOutput, remoteIOAdapter, remoteDigitalInput, remoteDigitalOutput
    case analogInput, analogOutput, safetyInput, safetyOutput, safetyController, ethernetDevice, managedSwitch
    case vfd, servoDrive, motorStarter, motor, encoder, transmitter, pneumaticManifold, solenoidValve, controlValve
    case pump, heater, contactor, overload, pidLoop, instrumentation, networkGateway
}

public struct IndustrialComponent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var kind: IndustrialComponentKind
    public var description: String
    public var network: String?
    public var rackSlot: Int?
    public var channels: [String]
    public init(id:String, tag:String, kind:IndustrialComponentKind, description:String, network:String?=nil, rackSlot:Int?=nil, channels:[String]=[]) {
        self.id=id; self.tag=tag; self.kind=kind; self.description=description; self.network=network; self.rackSlot=rackSlot; self.channels=channels
    }
}

public struct IndustrialSignalPath: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var source:String
    public var destination:String
    public var signal:String
    public var layer:String
    public init(_ id:String,_ source:String,_ destination:String,_ signal:String,_ layer:String){self.id=id;self.source=source;self.destination=destination;self.signal=signal;self.layer=layer}
}

public struct MachineFailureChain: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var faultKind:PlantFaultKind
    public var title:String
    public var propagation:[String]
    public var technicianLesson:String
    public init(id:String,faultKind:PlantFaultKind,title:String,propagation:[String],technicianLesson:String){self.id=id;self.faultKind=faultKind;self.title=title;self.propagation=propagation;self.technicianLesson=technicianLesson}
}

public struct HeroMachineArchitecture: Identifiable, Codable, Equatable, Sendable {
    public var id:String { machine.rawValue }
    public var machine:PlayableMachineKind
    public var title:String
    public var architectureSummary:String
    public var components:[IndustrialComponent]
    public var signalPaths:[IndustrialSignalPath]
    public var failureChains:[MachineFailureChain]
    public var primaryProcessFault:PlayableFaultKind
    public init(machine:PlayableMachineKind,title:String,architectureSummary:String,components:[IndustrialComponent],signalPaths:[IndustrialSignalPath],failureChains:[MachineFailureChain],primaryProcessFault:PlayableFaultKind){self.machine=machine;self.title=title;self.architectureSummary=architectureSummary;self.components=components;self.signalPaths=signalPaths;self.failureChains=failureChains;self.primaryProcessFault=primaryProcessFault}
}

public extension PlantFaultKind {
    static var architectureKinds:[PlantFaultKind] { [.remoteIOConnectionLoss,.analogModuleDrift,.safetyChannelDiscrepancy,.ethernetPacketLoss,.servoFeedbackLoss,.pneumaticLeak,.valveStiction,.pumpCavitation,.heaterOpenCircuit,.pidSensorBias,.encoderSlip,.contactorFailure,.motorOverload] }
}

public enum HeroMachineArchitectureCatalog {
    private static func c(_ id:String,_ tag:String,_ kind:IndustrialComponentKind,_ desc:String,_ net:String?=nil,_ slot:Int?=nil,_ ch:[String]=[]) -> IndustrialComponent { .init(id:id,tag:tag,kind:kind,description:desc,network:net,rackSlot:slot,channels:ch) }
    private static func f(_ id:String,_ kind:PlantFaultKind,_ title:String,_ path:[String],_ lesson:String) -> MachineFailureChain { .init(id:id,faultKind:kind,title:title,propagation:path,technicianLesson:lesson) }
    private static func p(_ id:String,_ s:String,_ d:String,_ sig:String,_ layer:String)->IndustrialSignalPath{.init(id,s,d,sig,layer)}

    public static let all:[HeroMachineArchitecture] = [
        make(.packagingCell,"Packaging Cell","Distributed discrete I/O, safety circuit, EtherNet/IP VFD and pneumatic stops.",.packagingStickyPhotoeye,[.remoteIOConnectionLoss,.safetyChannelDiscrepancy,.ethernetPacketLoss,.pneumaticLeak]),
        make(.pressureSkid,"Pressure / Flow Skid","Remote analog I/O, 4–20 mA pressure/flow transmitters, PID loop and networked pump VFD.",.pressureValveStiction,[.analogModuleDrift,.pidSensorBias,.valveStiction,.pumpCavitation]),
        make(.servoConveyor,"Servo Conveyor","Safety I/O, EtherNet/IP motion, servo drive, encoder feedback and pneumatic brake release.",.servoBearingResonance,[.servoFeedbackLoss,.encoderSlip,.safetyChannelDiscrepancy,.ethernetPacketLoss]),
        make(.pumpStation,"Pump Station","Level/pressure analog I/O, duplex pump VFDs, HOA permissives and wet-well instrumentation.",.pumpCavitation,[.pumpCavitation,.analogModuleDrift,.contactorFailure,.remoteIOConnectionLoss]),
        make(.airHandlingUnit,"Air Handling Unit","Remote I/O, temperature/pressure analogs, VFD fans, dampers and PID loops.",.ahuLoopInteraction,[.pidSensorBias,.valveStiction,.ethernetPacketLoss,.analogModuleDrift]),
        make(.batchMixingTank,"Batch Mixing Tank","Batch state logic, load cells/level analogs, agitator VFD, valves and safety permissives.",.batchAgitatorDrag,[.motorOverload,.valveStiction,.analogModuleDrift,.safetyChannelDiscrepancy]),
        make(.industrialOven,"Industrial Oven","Safety chain, heater/burner outputs, thermocouple analog modules, circulation VFD and temperature PID.",.ovenBurnerDisturbance,[.heaterOpenCircuit,.analogModuleDrift,.safetyChannelDiscrepancy,.pidSensorBias]),
        make(.roboticPalletizer,"Robotic Palletizer","Safety controller, robot EtherNet/IP interface, remote I/O and pneumatic vacuum tooling.",.palletizerVacuumLoss,[.pneumaticLeak,.ethernetPacketLoss,.safetyChannelDiscrepancy,.remoteIOConnectionLoss]),
        make(.wastewaterLiftStation,"Wastewater Lift Station","Level transmitters, remote I/O, duplex VFD pumps and check-valve feedback.",.liftStationCheckValveLeak,[.pumpCavitation,.analogModuleDrift,.remoteIOConnectionLoss,.motorOverload]),
        make(.refrigerationRack,"Refrigeration Rack","Pressure/temperature analogs, compressor starters/VFDs, solenoids and suction-pressure PID.",.refrigerationCondenserFouling,[.contactorFailure,.analogModuleDrift,.valveStiction,.motorOverload]),
        make(.boilerSteamPlant,"Boiler / Steam Plant","Burner safety interlocks, flame/permissive safety I/O, fuel/air actuators and pressure PID.",.boilerFuelAirDrift,[.safetyChannelDiscrepancy,.pidSensorBias,.valveStiction,.analogModuleDrift]),
        make(.cncCoolantCell,"CNC Coolant Cell","Machine interface I/O, pump starter/VFD, flow/pressure instruments and filter DP.",.cncCoolantRestriction,[.pumpCavitation,.contactorFailure,.analogModuleDrift,.remoteIOConnectionLoss]),
        make(.cleanroomPressureSystem,"Cleanroom Pressure System","Differential-pressure transmitters, VAV/damper actuators, fan VFDs and cascaded PID loops.",.cleanroomDoorLeak,[.pidSensorBias,.analogModuleDrift,.valveStiction,.ethernetPacketLoss]),
        make(.asrsCrane,"AS/RS Crane","Safety I/O, dual networked servo axes, absolute encoders and distributed rack I/O.",.asrsEncoderSlip,[.encoderSlip,.servoFeedbackLoss,.ethernetPacketLoss,.safetyChannelDiscrepancy]),
        make(.bottlingLine,"Bottling / Filling Line","High-speed remote I/O, valve manifold, flow/fill instrumentation, conveyor VFDs and reject devices.",.bottlingFillValveDrift,[.pneumaticLeak,.valveStiction,.remoteIOConnectionLoss,.ethernetPacketLoss]),
        make(.cipSkid,"CIP Cleaning Skid","Conductivity/temp/flow analogs, sanitary valve manifold, pump VFD and recipe PID control.",.cipConductivityDrift,[.analogModuleDrift,.pidSensorBias,.valveStiction,.pumpCavitation]),
        make(.compressedAirPlant,"Compressed-Air Plant","Header pressure instrumentation, sequenced compressor starters/VFDs and networked utility controls.",.compressedAirLeakGrowth,[.pneumaticLeak,.motorOverload,.ethernetPacketLoss,.pidSensorBias]),
        make(.reverseOsmosisPlant,"Reverse-Osmosis Plant","Pressure/conductivity/flow analogs, high-pressure pump VFD, valves and permissive interlocks.",.roMembraneFouling,[.pumpCavitation,.analogModuleDrift,.pidSensorBias,.valveStiction]),
        make(.dataCenterCooling,"Data-Center Cooling Loop","Networked CRAH units, chilled-water valves, fan VFDs, temperature sensors and PID loops.",.dataCenterValveStiction,[.valveStiction,.ethernetPacketLoss,.pidSensorBias,.analogModuleDrift]),
        make(.parcelSortation,"Parcel Sortation System","High-speed encoder inputs, distributed I/O, networked VFDs and pneumatic/electric diverters.",.parcelDiverterTimingDrift,[.encoderSlip,.remoteIOConnectionLoss,.pneumaticLeak,.ethernetPacketLoss]),
        make(.automotivePaintBooth,"Automotive Paint Booth","Safety interlocks, fan VFDs, pressure/airflow analogs, damper actuators and environmental monitoring.",.paintBoothFilterLoading,[.pidSensorBias,.analogModuleDrift,.motorOverload,.safetyChannelDiscrepancy]),
        make(.injectionMoldingCell,"Injection-Molding Cell","Heater zones, thermocouple modules, hydraulic/servo interfaces, safety I/O and temperature PID loops.",.moldingHeaterFailure,[.heaterOpenCircuit,.analogModuleDrift,.safetyChannelDiscrepancy,.servoFeedbackLoss]),
        make(.crusherConveyor,"Crusher / Mining Conveyor","Remote I/O islands, motor starters/VFDs, zero-speed switches, belt scales and pull-cord safety.",.crusherBeltSlip,[.motorOverload,.remoteIOConnectionLoss,.safetyChannelDiscrepancy,.encoderSlip]),
        make(.grainElevator,"Grain Elevator","Bearing temp/vibration analogs, bucket speed sensing, motor starter and distributed safety switches.",.grainBearingDrag,[.motorOverload,.analogModuleDrift,.remoteIOConnectionLoss,.safetyChannelDiscrepancy]),
        make(.htstPasteurizer,"HTST Pasteurizer","Sanitary analog instrumentation, divert-valve outputs/feedback, safety permissives and temperature PID.",.pasteurizerDivertLeak,[.valveStiction,.analogModuleDrift,.pidSensorBias,.safetyChannelDiscrepancy]),
        make(.bioreactor,"Bioreactor","DO/pH/temp analog modules, agitation VFD, gas valve manifold and cascaded PID loops.",.bioreactorOxygenTransferLoss,[.analogModuleDrift,.pidSensorBias,.valveStiction,.motorOverload]),
        make(.chilledWaterPlant,"Central Chilled-Water Plant","Distributed plant I/O, DP/temp analogs, pump VFDs, valve actuators and supervisory PID.",.chilledWaterDPBias,[.pidSensorBias,.analogModuleDrift,.ethernetPacketLoss,.pumpCavitation]),
        make(.batteryFormationLine,"Battery Formation / Test Line","High-current fixture contactors, analog voltage/current acquisition, thermal monitoring and EtherNet/IP test stations.",.batteryContactResistance,[.contactorFailure,.analogModuleDrift,.ethernetPacketLoss,.motorOverload])
    ]

    public static func profile(for machine:PlayableMachineKind)->HeroMachineArchitecture { all.first{$0.machine==machine}! }

    private static func make(_ machine:PlayableMachineKind,_ title:String,_ summary:String,_ processFault:PlayableFaultKind,_ failureKinds:[PlantFaultKind])->HeroMachineArchitecture {
        var components:[IndustrialComponent] = [
            c("plc","CLX-CPU",.controller,"ControlLogix-style controller","EtherNet/IP",0),
            c("switch","SW-01",.managedSwitch,"Managed industrial Ethernet switch","EtherNet/IP"),
            c("rio","RIO-01",.remoteIOAdapter,"Remote I/O adapter","EtherNet/IP"),
            c("di","RIO-DI",.remoteDigitalInput,"24 VDC remote digital inputs","EtherNet/IP",1,["DI0","DI1","DI2","DI3"]),
            c("do","RIO-DO",.remoteDigitalOutput,"24 VDC remote digital outputs","EtherNet/IP",2,["DO0","DO1","DO2","DO3"]),
            c("ai","RIO-AI",.analogInput,"4–20 mA / voltage analog input module","EtherNet/IP",3,["AI0","AI1","AI2","AI3"]),
            c("safe","SAFE-01",.safetyController,"Safety controller / safety I/O","CIP Safety"),
            c("drive","DRV-01", machine == .servoConveyor || machine == .asrsCrane ? .servoDrive:.vfd,"Networked motor drive","EtherNet/IP"),
            c("tx","PT-01",.transmitter,"Primary process transmitter",nil,nil,["4-20mA"]),
            c("act","FV-01",.controlValve,"Primary process actuator")
        ]
        if [.industrialOven,.injectionMoldingCell].contains(machine) { components.append(c("heat","HTR-01",.heater,"Electric heater zone")) }
        if [.pressureSkid,.pumpStation,.wastewaterLiftStation,.cipSkid,.reverseOsmosisPlant,.chilledWaterPlant,.cncCoolantCell].contains(machine) { components.append(c("pump","P-01",.pump,"Process pump")) }
        if [.roboticPalletizer,.bottlingLine,.parcelSortation,.compressedAirPlant].contains(machine) { components.append(c("pneu","VM-01",.pneumaticManifold,"Pneumatic valve manifold","EtherNet/IP")) }
        components.append(c("pid","PID-01",.pidLoop,"PLC process-control loop"))
        let paths=[p("p1","PT-01","RIO-AI","PV 4–20 mA","field analog"),p("p2","RIO-AI","CLX-CPU","PV engineering units","I/O image"),p("p3","CLX-CPU","DRV-01","run/speed reference","EtherNet/IP"),p("p4","SAFE-01","CLX-CPU","safety permissive","safety status"),p("p5","CLX-CPU","FV-01","actuator command","field output")]
        let chains = failureKinds.enumerated().map { index,kind in
            f("\(machine.rawValue)-\(index)",kind,kind.rawValue,[faultOrigin(kind),"field / network observation","PLC input image or permissive","ladder/PID decision","actuator response","process signature","alarm + historian + production"],lesson(kind))
        }
        return .init(machine:machine,title:title,architectureSummary:summary,components:components,signalPaths:paths,failureChains:chains,primaryProcessFault:processFault)
    }

    private static func faultOrigin(_ k:PlantFaultKind)->String { switch k { case .remoteIOConnectionLoss:"remote I/O adapter / network"; case .analogModuleDrift:"analog conversion channel"; case .safetyChannelDiscrepancy:"dual-channel safety input"; case .ethernetPacketLoss:"EtherNet/IP path"; case .servoFeedbackLoss:"servo feedback path"; case .pneumaticLeak:"pneumatic supply / actuator"; case .valveStiction:"control valve mechanics"; case .pumpCavitation:"pump hydraulic condition"; case .heaterOpenCircuit:"heater power circuit"; case .pidSensorBias:"measurement feedback"; case .encoderSlip:"encoder/mechanical reference"; case .contactorFailure:"contactor/overload circuit"; case .motorOverload:"motor mechanical/electrical load"; default:k.rawValue } }
    private static func lesson(_ k:PlantFaultKind)->String { "Prove where \(k.rawValue) first separates physical truth from controller-observed truth, then verify downstream consequences and post-repair recovery." }
}

public extension HeroMachineArchitecture {
    func processFaultInjection(from faults:[ProgressivePlantFault], hour:Double)->ScenarioFaultInjection {
        let severity = faults.filter { failureChains.map(\.faultKind).contains($0.kind) }.map{$0.severity(at:hour)}.max() ?? 0
        guard severity > 0 else { return .init() }
        return .init(kind:primaryProcessFault,severity:severity)
    }
}
