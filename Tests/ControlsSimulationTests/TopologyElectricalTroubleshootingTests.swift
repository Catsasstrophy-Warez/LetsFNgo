import XCTest
@testable import ControlsSimulation

final class TopologyElectricalTroubleshootingTests: XCTestCase {
    func testAll28MachinesBuildTopologyForEveryIOPoint() throws {
        for machine in PlayableMachineKind.allCases {
            let project=HeroMachineControlsProjectCatalog.project(for:machine)
            let topology=try MachineElectricalTopologyBuilder.build(machine:machine)
            XCTAssertEqual(topology.bindingCircuitIDs.count,project.ioPoints.count,machine.rawValue)
            for io in project.ioPoints {
                let branch=topology.circuit(for:io.tag)
                XCTAssertGreaterThanOrEqual(branch.count,8,"\(machine.rawValue) \(io.tag)")
                XCTAssertTrue(branch.contains{$0.kind == .source})
                XCTAssertTrue(branch.contains{$0.kind == .ioChannel})
                XCTAssertTrue(branch.contains{$0.kind == .common})
            }
        }
    }

    func test2800GeneratedScenariosAreTopologyValid() throws {
        var ids=Set<String>()
        for machine in PlayableMachineKind.allCases {
            for seed in 1...100 {
                let s=try TopologyProceduralFaultGenerator.generate(machine:machine,seed:UInt64(seed),difficulty:.expertNightmare)
                XCTAssertFalse(s.faults.isEmpty)
                for f in s.faults {
                    XCTAssertNotNil(s.topology.node(f.targetNodeID))
                    XCTAssertTrue(s.topology.nodes.contains{$0.circuitID == f.circuitID})
                    if let edge=f.targetEdgeID { XCTAssertTrue(s.topology.edges.contains{$0.id == edge}) }
                }
                ids.insert(s.id)
            }
        }
        XCTAssertEqual(ids.count,PlayableMachineKind.allCases.count*100)
    }

    func testGeneratorIsDeterministicForMachineAndSeed() throws {
        let a=try TopologyProceduralFaultGenerator.generate(machine:.reverseOsmosisPlant,seed:1802,difficulty:.expertNightmare)
        let b=try TopologyProceduralFaultGenerator.generate(machine:.reverseOsmosisPlant,seed:1802,difficulty:.expertNightmare)
        XCTAssertEqual(a,b)
    }

