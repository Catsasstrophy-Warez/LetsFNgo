import Foundation
import ControlsPLC

public enum TopologyElectricalNodeKind: String, Codable, CaseIterable, Sendable {
    case source, protection, fieldDevice, fieldTerminal, cableCore, panelTerminal, ioChannel, interposingDevice, load, common, shield, ground, networkSwitch, networkDevice
}

public struct TopologyElectricalNode: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var machine: PlayableMachineKind
    public var circuitID: String
    public var order: Int
    public var kind: TopologyElectricalNodeKind
    public var tag: String
    public var label: String
    public var drawingSheet: String?
    public var rack: String?
    public var slot: Int?
    public var channel: Int?
    public var nominalPotential: Double
}

public struct TopologyElectricalEdge: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var circuitID: String
    public var fromNodeID: String
    public var toNodeID: String
    public var kind: String
    public var conductorID: String?
    public var wireNumber: String?
    public var nominalResistanceOhms: Double
    public var loadResistanceOhms: Double?
}

public struct MachineElectricalTopology: Codable, Equatable, Sendable {
    public var machine: PlayableMachineKind
    public var projectNumber: String
    public var nodes: [TopologyElectricalNode]
    public var edges: [TopologyElectricalEdge]
    public var bindingCircuitIDs: [String:String]

    public func circuit(for ioTag: String) -> [TopologyElectricalNode] {
        guard let id = bindingCircuitIDs[ioTag] else { return [] }
        return nodes.filter { $0.circuitID == id }.sorted { $0.order < $1.order }
    }
    public func node(_ id: String) -> TopologyElectricalNode? { nodes.first { $0.id == id } }
    public func edges(in circuitID: String) -> [TopologyElectricalEdge] { edges.filter { $0.circuitID == circuitID } }
}

