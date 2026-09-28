import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation
import Testing

@testable import NexusLearning

private let tech = Origin.user(id: "tech-7")

private func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString).sqlite")
}

@Suite struct GenericScenarioTests {
    /// A motor frame (thermal mass) and its rotor (inertia), with a blocked
    /// cooling fan: loss coefficient cut to a fifth.
    func simulator() -> GenericScenarioSimulator {
        let frame = ObjectID.make()
        let rotor = ObjectID.make()
        let mass = ThermalMass(object: frame)
        let body = RotatingInertia(object: rotor)
        var state = mass.state(heatInput: 400, heatCapacity: 20_000, lossCoefficient: 10)
        let spin = body.state(inertia: 0.2, torque: 5, viscousFriction: 0.01)
        state.parameters.merge(spin.parameters) { $1 }
        state.values.merge(spin.values) { $1 }
        return GenericScenarioSimulator(
            state: state, solvers: [.thermal(frame), .mechanical(rotor)],
            faults: [SimulatedFault(parameter: mass.lossCoefficient, value: 2, summary: "Cooling fan blocked")], dt: 10, runSeconds: 20_000
        )
    }

    @Test func genericScenarioReplaysDeterministically() throws {
        let simulator = simulator()
        let first = try simulator.makeField()
        let second = try simulator.makeField()
        #expect(first.history.count == 2_001)
        #expect(first.history.map(\.values) == second.history.map(\.values))
        #expect(first.events.map(\.summary) == second.events.map(\.summary))

        // Stored and decoded, it replays the same run.
        let decoded = try GenericScenarioSimulator(decoding: simulator.encoded())
        #expect(decoded == simulator)
        #expect(try decoded.makeField().history.map(\.values) == first.history.map(\.values))

        // The fault is what separates field from twin.
        let mass = ThermalMass(
            object: try #require(
                simulator.solvers.compactMap { spec -> ObjectID? in
                    if case .thermal(let id) = spec { return id }
                    return nil
                }.first))
        let hot = try first.value(mass.temperature)
        let healthy = try simulator.makeTwin().value(mass.temperature)
        #expect(hot > healthy + 20)
    }

    @Test func genericScenarioFromAResolvedInvestigationSurvivesReload() throws {
        let url = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ManualClock(fixtureStart)
        var store = try NexusStore(.file(url), clock: clock)
        let simulator = simulator()
        guard case .thermal(let frame) = simulator.solvers[0] else { Issue.record("No frame"); return }
        let mass = ThermalMass(object: frame)
        try store.create(
            ObjectRecord(id: frame, type: .component, title: "Motor frame", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now())))
        let investigations = InvestigationRuntime(store: store, clock: clock)
        let investigation = try investigations.open(symptom: "Motor trips on overtemperature", subjects: [frame], by: tech).id
        let blocked = try investigations.propose(
            "Blocked cooling fan", in: investigation,
            predictions: [Prediction(testPoint: frame, quantity: "temperature", unit: "degC", low: 60, high: 250)], by: tech
        )
        _ = try investigations.propose(
            "Overloaded drive train", in: investigation,
            predictions: [Prediction(testPoint: frame, quantity: "temperature", unit: "degC", low: 25, high: 59)], by: tech
        )
        let field = try simulator.makeField()
        let reading = MeasurementRecord(
            quantityName: "temperature", value: Quantity(try field.value(mass.temperature), "degC"), testPoint: frame, sampledAt: clock.now(),
            provenance: Provenance(origin: tech, truth: .observed, timestamp: clock.now())
        )
        try store.add(reading)
        try investigations.assess(reading.id, in: investigation, by: tech)
        try investigations.confirm(blocked.id, in: investigation, by: tech)

        let tests = [TestOption(title: "Frame temperature", testPoint: frame, quantity: "temperature", cost: 2)]
        let scenario = try LearningRuntime(store: store, clock: clock).makeScenario(from: investigation, simulator: simulator, tests: tests, by: tech)
        #expect(scenario.topic == "generic" && scenario.expertPath == ["Frame temperature"])
        #expect(scenario.candidateReadings["Blocked cooling fan"]?["Frame temperature"] == ReadingRange(low: 60, high: 250, unit: "degC"))
        #expect(scenario.fault?.summary == "Cooling fan blocked" && scenario.loop == nil)
        #expect(try scenario.simulator.readings(for: tests, faulted: true)["Frame temperature"] == reading.value.value)

        store = try NexusStore(.file(url), clock: clock)
        let reloaded = try LearningRuntime(store: store).scenario(scenario.id)
        #expect(reloaded == scenario)
        #expect(try reloaded.makeField().history.map(\.values) == field.history.map(\.values))
    }

    @Test func scenariosStoredBeforeSimulatorsStillLoad() throws {
        let loop = InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())
        let fault = SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded")
        let legacy: [String: Attribute] = [
            "briefing": Attribute(.string("Reads low")),
            "loop": Attribute(ScenarioCodec.encode(loop)),
            "fault": Attribute(ScenarioCodec.encode(fault)),
            "choices": Attribute(.list([.string("A")])),
            "tests": Attribute(.list([])),
            "cause": Attribute(.string("A")),
            "expertPath": Attribute(.list([])),
        ]
        let record = ObjectRecord(
            type: .trainingScenario, title: "s", attributes: legacy, provenance: Provenance(origin: tech, truth: .derived, timestamp: fixtureStart)
        )
        let scenario = try LearningRuntime.scenario(from: record)
        #expect(scenario.loop == loop && scenario.fault == fault && scenario.topic == LoopScenarioSimulator.kind)
    }
}

