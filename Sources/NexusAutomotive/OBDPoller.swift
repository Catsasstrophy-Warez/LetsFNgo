import Foundation
import NexusCore

/// One polling pass: the values read and the PIDs that returned nothing.
public struct OBDLiveFrame: Sendable, Hashable {
    public var at: Date
    public var readings: [OBDReading]
    /// Requested PIDs that got `NO DATA`, a refusal, or a reply that didn't decode.
    public var missing: [UInt8]

    public init(at: Date, readings: [OBDReading], missing: [UInt8]) {
        self.at = at
        self.readings = readings
        self.missing = missing
    }

    /// Nothing answered: typically the ignition was switched off.
    public var isEmpty: Bool { readings.isEmpty }
}

/// The ECU's snapshot at the moment a code was set (service 02, frame 0).
public struct FreezeFrame: Sendable, Hashable {
    /// The code that caused the snapshot (PID 02); nil when no frame is stored.
    public var trigger: DTC?
    public var readings: [OBDReading]

    public init(trigger: DTC?, readings: [OBDReading]) {
        self.trigger = trigger
        self.readings = readings
    }
}

/// A person's explicit go-ahead to erase a vehicle's codes (service 04).
///
/// Clearing codes turns the MIL off, erases freeze frames and resets
/// readiness monitors: an irreversible action on an external system (P4). It
/// never happens automatically: only a person (`Origin.user`) can confirm,
/// the confirmation names one vehicle, and it goes stale after a few minutes.
/// Agents, automations, importers and the system cannot construct one.
public struct ClearCodesConfirmation: Sendable, Hashable {
    public let person: Origin
    public let vehicle: ObjectID
    public let confirmedAt: Date
    /// How long a confirmation stays valid.
    public static let validity: TimeInterval = 300

    public init(person: Origin, vehicle: ObjectID, confirmedAt: Date) throws {
        guard case .user = person else {
            throw OBDLinkError.confirmationRequired("only a person can confirm clearing codes, not \(person)")
        }
        self.person = person
        self.vehicle = vehicle
        self.confirmedAt = confirmedAt
    }

    /// Valid for `vehicle` at `now`.
    public func isValid(for vehicle: ObjectID, at now: Date) -> Bool {
        self.vehicle == vehicle && now >= confirmedAt && now.timeIntervalSince(confirmedAt) <= Self.validity
    }
}

/// SAE J1979 services over an `ELM327Session`: supported PIDs, live PIDs,
/// trouble codes, freeze frame, VIN and (confirmed) code clearing.
///
/// Requests go one PID at a time, which every adapter and ECU accepts. With
/// headers on, several modules may answer; values come from the lowest
/// header that answered (the engine ECU, 7E8, on CAN).
public struct OBDPoller: Sendable {
    public let session: ELM327Session

    public init(session: ELM327Session) {
        self.session = session
    }

    /// PIDs the vehicle supports for service 01, from the bitmaps at 00, 20, 40…
    /// The bitmap PIDs themselves are left out.
    public func supportedPIDs() async throws -> Set<UInt8> {
        var supported: Set<UInt8> = []
        var base: UInt8 = 0x00
        while true {
            let messages: [ECUMessage]
            do {
                messages = try await session.request("01" + ELM327.hex(base))
            } catch OBDLinkError.noData, OBDLinkError.negativeResponse {
                if base == 0 { throw OBDLinkError.noData(command: "0100") }
                break
            }
            var next: Set<UInt8> = []
            for message in messages where message.bytes.count >= 6 && message.bytes[1] == base {
                next.formUnion(try OBD.supportedPIDs(message.bytes))
            }
            supported.formUnion(next)
            guard base < 0xE0, next.contains(base + 0x20) else { break }
            base += 0x20
        }
        return supported.filter { $0 % 0x20 != 0 }
    }

    /// Reads each PID once. A PID the vehicle doesn't answer is reported
    /// missing, not thrown; a link failure (timeout, disconnect) is thrown.
    public func read(_ pids: [UInt8], clock: NexusClock = SystemClock()) async throws -> OBDLiveFrame {
        var readings: [OBDReading] = []
        var missing: [UInt8] = []
        for pid in pids {
            try Task.checkCancellation()
            if let reading = try await read(pid) {
                readings.append(reading)
            } else {
                missing.append(pid)
            }
        }
        return OBDLiveFrame(at: clock.now(), readings: readings, missing: missing)
    }

