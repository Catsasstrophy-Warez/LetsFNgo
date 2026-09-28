import Foundation
import NexusActions
import NexusCore
import NexusDemo
import NexusInvestigation
import NexusModel
import NexusPersistence
import Testing

/// The iPhone field workflow, command for command, as the UI issues it.
@Suite struct UIFlowReplayTests {
    @Test func fieldWorkflowThroughCommands() throws {
        let store = try NexusStore(.inMemory)
        let world = try DemoWorld.seedIfNeeded(into: store)
        let user = Origin.user(id: "local")
        let actions = ActionExecutor(store: store, actor: user, loops: [LoopBinding(loop: world.loop, faults: [world.fault], tests: world.tests)])
        let investigations = InvestigationRuntime(store: store)

        func record(_ value: Double, _ unit: String) throws {
            let best = try #require(try investigations.rankTests(world.tests, for: world.investigation).first?.option)
            var p = ActionParameters()
            p.investigation = world.investigation
            p.tests = world.tests
            p.testPoint = best.testPoint
            p.quantity = best.quantity
            p.loading = best.condition
            p.truth = .observed
            let first = try actions.perform(.recordMeasurement, selection: [world.investigation], parameters: p)
            guard case .needsInput = first else { Issue.record("Expected a form, got \(first)"); return }
            p.value = value
            p.unit = unit
            let outcome = try actions.perform(.recordMeasurement, selection: [world.investigation], parameters: p)
            #expect(outcome.report != nil, "\(best.title): \(outcome)")
        }

        try record(100, "%")
        try record(11.4, "V")
        let states = try investigations.hypotheses(of: world.investigation).map { "\($0.statement.prefix(20)): \($0.state)" }
        let live = try investigations.hypotheses(of: world.investigation).filter(\.state.isLive)
        #expect(live.count == 1, "\(states)")
        let cause = try #require(live.first)
        var confirm = ActionParameters()
        confirm.investigation = world.investigation
        #expect(try actions.perform(.confirmHypothesis, selection: [cause.id], parameters: confirm).report != nil)

        let form = try actions.perform(.createRepairTask, selection: [world.investigation])
        guard case .needsInput = form else { Issue.record("Expected a form, got \(form)"); return }
        var repair = ActionParameters()
        repair.steps = ["Clean and re-terminate TB-4"]
        let created = try actions.perform(.createRepairTask, selection: [world.investigation], parameters: repair)
        #expect(created.report != nil, "\(created)")
        var close = ActionParameters()
        close.resolution = "Corroded terminal cleaned"
        let closed = try actions.perform(.closeInvestigation, selection: [world.investigation], parameters: close)
        #expect(closed.report != nil, "\(closed)")
    }
}
