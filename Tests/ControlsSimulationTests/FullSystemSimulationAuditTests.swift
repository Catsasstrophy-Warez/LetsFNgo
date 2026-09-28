import XCTest
@testable import ControlsSimulation
@testable import ControlsPLC

final class FullSystemSimulationAuditTests: XCTestCase {
    func testAll28HeroMachinesExecuteClosedLoopPhysicalCycles() throws {
        for machine in PlayableMachineKind.allCases {
            var runtime = try FullyClosedLoopMachineRuntime(machine: machine)
            for _ in 0..<10 { _ = try runtime.cycle(elapsedMilliseconds: 100) }
            XCTAssertGreaterThanOrEqual(runtime.authoredCycle.elapsedSeconds, 0.999, "Cycle physics did not advance for \(machine)")
            XCTAssertFalse(runtime.executable.controllerProject.tasks.flatMap(\.programs).isEmpty, "No executable PLC programs for \(machine)")
            XCTAssertFalse(runtime.materialFlow.profile.zones.isEmpty, "No material flow zones for \(machine)")
        }
    }

    func testAllFiveBranchingPacksCompleteTwentyFourHoursAfterTenDecisions() throws {
        for pack in BranchingScenarioPackCatalog.all {
            let project: LineBuilderProject = (pack.id == .customerLaunchDay || pack.id == .utilityCrisis) ? ProductionLineTemplates.beverageLine : ProductionLineTemplates.packagingToPalletizing
            var runtime = try BranchingScenarioRuntime(pack: pack, project: project)
            for _ in 0..<10 {
                let choice = try XCTUnwrap(runtime.currentGate?.choices.first)
                _ = try runtime.choose(choice.id)
            }
            XCTAssertTrue(runtime.complete, "Decision gates not complete for \(pack.title)")
            let snap = try runtime.finish24Hours(stepMilliseconds: 600_000)
            XCTAssertGreaterThanOrEqual(snap.plant.elapsedSeconds, 86_400, "24h simulation incomplete for \(pack.title)")
            XCTAssertTrue((0...100).contains(runtime.score().overall), "Invalid score for \(pack.title)")
            XCTAssertFalse(runtime.ending().decisiveMoments.isEmpty, "No ending replay for \(pack.title)")
        }
    }
    func testAllFiveBranchingPacksCompleteTwentyFourHoursAcrossThreeDecisionStrategies() throws {
        for pack in BranchingScenarioPackCatalog.all {
            for strategyIndex in 0..<3 {
                let project: LineBuilderProject = (pack.id == .customerLaunchDay || pack.id == .utilityCrisis) ? ProductionLineTemplates.beverageLine : ProductionLineTemplates.packagingToPalletizing
                var runtime = try BranchingScenarioRuntime(pack: pack, project: project)
                for _ in 0..<10 {
                    let choices = try XCTUnwrap(runtime.currentGate?.choices)
                    let idx = min(strategyIndex, choices.count - 1)
                    _ = try runtime.choose(choices[idx].id)
                }
                let snap = try runtime.finish24Hours(stepMilliseconds: 600_000)
                XCTAssertGreaterThanOrEqual(snap.plant.elapsedSeconds, 86_400, "24h simulation incomplete for \(pack.title), strategy \(strategyIndex)")
                XCTAssertTrue((0...100).contains(runtime.score().overall))
                XCTAssertEqual(runtime.records.count, 10)
            }
        }
    }

}
