import XCTest
@testable import ControlsSimulation
@testable import ControlsTraining

final class HeroMachineArchitectureTests: XCTestCase {
    func testEveryHeroMachineHasUniqueArchitectureProfile() {
        XCTAssertEqual(HeroMachineArchitectureCatalog.all.count, PlayableMachineKind.allCases.count)
        XCTAssertEqual(Set(HeroMachineArchitectureCatalog.all.map(\.machine)).count, PlayableMachineKind.allCases.count)
        for kind in PlayableMachineKind.allCases {
            let profile = HeroMachineArchitectureCatalog.profile(for: kind)
            XCTAssertFalse(profile.components.isEmpty, "Missing components for \(kind)")
            XCTAssertFalse(profile.signalPaths.isEmpty, "Missing signal paths for \(kind)")
            XCTAssertGreaterThanOrEqual(profile.failureChains.count, 4, "Need deep failure ecology for \(kind)")
        }
    }

    func testRosterIncludesRequiredIndustrialTechnologies() {
        let kinds = Set(HeroMachineArchitectureCatalog.all.flatMap { $0.components.map(\.kind) })
        for required:IndustrialComponentKind in [.remoteIOAdapter,.analogInput,.safetyController,.managedSwitch,.vfd,.servoDrive,.pneumaticManifold,.controlValve,.pump,.heater,.pidLoop] {
            XCTAssertTrue(kinds.contains(required), "Roster missing \(required)")
        }
    }

    func testMachineCampaignUsesItsOwnFailureEcology() {
        let profile = HeroMachineArchitectureCatalog.profile(for:.industrialOven)
        let campaign = IntegratedPlantCampaignCatalog.sevenDayCampaign(for:.industrialOven)
        XCTAssertEqual(campaign.title, "Industrial Oven — 7-Day Integrated Campaign")
        XCTAssertEqual(Set(campaign.faults.map(\.kind)), Set(profile.failureChains.map(\.faultKind)))
        XCTAssertTrue(campaign.faults.contains{$0.kind == .heaterOpenCircuit})
        XCTAssertTrue(campaign.faults.contains{$0.kind == .safetyChannelDiscrepancy})
    }

    func testArchitectureFaultMapsIntoNativeProcessPhysics() {
        let profile = HeroMachineArchitectureCatalog.profile(for:.pumpStation)
        let fault = ProgressivePlantFault(id:"pump",kind:.pumpCavitation,target:"P-01",onsetHour:0,initialSeverity:0.8,growthPerHour:0)
        let injection = profile.processFaultInjection(from:[fault],hour:1)
        XCTAssertEqual(injection.kind,.pumpCavitation)
        XCTAssertEqual(injection.severity,0.8,accuracy:0.0001)
    }

    func testAnalogAndNetworkFaultsDistortPLCObservation() {
        var engine=PlantFaultPropagationEngine()
        let physical=ScenarioProcessSnapshot(analog:["PressurePV":100],discrete:["PermissiveOK":true],events:[])
        let faults=[
            ProgressivePlantFault(id:"ai",kind:.analogModuleDrift,target:"AI",onsetHour:0,initialSeverity:0.8,growthPerHour:0),
            ProgressivePlantFault(id:"safe",kind:.safetyChannelDiscrepancy,target:"SAFE",onsetHour:0,initialSeverity:1,growthPerHour:0)
        ]
        let result=engine.applySensorPath(physical:physical,faults:faults,hour:1,time:0.5)
        XCTAssertGreaterThan(result.0.analog["PressurePV"] ?? 0,100)
    }

    func testAllUIHeroMachinesMapToPlayableArchitecture() {
        XCTAssertEqual(HeroMachineID.allCases.count, HeroMachineArchitectureCatalog.all.count)
        for machine in HeroMachineID.allCases {
            let playable=machine.playableMachineKind
            XCTAssertNotNil(playable)
            if let playable { XCTAssertEqual(HeroMachineArchitectureCatalog.profile(for:playable).machine,playable) }
        }
    }
}
