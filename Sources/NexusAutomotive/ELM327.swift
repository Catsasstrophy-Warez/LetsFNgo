import Foundation

/// One reply from one control module, after frame reassembly.
public struct ECUMessage: Hashable, Sendable {
    /// The responding module's header ("7E8", "18DAF110", "486B10"), or nil with headers off.
    public var ecu: String?
    /// The OBD payload, starting at the response mode byte (0x41, 0x43, 0x49…).
    public var bytes: [UInt8]

    public init(ecu: String?, bytes: [UInt8]) {
        self.ecu = ecu
        self.bytes = bytes
    }
}

public enum ELM327Error: Error, Equatable, Sendable {
    /// "NO DATA": the vehicle did not answer the request.
    case noData
    /// An adapter or bus error line ("CAN ERROR", "UNABLE TO CONNECT", "?").
    case adapter(String)
    /// A line that is not hex data.
    case malformed(String)
}

/// Parses the text an ELM327-compatible adapter prints for an OBD request.
///
/// Handles spaces on or off (`ATS0`), the `>` prompt, `SEARCHING...`, echoed
/// commands, headers off (`ATH0`) including the CAN multi-frame layout
/// (`014` then `0: …`, `1: …`), and headers on (`ATH1`) for 11-bit CAN
/// (`7E8 04 41 0C 1A F8`), 29-bit CAN (`18 DA F1 10 04 41 0C 1A F8`) and the
/// legacy J1850/ISO 9141/KWP layout (three header bytes, data, checksum).
/// CAN replies are reassembled per module from ISO-TP single, first and
/// consecutive frames.
public enum ELM327 {
    public enum Headers: Sendable {
        case off
        /// Headers on; the format is detected from each line.
        case on
    }

    static let informational = ["SEARCHING...", "SEARCHING", "OK", "ELM327", "BUS INIT"]
    static let errors = [
        "UNABLE TO CONNECT", "CAN ERROR", "BUS ERROR", "BUS BUSY", "STOPPED", "BUFFER FULL", "FB ERROR", "DATA ERROR",
        "<DATA ERROR", "<RX ERROR", "RX ERROR", "LV RESET", "ACT ALERT", "ERR",
    ]

