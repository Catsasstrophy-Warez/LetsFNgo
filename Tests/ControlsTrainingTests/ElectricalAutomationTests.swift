import XCTest
@testable import ControlsTraining

final class ElectricalAutomationTests: XCTestCase {
    func testCurriculumCoversEveryChapter() {
        XCTAssertEqual(ElectricalAutomationCatalog.lessons.count, 40)
        for chapter in ElectricalChapter.allCases { XCTAssertFalse(ElectricalAutomationCatalog.lessons(in: chapter).isEmpty, "Missing \(chapter)") }
    }
    func testLessonIDsAreUnique() {
        let ids = ElectricalAutomationCatalog.lessons.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
    func testFaultIDsAreUniqueAndDomainsHaveCoverage() {
        let ids = ElectricalAutomationCatalog.faultScenarios.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThanOrEqual(Set(ElectricalAutomationCatalog.faultScenarios.map(\.domain)).count, 8)
    }
    func testOhmsLaw() {
        let result = ElectricalCalculator.fromVoltageResistance(voltage: 24, resistance: 240)
        XCTAssertEqual(result?.current ?? -1, 0.1, accuracy: 0.000001)
        XCTAssertEqual(result?.power ?? -1, 2.4, accuracy: 0.000001)
    }
    func testAnalogScaling() {
        XCTAssertEqual(ElectricalCalculator.milliampToPercent(12), 50, accuracy: 0.000001)
        XCTAssertEqual(ElectricalCalculator.scale(raw: 12, rawLow: 4, rawHigh: 20, euLow: 0, euHigh: 100) ?? -1, 50, accuracy: 0.000001)
    }
    func testProgressionUnlocksAfterPriorLevelMastery() {
        var p = ElectricalProgressProfile()
        let apprentice = ElectricalAutomationCatalog.lessons.filter { $0.level == .apprentice }
        for lesson in apprentice { p.completeLesson(lesson.id) }
        let technician = ElectricalAutomationCatalog.lessons.first { $0.level == .technician }!
        XCTAssertTrue(p.isUnlocked(technician))
    }
    func testSignalTracesCrossPhysicalAndSoftwareLayers() {
        for trace in ElectricalAutomationCatalog.traces {
            let layers = Set(trace.nodes.map(\.layer))
            XCTAssertTrue(layers.contains(.device))
            XCTAssertTrue(layers.contains(.ioChannel))
            XCTAssertTrue(layers.contains(.controllerTag))
            XCTAssertTrue(layers.contains(.ladder))
        }
    }
}
