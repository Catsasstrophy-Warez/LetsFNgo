import Foundation

/// One classic CAN frame (up to 8 data bytes).
public struct CANFrame: Hashable, Sendable {
    public var id: UInt32
    /// 29-bit identifier when true, 11-bit otherwise.
    public var isExtended: Bool
    public var data: [UInt8]
    /// Capture time in seconds, when known.
    public var timestamp: Double?

    public init(id: UInt32, isExtended: Bool = false, data: [UInt8], timestamp: Double? = nil) {
        self.id = id
        self.isExtended = isExtended
        self.data = data
        self.timestamp = timestamp
    }

    public var dlc: Int { data.count }
}

/// Bit layout of a signal, as DBC writes it: `@1` is Intel (little endian),
/// `@0` is Motorola (big endian).
public enum ByteOrder: String, Codable, Sendable {
    case littleEndian
    case bigEndian
}

public enum CANError: Error, Equatable, Sendable {
    /// The signal's bits fall outside the frame's data.
    case signalOutOfRange(String)
    case malformedDBC(line: Int, text: String)
}

/// A DBC signal definition (`SG_` line).
public struct DBCSignal: Hashable, Sendable {
    public var name: String
    /// DBC start bit: the least significant bit for Intel signals, the most
    /// significant bit (in DBC's sawtooth numbering) for Motorola signals.
    public var startBit: Int
    public var length: Int
    public var byteOrder: ByteOrder
    public var isSigned: Bool
    public var factor: Double
    public var offset: Double
    public var minimum: Double
    public var maximum: Double
    public var unit: String
    public var receivers: [String]

    public init(
        name: String, startBit: Int, length: Int, byteOrder: ByteOrder, isSigned: Bool = false, factor: Double = 1, offset: Double = 0,
        minimum: Double = 0, maximum: Double = 0, unit: String = "", receivers: [String] = []
    ) {
        self.name = name
        self.startBit = startBit
        self.length = length
        self.byteOrder = byteOrder
        self.isSigned = isSigned
        self.factor = factor
        self.offset = offset
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
        self.receivers = receivers
    }

    /// Absolute bit positions (byte × 8 + bit, bit 0 = LSB of the byte), most
    /// significant first.
    func bitPositions() -> [Int] {
        switch byteOrder {
        case .littleEndian:
            return (0..<length).map { startBit + $0 }.reversed()
        case .bigEndian:
            // Walk DBC's sawtooth: down within a byte, then to bit 7 of the next byte.
            var positions: [Int] = []
            var bit = startBit
            for _ in 0..<length {
                positions.append(bit)
                bit = bit % 8 == 0 ? bit + 15 : bit - 1
            }
            return positions
        }
    }

    /// The raw unsigned field.
    public func raw(from data: [UInt8]) throws -> UInt64 {
        var value: UInt64 = 0
        for position in bitPositions() {
            let byte = position / 8
            guard byte >= 0, byte < data.count, length <= 64 else { throw CANError.signalOutOfRange(name) }
            value = value << 1 | UInt64((data[byte] >> (position % 8)) & 1)
        }
        return value
    }

    /// The physical value: raw (sign-extended when signed) × factor + offset.
    public func decode(_ data: [UInt8]) throws -> Double {
        let raw = try raw(from: data)
        if isSigned, length < 64, raw & (1 << (length - 1)) != 0 {
            let extended = Int64(bitPattern: raw | ~((1 << length) - 1))
            return Double(extended) * factor + offset
        }
        if isSigned, length == 64 {
            return Double(Int64(bitPattern: raw)) * factor + offset
        }
        return Double(raw) * factor + offset
    }

    /// Writes `physical` into `data` (the inverse of `decode`), rounding to the nearest raw step.
    public func encode(_ physical: Double, into data: inout [UInt8]) throws {
        let scaled = ((physical - offset) / factor).rounded()
        let mask: UInt64 = length == 64 ? .max : (1 << length) - 1
        let raw = isSigned ? UInt64(bitPattern: Int64(scaled)) & mask : UInt64(max(0, scaled)) & mask
        for (index, position) in bitPositions().enumerated() {
            let byte = position / 8
            guard byte >= 0, byte < data.count else { throw CANError.signalOutOfRange(name) }
            let bit = (raw >> UInt64(length - 1 - index)) & 1
            if bit == 1 {
                data[byte] |= 1 << (position % 8)
            } else {
                data[byte] &= ~(1 << (position % 8))
            }
        }
    }
}

/// A DBC message definition (`BO_` line) and its signals.
public struct DBCMessage: Hashable, Sendable {
    /// The DBC identifier. Bit 31 set marks an extended (29-bit) ID.
    public var id: UInt32
    public var name: String
    public var length: Int
    public var sender: String
    public var signals: [DBCSignal]

