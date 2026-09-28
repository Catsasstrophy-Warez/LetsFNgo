import Foundation
import NexusAutomotive
import NexusCore
import NexusModel
import NexusPersistence
import NexusTelemetry
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 810_000_000)
private let hondaVIN = "1HGCM82633A004352"

/// Generous timeouts, so a busy test machine never times out a scripted reply.
private let steady = ELM327Session.Configuration(
    commandTimeout: .seconds(3), resetTimeout: .seconds(3), searchTimeout: .seconds(3), retries: 2, retryDelay: .milliseconds(5)
)

/// Short command timeouts, for the tests where the adapter stays silent.
private let fast = ELM327Session.Configuration(
    commandTimeout: .milliseconds(150), resetTimeout: .milliseconds(150), searchTimeout: .seconds(3), retries: 2,
    retryDelay: .milliseconds(5)
)

/// The standard initialisation, as a given adapter answers it.
private func initScript(
    banner: String = "ELM327 v1.5", ath1: String = "OK", ats0: String = "OK", volts: String = "12.6V", first: String,
    dpn: String = "A6", dp: String = "AUTO, ISO 15765-4 (CAN 11/500)"
) -> [(String, MockAdapterReply)] {
    [
        ("ATZ", .text(banner)), ("ATE0", .text("OK")), ("ATL0", .text("OK")), ("ATS0", .text(ats0)), ("ATH1", .text(ath1)),
        ("ATSP0", .text("OK")), ("ATRV", .text(volts)), ("0100", .text(first)), ("ATDPN", .text(dpn)), ("ATDP", .text(dp)),
    ]
}

/// A running car on 11-bit CAN, headers on: engine ECU 7E8.
private func car(_ command: String) -> MockAdapterReply? {
    switch command {
    case "ATZ": .text("ELM327 v1.5")
    case "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0": .text("OK")
    case "ATRV": .text("12.4V")
    case "ATDPN": .text("A6")
    case "ATDP": .text("AUTO, ISO 15765-4 (CAN 11/500)")
    case "0100": .text("SEARCHING...\r7E8 06 41 00 BE 3F A8 13")
    // 21, 30, 31 and 40 → next block; 42 in the one after.
    case "0120": .text("7E8 06 41 20 80 01 80 01")
    case "0140": .text("7E8 06 41 40 40 00 00 00")
    case "0902": .text("7E8 10 14 49 02 01 31 48 47\r7E8 21 43 4D 38 32 36 33 33\r7E8 22 41 30 30 34 33 35 32")
    case "0104": .text("7E8 03 41 04 80")
    case "0105": .text("7E8 03 41 05 7B")
    case "0106": .text("7E8 03 41 06 80")
    case "0107": .text("7E8 03 41 07 90")
    case "010C": .text("7E8 04 41 0C 1A F8")
    case "010D": .text("7E8 03 41 0D 32")
    case "0142": .text("7E8 04 41 42 31 0B")
    case "03": .text("7E8 06 43 02 05 62 01 33")
    case "07": .text("7E8 02 47 00")
    case "0A": .text("7E8 03 7F 0A 11")
    case "020200": .text("7E8 05 42 02 00 05 62")
    case "020C00": .text("7E8 05 42 0C 00 1A F8")
    case "020500": .text("7E8 04 42 05 00 7B")
    default: .text("NO DATA")
    }
}

