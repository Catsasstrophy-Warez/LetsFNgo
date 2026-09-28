import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTelemetry

/// A drive in progress: which vehicle, adapter and protocol it runs on.
public struct OBDDrive: Sendable, Hashable {
    /// The `obdSession` event that opened the drive.
    public var event: ObjectID
    public var vehicle: ObjectID
    /// The adapter as an `instrument` object; live readings name it as their origin.
    public var adapter: ObjectID
    public var identity: ELM327Identity
    /// The VIN the car reported, when it supports service 09.
    public var vin: VIN?
    public var supportedPIDs: Set<UInt8>
    public var startedAt: Date
}

/// Records a live adapter session into the canonical store.
///
/// - Live PIDs stream into `NexusTelemetry` channels on the vehicle object,
///   one per quantity. The channel's provenance names the adapter instrument
///   as origin, and the adapter, protocol, PID and module in its method; each
///   sample carries its own time. `NO DATA` for a PID that has a channel is
///   stored as a NaN dropout, so gaps stay visible.
/// - Trouble codes and freeze frames go through `VehicleRuntime`, so they
///   appear in the garage and trouble-code screens like any imported log.
/// - The VIN picks (or adds) the vehicle, and must match a vehicle chosen up front.
/// - Each drive records an `obdSession` event when it starts and when it ends.
/// - Clearing codes needs a `ClearCodesConfirmation` from a person, for this
///   vehicle, made in the last five minutes. Nothing here clears on its own.
///
/// Live readings default to **observed** truth with an instrument origin: the
/// adapter observed these values on the bus during this drive. Pass
/// `liveTruth: .display` to store them as the ECU's displayed values instead
/// (the convention `VehicleRuntime.record` uses for imported logs).
public actor OBDDriveRecorder {
    public nonisolated let session: ELM327Session
    public nonisolated let telemetry: TelemetryStore
    public nonisolated let person: Origin
    public nonisolated let liveTruth: TruthClass
    let clock: NexusClock
    /// Buffered samples are written once the oldest is this old (seconds).
    public var flushInterval: TimeInterval = 5
    public private(set) var drive: OBDDrive?
    private var channels: [UInt8: TelemetryChannel] = [:]
    private var pending: [ObjectID: [TelemetrySample]] = [:]
    private var oldestPending: Date?
    private var samplesWritten = 0

    public init(session: ELM327Session, telemetry: TelemetryStore, by person: Origin, liveTruth: TruthClass = .observed, clock: NexusClock = SystemClock())
        throws
    {
        guard liveTruth == .observed || liveTruth == .display else { throw AutomotiveError.unsupportedTruth(liveTruth) }
        self.session = session
        self.telemetry = telemetry
        self.person = person
        self.liveTruth = liveTruth
        self.clock = clock
    }

    public nonisolated var poller: OBDPoller { OBDPoller(session: session) }

    // MARK: Starting and stopping

    /// Connects, reads the VIN and supported PIDs, finds the vehicle, and
    /// records the session's start.
    ///
    /// - Parameter vehicle: The vehicle this drive is for. When nil, the VIN
    ///   picks the vehicle in the garage, or adds it.
    @discardableResult
    public func start(vehicle chosen: ObjectID? = nil) async throws -> OBDDrive {
        if let drive { return drive }
        let identity = try await session.connect()
        let vin = try? await poller.vin()
        let supported = try await poller.supportedPIDs()
        let person = person
        let clock = clock
        let started = clock.now()

        let (vehicle, adapter, event) = try await telemetry.perform { store in
            try store.batch { store in
                let garage = VehicleRuntime(store: store, clock: clock)
                let vehicle: Vehicle
                if let chosen {
                    vehicle = try garage.vehicle(chosen)
                    if let vin, vin.rawValue != vehicle.vin.rawValue {
                        throw OBDLinkError.vinMismatch(expected: vehicle.vin.rawValue, found: vin.rawValue)
                    }
                } else if let vin {
                    vehicle = try garage.vehicle(vin: vin.rawValue) ?? garage.addVehicle(vin: vin.rawValue, requireCheckDigit: false, by: person)
                } else {
                    throw OBDLinkError.vinUnavailable
                }
                let adapter = try Self.adapterObject(identity.adapter, in: store, by: person, at: started)
                if let volts = identity.voltage {
                    try garage.recordAdapterVoltage(volts, on: vehicle.id, scanTool: adapter, at: started)
                }
                let event = Event(
                    at: started, kind: .obdSession, subjects: [vehicle.id, adapter],
                    summary: "Connected \(identity.adapter.name) over \(identity.adapter.kind.title): \(identity.vehicleProtocol.name)",
                    payload: [
                        "phase": .string("connected"),
                        "adapter": .string(identity.adapter.name),
                        AutomotiveKey.transport: .string(identity.adapter.kind.rawValue),
                        "adapterVersion": .string(identity.version),
                        "protocol": .string(identity.vehicleProtocol.name),
                        "protocolNumber": .string(identity.vehicleProtocol.number),
                        "modules": .list(identity.modules.map(Value.string)),
                        "supportedPIDs": .list(supported.sorted().map { .string(ELM327.hex($0)) }),
                        AutomotiveKey.vin: vin.map { .string($0.rawValue) } ?? .null,
                    ],
                    provenance: Provenance(origin: .instrument(id: adapter), truth: .observed, timestamp: started, method: "ELM327 session")
                )
                try store.record(event)
                return (vehicle.id, adapter, event.id)
            }
        }
        let drive = OBDDrive(
            event: event, vehicle: vehicle, adapter: adapter, identity: identity, vin: vin, supportedPIDs: supported, startedAt: started
        )
        self.drive = drive
        return drive
    }

    /// Writes buffered samples, records the session's end and disconnects.
    public func stop() async {
        try? await flush()
        if let drive {
            let ended = clock.now()
            let samples = samplesWritten
            _ = try? await telemetry.perform { store in
                try store.record(
                    Event(
                        at: ended, kind: .obdSession, subjects: [drive.vehicle, drive.adapter],
                        summary: "Disconnected \(drive.identity.adapter.name) after \(Int(ended.timeIntervalSince(drive.startedAt))) s",
                        payload: [
                            "phase": .string("ended"), "samples": .int(Int64(samples)), "startedBy": .string(drive.event.description),
                        ],
                        provenance: Provenance(origin: .instrument(id: drive.adapter), truth: .observed, timestamp: ended, method: "ELM327 session")
                    ))
            }
        }
        drive = nil
        channels = [:]
        await session.disconnect()
    }

    // MARK: Live data

    /// Reads `pids` once and buffers them as samples (see `flushInterval`).
    public func poll(_ pids: [UInt8]) async throws -> OBDLiveFrame {
        guard let drive else { throw OBDLinkError.notConnected }
        let frame = try await poller.read(pids, clock: clock)
        let time = frame.at.timeIntervalSinceReferenceDate
        for reading in frame.readings {
            let channel = try await channel(for: reading, drive: drive)
            pending[channel.id, default: []].append(TelemetrySample(time: time, value: reading.value))
        }
        for pid in frame.missing {
            if let channel = channels[pid] {
                pending[channel.id, default: []].append(TelemetrySample(time: time, value: .nan))
            }
        }
        if oldestPending == nil, !pending.isEmpty { oldestPending = frame.at }
        if let oldestPending, frame.at.timeIntervalSince(oldestPending) >= flushInterval {
            try await flush()
        }
        return frame
    }

    /// Polls `pids` every `interval` until the stream's consumer stops
    /// iterating. A link failure ends the stream with that error.
    public nonisolated func live(_ pids: [UInt8], every interval: Duration) -> AsyncThrowingStream<OBDLiveFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                do {
                    while !Task.isCancelled {
                        let deadline = clock.now.advanced(by: interval)
                        continuation.yield(try await self.poll(pids))
                        try await Task.sleep(until: deadline, clock: clock)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                try? await self.flush()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes buffered samples to their channels.
    public func flush() async throws {
        let batch = pending
        pending = [:]
        oldestPending = nil
        let truth = liveTruth
        for (channel, samples) in batch {
            try await telemetry.append(samples, to: channel, truth: truth)
            samplesWritten += samples.count
        }
    }

    /// The live channel for this reading's quantity, created on first use.
    /// Channels are reused across drives with the same adapter, protocol and module.
    private func channel(for reading: OBDReading, drive: OBDDrive) async throws -> TelemetryChannel {
        if let channel = channels[reading.pid] { return channel }
        let origin = Origin.instrument(id: drive.adapter)
        let identity = drive.identity
        let method =
            "\(identity.version) over \(identity.adapter.kind.title), \(identity.vehicleProtocol.name), mode 01 PID \(ELM327.hex(reading.pid))"
            + (reading.ecu.map { " from \($0)" } ?? "")
        let truth = liveTruth
        let existing = try await telemetry.channels(on: drive.vehicle).first {
            $0.quantity == reading.quantity && $0.truth == truth && $0.provenance.origin == origin && $0.provenance.method == method
        }
        let ecu = try await telemetry.perform { store in try VehicleRuntime(store: store).vehicle(drive.vehicle).component(.ecu) }
        let channel: TelemetryChannel
        if let existing {
            channel = existing
        } else {
            channel = try await telemetry.createChannel(
                object: drive.vehicle, quantity: reading.quantity, unit: reading.unit, sampleRate: nil,
                provenance: Provenance(
                    origin: origin, truth: truth, timestamp: clock.now(), method: method,
                    dependencies: [drive.adapter] + (ecu.map { [$0] } ?? [])
                )
            )
        }
        channels[reading.pid] = channel
        return channel
    }

    /// Live channels this drive has written to, by PID.
    public var liveChannels: [UInt8: TelemetryChannel] { channels }

    // MARK: Codes, freeze frame

    /// Reads stored, pending and permanent codes and records them as faults
    /// (recorded truth). Stored codes are always recorded, so "no codes" is
    /// on the timeline too; empty pending and permanent lists are not.
    @discardableResult
    public func readTroubleCodes() async throws -> [DTCStatus: [DTC]] {
        guard let drive else { throw OBDLinkError.notConnected }
        var read: [DTCStatus: [DTC]] = [:]
        for status in DTCStatus.allCases {
            read[status] = try await poller.troubleCodes(status)
        }
        let codes = read
        let person = person
        let clock = clock
        try await telemetry.perform { store in
            try store.batch { store in
                let garage = VehicleRuntime(store: store, clock: clock)
                for status in DTCStatus.allCases {
                    let list = codes[status] ?? []
                    if status == .stored || !list.isEmpty {
                        try garage.recordTroubleCodes(list, status: status, on: drive.vehicle, by: person)
                    }
                }
            }
        }
        return codes
    }

    /// Reads freeze frame 0 and stores its values as measurements (service 02).
    @discardableResult
    public func readFreezeFrame() async throws -> FreezeFrame {
        guard let drive else { throw OBDLinkError.notConnected }
        let frame = try await poller.freezeFrame()
        guard !frame.readings.isEmpty else { return frame }
        let truth = liveTruth
        let clock = clock
        _ = try await telemetry.perform { store in
            try VehicleRuntime(store: store, clock: clock).record(
                frame.readings, on: drive.vehicle, scanTool: drive.adapter, truth: truth, at: clock.now(), service: "02"
            )
        }
        return frame
    }

    /// Clears codes on the vehicle (service 04) after a person confirmed it,
    /// then archives the vehicle's active stored and pending faults. Permanent
    /// codes stay: only the ECU clears those, after its monitors pass.
    ///
    /// Throws `confirmationRequired` for a confirmation that is stale, for
    /// another vehicle, or not from a person; the adapter is not contacted.
    @discardableResult
    public func clearTroubleCodes(_ confirmation: ClearCodesConfirmation) async throws -> [ObjectRecord] {
        guard let drive else { throw OBDLinkError.notConnected }
        guard confirmation.isValid(for: drive.vehicle, at: clock.now()) else {
            throw OBDLinkError.confirmationRequired("the confirmation is for another vehicle or has expired")
        }
        try await poller.clearTroubleCodes(confirmation)
        let clock = clock
        return try await telemetry.perform { store in
            try store.batch { store in
                let garage = VehicleRuntime(store: store, clock: clock)
                let cleared = try garage.faults(of: drive.vehicle).filter { fault in
                    fault.lifecycle == .active && fault.attributes[AutomotiveKey.dtcStatus]?.value != .string(DTCStatus.permanent.rawValue)
                }
                let reason = "Codes cleared with the scan tool (mode 04), confirmed by the technician"
                let archived = try cleared.map { try garage.clearFault($0.id, reason: reason, by: confirmation.person) }
                try store.record(
                    Event(
                        at: clock.now(), kind: .troubleCodesCleared, subjects: [drive.vehicle] + archived.map(\.id),
                        summary: "Trouble codes cleared (\(archived.count) faults archived)",
                        payload: ["confirmedAt": .date(confirmation.confirmedAt), "adapter": .reference(drive.adapter)],
                        provenance: Provenance(
                            origin: confirmation.person, truth: .recorded, timestamp: clock.now(), method: "OBD-II mode 04 via \(drive.identity.version)"
                        )
                    ))
                return archived
            }
        }
    }

    // MARK: Adapter identity

    /// The adapter's `instrument` object, created the first time it's used.
    static func adapterObject(_ adapter: OBDAdapterDescriptor, in store: NexusStore, by person: Origin, at date: Date) throws -> ObjectID {
        let key = "\(adapter.kind.rawValue):\(adapter.identifier)"
        if let existing = try store.objects(ofType: .instrument).first(where: {
            $0.attributes[AutomotiveKey.adapterIdentifier]?.value == .string(key)
        }) {
            return existing.id
        }
        return try store.create(
            ObjectRecord(
                type: .instrument, title: "OBD-II adapter \(adapter.name)",
                attributes: [
                    AutomotiveKey.adapterIdentifier: Attribute(.string(key)),
                    AutomotiveKey.transport: Attribute(.string(adapter.kind.rawValue)),
                    "role": Attribute(.string("scanTool")),
                ],
                provenance: Provenance(origin: person, truth: person.defaultTruth, timestamp: date, method: "OBD adapter connected")
            )
        ).id
    }
}