    public var canID: UInt32 { id & 0x1FFF_FFFF }
    public var isExtended: Bool { id & 0x8000_0000 != 0 }

    /// Every signal's physical value in `frame`.
    public func decode(_ frame: CANFrame) throws -> [String: Double] {
        var values: [String: Double] = [:]
        for signal in signals {
            values[signal.name] = try signal.decode(frame.data)
        }
        return values
    }
}

/// The subset of the DBC format Nexus reads: `BO_` messages and their `SG_`
/// signals, including multiplexer markers (read, but not interpreted). Other
/// sections (`VERSION`, `NS_`, `BU_`, `CM_`, `BA_`, `VAL_`…) are skipped.
public struct DBCDatabase: Hashable, Sendable {
    public var messages: [DBCMessage]

    public init(messages: [DBCMessage]) {
        self.messages = messages
    }

    public func message(for frame: CANFrame) -> DBCMessage? {
        messages.first { $0.canID == frame.id && $0.isExtended == frame.isExtended }
    }

    public func message(named name: String) -> DBCMessage? {
        messages.first { $0.name == name }
    }

    /// Decodes a frame with its message definition; nil for unknown IDs.
    public func decode(_ frame: CANFrame) throws -> [String: Double]? {
        try message(for: frame)?.decode(frame)
    }

    public static func parse(_ text: String) throws -> DBCDatabase {
        var messages: [DBCMessage] = []
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("BO_ ") {
                messages.append(try parseMessage(line, number: index + 1))
            } else if line.hasPrefix("SG_ ") {
                guard !messages.isEmpty else { throw CANError.malformedDBC(line: index + 1, text: line) }
                messages[messages.count - 1].signals.append(try parseSignal(line, number: index + 1))
            }
        }
        return DBCDatabase(messages: messages)
    }

    /// `BO_ 2364540158 EEC1: 8 Engine`
    static func parseMessage(_ line: String, number: Int) throws -> DBCMessage {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, let id = UInt32(parts[1]), parts[2].hasSuffix(":"), let length = Int(parts[3]) else {
            throw CANError.malformedDBC(line: number, text: line)
        }
        return DBCMessage(id: id, name: String(parts[2].dropLast()), length: length, sender: parts.count > 4 ? parts[4] : "", signals: [])
    }

    /// `SG_ EngineSpeed : 24|16@1+ (0.125,0) [0|8031.875] "rpm" Vector__XXX`
    static func parseSignal(_ line: String, number: Int) throws -> DBCSignal {
        func fail() -> CANError { .malformedDBC(line: number, text: line) }
        guard let colon = line.firstIndex(of: ":") else { throw fail() }
        let head = line[line.index(line.startIndex, offsetBy: 4)..<colon].split(separator: " ")
        guard let name = head.first else { throw fail() }
        var rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

        // start|length@order sign
        guard let space = rest.firstIndex(of: " ") else { throw fail() }
        let layout = rest[..<space]
        rest = rest[space...].trimmingCharacters(in: .whitespaces)
        let layoutParts = layout.split(whereSeparator: { $0 == "|" || $0 == "@" })
        guard layoutParts.count == 3, let start = Int(layoutParts[0]), let length = Int(layoutParts[1]), layoutParts[2].count == 2 else {
            throw fail()
        }
        let orderSign = Array(layoutParts[2])
        guard let order: ByteOrder = orderSign[0] == "1" ? .littleEndian : (orderSign[0] == "0" ? .bigEndian : nil),
            orderSign[1] == "+" || orderSign[1] == "-"
        else { throw fail() }

        func bracketed(_ open: Character, _ close: Character) throws -> [Double] {
            guard let from = rest.firstIndex(of: open), let to = rest.firstIndex(of: close), from < to else { throw fail() }
            let numbers = rest[rest.index(after: from)..<to].split(whereSeparator: { $0 == "," || $0 == "|" }).map {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard numbers.allSatisfy({ $0 != nil }) else { throw fail() }
            rest = String(rest[rest.index(after: to)...])
            return numbers.map { $0! }
        }
        let scaling = try bracketed("(", ")")
        let limits = try bracketed("[", "]")
        guard scaling.count == 2, limits.count == 2 else { throw fail() }

        var unit = ""
        if let open = rest.firstIndex(of: "\""), let close = rest[rest.index(after: open)...].firstIndex(of: "\"") {
            unit = String(rest[rest.index(after: open)..<close])
            rest = String(rest[rest.index(after: close)...])
        }
        let receivers = rest.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { $0 != "Vector__XXX" }
        return DBCSignal(
            name: String(name), startBit: start, length: length, byteOrder: order, isSigned: orderSign[1] == "-", factor: scaling[0],
            offset: scaling[1], minimum: limits[0], maximum: limits[1], unit: unit, receivers: receivers
        )
    }
}
