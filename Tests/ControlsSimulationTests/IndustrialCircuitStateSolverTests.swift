import XCTest
@testable import ControlsSimulation

final class IndustrialCircuitStateSolverTests: XCTestCase {
    func testKirchhoffSeriesCircuitSolvesNodeVoltageAndCurrent() {
        let net = CircuitNetlist(
            nodes: [.init(id:"P",label:"24V"),.init(id:"MID",label:"mid"),.init(id:"0",label:"0V",isGround:true)],
            branches: [
                .init(id:"R1",fromNodeID:"P",toNodeID:"MID",kind:.resistor,baseResistanceOhms:100),
                .init(id:"R2",fromNodeID:"MID",toNodeID:"0",kind:.resistor,baseResistanceOhms:100)
            ],
            sources:[.init(id:"PS",positiveNodeID:"P",negativeNodeID:"0",nominalVolts:24,internalResistanceOhms:0.001)]
        )
        let s=IndustrialCircuitSolver.solve(net)
        XCTAssertEqual(s.voltage("MID")!,12,accuracy:0.02)
        XCTAssertEqual(abs(s.branch("R1")!.currentAmps),0.12,accuracy:0.001)
    }

    func testPowerSupplyCurrentLimitCollapsesVoltageUnderShort() {
        let net=CircuitNetlist(nodes:[.init(id:"P",label:"P"),.init(id:"0",label:"0",isGround:true)],branches:[.init(id:"LOAD",fromNodeID:"P",toNodeID:"0",baseResistanceOhms:1)],sources:[.init(id:"PS",positiveNodeID:"P",negativeNodeID:"0",nominalVolts:24,internalResistanceOhms:0.1,currentLimitAmps:5,foldbackVolts:2)])
        let s=IndustrialCircuitSolver.solve(net)
        XCTAssertTrue(s.sourceLimited["PS"] == true)
        XCTAssertLessThan(s.voltage("P")!,8)
        XCTAssertLessThanOrEqual(abs(s.branch("LOAD")!.currentAmps),5.1)
    }

    func testFuseI2tAndBreakerMagneticTripAreStateful() {
        var state=CircuitDynamicState()
        let net=CircuitNetlist(nodes:[.init(id:"P",label:"P"),.init(id:"0",label:"0",isGround:true)],branches:[.init(id:"B",fromNodeID:"P",toNodeID:"0",baseResistanceOhms:1)],sources:[.init(id:"S",positiveNodeID:"P",negativeNodeID:"0",nominalVolts:24,internalResistanceOhms:0.05)],protection:[.init(id:"FU",branchID:"B",kind:.fuse,ratedAmps:2,i2tCapacity:2),.init(id:"CB",branchID:"B",kind:.thermalMagneticBreaker,ratedAmps:2,magneticPickupMultiple:5)])
        _=IndustrialCircuitSolver.advance(net,state:&state,dtSeconds:0.1)
        XCTAssertTrue(state.protectionByID["CB"]?.tripped == true)
        // Magnetic trip opens the shared branch immediately; prove the fuse curve separately.
        var fuseState=CircuitDynamicState()
        let fuseNet=CircuitNetlist(nodes:net.nodes,branches:net.branches,sources:net.sources,protection:[.init(id:"FU",branchID:"B",kind:.fuse,ratedAmps:2,i2tCapacity:2)])
        _=IndustrialCircuitSolver.advance(fuseNet,state:&fuseState,dtSeconds:0.2)
        XCTAssertTrue(fuseState.protectionByID["FU"]?.tripped == true)
    }

    func testContactHeatingRaisesResistanceAndCanProgressToFailure() {
        var state=CircuitDynamicState()
        let net=CircuitNetlist(nodes:[.init(id:"P",label:"P"),.init(id:"M",label:"M"),.init(id:"0",label:"0",isGround:true)],branches:[.init(id:"HOT",fromNodeID:"P",toNodeID:"M",kind:.contact,baseResistanceOhms:2),.init(id:"LOAD",fromNodeID:"M",toNodeID:"0",kind:.coil,baseResistanceOhms:4)],sources:[.init(id:"S",positiveNodeID:"P",negativeNodeID:"0",nominalVolts:24,internalResistanceOhms:0.05)],thermal:[.init(branchID:"HOT",thermalMassJPerC:2,thermalResistanceCPerW:20,warningTemperatureC:35,failureTemperatureC:70)])
        for _ in 0..<20 { _=IndustrialCircuitSolver.advance(net,state:&state,dtSeconds:2,ambientC:25) }
        let t=state.thermalByBranch["HOT"]!
        XCTAssertGreaterThan(t.temperatureC,35)
        XCTAssertGreaterThan(t.damage,0)
    }

