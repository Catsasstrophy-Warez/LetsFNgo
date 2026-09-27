import XCTest
@testable import ControlsSimulation
@testable import ControlsPLC

final class ClosedLoopOutputPhysicsTests: XCTestCase {
    func testAllHeroMachinesExposePhysicalOutputs() throws {
        for machine in PlayableMachineKind.allCases {
            let runtime = try FullyClosedLoopMachineRuntime(machine: machine)
            XCTAssertFalse(ClosedLoopPlantRuntime.outputPaths(for: runtime.executable).isEmpty, "\(machine) must expose physical outputs")
        }
    }

    func testOutputCommandCreatesElectricalAndActuatorState() throws {
        var runtime = try FullyClosedLoopMachineRuntime(machine: .packagingCell)
        guard let path = ClosedLoopPlantRuntime.outputPaths(for: runtime.executable).first else { return XCTFail("no output") }
        try runtime.forceControllerValue(path.commandTag, .bool(true))
        let s = try runtime.cycle(elapsedMilliseconds: 100)
        let e = try XCTUnwrap(s.physical.electrical[path.commandTag])
        XCTAssertGreaterThan(e.moduleVoltage, 0)
        XCTAssertGreaterThan(s.physical.actuators[path.fieldDeviceTag]?.actualPercent ?? 0, 0)
    }

    func testBrokenFieldWireSeparatesPLCCommandFromActuator() throws {
        var runtime = try FullyClosedLoopMachineRuntime(machine: .packagingCell)
        guard let path = ClosedLoopPlantRuntime.outputPaths(for: runtime.executable).first else { return XCTFail("no output") }
        try runtime.forceControllerValue(path.commandTag, .bool(true))
        runtime.injectOutputFault(.init(target: path.commandTag, kind: .brokenFieldWire))
        let s = try runtime.cycle(elapsedMilliseconds: 100)
        let e = try XCTUnwrap(s.physical.electrical[path.commandTag])
        XCTAssertGreaterThan(e.moduleVoltage, 0)
        XCTAssertEqual(e.fieldCurrentMilliamps, 0, accuracy: 0.001)
        XCTAssertEqual(s.physical.actuators[path.fieldDeviceTag]?.actualPercent ?? -1, 0, accuracy: 0.001)
    }

    func testWeldedContactorCanRunWithPLCCommandOff() throws {
        var runtime = try FullyClosedLoopMachineRuntime(machine: .packagingCell)
        guard let path = ClosedLoopPlantRuntime.outputPaths(for: runtime.executable).first else { return XCTFail("no output") }
        try runtime.forceControllerValue(path.commandTag, .bool(false))
        runtime.injectOutputFault(.init(target: path.commandTag, kind: .weldedContactor))
        let s = try runtime.cycle(elapsedMilliseconds: 100)
        XCTAssertEqual(s.physical.electrical[path.commandTag]?.plcCommand ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(s.physical.actuators[path.fieldDeviceTag]?.actualPercent ?? 0, 0)
    }

    func testDriveFaultCollapsesPhysicalSpeedAndPublishesFaultFeedback() throws {
        var runtime = try FullyClosedLoopMachineRuntime(machine: .servoConveyor)
        guard let path = ClosedLoopPlantRuntime.outputPaths(for: runtime.executable).first(where: { $0.kind == .servo || $0.kind == .vfd }) else { return XCTFail("no drive") }
        try runtime.forceControllerValue(path.commandTag, .bool(true))
        runtime.injectOutputFault(.init(target: path.fieldDeviceTag, kind: .driveFault))
        let s = try runtime.cycle(elapsedMilliseconds: 100)
        XCTAssertEqual(s.physical.actuators[path.fieldDeviceTag]?.speedHz ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(s.physical.actuators[path.fieldDeviceTag]?.faulted ?? false)
    }

    func testPhysicalProcessGeneratesFeedbackForSubsequentPLCScan() throws {
        var runtime = try FullyClosedLoopMachineRuntime(machine: .packagingCell)
        guard let path = ClosedLoopPlantRuntime.outputPaths(for: runtime.executable).first else { return XCTFail("no output") }
        try runtime.forceControllerValue(path.commandTag, .bool(true))
        _ = try runtime.cycle(elapsedMilliseconds: 500)
        let second = try runtime.cycle(elapsedMilliseconds: 500)
        XCTAssertGreaterThan(second.physical.process.speedPercent + second.physical.process.flowPercent, 0)
        XCTAssertGreaterThanOrEqual(second.physical.process.producedUnits, 0)
    }

    func testOutputFaultKindsAreCodable() throws {
        let fault = OutputPathFault(target: "O:1", kind: .outputChannelOpen, magnitude: 0.2)
        let data = try JSONEncoder().encode(fault)
        XCTAssertEqual(try JSONDecoder().decode(OutputPathFault.self, from: data), fault)
    }
}
