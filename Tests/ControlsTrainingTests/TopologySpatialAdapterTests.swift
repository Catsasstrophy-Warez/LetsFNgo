import XCTest
@testable import ControlsTraining
@testable import ControlsSimulation

final class TopologySpatialAdapterTests: XCTestCase {
    func testGeneratedScenarioCreatesSpatialDrawingWithRealTopologyEdges() throws {
        let s=try TopologyProceduralFaultGenerator.generate(machine:.reverseOsmosisPlant,seed:1802,difficulty:.expertNightmare)
        let d=TopologySpatialElectricalAdapter.document(from:s)
        XCTAssertFalse(d.symbols.isEmpty); XCTAssertFalse(d.conductors.isEmpty)
        XCTAssertEqual(d.validationIssues().filter{$0.contains("missing terminal")}.count,0)
        XCTAssertNotNil(d.selectedFaultWireID)
    }
}
