import XCTest
@testable import ControlsSimulation

final class HeroMachineControlsProjectTests: XCTestCase {
    func testAll28MachinesHaveDistinctControlsProjects() {
        XCTAssertEqual(HeroMachineControlsProjectCatalog.all.count, 28)
        XCTAssertEqual(Set(HeroMachineControlsProjectCatalog.all.map(\.projectNumber)).count, 28)
        XCTAssertEqual(Set(HeroMachineControlsProjectCatalog.all.map(\.machine)).count, 28)
    }

    func testEveryProjectHasRealDrawingAndHardwareDepth() {
        for project in HeroMachineControlsProjectCatalog.all {
            XCTAssertGreaterThanOrEqual(project.drawings.count, 7, project.projectTitle)
            XCTAssertGreaterThanOrEqual(project.racks.count, 2, project.projectTitle)
            XCTAssertGreaterThanOrEqual(project.configuredModuleCount, 9, project.projectTitle)
            XCTAssertGreaterThanOrEqual(project.ioPoints.count, 6, project.projectTitle)
            XCTAssertGreaterThanOrEqual(project.ethernetNodes.count, 3, project.projectTitle)
            XCTAssertGreaterThanOrEqual(project.ladderRoutines.count, 4, project.projectTitle)
            XCTAssertFalse(project.alarms.isEmpty)
        }
    }

    func testIOAddressesResolveToConfiguredRackSlots() {
        for project in HeroMachineControlsProjectCatalog.all {
            let slots = Dictionary(uniqueKeysWithValues: project.racks.map { ($0.rackName, Set($0.modules.map(\.slot))) })
            for point in project.ioPoints {
                XCTAssertTrue(slots[point.rack]?.contains(point.slot) == true, "\(project.projectTitle) \(point.tag) references missing rack/slot")
            }
        }
    }

    func testEveryMachineHasDistinctIOAndRoutineFingerprint() {
        let ioFingerprints = HeroMachineControlsProjectCatalog.all.map { $0.ioPoints.map(\.tag).sorted().joined(separator:"|") }
        let routineFingerprints = HeroMachineControlsProjectCatalog.all.map { $0.ladderRoutines.flatMap(\.rungSummaries).joined(separator:"|") }
        XCTAssertEqual(Set(ioFingerprints).count, 28)
        XCTAssertEqual(Set(routineFingerprints).count, 28)
    }

    func testNetworkNodeAddressesAreUniqueWithinEachProject() {
        for project in HeroMachineControlsProjectCatalog.all {
            XCTAssertEqual(Set(project.ethernetNodes.map(\.ipAddress)).count, project.ethernetNodes.count, project.projectTitle)
        }
    }

    func testMachineSpecificTechnologiesDiffer() {
        let oven = HeroMachineControlsProjectCatalog.project(for:.industrialOven)
        let servo = HeroMachineControlsProjectCatalog.project(for:.servoConveyor)
        let robot = HeroMachineControlsProjectCatalog.project(for:.roboticPalletizer)
        XCTAssertTrue(oven.instruments.contains { $0.signal == .thermocouple })
        XCTAssertTrue(servo.drives.contains { $0.driveFamily.contains("Kinetix") })
        XCTAssertFalse(robot.pneumatics.isEmpty)
        XCTAssertNotEqual(oven.ioPoints.map(\.tag), servo.ioPoints.map(\.tag))
    }

    func testProcessMachinesHaveAuthoredPIDConfiguration() {
        let expected:[PlayableMachineKind] = [.pressureSkid,.pumpStation,.airHandlingUnit,.industrialOven,.boilerSteamPlant,.cleanroomPressureSystem,.cipSkid,.reverseOsmosisPlant,.bioreactor,.chilledWaterPlant]
        for machine in expected { XCTAssertFalse(HeroMachineControlsProjectCatalog.project(for:machine).pidLoops.isEmpty, "Missing PID for \(machine)") }
    }

    func testSafetyConfigurationExistsForEveryMachine() {
        for project in HeroMachineControlsProjectCatalog.all {
            XCTAssertFalse(project.safety.inputDevices.isEmpty)
            XCTAssertTrue(project.safety.safetyNetwork.contains("CIP Safety"))
            XCTAssertFalse(project.safety.restartInterlock.isEmpty)
        }
    }

    func testProjectCanRoundTripCodable() throws {
        let original = HeroMachineControlsProjectCatalog.project(for:.htstPasteurizer)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HeroMachineControlsProject.self,from:data)
        XCTAssertEqual(decoded,original)
    }
}