/// A flag the scripted car can read from its responder.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite struct ELM327SessionTests {
    @Test func genuineAdapterEchoOnThenOffCAN11() async throws {
        let transport = MockOBDTransport(script: initScript(first: "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001"), chunkSize: 3)
        let session = ELM327Session(transport: transport, configuration: steady)
        let identity = try await session.connect()

        #expect(identity.version == "ELM327 V1.5")
        #expect(identity.vehicleProtocol.number == "6" && identity.vehicleProtocol.automatic && identity.vehicleProtocol.isCAN)
        #expect(identity.vehicleProtocol.name == "ISO 15765-4 (CAN 11/500)")
        #expect(identity.headers && identity.voltage == 12.6)
        #expect(identity.modules == ["7E8", "7E9"])
        #expect(transport.sent == ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "ATRV", "0100", "ATDPN", "ATDP"])
        #expect(transport.unexpectedCommands.isEmpty && transport.remainingScript == 0)
        // Echo was on for ATZ and ATE0; neither echo leaked into the banner.
        let log = await session.log
        #expect(log.first?.reply.contains("ATZ") == true)
    }

    @Test func cloneKeepsEchoSpacesAndJunk29BitCAN() async throws {
        // A cheap clone: ignores ATE0, refuses ATS0 and ATRV, prints junk after reset, and doesn't know ATDPN.
        var script = initScript(
            banner: "ELM327 v2.1", ats0: "?", volts: "?", first: "SEARCHING...\r18 DA F1 10 06 41 00 BE 3F A8 13", dpn: "?", dp: "?"
        )
        script.append(("010C", .text("18 DA F1 10 04 41 0C 1A F8")))
        let transport = MockOBDTransport(script: script, chunkSize: 5, ignoresEchoOff: true, resetNoise: [0x00, 0xFC, 0xFF, 0x0D])
        let session = ELM327Session(transport: transport, configuration: steady)
        let identity = try await session.connect()

        #expect(identity.version == "ELM327 V2.1" && identity.voltage == nil)
        #expect(identity.vehicleProtocol.number == "7" && identity.modules == ["18DAF110"])
        let rpm = try await OBDPoller(session: session).read(0x0C)
        #expect(rpm?.value == 1726 && rpm?.ecu == "18DAF110")
    }

    @Test func headersRefusedLegacyISO9141() async throws {
        var script = initScript(
            ath1: "?", first: "SEARCHING...\rBUS INIT: ...OK\r41 00 BE 3E B8 11", dpn: "A3", dp: "AUTO, ISO 9141-2"
        )
        // Legacy trouble codes have no count byte; the VIN comes in five frames.
        script.append(("03", .text("43 01 33 00 00 00 00")))
        script.append(("0902", .text("49 02 01 00 00 00 31\r49 02 02 48 47 43 4D\r49 02 03 38 32 36 33\r49 02 04 33 41 30 30\r49 02 05 34 33 35 32")))
        let transport = MockOBDTransport(script: script)
        let session = ELM327Session(transport: transport, configuration: steady)
        let identity = try await session.connect()

        #expect(!identity.headers && identity.vehicleProtocol.number == "3" && !identity.vehicleProtocol.isCAN)
        #expect(identity.vehicleProtocol.name == "ISO 9141-2")
        let poller = OBDPoller(session: session)
        #expect(try await poller.troubleCodes(.stored).map(\.code) == ["P0133"])
        #expect(try await poller.vin().rawValue == hondaVIN)
    }

    @Test func multiFrameISOTPWithHeadersOnAndOff() async throws {
        // Headers on: first frame then consecutive frames from 7E8.
        let on = MockOBDTransport(script: initScript(first: "7E8 06 41 00 BE 3F A8 13"), responder: car)
        let onSession = ELM327Session(transport: on, configuration: steady)
        try await onSession.connect()
        #expect(try await OBDPoller(session: onSession).vin().rawValue == hondaVIN)

        // Headers off (ATH1 refused): the "014" byte count and "0:" "1:" "2:" lines.
        var script = initScript(ath1: "?", first: "41 00 BE 3F A8 13")
        script.append(("0902", .text("014\r0: 49 02 01 31 48 47\r1: 43 4D 38 32 36 33 33\r2: 41 30 30 34 33 35 32")))
        let off = MockOBDTransport(script: script)
        let offSession = ELM327Session(transport: off, configuration: steady)
        try await offSession.connect()
        #expect(try await OBDPoller(session: offSession).vin().rawValue == hondaVIN)
    }

    @Test func noVehicleWhenIgnitionIsOff() async throws {
        for reply in ["SEARCHING...\rUNABLE TO CONNECT", "NO DATA", "SEARCHING...\rCAN ERROR"] {
            let transport = MockOBDTransport(script: initScript(first: reply)) { command in
                command == "0100" ? .text(reply) : nil
            }
            let session = ELM327Session(transport: transport, configuration: steady)
            await #expect {
                try await session.connect()
            } throws: { error in
                if case OBDLinkError.noVehicleResponse = error { return true }
                return false
            }
        }
    }

    @Test func timeoutsRetryThenFail() async throws {
        // Silent once, then answers: the retry succeeds.
        var script = initScript(first: "7E8 06 41 00 BE 3F A8 13")
        script += [("010C", .silence), ("010C", .text("7E8 04 41 0C 1A F8"))]
        // Silent every time: fails after 1 + 2 retries.
        script += [("010D", .silence), ("010D", .silence), ("010D", .silence)]
        let transport = MockOBDTransport(script: script)
        let session = ELM327Session(transport: transport, configuration: fast)
        try await session.connect()
        let poller = OBDPoller(session: session)
        #expect(try await poller.read(0x0C)?.value == 1726)
        await #expect(throws: OBDLinkError.timeout(command: "010D")) { try await poller.read(0x0D) }
        #expect(transport.sent.filter { $0 == "010D" }.count == 3)

        // An adapter that never answers the reset.
        let dead = ELM327Session(transport: MockOBDTransport(script: [("ATZ", .silence), ("ATZ", .silence), ("ATZ", .silence)]), configuration: fast)
        await #expect(throws: OBDLinkError.timeout(command: "ATZ")) { try await dead.connect() }
    }

    @Test func transientBusErrorsAreRetried() async throws {
        var script = initScript(first: "7E8 06 41 00 BE 3F A8 13")
        script += [("010D", .text("STOPPED")), ("010D", .text("BUS BUSY")), ("010D", .text("7E8 03 41 0D 32"))]
        script += [("0105", .text("CAN ERROR")), ("0105", .text("CAN ERROR")), ("0105", .text("CAN ERROR"))]
        let transport = MockOBDTransport(script: script)
        let session = ELM327Session(transport: transport, configuration: steady)
        try await session.connect()
        let poller = OBDPoller(session: session)
        #expect(try await poller.read(0x0D)?.value == 50)
        await #expect(throws: OBDLinkError.bus("CAN ERROR")) { try await poller.read(0x05) }
    }

    @Test func concurrentRequestsTakeTurns() async throws {
        // A code read started while live polling runs must not interleave on the wire.
        let transport = MockOBDTransport(responder: car, chunkSize: 2)
        let session = ELM327Session(transport: transport, configuration: steady)
        try await session.connect()
        let poller = OBDPoller(session: session)
        async let rpm = poller.read(0x0C)
        async let speed = poller.read(0x0D)
        async let codes = poller.troubleCodes(.stored)
        async let vin = poller.vin()
        #expect(try await rpm?.value == 1726)
        #expect(try await speed?.value == 50)
        #expect(try await codes.map(\.code) == ["P0133", "P0562"])
        #expect(try await vin.rawValue == hondaVIN)
        #expect(transport.unexpectedCommands.isEmpty)
    }

    @Test func linefeedsAndPromptSplitAcrossChunks() async throws {
        // ATL1 adapters end lines with "\r\n"; one byte per chunk splits every line and the prompt.
        let transport = MockOBDTransport(responder: { command in command == "ATL0" ? .text("?") : car(command) }, chunkSize: 1)
        let session = ELM327Session(transport: transport, configuration: steady)
        let identity = try await session.connect()
        #expect(identity.version == "ELM327 V1.5" && identity.modules == ["7E8"])
        #expect(try await OBDPoller(session: session).read(0x0C)?.value == 1726)
    }

    @Test func openFailureAndClosedLink() async throws {
        let session = ELM327Session(transport: MockOBDTransport(openFailure: "Bluetooth is off."), configuration: steady)
        await #expect(throws: OBDLinkError.transport("Bluetooth is off.")) { try await session.connect() }
        await #expect(throws: OBDLinkError.notConnected) { try await session.request("010C") }
    }
}

