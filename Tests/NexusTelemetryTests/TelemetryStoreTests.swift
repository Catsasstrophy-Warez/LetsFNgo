import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusSimulation
import NexusVisualization
import Testing

@testable import NexusTelemetry

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000).timeIntervalSinceReferenceDate

private func observed() -> Provenance {
    Provenance(origin: .instrument(id: .make()), truth: .observed, timestamp: Date(timeIntervalSinceReferenceDate: t0), method: "DMM")
}

private func ramp(_ count: Int, rate: Double = 10, start: Double = t0) -> [TelemetrySample] {
    (0..<count).map { TelemetrySample(time: start + Double($0) / rate, value: Double($0)) }
}

private func makeStore(chunkSize: Int = 1_000) throws -> TelemetryStore {
    TelemetryStore(store: try NexusStore(.inMemory), chunkSize: chunkSize)
}

@Suite struct TelemetryStoreTests {
    @Test func migrationFiveAddsTelemetryAndChannelsRoundTrip() async throws {
        let telemetry = try makeStore()
        #expect(telemetry.store.schemaVersion >= 5)
        let testPoint = ObjectID.make()
        let channel = try await telemetry.createChannel(object: testPoint, quantity: "voltage", unit: "V", sampleRate: 10, provenance: observed())
        #expect(try await telemetry.channel(channel.id) == channel)
        #expect(try await telemetry.channels(on: testPoint).map(\.id) == [channel.id])
        #expect(try await telemetry.channels(on: .make()).isEmpty)
        #expect(channel.truth == .observed)
        await #expect(throws: StoreError.duplicate(channel.id)) { try await telemetry.perform { try $0.createTelemetryChannel(channel) } }
    }

    @Test func appendsInChunksAndQueriesInclusiveRanges() async throws {
        let telemetry = try makeStore(chunkSize: 1_000)
        let channel = try await telemetry.createChannel(object: .make(), quantity: "voltage", unit: "V", provenance: observed())
        try await telemetry.append(ramp(10_000), to: channel.id, truth: .observed)

        let chunks = try await telemetry.perform { try $0.telemetryChunks(channel: channel.id) }
        #expect(chunks.count == 10)
        #expect(try await telemetry.sampleCount(channel.id) == 10_000)

        let all = try await telemetry.samples(channel.id)
        #expect(all == ramp(10_000), "Values and times survive the round trip bit for bit")

        // Samples 2500...2600, crossing a chunk boundary, bounds inclusive.
        let range = try await telemetry.samples(channel.id, from: t0 + 250, to: t0 + 260)
        #expect(range.count == 101)
        #expect(range.first?.value == 2_500 && range.last?.value == 2_600)

        let reduced = try await telemetry.samples(channel.id, maxPoints: 100)
        #expect(reduced.count == 100)
        #expect(reduced.first == all.first && reduced.last == all.last)
        #expect(try await telemetry.samples(channel.id, from: t0 + 5_000).isEmpty)
    }

