import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusSimulation

private func makeLoop() -> InstrumentLoop {
    InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())
}

private func started(_ loop: InstrumentLoop) throws -> SimulationRuntime {
    let runtime = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
    try runtime.start()
    return runtime
}

@Suite struct SimulationEventTests {
    @Test func faultChangesAreDeliveredWithTheNextSnapshot() throws {
        let loop = makeLoop()
        let sim = try started(loop)
        for _ in 0..<10 { try sim.step() }
        let fault = SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded terminal")
        sim.inject(fault)
        let injected = try sim.step()
        #expect(injected.tick == 11)
        #expect(injected.events.count == 1)
        let event = try #require(injected.events.first)
        #expect(event.kind == .faultInjected)
        #expect(event.tick == 10 && event.seconds == 5, "Stamped when injected, between ticks 10 and 11")
        #expect(event.key == loop.contactOhms && event.value == 400 && event.summary == "Corroded terminal")

        #expect(try sim.step().events.isEmpty)
        sim.clear(ObjectID.make())  // Unknown fault: nothing to report.
        #expect(try sim.step().events.isEmpty)
        sim.clear(fault.id)
        let cleared = try sim.step()
        #expect(cleared.events.map(\.kind) == [.faultCleared])
        #expect(cleared.events.first?.summary == "Cleared: Corroded terminal")
        #expect(sim.events.map(\.kind) == [.faultInjected, .faultCleared])
    }

    @Test func thresholdCrossingsAreReportedOnceInTheWatchedDirection() throws {
        let loop = makeLoop()
        let sim = try started(loop)
        sim.watch(SimulationThreshold(name: "High level", key: loop.level, level: 70, direction: .rising))
        sim.watch(SimulationThreshold(name: "Low level", key: loop.level, level: 30, direction: .falling))
        try sim.run(for: 600)
        let crossings = sim.events.filter { $0.kind == .thresholdCrossed }
        #expect(crossings.count == 1, "The level rises from 50 to 90 once and never falls below 30")
        let crossing = try #require(crossings.first)
        #expect(crossing.reference == 70)
        #expect(try #require(crossing.value) >= 70)
        let before = try #require(sim.history.first { $0.tick == crossing.tick - 1 }?.values[loop.level])
        #expect(before < 70)
        #expect(sim.history.flatMap(\.events) == sim.events)
    }

    @Test func attachedDetectorReportsTheFirstDivergenceOnce() throws {
        let loop = makeLoop()
        let reference = try started(loop)
        try reference.run(for: 60)

        let actual = try started(loop)
        let path = [loop.terminalVoltage, loop.loopCurrent, loop.measuredLevel]
        actual.attach(DivergenceWatch(reference: reference.history, signalPath: path, defaultTolerance: 1e-6))
        for _ in 0..<20 { try actual.step() }
        #expect(actual.firstDivergence == nil)
        actual.inject(SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded terminal"))
        try actual.run(for: 50)

        let divergences = actual.events.filter { $0.kind == .firstDivergence }
        #expect(divergences.count == 1)
        let offline = try #require(
            DivergenceDetector.firstDivergence(reference: reference.history, actual: actual.history, signalPath: path, defaultTolerance: 1e-6)
        )
        let found = try #require(actual.firstDivergence)
        #expect(found == offline, "Online detection matches the offline detector")
        #expect(found.key == loop.terminalVoltage, "The most upstream signal is reported")
        #expect(divergences.first?.tick == found.tick && divergences.first?.reference == found.expected)
    }

    @Test func eventsBecomeModeledTimelineEvents() throws {
        let run = ObjectID.make()
        let key = StateKey(.make(), "level")
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let event = SimulationEvent(kind: .thresholdCrossed, tick: 8, seconds: 4, key: key, value: 71, reference: 70, summary: "High level")
        let simulation = ObjectID.make()
        let timeline = event.timelineEvent(run: run, startedAt: start, extraSubjects: [simulation])
        #expect(timeline.kind == .thresholdCrossed)
        #expect(timeline.at == start.addingTimeInterval(4))
        #expect(timeline.subjects == [key.object, simulation])
        #expect(timeline.provenance.truth == .modeled)
        #expect(timeline.provenance.origin == .simulation(run: run))
        #expect(timeline.payload["value"] == .double(71) && timeline.payload["quantity"] == .string("level"))
        #expect(Set(SimulationEvent.Kind.allCases.map(\.eventKind.rawValue)).count == 4)
    }

    @Test func snapshotsEncodedBeforeEventsStillDecode() throws {
        let key = StateKey(.make(), "level")
        let legacy = Snapshot(tick: 3, seconds: 1.5, values: [key: 42])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["events"] = nil
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == legacy)
        #expect(classify(SimulationError.invalidTimeStep(0)).category == .userInput)
    }
}

@Suite struct AsyncRunTests {
    private func thermal(_ mass: ThermalMass = ThermalMass(object: .make())) throws -> (SimulationRuntime, ThermalMass) {
        let runtime = try SimulationRuntime(
            dt: 0.1, state: mass.state(heatInput: 100, heatCapacity: 1_000, lossCoefficient: 2), solvers: [mass.solver], historyLimit: 1_000
        )
        try runtime.start()
        return (runtime, mass)
    }

    @Test func asyncRunReportsProgressAndMatchesTheSynchronousRun() async throws {
        let (background, mass) = try thermal()
        let (sync, _) = try thermal(mass)
        let progress = WorkProgress(title: "Heat soak", stages: [("Ticks", nil)])
        let last = try await background.run(ticks: 1_000, progress: progress, checkEvery: 64)
        try sync.run(for: 100)

        #expect(last?.tick == 1_000)
        #expect(try background.value(mass.temperature) == sync.value(mass.temperature))
        let snapshot = progress.snapshot
        #expect(snapshot.stages[0].state == .completed)
        #expect(snapshot.stages[0].completedUnits == 1_000)
        #expect(snapshot.stages[0].totalUnits == 1_000)
    }

    @Test func cancellationStopsTheRunAndKeepsCompletedTicks() async throws {
        let (runtime, _) = try thermal()
        let progress = WorkProgress(title: "Long run", stages: [("Ticks", nil)])
        let task = Task { try await runtime.run(ticks: 50_000_000, progress: progress, checkEvery: 100) }
        // Cancel once some work is visibly done.
        for await update in progress.updates() where update.stages[0].completedUnits > 0 {
            task.cancel()
            break
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(progress.snapshot.isCancelled)
        #expect(runtime.tick > 0 && runtime.tick < 50_000_000)
        #expect(runtime.tick % 100 == 0, "Stops on a batch boundary")
    }
}