    func testTransformerReportsRegulationAndOverload() {
        let light=TransformerModel.solve(primaryVolts:480,ratioPrimaryToSecondary:4,ratedVA:500,secondaryLoadOhms:100)
        let heavy=TransformerModel.solve(primaryVolts:480,ratioPrimaryToSecondary:4,ratedVA:100,secondaryLoadOhms:2)
        XCTAssertGreaterThan(light.secondaryVolts,119)
        XCTAssertTrue(heavy.overloaded)
        XCTAssertLessThan(heavy.secondaryVolts,120)
    }

    func testThreePhasePhaseLossCreatesCurrentImbalanceAndThermalStress() {
        let spec=ThreePhaseMotorSpec(ratedHP:10)
        let healthy=ThreePhaseMotorModel.solve(spec:spec,lineToLineVolts:[480,480,480])
        let lost=ThreePhaseMotorModel.solve(spec:spec,lineToLineVolts:[480,480,480],phaseOpen:1)
        XCTAssertFalse(healthy.phaseLoss)
        XCTAssertTrue(lost.phaseLoss)
        XCTAssertGreaterThan(lost.currentImbalancePercent,healthy.currentImbalancePercent)
        XCTAssertGreaterThan(lost.thermalStress,healthy.thermalStress)
    }

    func testCurrentLoopComplianceLimitsTwentyMilliampSignal() {
        let healthy=CurrentLoopModel.solve(supplyVolts:24,requestedMilliamps:20,receiverOhms:250,wireOhms:20,minimumTransmitterVolts:10)
        let starved=CurrentLoopModel.solve(supplyVolts:12,requestedMilliamps:20,receiverOhms:500,wireOhms:100,barrierDropVolts:2,minimumTransmitterVolts:10)
        XCTAssertTrue(healthy.inCompliance)
        XCTAssertEqual(healthy.actualMilliamps,20,accuracy:0.001)
        XCTAssertFalse(starved.inCompliance)
        XCTAssertLessThan(starved.actualMilliamps,20)
    }

    func testAnalogInputImpedanceAndCommonModeLimits() {
        let loaded=AnalogInputModel.solve(signalVolts:10,sourceResistanceOhms:100_000,inputImpedanceOhms:100_000)
        XCTAssertEqual(loaded.sensedVolts,5,accuracy:0.001)
        let bad=AnalogInputModel.solve(signalVolts:5,sourceResistanceOhms:100,commonModeVolts:24,commonModeLimitVolts:10,isolationRatingVolts:50)
        XCTAssertFalse(bad.commonModeValid)
        XCTAssertTrue(bad.isolationValid)
        XCTAssertTrue(bad.saturated)
    }

    func testAll28MachinesProduceSolvableTopologyNetlists() throws {
        for machine in PlayableMachineKind.allCases {
            let scenario=try TopologyProceduralFaultGenerator.generate(machine:machine,seed:77,difficulty:.controlsTechnician)
            guard let cid=scenario.faults.first?.circuitID else { XCTFail("No circuit for \(machine)"); continue }
            var dynamic=CircuitDynamicState()
            let snap=TopologyCircuitNetlistBuilder.solve(scenario:scenario,circuitID:cid,state:&dynamic)
            XCTAssertTrue(snap.solution.converged,"Did not converge: \(machine)")
            XCTAssertFalse(snap.solution.nodeVoltages.isEmpty)
            XCTAssertFalse(snap.solution.branches.isEmpty)
        }
    }