@Suite struct OBDPollerTests {
    func connected(_ responder: @escaping @Sendable (String) -> MockAdapterReply? = car) async throws -> (OBDPoller, MockOBDTransport) {
        let transport = MockOBDTransport(responder: responder)
        let session = ELM327Session(transport: transport, configuration: steady)
        try await session.connect()
        return (OBDPoller(session: session), transport)
    }

    @Test func supportedPIDsWalkTheBitmaps() async throws {
        let (poller, transport) = try await connected()
        let supported = try await poller.supportedPIDs()
        #expect(supported.isSuperset(of: [0x04, 0x05, 0x0C, 0x0D, 0x1F, 0x21, 0x30, 0x31, 0x42]))
        #expect(!supported.contains(0x20) && !supported.contains(0x40))
        #expect(transport.sent.suffix(3) == ["0100", "0120", "0140"])
    }

    @Test func readsReportMissingPIDs() async throws {
        let (poller, _) = try await connected()
        let frame = try await poller.read([0x0C, 0x0D, 0x05, 0x42, 0x0F])
        #expect(frame.readings.map(\.quantity) == ["engineSpeed", "vehicleSpeed", "coolantTemperature", "controlModuleVoltage"])
        #expect(frame.readings.map(\.value) == [1726, 50, 83, 12.555])
        #expect(frame.readings.allSatisfy { $0.ecu == "7E8" })
        #expect(frame.missing == [0x0F])
    }

