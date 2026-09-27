import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusSimulation

extension TelemetryStore {
    /// Writes snapshot values as samples on modeled channels, one channel per
    /// (object, quantity) for this run, created on first use.
    ///
    /// Simulation output is modeled truth, so it only ever goes to channels
    /// whose provenance is `.simulation(run:)` with `.modeled` truth. An
    /// observed channel on the same test point is never touched, and the store
    /// would refuse modeled samples there anyway.
    ///
    /// - Parameters:
    ///   - keys: Values to record; nil records every value in the snapshots.
    ///   - unit: The unit of each quantity (snapshots carry numbers only).
    ///   - startedAt: Wall-clock time of tick 0; sample time is this plus the snapshot's seconds.
    ///   - sampleRate: Nominal rate for new channels, usually 1 / dt.
    /// - Returns: The channel for each recorded key.
    @discardableResult
    public func ingest(
        _ snapshots: [Snapshot], run: ObjectID, startedAt: Date, keys: Set<StateKey>? = nil, sampleRate: Double? = nil,
        unit: @Sendable (StateKey) -> String = { _ in "" }
    ) async throws -> [StateKey: TelemetryChannel] {
        var columns: [StateKey: [TelemetrySample]] = [:]
        let origin = startedAt.timeIntervalSinceReferenceDate
        for snapshot in snapshots {
            let time = origin + snapshot.seconds
            for (key, value) in snapshot.values where keys?.contains(key) ?? true {
                columns[key, default: []].append(TelemetrySample(time: time, value: value))
            }
        }

        var channels: [StateKey: TelemetryChannel] = [:]
        for key in columns.keys.sorted() {
            try Task.checkCancellation()
            let channel = try await modeledChannel(for: key, run: run, startedAt: startedAt, sampleRate: sampleRate, unit: unit(key))
            try await append(columns[key]!, to: channel.id, truth: .modeled)
            channels[key] = channel
        }
        return channels
    }

    /// Ingests a runtime's retained history under its run id, at 1 / dt.
    @discardableResult
    public func ingest(
        _ runtime: SimulationRuntime, startedAt: Date, keys: Set<StateKey>? = nil, unit: @Sendable (StateKey) -> String = { _ in "" }
    ) async throws -> [StateKey: TelemetryChannel] {
        try await ingest(runtime.history, run: runtime.run, startedAt: startedAt, keys: keys, sampleRate: 1 / runtime.dt, unit: unit)
    }

    /// Records simulation events on the shared timeline as modeled events,
    /// in one transaction. Each event's object (and every `extraSubjects`
    /// object) must exist in the store.
    public func record(_ events: [SimulationEvent], run: ObjectID, startedAt: Date, extraSubjects: [ObjectID] = []) async throws {
        let timeline = events.map { $0.timelineEvent(run: run, startedAt: startedAt, extraSubjects: extraSubjects) }
        try await perform { store in
            try store.batch { store in
                for event in timeline { try store.record(event) }
            }
        }
    }

    /// The run's modeled channel for `key`, created if missing.
    private func modeledChannel(for key: StateKey, run: ObjectID, startedAt: Date, sampleRate: Double?, unit: String) async throws -> TelemetryChannel {
        let existing = try await channels(on: key.object).first { channel in
            channel.quantity == key.quantity && channel.truth == .modeled && channel.provenance.origin == .simulation(run: run)
        }
        if let existing { return existing }
        return try await createChannel(
            object: key.object, quantity: key.quantity, unit: unit, sampleRate: sampleRate,
            provenance: Provenance(origin: .simulation(run: run), truth: .modeled, timestamp: startedAt, method: "simulation run \(run)")
        )
    }
}