    func testTrulyFloatingConductorShowsGhostWithHighZButCollapsesWithLoZ() {
        let baseNodes:[CircuitNodeSpec]=[.init(id:"P",label:"24V"),.init(id:"F",label:"floating"),.init(id:"0",label:"0V",isGround:true)]
        let source=CircuitVoltageSource(id:"PS",positiveNodeID:"P",negativeNodeID:"0",nominalVolts:24,internalResistanceOhms:0.1)
        let coupling=CircuitBranchSpec(id:"COUPLE",fromNodeID:"P",toNodeID:"F",kind:.leakage,baseResistanceOhms:8_000_000,temperatureCoefficientPerC:0)
        var highNet=CircuitNetlist(nodes:baseNodes,branches:[coupling,.init(id:"METER",fromNodeID:"F",toNodeID:"0",kind:.sensorInput,baseResistanceOhms:10_000_000,temperatureCoefficientPerC:0)],sources:[source])
        let hi=IndustrialCircuitSolver.solve(highNet).voltage("F")!
        highNet.branches[1].baseResistanceOhms=3_000
        let lo=IndustrialCircuitSolver.solve(highNet).voltage("F")!
        XCTAssertGreaterThan(hi,10)
        XCTAssertLessThan(lo,0.1)
    }

    func testTopologyMeterUsesSolvedCircuitAndLoZLoadsFloatingNode() throws {
        var scenario=try TopologyProceduralFaultGenerator.generate(machine:.packagingCell,seed:42,difficulty:.technician)
        guard let fault=scenario.faults.first, let cid=scenario.topology.bindingCircuitIDs[fault.ioTag ?? ""] else { return XCTFail("missing generated circuit") }
        let nodes=scenario.topology.nodes.filter{$0.circuitID==cid}.sorted{$0.order<$1.order}
        guard let source=nodes.first(where:{$0.kind == .source}),let far=nodes.last(where:{$0.kind != .common && $0.kind != .ground}) else{return XCTFail("missing points")}
        // Force a physical open so the parasitic/high-Z vs LoZ behavior is deterministic.
        if let edge=scenario.topology.edges(in:cid).dropFirst().first {
            scenario.faults=[.init(id:"OPEN",kind:.vibrationIntermittentOpen,machine:scenario.machine,circuitID:cid,targetNodeID:edge.toNodeID,targetEdgeID:edge.id,ioTag:fault.ioTag,fieldDeviceTag:fault.fieldDeviceTag,magnitude:1,intermittent:false,explanation:"test open")]
        }
        let high=TopologyMeterEngine.measureVoltage(scenario:scenario,redNodeID:far.id,blackNodeID:nodes.first(where:{$0.kind == .common})!.id,loaded:false,loZ:false)
        let low=TopologyMeterEngine.measureVoltage(scenario:scenario,redNodeID:far.id,blackNodeID:nodes.first(where:{$0.kind == .common})!.id,loaded:false,loZ:true)
        XCTAssertGreaterThan(high.value ?? 0,low.value ?? 0)
        _=source
    }
    func testSolvedCircuitRuntimeAppliesElectricalConsequencesToClosedLoopMachine() throws {
        var scenario=try TopologyProceduralFaultGenerator.generate(machine:.packagingCell,seed:88,difficulty:.technician)
        var machine=try FullyClosedLoopMachineRuntime(machine:.packagingCell)
        guard let binding=machine.executable.bindings.first(where:{$0.direction == .output}),
              let cid=scenario.topology.bindingCircuitIDs[binding.ioTag],
              let terminal=scenario.topology.nodes.first(where:{$0.circuitID==cid && $0.kind == .panelTerminal}),
              let edge=scenario.topology.edges.first(where:{$0.toNodeID==terminal.id}) else { return XCTFail("output circuit missing") }
        scenario.faults=[.init(id:"SOLVED-HR",kind:.looseHighResistanceTerminal,machine:.packagingCell,circuitID:cid,targetNodeID:terminal.id,targetEdgeID:edge.id,ioTag:binding.ioTag,fieldDeviceTag:binding.fieldDeviceTag,magnitude:80,intermittent:false,explanation:"solver-coupled high resistance")]
        var coupled=CircuitCoupledElectricalScenarioRuntime(scenario:scenario)
        let snap=coupled.advanceAndApply(seconds:1,to:&machine)
        XCTAssertFalse(snap.circuitSnapshots.isEmpty)
        XCTAssertTrue(machine.plant.faults.contains{$0.id=="SOLVED-HR"})
        _=try machine.cycle(elapsedMilliseconds:100)
        XCTAssertNotNil(machine.latest)
    }

}