@Suite struct AutomotiveScenarioTests {
    @Test func chargingScenarioFromTheAutomotiveSlice() throws {
        let url = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ManualClock(fixtureStart)
        var store = try NexusStore(.file(url), clock: clock)
        let closed = try ChargingCase.make(store: store, clock: clock, tech: tech)

        let learning = LearningRuntime(store: store, clock: clock)
        let scenario = try learning.makeScenario(from: closed.investigation, by: tech)
        let simulator = try #require(scenario.simulator as? ChargingScenarioSimulator)
        #expect(simulator.cause == .failingAlternator && simulator.severity == 1 && simulator.system == closed.system)
        #expect(scenario.topic == "chargingSystem")
        #expect(scenario.cause == ChargingFaultKind.failingAlternator.statement)
        #expect(scenario.choices.count == 4)
        #expect(scenario.expertPath == [ChargingTest.crankingVoltage.title, ChargingTest.chargingVoltage.title])
        #expect(scenario.firstDivergence == "Alternator output departs from the twin at once")
        #expect(scenario.candidateReadings.count == 4)

        // The replay reproduces what the meter saw.
        let replayed = try scenario.simulator.readings(for: scenario.tests, faulted: true)
        #expect(abs(try #require(replayed[ChargingTest.crankingVoltage.title]) - closed.crank.value.value) < 1e-9)
        #expect(abs(try #require(replayed[ChargingTest.chargingVoltage.title]) - closed.charging.value.value) < 1e-9)
        let healthy = try scenario.simulator.readings(for: scenario.tests, faulted: false)
        #expect(try #require(healthy[ChargingTest.chargingVoltage.title]) > 14)

        // Grading uses the same expert path as the loop.
        let expert = try learning.grade(scenario.id, learner: tech, testsRun: scenario.expertPath, diagnosis: scenario.cause)
        #expect(expert.score == 100)

        store = try NexusStore(.file(url), clock: clock)
        #expect(try LearningRuntime(store: store).scenario(scenario.id) == scenario)
        #expect(try store.relationships(from: scenario.id, kind: .derivedFrom).map(\.to) == [closed.investigation])
    }

    @Test func investigationsWithoutASimulatorAreRefused() throws {
        let store = try NexusStore(.inMemory)
        let clock = ManualClock(fixtureStart)
        let point = try store.create(
            ObjectRecord(type: .testPoint, title: "TP", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now()))
        ).id
        let investigations = InvestigationRuntime(store: store, clock: clock)
        let investigation = try investigations.open(symptom: "Odd", subjects: [point], by: tech).id
        let hypothesis = try investigations.propose(
            "Something", in: investigation, predictions: [Prediction(testPoint: point, quantity: "v", unit: "V", low: 0, high: 1)], by: tech
        )
        let reading = MeasurementRecord(
            quantityName: "v", value: Quantity(0.5, "V"), testPoint: point, sampledAt: clock.now(),
            provenance: Provenance(origin: tech, truth: .observed, timestamp: clock.now())
        )
        try store.add(reading)
        try investigations.assess(reading.id, in: investigation, by: tech)
        try investigations.confirm(hypothesis.id, in: investigation, by: tech)
        #expect(throws: LearningError.noSimulator(investigation)) {
            try LearningRuntime(store: store, clock: clock).makeScenario(from: investigation, by: tech)
        }
    }
}
