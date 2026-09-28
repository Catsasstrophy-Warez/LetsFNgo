import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusLearning
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSimulation
import Testing

@testable import NexusActions

/// `generateTrainingScenario` without a loop binding takes the generic path.
@Suite struct GenericScenarioActionTests {
    @Test func automotiveInvestigationsBecomeScenariosWithoutALoop() throws {
        let clock = ManualClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let store = try NexusStore(.inMemory, clock: clock)
        let tech = Origin.user(id: "tech-7")
        let actions = ActionExecutor(store: store, actor: tech, clock: clock)
        let garage = VehicleRuntime(store: store, clock: clock)
        let car = try garage.addVehicle(vin: "1HGCM82633A004352", by: tech)
        let system = try #require(ChargingSystem(car))
        let meter = try store.create(
            ObjectRecord(type: .instrument, title: "DMM", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now()))
        ).id
        let diagnosis = ChargingDiagnosis(system: system)
        let (investigation, hypotheses) = try diagnosis.open(in: actions.investigations, vehicle: car.id, by: tech)
        let field = try ChargingProtocol.run(system, faults: ChargingFaultKind.highResistanceGround.faults(on: system, severity: 0.5))
        for test in [ChargingTest.crankingVoltage, .groundDrop] {
            clock.advance(by: 60)
            let reading = diagnosis.observe(test, in: field, instrument: meter, at: clock.now())
            try store.add(reading)
            try actions.investigations.assess(reading.id, in: investigation, by: tech)
        }

        #expect(throws: LearningError.investigationNotResolved(investigation)) { try actions.generateTrainingScenario(from: investigation) }
        _ = try actions.confirmHypothesis(try #require(hypotheses[.highResistanceGround]).id)
        let result = try actions.generateTrainingScenario(from: investigation)
        let scenario = result.detail
        let simulator = try #require(scenario.simulator as? ChargingScenarioSimulator)
        #expect(simulator.cause == .highResistanceGround && abs(simulator.severity - 0.5) < 1e-9)
        #expect(scenario.loop == nil && result.produced == [scenario.id])
        #expect(scenario.expertPath == [ChargingTest.crankingVoltage.title, ChargingTest.groundDrop.title])
        #expect(try actions.learning.scenario(scenario.id) == scenario)
    }

    @Test func investigationsWithNothingToSimulateAreUnsupported() throws {
        let clock = ManualClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let store = try NexusStore(.inMemory, clock: clock)
        let tech = Origin.user(id: "tech-7")
        let actions = ActionExecutor(store: store, actor: tech, clock: clock)
        let point = try store.create(
            ObjectRecord(type: .testPoint, title: "TP", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now()))
        ).id
        let investigation = try actions.investigations.open(symptom: "Odd", subjects: [point], by: tech).id
        let hypothesis = try actions.investigations.propose(
            "Something", in: investigation, predictions: [Prediction(testPoint: point, quantity: "v", unit: "V", low: 0, high: 1)], by: tech
        )
        let reading = MeasurementRecord(
            quantityName: "v", value: Quantity(0.5, "V"), testPoint: point, sampledAt: clock.now(),
            provenance: Provenance(origin: tech, truth: .observed, timestamp: clock.now())
        )
        try store.add(reading)
        try actions.investigations.assess(reading.id, in: investigation, by: tech)
        try actions.investigations.confirm(hypothesis.id, in: investigation, by: tech)
        do {
            _ = try actions.generateTrainingScenario(from: investigation)
            Issue.record("Expected unsupported")
        } catch ActionError.unsupported(let reason) {
            #expect(reason.command == .generateTrainingScenario)
        }
    }
}
