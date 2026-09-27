import Foundation

/// One Mode 01 parameter ID with its SAE J1979 scaling.
///
/// `A`, `B`, `C`, `D` are the data bytes after the PID in the response.
public struct OBDPID: Hashable, Sendable {
    public var pid: UInt8
    public var name: String
    /// Short quantity name used for measurements, e.g. "engineSpeed".
    public var quantity: String
    public var unit: String
    /// Data bytes the PID returns.
    public var byteCount: Int
    /// The component whose value this is; readings are stored against it.
    public var site: VehicleComponentRole
    let formula: @Sendable ([UInt8]) -> Double

    init(
        _ pid: UInt8, _ name: String, _ quantity: String, _ unit: String, bytes: Int, site: VehicleComponentRole,
        _ formula: @escaping @Sendable ([UInt8]) -> Double
    ) {
        self.pid = pid
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.byteCount = bytes
        self.site = site
        self.formula = formula
    }

    /// The physical value for `data` (exactly `byteCount` bytes).
    public func decode(_ data: [UInt8]) -> Double? {
        guard data.count >= byteCount else { return nil }
        return formula(Array(data.prefix(byteCount)))
    }

    public static func == (lhs: OBDPID, rhs: OBDPID) -> Bool { lhs.pid == rhs.pid }
    public func hash(into hasher: inout Hasher) { hasher.combine(pid) }
}

/// A decoded Mode 01 value.
public struct OBDReading: Hashable, Sendable {
    public var pid: UInt8
    public var name: String
    public var quantity: String
    public var value: Double
    public var unit: String
    public var site: VehicleComponentRole
    /// The ECU header the reply came from, when headers were on ("7E8").
    public var ecu: String?

    public init(pid: UInt8, name: String, quantity: String, value: Double, unit: String, site: VehicleComponentRole, ecu: String? = nil) {
        self.pid = pid
        self.name = name
        self.quantity = quantity
        self.value = value
        self.unit = unit
        self.site = site
        self.ecu = ecu
    }
}

public enum OBDError: Error, Equatable, Sendable {
    case unexpectedMode(UInt8)
    case unknownPID(UInt8)
    case truncated
    case invalidVIN(String)
}

/// SAE J1979 decoding for service modes 01, 03/07/0A and 09.
public enum OBD {
    // MARK: Mode 01

    private static func word(_ d: [UInt8]) -> Double { Double(Int(d[0]) << 8 | Int(d[1])) }
    private static func percent(_ d: [UInt8]) -> Double { Double(d[0]) * 100 / 255 }
    private static func temperature(_ d: [UInt8]) -> Double { Double(d[0]) - 40 }
    private static func trim(_ d: [UInt8]) -> Double { (Double(d[0]) - 128) * 100 / 128 }

