import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusSimulation
import Testing

@testable import NexusTelemetry

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func makeLoop() -> InstrumentLoop {
    InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())
}

@Suite struct SimulationIngestTests {
    @Test func snapshotValuesBecomeSamplesOnModeledChannels() async throws {
        let loop = makeLoop()
        let sim = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        try sim.start()
        try await sim.run(ticks: 240)

        let telemetry = TelemetryStore(store: try NexusStore(.inMemory))
        // A technician's observed channel on the same test point and quantity.
        let meter = try await telemetry.createChannel(
            object: loop.terminal, quantity: "terminalVoltage", unit: "V",
            provenance: Provenance(origin: .instrument(id: .make()), truth: .observed, timestamp: start)
        )
        try await telemetry.append([TelemetrySample(date: start, value: 20.7)], to: meter.id, truth: .observed)

        let keys: Set<StateKey> = [loop.terminalVoltage, loop.loopCurrent]
        let units: [String: String] = ["terminalVoltage": "V", "loopCurrent": "mA"]
        let channels = try await telemetry.ingest(sim, startedAt: start, keys: keys) { units[$0.quantity] ?? "" }

        #expect(Set(channels.keys) == keys)
        for (key, channel) in channels {
            #expect(channel.truth == .modeled)
            #expect(channel.provenance.origin == .simulation(run: sim.run))
            #expect(channel.object == key.object && channel.quantity == key.quantity)
            #expect(channel.unit == units[key.quantity])
            #expect(channel.sampleRate == 2)
            let samples = try await telemetry.samples(channel.id)
            #expect(samples.count == sim.history.count)
            #expect(samples.map(\.value) == sim.history.map { $0.values[key]! })
            #expect(samples.last?.time == start.timeIntervalSinceReferenceDate + 120)
        }
        #expect(channels[loop.terminalVoltage]?.id != meter.id, "Modeled output gets its own channel")
        #expect(try await telemetry.samples(meter.id) == [TelemetrySample(date: start, value: 20.7)], "The observed channel is untouched")
        #expect(try await telemetry.channels(on: loop.terminal).count == 3, "The meter plus two modeled channels")

        // Re-ingesting the same run appends to the same channels.
        let again = try await telemetry.ingest(Array(sim.history.suffix(1)), run: sim.run, startedAt: start.addingTimeInterval(1), keys: keys)
        #expect(again[loop.loopCurrent]?.id == channels[loop.loopCurrent]?.id)
        #expect(try await telemetry.sampleCount(channels[loop.loopCurrent]!.id) == sim.history.count + 1)
    }

    @Test func ingestingEverythingCoversEveryValue() async throws {
        let mass = ThermalMass(object: .make())
        let sim = try SimulationRuntime(dt: 1, state: mass.state(heatInput: 100, heatCapacity: 1_000, lossCoefficient: 2), solvers: [mass.solver])
        try sim.start()
        try sim.run(for: 60)
        let telemetry = TelemetryStore(store: try NexusStore(.inMemory))
        let channels = try await telemetry.ingest(sim, startedAt: start)
        #expect(Set(channels.keys) == [mass.temperature, mass.heatLoss])
    }

    @Test func simulationEventsAreRecordedAsModeledTimelineEvents() async throws {
        let loop = makeLoop()
        let telemetry = TelemetryStore(store: try NexusStore(.inMemory))
        let author = Provenance(origin: .system, truth: .recorded, timestamp: start)
        let simulation = try telemetry.store.create(ObjectRecord(type: .simulation, title: "Loop run", provenance: author))
        for (id, title) in [(loop.terminal, "TB-4"), (loop.tank, "Tank")] {
            _ = try telemetry.store.create(ObjectRecord(id: id, type: .component, title: title, provenance: author))
        }

        let sim = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        sim.watch(SimulationThreshold(name: "High level", key: loop.level, level: 70, direction: .rising))
        try sim.start()
        try sim.run(for: 10)
        sim.inject(SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded terminal"))
        try sim.run(for: 300)
        #expect(sim.events.map(\.kind) == [.faultInjected, .thresholdCrossed])

        try await telemetry.record(sim.events, run: sim.run, startedAt: start, extraSubjects: [simulation.id])
        let terminalEvents = try telemetry.store.events(about: loop.terminal)
        #expect(terminalEvents.map(\.kind) == [.faultInjected])
        #expect(terminalEvents.first?.provenance.truth == .modeled)
        #expect(terminalEvents.first?.at == start.addingTimeInterval(10))
        let runEvents = try telemetry.store.events(about: simulation.id)
        #expect(runEvents.map(\.kind) == [.faultInjected, .thresholdCrossed])
        #expect(runEvents.allSatisfy { $0.provenance.origin == .simulation(run: sim.run) })
    }
}