    @Test func troubleCodesAndFreezeFrame() async throws {
        let (poller, _) = try await connected()
        #expect(try await poller.troubleCodes(.stored).map(\.code) == ["P0133", "P0562"])
        #expect(try await poller.troubleCodes(.pending).isEmpty)
        // 7F 0A 11: service 0A not supported on this (older) ECU.
        #expect(try await poller.troubleCodes(.permanent).isEmpty)
        let frame = try await poller.freezeFrame()
        #expect(frame.trigger?.code == "P0562")
        #expect(frame.readings.map(\.quantity) == ["coolantTemperature", "engineSpeed"])
        #expect(frame.readings.map(\.value) == [83, 1726])
    }
}

@Suite struct OBDDriveRecorderTests {
    let tech = Origin.user(id: "tech")

    func setUp(_ responder: @escaping @Sendable (String) -> MockAdapterReply? = car) throws -> (
        OBDDriveRecorder, MockOBDTransport, TelemetryStore, ManualClock
    ) {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let telemetry = TelemetryStore(store: store)
        let transport = MockOBDTransport(
            responder: responder, descriptor: OBDAdapterDescriptor(kind: .bluetoothLE, identifier: "A1B2", name: "Vgate iCar Pro")
        )
        let session = ELM327Session(transport: transport, configuration: steady)
        return (try OBDDriveRecorder(session: session, telemetry: telemetry, by: tech, clock: clock), transport, telemetry, clock)
    }

    @Test func pollsIntoObservedTelemetryOnTheVehicle() async throws {
        let ignitionOff = Switch()
        let (recorder, transport, telemetry, clock) = try setUp { command in
            ignitionOff.isOn && command.hasPrefix("01") ? .text("NO DATA") : car(command)
        }
        let drive = try await recorder.start()
        let garage = VehicleRuntime(store: telemetry.store)
        let vehicle = try garage.vehicle(drive.vehicle)
        #expect(vehicle.vin.rawValue == hondaVIN && drive.vin?.rawValue == hondaVIN)
        #expect(drive.identity.vehicleProtocol.number == "6" && drive.supportedPIDs.contains(0x42))

        let pids: [UInt8] = [0x0C, 0x0D, 0x05, 0x42]
        for _ in 0..<3 {
            let frame = try await recorder.poll(pids)
            #expect(frame.readings.count == 4 && frame.missing.isEmpty)
            clock.advance(by: 0.5)
        }
        ignitionOff.isOn = true
        let dark = try await recorder.poll(pids)
        #expect(dark.isEmpty && dark.missing == pids)
        await recorder.stop()

        let channels = try await telemetry.channels(on: drive.vehicle)
        #expect(Set(channels.map(\.quantity)) == ["engineSpeed", "vehicleSpeed", "coolantTemperature", "controlModuleVoltage"])
        let rpm = try #require(channels.first { $0.quantity == "engineSpeed" })
        #expect(rpm.truth == .display && rpm.unit == "rpm")
        #expect(rpm.provenance.origin == .instrument(id: drive.adapter))
        let method = try #require(rpm.provenance.method)
        #expect(method.contains("PID 0C") && method.contains("ISO 15765-4 (CAN 11/500)") && method.contains("7E8") && method.contains("Bluetooth LE"))
        #expect(rpm.provenance.dependencies.contains(drive.adapter))
        let samples = try await telemetry.samples(rpm.id)
        #expect(samples.count == 4)
        #expect(samples.prefix(3).map(\.value) == [1726, 1726, 1726])
        #expect(samples.last?.value.isNaN == true)  // Ignition off: a dropout, not a zero.
        #expect(samples.first?.time == t0.timeIntervalSinceReferenceDate)

        // The adapter is an instrument object; its voltage reading is observed.
        let adapter = try #require(try telemetry.store.object(drive.adapter))
        #expect(adapter.type == .instrument && adapter.attributes[AutomotiveKey.adapterIdentifier]?.value == .string("bluetoothLE:A1B2"))
        // One session event at the start and one at the end.
        let sessions = try telemetry.store.events(about: drive.vehicle).filter { $0.kind == .obdSession }
        #expect(sessions.count == 2)
        let opened = try #require(sessions.first { $0.payload["phase"] == .string("connected") })
        #expect(opened.payload["protocol"] == .string("ISO 15765-4 (CAN 11/500)") && opened.payload["adapter"] == .string("Vgate iCar Pro"))
        #expect(opened.provenance.origin == .instrument(id: drive.adapter) && opened.provenance.truth == .observed)
        let ended = try #require(sessions.first { $0.payload["phase"] == .string("ended") })
        #expect(ended.payload["samples"] == .int(16))
        // Polling never clears codes.
        #expect(!transport.sent.contains("04"))
    }