    @Test func outOfOrderBatchesMergeAndBadSamplesAreRejected() async throws {
        let telemetry = try makeStore(chunkSize: 4)
        let channel = try await telemetry.createChannel(object: .make(), quantity: "level", unit: "%", provenance: observed())
        let samples = ramp(20)
        try await telemetry.append(Array(samples[10...]).reversed(), to: channel.id, truth: .observed)
        try await telemetry.append(Array(samples[..<10]), to: channel.id, truth: .observed)
        #expect(try await telemetry.samples(channel.id) == samples)

        let dropout = TelemetrySample(time: t0 + 100, value: .nan)
        try await telemetry.append([dropout], to: channel.id, truth: .observed)
        #expect(try await telemetry.samples(channel.id, from: t0 + 100).first?.value.isNaN == true, "NaN marks a dropout and is kept")

        await #expect(throws: TelemetryError.invalidSample(index: 1)) {
            try await telemetry.append([TelemetrySample(time: t0, value: 1), TelemetrySample(time: .infinity, value: 2)], to: channel.id, truth: .observed)
        }
        let unknown = ObjectID.make()
        await #expect(throws: TelemetryError.channelNotFound(unknown)) { _ = try await telemetry.samples(unknown) }
        #expect(try await telemetry.sampleCount(channel.id) == 21, "A rejected batch writes nothing")
    }

    @Test func modeledSamplesNeverEnterAnObservedChannel() async throws {
        let telemetry = try makeStore()
        let channel = try await telemetry.createChannel(object: .make(), quantity: "voltage", unit: "V", provenance: observed())
        try await telemetry.append(ramp(5), to: channel.id, truth: .observed)
        do {
            try await telemetry.append(ramp(5, start: t0 + 10), to: channel.id, truth: .modeled)
            Issue.record("Modeled samples were accepted into an observed channel")
        } catch let error as StoreError {
            #expect(error == .truthConflict(object: channel.id, attribute: "voltage", existing: .observed, incoming: .modeled))
            let classified = classify(error)
            #expect(classified.category == .evidenceVerification)
            #expect(classified.whatSurvived == ["The observed values are unchanged."])
        }
        #expect(try await telemetry.sampleCount(channel.id) == 5)
    }

    @Test func retentionTrimsStraddlingChunksAndProtectsObservedData() async throws {
        let telemetry = try makeStore(chunkSize: 100)
        let observedChannel = try await telemetry.createChannel(object: .make(), quantity: "voltage", unit: "V", provenance: observed())
        let modeledChannel = try await telemetry.createChannel(
            object: .make(), quantity: "voltage", unit: "V",
            provenance: Provenance(origin: .simulation(run: .make()), truth: .modeled, timestamp: Date(timeIntervalSinceReferenceDate: t0))
        )
        try await telemetry.append(ramp(1_000), to: observedChannel.id, truth: .observed)
        try await telemetry.append(ramp(1_000), to: modeledChannel.id, truth: .modeled)

        // An agent may prune modeled data but not observed data.
        let agent = Origin.agent(id: "janitor", run: nil)
        await #expect(throws: StoreError.protectedRemoval(object: observedChannel.id, attribute: "voltage", by: agent)) {
            try await telemetry.removeSamples(from: observedChannel.id, before: t0 + 50, by: agent)
        }
        #expect(try await telemetry.removeSamples(from: modeledChannel.id, before: t0 + 25.05, by: agent) == 251)
        let kept = try await telemetry.samples(modeledChannel.id)
        #expect(kept.count == 749)
        #expect(kept.first?.value == 251, "The straddling chunk keeps its tail")

        // System retention across every channel.
        let now = Date(timeIntervalSinceReferenceDate: t0 + 100)
        let removed = try await telemetry.applyRetention(maxAge: 40, now: now)
        #expect(removed[observedChannel.id] == 600)
        #expect(removed[modeledChannel.id] == 349)
        #expect(try await telemetry.samples(observedChannel.id).first?.time == t0 + 60)

        try await telemetry.deleteChannel(modeledChannel.id, by: agent)
        #expect(try await telemetry.channel(modeledChannel.id) == nil)
    }

    @Test func samplesSurviveReopeningAFileStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nexus.sqlite")

        let id: ObjectID
        do {
            let telemetry = TelemetryStore(store: try NexusStore(.file(url)), chunkSize: 256)
            id = try await telemetry.createChannel(object: .make(), quantity: "current", unit: "mA", provenance: observed()).id
            try await telemetry.append(ramp(1_000), to: id, truth: .observed)
        }
        let reopened = TelemetryStore(store: try NexusStore(.file(url)))
        #expect(try await reopened.samples(id) == ramp(1_000))
        let series = try await reopened.series(id, name: "Loop current", maxPoints: 50)
        #expect(series.unit == "mA" && series.truth == .observed && series.points.count == 50)
    }

    @Test func oneMillionSamplesAppendAndQueryQuickly() async throws {
        let telemetry = try makeStore(chunkSize: 4_096)
        let channel = try await telemetry.createChannel(object: .make(), quantity: "vibration", unit: "g", sampleRate: 10_000, provenance: observed())
        let total = 1_000_000
        let batch = 250_000
        let clock = ContinuousClock()

        let appendTime = try await clock.measure {
            for start in stride(from: 0, to: total, by: batch) {
                let samples = (start..<(start + batch)).map { TelemetrySample(time: t0 + Double($0) / 10_000, value: sin(Double($0) / 50)) }
                try await telemetry.append(samples, to: channel.id, truth: .observed)
            }
        }
        var middle: [TelemetrySample] = []
        let rangeTime = try await clock.measure {
            middle = try await telemetry.samples(channel.id, from: t0 + 40, to: t0 + 50)
        }
        var overview: [TelemetrySample] = []
        let overviewTime = try await clock.measure {
            overview = try await telemetry.samples(channel.id, maxPoints: 2_000)
        }
        print("1M samples: append \(appendTime), 100k-sample range \(rangeTime), full LTTB overview \(overviewTime)")

        #expect(try await telemetry.sampleCount(channel.id) == total)
        #expect(middle.count == 100_001)
        #expect(middle.first?.time == t0 + 40)
        #expect(overview.count == 2_000)
        #expect(overview.last?.time == t0 + Double(total - 1) / 10_000)
        // Appends are bounded by structure, not wall time (which varies with
        // parallel test load on CI): a million samples are a few hundred
        // chunk rows, never a row per sample.
        let chunks = try await telemetry.perform { try $0.telemetryChunks(channel: channel.id).count }
        #expect((245...250).contains(chunks), "\(chunks) chunks for 1M samples at 4,096 per chunk")
        // Reads touch only the chunks in range. Generous limits for debug builds.
        #expect(rangeTime < .seconds(2))
        #expect(overviewTime < .seconds(10))
    }
}
