import XCTest
@testable import ControlsPLC
@testable import ControlsSimulation
@testable import ControlsTraining

final class EndToEndMachineControlsTests: XCTestCase {
    func testAllHeroMachinesCompileToExecutableLadderAST() throws {
        for machine in PlayableMachineKind.allCases {
            let source = HeroMachineControlsProjectCatalog.project(for: machine)
            let compiled = try MachineLadderCompiler.compile(source)
            XCTAssertFalse(compiled.controllerProject.tasks.isEmpty, "\(machine)")
            let program = try XCTUnwrap(compiled.controllerProject.tasks.first?.programs.first)
            XCTAssertNotNil(program.routine(named: "MainRoutine"), "\(machine)")
            XCTAssertGreaterThan(program.routines.reduce(0) { $0 + $1.rungs.count }, source.ladderRoutines.count, "\(machine)")
            XCTAssertEqual(compiled.bindings.count, source.ioPoints.count, "\(machine)")
        }
    }

    func testROPT1802ResolvesThroughPhysicalAndPLCChain() throws {
        let source = HeroMachineControlsProjectCatalog.project(for: .reverseOsmosisPlant)
        let compiled = try MachineLadderCompiler.compile(source)
        let binding = try XCTUnwrap(compiled.binding(for: "PT1802"))
        XCTAssertEqual(binding.ioTag, "ROPress")
        XCTAssertEqual(binding.fieldDeviceTag, "PT1802")
        XCTAssertEqual(binding.signalType, .analog4to20mA)
        XCTAssertNotNil(binding.rawTag)
        XCTAssertTrue(binding.moduleCatalog.contains("1756") || binding.moduleCatalog.contains("5069") || !binding.moduleCatalog.isEmpty)
        XCTAssertFalse(compiled.links(for: "PT1802").isEmpty)
        XCTAssertTrue(compiled.links(for: "ROPress").contains { $0.pidTag == "PIC1801" })
    }

    func testROAnalogValueScalesFromFourToTwentyMilliampIntoPLC() throws {
        var runtime = try EndToEndMachineRuntime(machine: .reverseOsmosisPlant)
        let binding = try XCTUnwrap(runtime.executable.binding(for: "PT1802"))
        runtime.setAnalog("PT1802", engineeringValue: 300)
        let snapshot = try runtime.scan()
        let rawTag = try XCTUnwrap(binding.rawTag)
        XCTAssertEqual(snapshot.rawSignals[rawTag] ?? -1, 12, accuracy: 0.02)
        guard case let .real(eu)? = snapshot.plcValues["ROPress"] else { return XCTFail("ROPress not REAL") }
        XCTAssertEqual(eu, 300, accuracy: 0.5)
    }

    func testOpenWirePhysicallyChangesRawSignalAndPLCValue() throws {
        var runtime = try EndToEndMachineRuntime(machine: .reverseOsmosisPlant)
        runtime.setAnalog("PT1802", engineeringValue: 300)
        _ = try runtime.scan()
        runtime.inject(.init(target: "PT1802", kind: .openWire))
        let snapshot = try runtime.scan()
        let binding = try XCTUnwrap(runtime.executable.binding(for: "PT1802"))
        XCTAssertEqual(snapshot.rawSignals[try XCTUnwrap(binding.rawTag)] ?? -1, 4, accuracy: 0.01)
        guard case let .real(eu)? = snapshot.plcValues["ROPress"] else { return XCTFail() }
        XCTAssertEqual(eu, binding.engineeringLow ?? 0, accuracy: 0.01)
    }

    func testSpatialAdapterBuildsFieldTerminalAndIOPathForEveryPoint() throws {
        for machine in PlayableMachineKind.allCases {
            let compiled = try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for: machine))
            for binding in compiled.bindings {
                let doc = EndToEndSpatialAdapter.document(for: binding)
                XCTAssertEqual(doc.symbols.count, 3, "\(machine) \(binding.ioTag)")
                XCTAssertEqual(doc.conductors.count, 2, "\(machine) \(binding.ioTag)")
                XCTAssertTrue(doc.symbols.contains { $0.tag == binding.fieldDeviceTag })
                XCTAssertTrue(doc.symbols.contains { $0.tag.contains(binding.rack) })
                XCTAssertTrue(doc.validationIssues().isEmpty, "\(machine) \(binding.ioTag): \(doc.validationIssues())")
            }
        }
    }

    func testDebugIndexReferencesExecutableRungForAnalogPoint() throws {
        let compiled = try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for: .reverseOsmosisPlant))
        let links = compiled.links(for: "PT1802")
        let executable = try XCTUnwrap(links.first { $0.routine != nil && $0.rungNumber != nil })
        XCTAssertEqual(executable.task, "MainTask")
        XCTAssertEqual(executable.program, "MachineControl")
    }

    func testNetworkDevicesAreClickableIntoDebuggerIndex() throws {
        for machine in PlayableMachineKind.allCases {
            let source = HeroMachineControlsProjectCatalog.project(for: machine)
            let compiled = try MachineLadderCompiler.compile(source)
            for node in source.ethernetNodes {
                XCTAssertFalse(compiled.links(for: node.name).isEmpty, "Missing debugger link: \(machine) / \(node.name)")
            }
        }
    }

    func testInjectedDiscreteWiringFaultChangesLadderObservedInput() throws {
        let machine = PlayableMachineKind.packagingCell
        var runtime = try EndToEndMachineRuntime(machine: machine)
        let discrete = try XCTUnwrap(runtime.executable.bindings.first { $0.direction == .input && $0.rawTag == nil })
        runtime.setDigital(discrete.ioTag, value: true)
        var snapshot = try runtime.scan()
        XCTAssertEqual(snapshot.plcValues[discrete.ioTag]?.boolValue, true)
        runtime.inject(.init(target: discrete.cableID, kind: .openWire))
        snapshot = try runtime.scan()
        XCTAssertEqual(snapshot.plcValues[discrete.ioTag]?.boolValue, false)
    }
}