public enum MachineElectricalTopologyBuilder {
    public static func build(machine: PlayableMachineKind) throws -> MachineElectricalTopology {
        try build(executable: MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for: machine)))
    }

    public static func build(executable: ExecutableMachineControlsProject) -> MachineElectricalTopology {
        var nodes:[TopologyElectricalNode] = []
        var edges:[TopologyElectricalEdge] = []
        var map:[String:String] = [:]
        func appendCircuit(binding b: MachineIOBinding) {
            let cid = "\(executable.sourceProject.projectNumber)|\(b.ioTag)"
            map[b.ioTag] = cid
            let sourceV = b.signalType == .digital120VAC ? 120.0 : 24.0
            let source = TopologyElectricalNode(id:"\(cid)|SRC",machine:executable.machine,circuitID:cid,order:0,kind:.source,tag:b.signalType == .digital120VAC ? "L1" : "PS24",label:"Circuit source",drawingSheet:b.drawingSheet,nominalPotential:sourceV)
            let fuse = TopologyElectricalNode(id:"\(cid)|FU",machine:executable.machine,circuitID:cid,order:1,kind:.protection,tag:"FU-\(b.slot)-\(b.channel)",label:"Branch protection",drawingSheet:b.drawingSheet,nominalPotential:sourceV)
            let io = TopologyElectricalNode(id:"\(cid)|IO",machine:executable.machine,circuitID:cid,order:b.direction == .input ? 6 : 2,kind:.ioChannel,tag:b.ioTag,label:"\(b.rack) Slot \(b.slot) Channel \(b.channel) • \(b.moduleCatalog)",drawingSheet:b.drawingSheet,rack:b.rack,slot:b.slot,channel:b.channel,nominalPotential:sourceV)
            let panel = TopologyElectricalNode(id:"\(cid)|TB",machine:executable.machine,circuitID:cid,order:b.direction == .input ? 5 : 3,kind:.panelTerminal,tag:"\(b.terminalStrip)-\(b.terminalNumber)",label:"Panel terminal \(b.terminalStrip) \(b.terminalNumber)",drawingSheet:b.drawingSheet,nominalPotential:sourceV)
            let cable = TopologyElectricalNode(id:"\(cid)|CBL",machine:executable.machine,circuitID:cid,order:4,kind:.cableCore,tag:"\(b.cableID)/\(b.cableCore)",label:"Cable \(b.cableID) core \(b.cableCore)",drawingSheet:b.drawingSheet,nominalPotential:sourceV)
            let fieldT = TopologyElectricalNode(id:"\(cid)|FT",machine:executable.machine,circuitID:cid,order:b.direction == .input ? 3 : 5,kind:.fieldTerminal,tag:"\(b.fieldDeviceTag):\(b.fieldTerminal)",label:"Field terminal",drawingSheet:b.drawingSheet,nominalPotential:sourceV)
            let device = TopologyElectricalNode(id:"\(cid)|DEV",machine:executable.machine,circuitID:cid,order:b.direction == .input ? 2 : 6,kind:b.direction == .input ? .fieldDevice : .load,tag:b.fieldDeviceTag,label:b.fieldDeviceDescription,drawingSheet:b.drawingSheet,nominalPotential:sourceV)
            let common = TopologyElectricalNode(id:"\(cid)|COM",machine:executable.machine,circuitID:cid,order:7,kind:.common,tag:b.signalType == .digital120VAC ? "N" : "0V",label:"Circuit return/common",drawingSheet:b.drawingSheet,nominalPotential:0)
            var branch = [source,fuse]
            if b.direction == .input { branch += [device,fieldT,cable,panel,io,common] }
            else { branch += [io,panel,cable,fieldT,device,common] }
            nodes += branch
            for pair in zip(branch, branch.dropFirst()) {
                let loadR:Double? = pair.1.kind == .load || pair.1.kind == .fieldDevice ? loadResistance(binding:b) : nil
                edges.append(.init(id:"\(pair.0.id)->\(pair.1.id)",circuitID:cid,fromNodeID:pair.0.id,toNodeID:pair.1.id,kind:pair.1.kind.rawValue,conductorID:pair.1.kind == .cableCore ? b.cableID : nil,wireNumber:b.wireNumber,nominalResistanceOhms:pair.1.kind == .cableCore ? 0.12 : 0.03,loadResistanceOhms:loadR))
            }
            if !isDiscrete(b.signalType) {
                let sh = TopologyElectricalNode(id:"\(cid)|SH",machine:executable.machine,circuitID:cid,order:8,kind:.shield,tag:"SH-\(b.cableID)",label:"Cable shield",drawingSheet:b.drawingSheet,nominalPotential:0)
                let g = TopologyElectricalNode(id:"\(cid)|GND",machine:executable.machine,circuitID:cid,order:9,kind:.ground,tag:"PE",label:"Protective/reference ground",drawingSheet:b.drawingSheet,nominalPotential:0)
                nodes += [sh,g]
                edges.append(.init(id:"\(sh.id)->\(g.id)",circuitID:cid,fromNodeID:sh.id,toNodeID:g.id,kind:"shieldBond",nominalResistanceOhms:0.05))
            }
        }
        for b in executable.bindings { appendCircuit(binding:b) }
        for n in executable.sourceProject.ethernetNodes {
            let cid="NET|\(n.name)"; let sw=TopologyElectricalNode(id:"\(cid)|SW",machine:executable.machine,circuitID:cid,order:0,kind:.networkSwitch,tag:n.parent ?? "ENET-SW",label:"EtherNet/IP parent",drawingSheet:executable.sourceProject.drawings.first(where:{$0.discipline == .network})?.sheetNumber,nominalPotential:24)
            let dev=TopologyElectricalNode(id:"\(cid)|DEV",machine:executable.machine,circuitID:cid,order:1,kind:.networkDevice,tag:n.name,label:"\(n.deviceType) • \(n.ipAddress)",drawingSheet:executable.sourceProject.drawings.first(where:{$0.discipline == .network})?.sheetNumber,nominalPotential:24)
            nodes += [sw,dev]; edges.append(.init(id:"\(sw.id)->\(dev.id)",circuitID:cid,fromNodeID:sw.id,toNodeID:dev.id,kind:"EtherNet/IP",conductorID:n.name,nominalResistanceOhms:0))
        }
        return .init(machine:executable.machine,projectNumber:executable.sourceProject.projectNumber,nodes:nodes,edges:edges,bindingCircuitIDs:map)
    }

    private static func loadResistance(binding:MachineIOBinding)->Double {
        switch binding.signalType { case .analog4to20mA: return 250; case .digital120VAC: return 1200; default:return binding.direction == .output ? 120 : 1800 }
    }
    private static func isDiscrete(_ type: ProjectIOSignalType)->Bool { switch type { case .digital24VDC,.digital120VAC,.safetyDualChannel,.networkProduced,.networkConsumed:return true;default:return false } }
}