    @Test func secondDriveReusesTheVehicleAdapterAndChannels() async throws {
        let (recorder, _, telemetry, clock) = try setUp()
        let first = try await recorder.start()
        _ = try await recorder.poll([0x0C])
        await recorder.stop()
        clock.advance(by: 3600)

        let session = ELM327Session(
            transport: MockOBDTransport(
                responder: car, descriptor: OBDAdapterDescriptor(kind: .bluetoothLE, identifier: "A1B2", name: "Vgate iCar Pro")),
            configuration: steady
        )
        let again = try OBDDriveRecorder(session: session, telemetry: telemetry, by: tech, clock: clock)
        let second = try await again.start()
        _ = try await again.poll([0x0C])
        await again.stop()
        #expect(second.vehicle == first.vehicle && second.adapter == first.adapter)
        let channels = try await telemetry.channels(on: first.vehicle)
        #expect(channels.count == 1)
        #expect(try await telemetry.sampleCount(channels[0].id) == 2)
    }

    @Test func liveStreamPollsAtARate() async throws {
        let (recorder, _, telemetry, _) = try setUp()
        let drive = try await recorder.start()
        var frames: [OBDLiveFrame] = []
        for try await frame in recorder.live([0x0C, 0x0D], every: .milliseconds(2)) {
            frames.append(frame)
            if frames.count == 3 { break }
        }
        await recorder.stop()
        #expect(frames.count == 3 && frames.allSatisfy { $0.readings.count == 2 })
        let channels = try await telemetry.channels(on: drive.vehicle)
        #expect(channels.count == 2)
        for channel in channels { #expect(try await telemetry.sampleCount(channel.id) >= 3) }
    }

    @Test func troubleCodesAndFreezeFrameGoThroughTheGarage() async throws {
        let (recorder, _, telemetry, _) = try setUp()
        let drive = try await recorder.start()
        let codes = try await recorder.readTroubleCodes()
        #expect(codes[.stored]?.map(\.code) == ["P0133", "P0562"] && codes[.pending] == [] && codes[.permanent] == [])
        let faults = try VehicleRuntime(store: telemetry.store).faults(of: drive.vehicle)
        #expect(faults.count == 2 && faults.allSatisfy { $0.provenance.truth == .recorded })
        #expect(Set(faults.compactMap { if case .string(let c)? = $0.attributes[AutomotiveKey.dtc]?.value { c } else { nil } }) == ["P0133", "P0562"])

        let frame = try await recorder.readFreezeFrame()
        #expect(frame.trigger?.code == "P0562")
        let ect = try #require(try VehicleRuntime(store: telemetry.store).vehicle(drive.vehicle).component(.coolantTemperatureSensor))
        let stored = try telemetry.store.measurements(at: ect)
        #expect(stored.count == 1 && stored[0].value.value == 83 && stored[0].provenance.truth == .display)
        #expect(stored[0].provenance.method?.contains("mode 02") == true && stored[0].instrument == drive.adapter)
        await recorder.stop()
    }

    @Test func clearingCodesRequiresAPersonsFreshConfirmation() async throws {
        let refuse = Switch()
        let (recorder, transport, telemetry, clock) = try setUp { command in
            command == "04" ? .text(refuse.isOn ? "7E8 03 7F 04 22" : "7E8 01 44") : car(command)
        }
        let drive = try await recorder.start()
        try await recorder.readTroubleCodes()
        let garage = VehicleRuntime(store: telemetry.store)

        // Only a person can confirm.
        #expect(throws: OBDLinkError.self) {
            try ClearCodesConfirmation(person: .agent(id: "diagnostician", run: nil), vehicle: drive.vehicle, confirmedAt: clock.now())
        }
        #expect(throws: OBDLinkError.self) { try ClearCodesConfirmation(person: .system, vehicle: drive.vehicle, confirmedAt: clock.now()) }
        // For another vehicle, or stale: refused before the adapter is asked.
        let other = try ClearCodesConfirmation(person: tech, vehicle: .make(), confirmedAt: clock.now())
        await #expect(throws: OBDLinkError.self) { try await recorder.clearTroubleCodes(other) }
        let stale = try ClearCodesConfirmation(person: tech, vehicle: drive.vehicle, confirmedAt: clock.now())
        clock.advance(by: ClearCodesConfirmation.validity + 1)
        await #expect(throws: OBDLinkError.self) { try await recorder.clearTroubleCodes(stale) }
        #expect(!transport.sent.contains("04"))
        #expect(try garage.faults(of: drive.vehicle).allSatisfy { $0.lifecycle == .active })

        // The ECU refuses (engine running): nothing is archived.
        refuse.isOn = true
        let confirmed = try ClearCodesConfirmation(person: tech, vehicle: drive.vehicle, confirmedAt: clock.now())
        await #expect(throws: OBDLinkError.negativeResponse(service: 0x04, code: 0x22)) { try await recorder.clearTroubleCodes(confirmed) }
        #expect(try garage.faults(of: drive.vehicle).allSatisfy { $0.lifecycle == .active })

        refuse.isOn = false
        let archived = try await recorder.clearTroubleCodes(confirmed)
        #expect(archived.count == 2 && transport.sent.filter { $0 == "04" }.count == 2)
        #expect(try garage.faults(of: drive.vehicle).allSatisfy { $0.lifecycle == .archived })
        let cleared = try #require(try telemetry.store.events(about: drive.vehicle).first { $0.kind == .troubleCodesCleared })
        #expect(cleared.provenance.origin == tech)
        await recorder.stop()
    }

