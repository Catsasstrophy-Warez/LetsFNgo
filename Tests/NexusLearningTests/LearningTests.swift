import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation
import Testing
@testable import NexusLearning

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

@Suite struct LearningTests {
    @Test func unresolvedInvestigationsCannotBecomeScenarios() throws {
        let store = try NexusStore(.inMemory)
        let point = try store.create(ObjectRecord(
            type: .testPoint, title: "TP", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        )).id
        let investigation = try InvestigationRuntime(store: store).open(symptom: "Open case", subjects: [point], by: tech).id
        let loop = InstrumentLoop(tank: .make(), transmitter: .make(), terminal: point, card: .make(), controller: .make(), valve: .make())
        #expect(throws: LearningError.investigationNotResolved(investigation)) {
            try LearningRuntime(store: store).makeScenario(
                from: investigation, loop: loop,
                fault: SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "x"), tests: [], by: tech
            )
        }
        #expect(throws: LearningError.notAScenario(point)) { try LearningRuntime(store: store).scenario(point) }
    }

    @Test func scenarioRoundTripsThroughItsAttributes() throws {
        let loop = InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())
        let scenario = TrainingScenario(
            id: .make(), briefing: "Reads low", loop: loop,
            fault: SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded"),
            choices: ["A", "B"],
            tests: [TestOption(title: "V", testPoint: loop.terminal, quantity: "terminalVoltage", condition: "high level", cost: 5, safety: .caution)],
            cause: "B", expertPath: ["V"], firstDivergence: nil
        )
        let record = ObjectRecord(
            id: scenario.id, type: .trainingScenario, title: "s", attributes: LearningRuntime.attributes(of: scenario),
            provenance: Provenance(origin: tech, truth: .derived, timestamp: t0)
        )
        #expect(try LearningRuntime.scenario(from: record) == scenario)
    }
}