public struct TopologyGeneratedFault: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var kind:AdvancedElectricalFaultKind
    public var machine:PlayableMachineKind
    public var circuitID:String
    public var targetNodeID:String
    public var targetEdgeID:String?
    public var ioTag:String?
    public var fieldDeviceTag:String?
    public var magnitude:Double
    public var intermittent:Bool
    public var explanation:String
}

public struct TopologyGeneratedScenario: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var seed:UInt64
    public var machine:PlayableMachineKind
    public var difficulty:TroubleshootingDifficulty
    public var topology:MachineElectricalTopology
    public var faults:[TopologyGeneratedFault]
    public var operatorSymptom:String
    public var misleadingEvidence:[String]
    public var expectedMeterBoundaries:[String]
}

public enum TopologyProceduralFaultGenerator {
    public static func generate(machine:PlayableMachineKind,seed:UInt64,difficulty:TroubleshootingDifficulty)throws->TopologyGeneratedScenario {
        let executable=try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for:machine))
        let topology=MachineElectricalTopologyBuilder.build(executable:executable)
        var rng=SeededElectricalRNG(state:seed == 0 ? 1 : seed)
        let count:Int = difficulty == .expertNightmare ? 3 : ([.seniorTechnician,.controlsTechnician,.commissioningTechnician].contains(difficulty) ? 2 : 1)
        var faults:[TopologyGeneratedFault]=[]
        let shuffled = executable.bindings.sorted { stableHash($0.ioTag, seed:seed) < stableHash($1.ioTag, seed:seed) }
        for i in 0..<min(count,max(1,shuffled.count)) {
            let b=shuffled[(i+rng.int(max(1,shuffled.count))) % max(1,shuffled.count)]
            guard let cid=topology.bindingCircuitIDs[b.ioTag] else{continue}
            let candidates=compatibleFaults(binding:b)
            let kind=candidates[rng.int(candidates.count)]
            let branch=topology.circuit(for:b.ioTag)
            let preferred=targetKind(for:kind,binding:b)
            let target=branch.first(where:{$0.kind == preferred}) ?? branch.dropFirst().first ?? branch[0]
            let edge=topology.edges(in:cid).first(where:{$0.toNodeID == target.id})
            let magnitude=magnitudeFor(kind:kind,rng:&rng)
            faults.append(.init(id:"TF-\(seed)-\(i)",kind:kind,machine:machine,circuitID:cid,targetNodeID:target.id,targetEdgeID:edge?.id,ioTag:b.ioTag,fieldDeviceTag:b.fieldDeviceTag,magnitude:magnitude,intermittent:isIntermittent(kind),explanation:"\(kind.rawValue) at \(target.tag) on \(b.drawingSheet), \(b.rack) slot \(b.slot) channel \(b.channel)"))
        }
        let symptom=symptomFor(faults.first?.kind,machine:machine)
        let misleading=difficulty == .expertNightmare ? ["Previous shift believes the PLC card is bad, but did not isolate the field circuit.","Operator reports the fault disappears after reset."] : difficulty == .seniorTechnician ? ["The machine ran after a reset earlier in the shift."] : []
        return .init(id:"TOPO-\(machine.rawValue)-\(seed)",seed:seed,machine:machine,difficulty:difficulty,topology:topology,faults:faults,operatorSymptom:symptom,misleadingEvidence:misleading,expectedMeterBoundaries:faults.compactMap{$0.targetEdgeID})
    }
    private static func stableHash(_ s:String,seed:UInt64)->UInt64 { s.utf8.reduce(seed &+ 1469598103934665603){($0 ^ UInt64($1)) &* 1099511628211} }
    private static func compatibleFaults(binding b:MachineIOBinding)->[AdvancedElectricalFaultKind] {
        let analog = !isDiscrete(b.signalType)
        if b.direction == .input {
            if analog { return [.looseHighResistanceTerminal,.corrodedConnection,.missingDCCommon,.floatingCommon,.groundLoop,.shieldGroundFault,.wrongTransmitterRange,.analogModuleDriftEquivalent,.vibrationIntermittentOpen,.positionDependentCableOpen,.moistureLeakage,.wrongTerminalLanding] }
            if b.signalType == .safetyDualChannel { return [.safetyChannelOpen,.safetyDiscrepancy,.edmFeedbackFailure,.resetCircuitFailure,.vibrationIntermittentOpen,.wrongTerminalLanding] }
            return [.blownFuse,.looseHighResistanceTerminal,.missingDCCommon,.inputChannelFailure,.vibrationIntermittentOpen,.positionDependentCableOpen,.noisySensor,.wrongSensorPolarity,.wrongSensorWireCount,.wrongPLCChannelAssignment,.wrongTerminalLanding]
        }
        return [.blownFuse,.downstreamShort,.looseHighResistanceTerminal,.outputChannelFailure,.weldedRelay,.stuckContactor,.failedSolenoidCoil,.mechanicalOverload,.wrongTerminalLanding,.jumperLeftInstalled,.defaultedVFDParameters]
    }
    private static func targetKind(for k:AdvancedElectricalFaultKind,binding:MachineIOBinding)->TopologyElectricalNodeKind {
        switch k { case .blownFuse,.wrongFuseReplacement,.downstreamShort:return .protection; case .outputChannelFailure,.inputChannelFailure,.wrongPLCChannelAssignment:return .ioChannel; case .shieldGroundFault,.groundLoop:return .shield; case .wrongTerminalLanding,.looseHighResistanceTerminal,.corrodedConnection:return .panelTerminal; case .vibrationIntermittentOpen,.positionDependentCableOpen,.moistureLeakage:return .cableCore; default:return binding.direction == .input ? .fieldDevice:.load }
    }
    private static func magnitudeFor(kind:AdvancedElectricalFaultKind,rng:inout SeededElectricalRNG)->Double { switch kind { case .looseHighResistanceTerminal,.corrodedConnection:return 15+rng.double()*120; case .wrongTransmitterRange,.groundLoop,.floatingCommon:return 4+rng.double()*12; default:return 1+rng.double()*3 } }
    private static func isIntermittent(_ k:AdvancedElectricalFaultKind)->Bool { [.vibrationIntermittentOpen,.positionDependentCableOpen,.heatSensitiveFailure,.intermittentNetworkDrop,.contactFailsUnderLoad].contains(k) }
    private static func isDiscrete(_ type:ProjectIOSignalType)->Bool { switch type {case .digital24VDC,.digital120VAC,.safetyDualChannel,.networkProduced,.networkConsumed:return true;default:return false} }
    private static func symptomFor(_ k:AdvancedElectricalFaultKind?,machine:PlayableMachineKind)->String { "\(machine.rawValue): \(k?.rawValue ?? "unknown electrical fault") is producing an abnormal machine response. Prove the failed electrical boundary before repair." }
}