    @Test func vinMustMatchTheChosenVehicle() async throws {
        let (recorder, transport, telemetry, _) = try setUp()
        let other = try VehicleRuntime(store: telemetry.store).addVehicle(vin: "WBA3A5C51CF256985", by: tech)
        await #expect(throws: OBDLinkError.vinMismatch(expected: "WBA3A5C51CF256985", found: hondaVIN)) {
            try await recorder.start(vehicle: other.id)
        }
        #expect(try telemetry.store.objects(ofType: .instrument).isEmpty)
        #expect(try VehicleRuntime(store: telemetry.store).vehicles().count == 1)
        _ = transport
    }

    @Test func noVINNeedsAChosenVehicle() async throws {
        let (recorder, _, telemetry, _) = try setUp { command in command == "0902" ? .text("NO DATA") : car(command) }
        await #expect(throws: OBDLinkError.vinUnavailable) { try await recorder.start() }
        let chosen = try VehicleRuntime(store: telemetry.store).addVehicle(vin: hondaVIN, by: tech)
        let drive = try await recorder.start(vehicle: chosen.id)
        #expect(drive.vehicle == chosen.id && drive.vin == nil)
        await recorder.stop()
    }

    @Test func liveTruthIsObservedOrDisplayOnly() throws {
        let store = try NexusStore(.inMemory)
        let session = ELM327Session(transport: MockOBDTransport())
        #expect(throws: AutomotiveError.unsupportedTruth(.modeled)) {
            try OBDDriveRecorder(session: session, telemetry: TelemetryStore(store: store), by: tech, liveTruth: .modeled)
        }
    }
}