    /// The common Mode 01 PIDs. O2 sensor PIDs 14–1B return the narrow-band
    /// voltage (A / 200); their short-term trim byte is available through
    /// `oxygenSensorTrim`.
    public static let pids: [UInt8: OBDPID] = {
        var table: [OBDPID] = [
            OBDPID(0x04, "Calculated engine load", "engineLoad", "%", bytes: 1, site: .engine, percent),
            OBDPID(0x05, "Engine coolant temperature", "coolantTemperature", "degC", bytes: 1, site: .coolantTemperatureSensor, temperature),
            OBDPID(0x06, "Short term fuel trim bank 1", "shortTermFuelTrimBank1", "%", bytes: 1, site: .engine, trim),
            OBDPID(0x07, "Long term fuel trim bank 1", "longTermFuelTrimBank1", "%", bytes: 1, site: .engine, trim),
            OBDPID(0x08, "Short term fuel trim bank 2", "shortTermFuelTrimBank2", "%", bytes: 1, site: .engine, trim),
            OBDPID(0x09, "Long term fuel trim bank 2", "longTermFuelTrimBank2", "%", bytes: 1, site: .engine, trim),
            OBDPID(0x0A, "Fuel pressure", "fuelPressure", "kPa", bytes: 1, site: .engine) { Double($0[0]) * 3 },
            OBDPID(0x0B, "Intake manifold absolute pressure", "manifoldPressure", "kPa", bytes: 1, site: .engine) { Double($0[0]) },
            OBDPID(0x0C, "Engine speed", "engineSpeed", "rpm", bytes: 2, site: .engine) { word($0) / 4 },
            OBDPID(0x0D, "Vehicle speed", "vehicleSpeed", "km/h", bytes: 1, site: .vehicleSpeedSensor) { Double($0[0]) },
            OBDPID(0x0E, "Timing advance", "timingAdvance", "deg", bytes: 1, site: .engine) { Double($0[0]) / 2 - 64 },
            OBDPID(0x0F, "Intake air temperature", "intakeAirTemperature", "degC", bytes: 1, site: .intakeAirTemperatureSensor, temperature),
            OBDPID(0x10, "Mass air flow rate", "massAirflow", "g/s", bytes: 2, site: .massAirflowSensor) { word($0) / 100 },
            OBDPID(0x11, "Throttle position", "throttlePosition", "%", bytes: 1, site: .throttlePositionSensor, percent),
            OBDPID(0x1F, "Run time since engine start", "runTime", "s", bytes: 2, site: .ecu, word),
            OBDPID(0x21, "Distance traveled with MIL on", "distanceWithMIL", "km", bytes: 2, site: .ecu, word),
            OBDPID(0x2F, "Fuel tank level", "fuelLevel", "%", bytes: 1, site: .engine, percent),
            OBDPID(0x31, "Distance since codes cleared", "distanceSinceClear", "km", bytes: 2, site: .ecu, word),
            OBDPID(0x33, "Barometric pressure", "barometricPressure", "kPa", bytes: 1, site: .ecu) { Double($0[0]) },
            OBDPID(0x42, "Control module voltage", "controlModuleVoltage", "V", bytes: 2, site: .ecu) { word($0) / 1000 },
            OBDPID(0x46, "Ambient air temperature", "ambientTemperature", "degC", bytes: 1, site: .ecu, temperature),
            OBDPID(0x5C, "Engine oil temperature", "oilTemperature", "degC", bytes: 1, site: .engine, temperature),
        ]
        for (index, pid) in (UInt8(0x14)...0x1B).enumerated() {
            let site: VehicleComponentRole = index % 4 == 0 ? .upstreamOxygenSensor : .downstreamOxygenSensor
            let bank = index / 4 + 1
            let sensor = index % 4 + 1
            table.append(
                OBDPID(
                    pid, "Oxygen sensor bank \(bank) sensor \(sensor) voltage", "o2VoltageB\(bank)S\(sensor)", "V", bytes: 2, site: site
                ) { Double($0[0]) / 200 })
        }
        return Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) })
    }()

    /// Short-term fuel trim reported by a narrow-band O2 PID (14–1B), or nil
    /// when the sensor is not used for trim (B = 0xFF).
    public static func oxygenSensorTrim(_ data: [UInt8]) -> Double? {
        guard data.count >= 2, data[1] != 0xFF else { return nil }
        return trim([data[1]])
    }

    /// Decodes a Mode 01 reply (`41 PID data [PID data…]`). A request for
    /// several PIDs gets one reply with each PID and its bytes in turn;
    /// unknown PIDs stop the walk because their length is unknown.
    public static func decodeMode01(_ bytes: [UInt8], ecu: String? = nil) throws -> [OBDReading] {
        guard let mode = bytes.first else { throw OBDError.truncated }
        guard mode == 0x41 else { throw OBDError.unexpectedMode(mode) }
        var readings: [OBDReading] = []
        var index = 1
        while index < bytes.count {
            let pidByte = bytes[index]
            guard let pid = pids[pidByte] else {
                if readings.isEmpty { throw OBDError.unknownPID(pidByte) }
                break
            }
            let data = Array(bytes[(index + 1)...].prefix(pid.byteCount))
            guard let value = pid.decode(data) else { throw OBDError.truncated }
            readings.append(OBDReading(pid: pid.pid, name: pid.name, quantity: pid.quantity, value: value, unit: pid.unit, site: pid.site, ecu: ecu))
            index += 1 + pid.byteCount
        }
        return readings
    }

    /// PIDs a "supported PIDs" reply (PID 00, 20, 40…) marks as available.
    public static func supportedPIDs(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 6, bytes[0] == 0x41 else { throw OBDError.truncated }
        let base = bytes[1]
        var supported: [UInt8] = []
        for (byteIndex, byte) in bytes[2..<6].enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                supported.append(base + UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return supported
    }

    /// Monitor status (PID 01): whether the MIL is lit and how many codes are stored.
    public static func monitorStatus(_ bytes: [UInt8]) throws -> (milOn: Bool, storedCodes: Int) {
        guard bytes.count >= 3, bytes[0] == 0x41, bytes[1] == 0x01 else { throw OBDError.truncated }
        return (bytes[2] & 0x80 != 0, Int(bytes[2] & 0x7F))
    }

    // MARK: Modes 03, 07, 0A

    /// Decodes a trouble-code reply for mode 03 (stored), 07 (pending) or 0A
    /// (permanent). On CAN (ISO 15765-4) the mode byte is followed by a count;
    /// older protocols send three codes per frame with no count. Zero pairs are
    /// padding.
    public static func decodeDTCs(_ bytes: [UInt8], hasCount: Bool) throws -> (status: DTCStatus, codes: [DTC]) {
        guard let mode = bytes.first else { throw OBDError.truncated }
        guard let status = DTCStatus(responseMode: mode) else { throw OBDError.unexpectedMode(mode) }
        var payload = Array(bytes.dropFirst())
        var expected: Int?
        if hasCount {
            guard let count = payload.first else { throw OBDError.truncated }
            expected = Int(count)
            payload.removeFirst()
        }
        var codes: [DTC] = []
        var index = 0
        while index + 1 < payload.count {
            if payload[index] != 0 || payload[index + 1] != 0 {
                codes.append(DTC(payload[index], payload[index + 1]))
            }
            index += 2
        }
        if let expected, codes.count < expected { throw OBDError.truncated }
        return (status, expected.map { Array(codes.prefix($0)) } ?? codes)
    }

    // MARK: Mode 09

    /// The VIN from a Mode 09 PID 02 reply. Accepts the reassembled CAN
    /// payload (`49 02 01` + 17 ASCII bytes) or legacy frames concatenated
    /// (`49 02 0n` + 4 bytes each), ignoring zero padding.
    public static func decodeVIN(_ bytes: [UInt8]) throws -> VIN {
        guard bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x02 else {
            throw OBDError.unexpectedMode(bytes.first ?? 0)
        }
        let legacy =
            bytes.count >= 14 && bytes.count % 7 == 0
            && stride(from: 0, to: bytes.count, by: 7).allSatisfy { bytes[$0] == 0x49 && bytes[$0 + 1] == 0x02 }
        var ascii: [UInt8] = []
        if legacy {
            // Repeated `49 02 seq b1 b2 b3 b4` frames.
            for start in stride(from: 0, to: bytes.count, by: 7) {
                ascii += bytes[(start + 3)..<(start + 7)]
            }
        } else {
            ascii = Array(bytes[3...])
        }
        let text = String(decoding: ascii.filter { $0 != 0 }, as: UTF8.self)
        do {
            return try VIN(text)
        } catch {
            throw OBDError.invalidVIN(text)
        }
    }
}

