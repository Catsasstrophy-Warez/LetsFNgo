import Foundation
import NexusCore
import NexusGraph
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSearch
import Testing
@testable import NexusDemo

@Suite struct DemoWorldTests {
    @Test func seedsAnOpenInvestigationReadyForTheTechnician() throws {
        let store = try NexusStore(.inMemory)
        let world = try DemoWorld.seed(into: store)
        let hypotheses = try InvestigationRuntime(store: store).hypotheses(of: world.investigation)
        #expect(hypotheses.count == 4 && hypotheses.allSatisfy { $0.state == .candidate })
        let display = try store.measurements(at: world.loop.card, truth: .display)
        let ceiling = (12.0 / 670 * 1000 - 4) / 16 * 100
        #expect(display.count == 1 && abs(display[0].value.value - ceiling) < 1e-9)
        let search = SearchEngine(store: store, graph: ObjectGraph(store: store))
        #expect(try search.search(SearchQuery("LT-101 transmitter", scope: world.project)).first?.id == world.loop.transmitter)
        let ranked = try InvestigationRuntime(store: store).rankTests(world.tests, for: world.investigation)
        #expect(ranked.first?.option.title == "Read channel span from controller")
    }

    @Test func seedingIsIdempotentAcrossRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try DemoWorld.seedIfNeeded(into: try NexusStore(.file(url)))
        let store = try NexusStore(.file(url))
        let second = try DemoWorld.seedIfNeeded(into: store)
        #expect(second.investigation == first.investigation && second.loop == first.loop && second.fault == first.fault)
        #expect(try store.objects(ofType: .project).count == 1)
    }

    @Test func fieldAndTwinDisagreeAtTheTerminal() throws {
        let world = try DemoWorld.seed(into: try NexusStore(.inMemory))
        let field = try world.makeField()
        let twin = try world.makeTwin()
        #expect(abs(try field.value(world.loop.terminalVoltage) - 12) < 1e-6)
        #expect(try twin.value(world.loop.terminalVoltage) > 18)
    }
}