private extension AdvancedElectricalFaultKind {
    static var analogModuleDriftEquivalent: AdvancedElectricalFaultKind { .wrongTransmitterRange }
}

public struct TopologyMeterReading: Codable, Equatable, Sendable {
    public var value:Double?
    public var display:String
    public var unit:String
    public var interpretation:String
    public var circuitID:String?
    public var redNode:String
    public var blackNode:String
}

public enum TopologyMeterEngine {
    public static func measureVoltage(scenario:TopologyGeneratedScenario,redNodeID:String,blackNodeID:String,loaded:Bool=true,loZ:Bool=false)->TopologyMeterReading {
        guard let red=scenario.topology.node(redNodeID),let black=scenario.topology.node(blackNodeID),red.circuitID == black.circuitID else{return .init(value:nil,display:"----",unit:"V",interpretation:"Test points are not on the same modeled electrical branch.",circuitID:nil,redNode:redNodeID,blackNode:blackNodeID)}
        var net=TopologyCircuitNetlistBuilder.build(scenario:scenario,circuitID:red.circuitID)
        // The meter participates in the netlist. Normal DMM input is high impedance; LoZ intentionally loads floating capacitively/leakage-coupled nodes.
        let meterR = loZ ? 3_000.0 : 10_000_000.0
        net.branches.append(.init(id:"METER|\(redNodeID)|\(blackNodeID)",fromNodeID:redNodeID,toNodeID:blackNodeID,kind:.sensorInput,baseResistanceOhms:meterR,temperatureCoefficientPerC:0))
        let solution=IndustrialCircuitSolver.solve(net)
        guard let rv=solution.voltage(redNodeID),let bv=solution.voltage(blackNodeID) else{return .init(value:nil,display:"----",unit:"V",interpretation:"Circuit solver could not resolve one or both test points.",circuitID:red.circuitID,redNode:redNodeID,blackNode:blackNodeID)}
        let value=abs(rv-bv)
        let text:String
        if loZ { text="LoZ reading is solved with the meter's low input impedance physically loading the circuit." }
        else if loaded { text="Voltage is calculated from the Kirchhoff nodal solution with real branch/load resistance." }
        else { text="High-impedance DMM reading is solved with modeled parasitic leakage/coupling paths." }
        return .init(value:value,display:String(format:"%.2f",value),unit:"V",interpretation:text,circuitID:red.circuitID,redNode:redNodeID,blackNode:blackNodeID)
    }