    /// Splits adapter output into ECU messages. `command` is dropped when the
    /// adapter echoes it (echo on, `ATE1`).
    public static func parse(_ text: String, headers: Headers = .off, command: String? = nil) throws -> [ECUMessage] {
        let echo = command.map { $0.uppercased().filter { !$0.isWhitespace } }
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: ">", with: "\n").split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if line.isEmpty || informational.contains(where: { line.hasPrefix($0) }) { continue }
            if let echo, line.filter({ !$0.isWhitespace }) == echo { continue }
            if line == "NO DATA" { continue }
            if line == "?" || errors.contains(where: { line.hasPrefix($0) }) { throw ELM327Error.adapter(line) }
            lines.append(line)
        }
        if lines.isEmpty { throw ELM327Error.noData }
        switch headers {
        case .off: return try parseHeadersOff(lines)
        case .on: return try parseHeadersOn(lines)
        }
    }

    /// The adapter's own battery reading (`ATRV`), e.g. "12.6V".
    public static func parseVoltage(_ text: String) -> Double? {
        let cleaned = text.uppercased().replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasSuffix("V") else { return nil }
        return Double(cleaned.dropLast().trimmingCharacters(in: .whitespaces))
    }

    // MARK: Headers off

    private static func parseHeadersOff(_ lines: [String]) throws -> [ECUMessage] {
        // CAN multi-frame: a byte-count line, then "n: bytes" lines.
        if let first = lines.first, lines.count > 1, !first.contains(" "), first.count == 3, let total = Int(first, radix: 16),
            lines.dropFirst().allSatisfy({ $0.contains(":") })
        {
            var bytes: [UInt8] = []
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { throw ELM327Error.malformed(line) }
                bytes += try hexBytes(String(parts[1]))
            }
            return [ECUMessage(ecu: nil, bytes: Array(bytes.prefix(total)))]
        }
        return try lines.map { ECUMessage(ecu: nil, bytes: try hexBytes($0)) }
    }

    // MARK: Headers on

    private enum Layout {
        case can11
        case can29
        case legacy
    }

    private static func parseHeadersOn(_ lines: [String]) throws -> [ECUMessage] {
        var order: [String] = []
        var pending: [String: (expected: Int, bytes: [UInt8])] = [:]
        var messages: [ECUMessage] = []

        for line in lines {
            let (layout, header, rest) = try split(line)
            switch layout {
            case .legacy:
                // Three header bytes are already removed; the last byte is the checksum.
                guard !rest.isEmpty else { throw ELM327Error.malformed(line) }
                messages.append(ECUMessage(ecu: header, bytes: Array(rest.dropLast())))
            case .can11, .can29:
                guard let pci = rest.first else { throw ELM327Error.malformed(line) }
                switch pci >> 4 {
                case 0:
                    let length = Int(pci & 0x0F)
                    messages.append(ECUMessage(ecu: header, bytes: Array(rest.dropFirst().prefix(length))))
                case 1:
                    guard rest.count >= 2 else { throw ELM327Error.malformed(line) }
                    let length = Int(pci & 0x0F) << 8 | Int(rest[1])
                    pending[header] = (length, Array(rest.dropFirst(2)))
                    order.append(header)
                case 2:
                    guard var frame = pending[header] else { throw ELM327Error.malformed(line) }
                    frame.bytes += rest.dropFirst()
                    pending[header] = frame
                default:
                    continue  // Flow control frames carry no payload.
                }
            }
        }
        for header in order {
            if let frame = pending[header] {
                guard frame.bytes.count >= frame.expected else { throw ELM327Error.malformed("incomplete reply from \(header)") }
                messages.append(ECUMessage(ecu: header, bytes: Array(frame.bytes.prefix(frame.expected))))
            }
        }
        return messages
    }

    private static func split(_ line: String) throws -> (Layout, String, [UInt8]) {
        let tokens = line.split(separator: " ").map(String.init)
        if let first = tokens.first, first.count == 3, tokens.count > 1 {
            return (.can11, first, try hexBytes(tokens.dropFirst().joined()))
        }
        if let first = tokens.first, first.count == 8, tokens.count > 1 {
            return (.can29, first, try hexBytes(tokens.dropFirst().joined()))
        }
        let compact = line.filter { !$0.isWhitespace }
        if tokens.count == 1, compact.count % 2 == 1 {
            // Spaces off, 11-bit CAN: "7E8064100BE3FA813".
            return (.can11, String(compact.prefix(3)), try hexBytes(String(compact.dropFirst(3))))
        }
        let bytes = try hexBytes(compact)
        if bytes.count > 5, bytes[0] == 0x18, bytes[1] == 0xDA || bytes[1] == 0xDB {
            return (.can29, bytes[0..<4].map(hex).joined(), Array(bytes.dropFirst(4)))
        }
        guard bytes.count > 3 else { throw ELM327Error.malformed(line) }
        return (.legacy, bytes[0..<3].map(hex).joined(), Array(bytes.dropFirst(3)))
    }

    // MARK: Hex

    static func hex(_ byte: UInt8) -> String {
        let text = String(byte, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    /// "41 0C 1A F8" or "410C1AF8" → [0x41, 0x0C, 0x1A, 0xF8].
    public static func hexBytes(_ text: String) throws -> [UInt8] {
        let compact = Array(text.filter { !$0.isWhitespace })
        guard compact.count % 2 == 0 else { throw ELM327Error.malformed(text) }
        return try stride(from: 0, to: compact.count, by: 2).map { index in
            guard let byte = UInt8(String(compact[index...index + 1]), radix: 16) else { throw ELM327Error.malformed(text) }
            return byte
        }
    }
}
