import Foundation
import NexusCore
import NexusModel

/// A JSON document, for providers that speak JSON over the wire.
///
/// Parsing and serialization are hand-written so that numbers keep their
/// integer/fraction distinction, output is deterministic (sorted keys), and
/// a member's raw text can be lifted out verbatim (`rawMember`).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let number): number
        case .double(let number) where number.rounded() == number && abs(number) < 9e18: Int64(number)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }
}

public enum JSONError: Error, Equatable, Sendable {
    /// Malformed JSON at a UTF-8 byte offset.
    case syntax(offset: Int, reason: String)
}

// MARK: - Parsing

extension JSONValue {
    public init(parsing text: String) throws {
        self = try JSONValue(parsing: Data(text.utf8))
    }

    public init(parsing data: Data) throws {
        var parser = JSONParser(bytes: Array(data))
        self = try parser.parseDocument()
    }

    /// The exact source text of member `key` of the top-level object in
    /// `data`, or nil when the document is not an object or lacks the key.
    /// Used to replay provider content byte for byte.
    public static func rawMember(_ key: String, in data: Data) throws -> String? {
        var parser = JSONParser(bytes: Array(data))
        guard let range = try parser.rangeOfTopLevelMember(key) else { return nil }
        return String(decoding: data[data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound], as: UTF8.self)
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("trailing characters") }
        return value
    }

    mutating func rangeOfTopLevelMember(_ key: String) throws -> Range<Int>? {
        skipWhitespace()
        guard peek() == UInt8(ascii: "{") else { return nil }
        index += 1
        var found: Range<Int>?
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { index += 1; return nil }
        while true {
            skipWhitespace()
            let name = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            let start = index
            _ = try parseValue()
            if name == key, found == nil { found = start ..< index }
            skipWhitespace()
            if try consumeSeparator(closing: "}") { break }
        }
        skipWhitespace()
        guard index == bytes.count else { throw error("trailing characters") }
        return found
    }

    private func error(_ reason: String) -> JSONError { .syntax(offset: index, reason: reason) }

    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func expect(_ character: Unicode.Scalar) throws {
        guard peek() == UInt8(ascii: character) else { throw error("expected '\(character)'") }
        index += 1
    }

    /// After a member or element: true at the closing bracket, false after a comma.
    private mutating func consumeSeparator(closing: Unicode.Scalar) throws -> Bool {
        switch peek() {
        case UInt8(ascii: ","): index += 1; return false
        case UInt8(ascii: closing): index += 1; return true
        default: throw error("expected ',' or '\(closing)'")
        }
    }

    private mutating func parseLiteral(_ word: String, _ value: JSONValue) throws -> JSONValue {
        let utf8 = Array(word.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index ..< index + utf8.count]) == utf8 else { throw error("invalid literal") }
        index += utf8.count
        return value
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        switch peek() {
        case nil: throw error("unexpected end")
        case UInt8(ascii: "{"):
            index += 1
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                members[key] = try parseValue()
                skipWhitespace()
                if try consumeSeparator(closing: "}") { return .object(members) }
            }
        case UInt8(ascii: "["):
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                if try consumeSeparator(closing: "]") { return .array(items) }
            }
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        default: return try parseNumber()
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isInteger = true
        scan: while let byte = peek() {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"): index += 1
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"):
                isInteger = false
                index += 1
            default: break scan
            }
        }
        let literal = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard !literal.isEmpty, literal != "-" else { throw error("invalid value") }
        if isInteger, let number = Int64(literal) { return .int(number) }
        guard let number = Double(literal), number.isFinite else { throw error("invalid number") }
        return .double(number)
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var scalars = String.UnicodeScalarView()
        var runStart = index
        func flush(_ end: Int) { scalars.append(contentsOf: String(decoding: bytes[runStart ..< end], as: UTF8.self).unicodeScalars) }
        while true {
            guard let byte = peek() else { throw error("unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                flush(index)
                index += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                flush(index)
                index += 1
                guard let escape = peek() else { throw error("unterminated escape") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    if (0xD800 ..< 0xDC00).contains(code) {
                        guard peek() == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                            throw error("unpaired surrogate")
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00 ..< 0xE000).contains(low) else { throw error("unpaired surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("invalid code point") }
                    scalars.append(scalar)
                default: throw error("invalid escape")
                }
                runStart = index
            case 0x00 ..< 0x20:
                throw error("control character in string")
            default:
                index += 1
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16) else {
            throw error("invalid \\u escape")
        }
        index += 4
        return code
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Compact JSON with sorted object keys, so equal values serialize equally.
    public var serialized: String {
        var output = ""
        write(to: &output)
        return output
    }

    private func write(to output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .int(let number): output += String(number)
        case .double(let number): output += number.isFinite ? "\(number)" : "null"
        case .string(let text): JSONValue.writeString(text, to: &output)
        case .array(let items):
            output += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { output += "," }
                item.write(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (offset, key) in members.keys.sorted().enumerated() {
                if offset > 0 { output += "," }
                JSONValue.writeString(key, to: &output)
                output += ":"
                members[key]!.write(to: &output)
            }
            output += "}"
        }
    }

    /// A JSON string literal for `text`.
    public static func quoted(_ text: String) -> String {
        var output = ""
        writeString(text, to: &output)
        return output
    }

    private static func writeString(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case let control where control.value < 0x20:
                let hex = String(control.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - World-model values

extension JSONValue {
    /// JSON for a world-model value. Types JSON lacks are written as the
    /// closest JSON shape: dates as ISO 8601 strings, references as their ID
    /// string, quantities as `{"value", "unit"}`.
    public init(_ value: Value) {
        switch value {
        case .string(let text): self = .string(text)
        case .int(let number): self = .int(number)
        case .double(let number): self = .double(number)
        case .bool(let flag): self = .bool(flag)
        case .date(let date): self = .string(ISO8601DateFormatter().string(from: date))
        case .quantity(let quantity): self = .object(["value": .double(quantity.value), "unit": .string(quantity.unit)])
        case .reference(let id): self = .string(id.description)
        case .list(let values): self = .array(values.map(JSONValue.init))
        case .map(let members): self = .object(members.mapValues(JSONValue.init))
        case .null: self = .null
        }
    }

    /// The world-model value for this JSON. Strings stay strings: tools
    /// accept object IDs as strings, so no guessing at references or dates.
    public var value: Value {
        switch self {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .int(let number): .int(number)
        case .double(let number): .double(number)
        case .string(let text): .string(text)
        case .array(let items): .list(items.map(\.value))
        case .object(let members): .map(members.mapValues(\.value))
        }
    }
}