    public static func voltageDropAcrossFault(scenario:TopologyGeneratedScenario,faultID:String)->TopologyMeterReading? {
        guard let f=scenario.faults.first(where:{$0.id==faultID}),let edgeID=f.targetEdgeID,let e=scenario.topology.edges.first(where:{$0.id==edgeID}) else{return nil}
        return measureVoltage(scenario:scenario,redNodeID:e.fromNodeID,blackNodeID:e.toNodeID,loaded:true)
    }
}

public extension FullyClosedLoopMachineRuntime {
    mutating func injectTopologyFault(_ fault:TopologyGeneratedFault) {
        guard let tag=fault.ioTag,let binding=executable.bindings.first(where:{$0.ioTag==tag}) else{return}
        if binding.direction == .input {
            let mapped:MachineFieldFaultKind
            switch fault.kind {
            case .blownFuse,.safetyChannelOpen,.inputChannelFailure,.failedSolenoidCoil: mapped = .openWire
            case .looseHighResistanceTerminal,.corrodedConnection: mapped = .highResistanceConnection
            case .groundLoop,.floatingCommon,.missingDCCommon,.shieldGroundFault,.wrongTransmitterRange: mapped = .referenceShift
            case .vibrationIntermittentOpen,.positionDependentCableOpen,.heatSensitiveFailure,.moistureLeakage: mapped = .intermittentOpen
            case .intermittentNetworkDrop: mapped = .networkStale
            case .noisySensor: mapped = .analogDrift
            case .wrongSensorPolarity,.wrongSensorWireCount,.wrongTerminalLanding,.wrongPLCChannelAssignment: mapped = .channelFailedLow
            default: mapped = .openWire
            }
            injectInputFault(.init(id:fault.id,target:tag,kind:mapped,magnitude:fault.magnitude))
        } else {
            let mapped:OutputPathFaultKind
            switch fault.kind {
            case .looseHighResistanceTerminal,.corrodedConnection: mapped = .highResistanceConnection
            case .weldedRelay,.stuckContactor,.jumperLeftInstalled: mapped = .weldedContactor
            case .mechanicalOverload: mapped = .motorOverload
            case .defaultedVFDParameters: mapped = .driveFault
            case .outputChannelFailure: mapped = .outputChannelOpen
            case .failedSolenoidCoil: mapped = .actuatorStuck
            case .downstreamShort,.blownFuse,.wrongTerminalLanding: mapped = .brokenFieldWire
            default: mapped = .brokenFieldWire
            }
            injectOutputFault(.init(id:fault.id,target:binding.scaledTag,kind:mapped,magnitude:fault.magnitude))
        }
    }
    mutating func injectTopologyScenario(_ scenario:TopologyGeneratedScenario) { for f in scenario.faults { injectTopologyFault(f) } }
}

public extension ProductionIntelligenceRuntime {
    mutating func injectTopologyScenario(_ scenario:TopologyGeneratedScenario, nodeID:String?=nil) {
        let id=nodeID ?? project.nodes.first(where:{$0.machine==scenario.machine})?.id
        guard let id,var machine=machines[id] else{return};machine.injectTopologyScenario(scenario);machines[id]=machine
    }
}
public extension ManufacturingExecutionRuntime { mutating func injectTopologyScenario(_ scenario:TopologyGeneratedScenario,nodeID:String?=nil){ line.injectTopologyScenario(scenario,nodeID:nodeID) } }
public extension PlantShiftManagementRuntime { mutating func injectTopologyScenario(_ scenario:TopologyGeneratedScenario,nodeID:String?=nil){ mes.injectTopologyScenario(scenario,nodeID:nodeID) } }
public extension SupervisorTechnicianDecisionGameRuntime { mutating func injectTopologyScenario(_ scenario:TopologyGeneratedScenario,nodeID:String?=nil){ plant.injectTopologyScenario(scenario,nodeID:nodeID) } }