    /// One PID, or nil when the vehicle doesn't answer it or it isn't decodable.
    public func read(_ pid: UInt8) async throws -> OBDReading? {
        let messages: [ECUMessage]
        do {
            messages = try await session.request("01" + ELM327.hex(pid))
        } catch OBDLinkError.noData, OBDLinkError.negativeResponse, OBDLinkError.malformed {
            return nil
        }
        for message in messages where message.bytes.count >= 2 && message.bytes[0] == 0x41 && message.bytes[1] == pid {
            if let reading = try? OBD.decodeMode01(message.bytes, ecu: message.ecu).first { return reading }
        }
        return nil
    }

    /// Codes from service 03 (stored), 07 (pending) or 0A (permanent), from
    /// every module that answered, sorted. No codes is an empty list.
    public func troubleCodes(_ status: DTCStatus) async throws -> [DTC] {
        let messages: [ECUMessage]
        do {
            messages = try await session.request(status.mode)
        } catch OBDLinkError.noData(_) {
            return []
        } catch OBDLinkError.negativeResponse(_, _) where status == .permanent {
            return []  // Service 0A is only required from 2010 model years.
        }
        let hasCount = await session.identity?.vehicleProtocol.isCAN ?? true
        var codes: Set<DTC> = []
        // Legacy protocols send several frames per module; decode each.
        for message in messages {
            codes.formUnion(try OBD.decodeDTCs(message.bytes, hasCount: hasCount).codes)
        }
        return codes.sorted()
    }

    /// Freeze frame 0: the code that triggered it and the requested PIDs.
    public func freezeFrame(pids: [UInt8] = [0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x11, 0x42]) async throws -> FreezeFrame {
        let trigger: DTC?
        do {
            let messages = try await session.request("020200")
            trigger = messages.lazy.filter { $0.bytes.count >= 5 && $0.bytes[0] == 0x42 && $0.bytes[1] == 0x02 }
                .map { DTC($0.bytes[3], $0.bytes[4]) }.first { $0.code != "P0000" }
        } catch OBDLinkError.noData(_), OBDLinkError.negativeResponse(_, _) {
            return FreezeFrame(trigger: nil, readings: [])
        }
        guard trigger != nil else { return FreezeFrame(trigger: nil, readings: []) }
        var readings: [OBDReading] = []
        for pid in pids {
            let messages: [ECUMessage]
            do {
                messages = try await session.request("02" + ELM327.hex(pid) + "00")
            } catch OBDLinkError.noData(_), OBDLinkError.negativeResponse(_, _) {
                continue
            }
            // `42 PID frame data…` decodes as service 01 once the frame byte is removed.
            for message in messages where message.bytes.count >= 4 && message.bytes[0] == 0x42 && message.bytes[1] == pid {
                if let reading = try? OBD.decodeMode01([0x41, pid] + message.bytes.dropFirst(3), ecu: message.ecu).first {
                    readings.append(reading)
                    break
                }
            }
        }
        return FreezeFrame(trigger: trigger, readings: readings)
    }

    /// The VIN from service 09 PID 02. Legacy protocols send it in five
    /// frames per module, joined here before decoding.
    public func vin() async throws -> VIN {
        let messages = try await session.request("0902", timeout: .seconds(5))
        var byModule: [String: [UInt8]] = [:]
        var order: [String] = []
        for message in messages {
            let key = message.ecu ?? ""
            if byModule[key] == nil { order.append(key) }
            byModule[key, default: []] += message.bytes
        }
        var lastError: any Error = OBDLinkError.noData(command: "0902")
        for key in order {
            do {
                return try OBD.decodeVIN(byModule[key]!)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The adapter's own voltage at the diagnostic connector (`ATRV`).
    public func adapterVoltage() async throws -> Double? {
        ELM327.parseVoltage(try await session.command("ATRV").joined())
    }

    /// Erases stored and pending codes and freeze frames (service 04).
    /// Requires a person's confirmation; the ECU may still refuse (for
    /// example with the engine running), which throws `negativeResponse`.
    public func clearTroubleCodes(_ confirmation: ClearCodesConfirmation) async throws {
        guard case .user = confirmation.person else {
            throw OBDLinkError.confirmationRequired("only a person can confirm clearing codes")
        }
        let messages = try await session.request("04", timeout: .seconds(5))
        guard messages.contains(where: { $0.bytes.first == 0x44 }) else {
            throw OBDLinkError.malformed(messages.map { $0.bytes.map(ELM327.hex).joined(separator: " ") }.joined(separator: "; "))
        }
    }
}