    func testMeterUsesActualBranchAndLoadedDrop() throws {
        var s=try TopologyProceduralFaultGenerator.generate(machine:.packagingCell,seed:9,difficulty:.technician)
        guard let binding=try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for:.packagingCell)).bindings.first(where:{$0.direction == .output}),
              let cid=s.topology.bindingCircuitIDs[binding.ioTag],let terminal=s.topology.nodes.first(where:{$0.circuitID==cid && $0.kind == .panelTerminal}),
              let edge=s.topology.edges.first(where:{$0.toNodeID == terminal.id}) else { return XCTFail("output branch") }
        s.faults=[.init(id:"HR",kind:.looseHighResistanceTerminal,machine:.packagingCell,circuitID:cid,targetNodeID:terminal.id,targetEdgeID:edge.id,ioTag:binding.ioTag,fieldDeviceTag:binding.fieldDeviceTag,magnitude:80,intermittent:false,explanation:"test")]
        let reading=TopologyMeterEngine.measureVoltage(scenario:s,redNodeID:edge.fromNodeID,blackNodeID:edge.toNodeID,loaded:true)
        XCTAssertGreaterThan(reading.value ?? 0,1)
    }

    func testOpenBranchShowsGhostUnloadedButCollapsesLoZ() throws {
        var s=try TopologyProceduralFaultGenerator.generate(machine:.pressureSkid,seed:4,difficulty:.technician)
        let binding=try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for:.pressureSkid)).bindings.first(where:{$0.direction == .input})!
        let branch=s.topology.circuit(for:binding.ioTag);let cable=branch.first(where:{$0.kind == .cableCore})!;let edge=s.topology.edges.first(where:{$0.toNodeID==cable.id})!
        s.faults=[.init(id:"OPEN",kind:.vibrationIntermittentOpen,machine:.pressureSkid,circuitID:cable.circuitID,targetNodeID:cable.id,targetEdgeID:edge.id,ioTag:binding.ioTag,fieldDeviceTag:binding.fieldDeviceTag,magnitude:2,intermittent:true,explanation:"open")]
        let common=branch.first(where:{$0.kind == .common})!
        let hi=TopologyMeterEngine.measureVoltage(scenario:s,redNodeID:cable.id,blackNodeID:common.id,loaded:false,loZ:false)
        let lo=TopologyMeterEngine.measureVoltage(scenario:s,redNodeID:cable.id,blackNodeID:common.id,loaded:false,loZ:true)
        XCTAssertLessThan(hi.value ?? 99,1); XCTAssertLessThanOrEqual(lo.value ?? 99, hi.value ?? 0.001)
    }

    func testTopologyFaultPropagatesIntoClosedLoopMachine() throws {
        var runtime=try FullyClosedLoopMachineRuntime(machine:.packagingCell)
        let binding=runtime.executable.bindings.first(where:{$0.direction == .output})!
        try runtime.forceControllerValue(binding.scaledTag,.bool(true))
        let topo=MachineElectricalTopologyBuilder.build(executable:runtime.executable);let cid=topo.bindingCircuitIDs[binding.ioTag]!;let cable=topo.circuit(for:binding.ioTag).first(where:{$0.kind == .cableCore})!
        let fault=TopologyGeneratedFault(id:"WIRE",kind:.wrongTerminalLanding,machine:.packagingCell,circuitID:cid,targetNodeID:cable.id,targetEdgeID:nil,ioTag:binding.ioTag,fieldDeviceTag:binding.fieldDeviceTag,magnitude:1,intermittent:false,explanation:"test")
        runtime.injectTopologyFault(fault)
        _=try runtime.cycle(elapsedMilliseconds:100)
        XCTAssertTrue(runtime.plant.faults.contains{$0.id=="WIRE"})
    }

    func testScenarioInjectsThroughLineMESAnd24HourLayers() throws {
        let scenario=try TopologyProceduralFaultGenerator.generate(machine:.packagingCell,seed:77,difficulty:.expertNightmare)
        var mes=try ManufacturingExecutionTemplates.trainingRuntime(project:ProductionLineTemplates.packagingToPalletizing)
        mes.injectTopologyScenario(scenario)
        let node=mes.line.project.nodes.first(where:{$0.machine == .packagingCell})!
        XCTAssertGreaterThan(mes.line.machines[node.id]!.controls.faults.count + mes.line.machines[node.id]!.plant.faults.count,0)
        var shift=PlantShiftManagementRuntime(mes:mes);shift.injectTopologyScenario(scenario,nodeID:node.id)
        var game=SupervisorTechnicianDecisionGameRuntime(plant:shift);game.injectTopologyScenario(scenario,nodeID:node.id)
        _=try game.cycle(elapsedMilliseconds:100)
        XCTAssertNotNil(game.plant.mes.line.machines[node.id]?.latest)
    }

    func testROPT1802TopologyCarriesDrawingCableTerminalAndChannel() throws {
        let executable=try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for:.reverseOsmosisPlant))
        guard let b=executable.binding(for:"PT1802") ?? executable.bindings.first(where:{$0.fieldDeviceTag.uppercased().contains("PT1802")}) else{return XCTFail("PT1802 missing")}
        let t=MachineElectricalTopologyBuilder.build(executable:executable);let branch=t.circuit(for:b.ioTag)
        XCTAssertTrue(branch.contains{$0.tag == b.fieldDeviceTag})
        XCTAssertTrue(branch.contains{$0.kind == .cableCore && $0.tag.contains(b.cableID)})
        XCTAssertTrue(branch.contains{$0.kind == .panelTerminal && $0.tag.contains(b.terminalStrip)})
        XCTAssertTrue(branch.contains{$0.kind == .ioChannel && $0.rack == b.rack && $0.slot == b.slot && $0.channel == b.channel})
    }
}