// MARK: Trouble codes

/// Which list a trouble code came from.
public enum DTCStatus: String, Codable, Sendable, CaseIterable {
    /// Mode 03: confirmed, MIL-relevant codes.
    case stored
    /// Mode 07: detected on the current or last drive cycle, not yet confirmed.
    case pending
    /// Mode 0A: cannot be cleared by a scan tool.
    case permanent

    init?(responseMode: UInt8) {
        switch responseMode {
        case 0x43: self = .stored
        case 0x47: self = .pending
        case 0x4A: self = .permanent
        default: return nil
        }
    }
}

/// A five-character diagnostic trouble code (SAE J2012), e.g. "P0562".
public struct DTC: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let code: String

    /// From the two raw bytes: bits 15–14 pick P/C/B/U, bits 13–12 the first
    /// digit, and the remaining three nibbles are hex digits.
    public init(_ high: UInt8, _ low: UInt8) {
        let letter = ["P", "C", "B", "U"][Int(high >> 6)]
        let digits = [(high >> 4) & 0x3, high & 0xF, low >> 4, low & 0xF].map { String($0, radix: 16, uppercase: true) }
        code = letter + digits.joined()
    }

    /// Parses "P0562"; nil unless it is a letter P/C/B/U, a digit 0–3 and three hex digits.
    public init?(_ text: String) {
        let upper = Array(text.uppercased())
        guard upper.count == 5, "PCBU".contains(upper[0]), ("0"..."3").contains(upper[1]),
            upper[2...].allSatisfy(\.isHexDigit)
        else { return nil }
        code = String(upper)
    }

    public var description: String { code }

    public var system: VehicleSystem {
        switch code.first {
        case "P": .powertrain
        case "C": .chassis
        case "B": .body
        default: .network
        }
    }

    /// SAE-defined (generic) rather than manufacturer-specific: second digit
    /// 0 or 2, and P34–P39.
    public var isGeneric: Bool {
        let characters = Array(code)
        switch characters[1] {
        case "0", "2": return true
        case "3": return characters[0] == "P" && ("4"..."9").contains(characters[2])
        default: return false
        }
    }

    /// The two raw bytes, the inverse of `init(_:_:)`.
    public var bytes: (UInt8, UInt8) {
        let characters = Array(code)
        let letter = UInt8(Array("PCBU").firstIndex(of: characters[0])!)
        let nibbles = characters[1...].map { UInt8($0.hexDigitValue!) }
        return (letter << 6 | nibbles[0] << 4 | nibbles[1], nibbles[2] << 4 | nibbles[3])
    }

    public static func < (lhs: DTC, rhs: DTC) -> Bool { lhs.code < rhs.code }
}
