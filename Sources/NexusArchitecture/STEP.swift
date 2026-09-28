import Foundation

/// A parameter of a STEP (ISO 10303-21) entity instance.
public indirect enum StepValue: Sendable, Hashable {
    /// `$`: no value.
    case null
    /// `*`: a value derived from other attributes.
    case derived
    case reference(Int)
    case string(String)
    /// `.ELEMENT.`, without the dots.
    case enumeration(String)
    case integer(Int)
    case real(Double)
    case list([StepValue])
    /// A typed value such as `IFCLABEL('x')`.
    case typed(String, [StepValue])

    public var string: String? {
        switch self {
        case .string(let text): text
        case .typed(_, let values): values.first?.string
        default: nil
        }
    }

    public var number: Double? {
        switch self {
        case .real(let value): value
        case .integer(let value): Double(value)
        case .typed(_, let values): values.first?.number
        default: nil
        }
    }

    public var reference: Int? { if case .reference(let id) = self { id } else { nil } }

    public var references: [Int] {
        if case .list(let values) = self { return values.compactMap(\.reference) }
        return reference.map { [$0] } ?? []
    }
}

/// One entity instance: `#12=IFCSPACE(...)`. Header entries have id 0.
public struct StepEntity: Sendable, Hashable {
    public var id: Int
    /// Upper-case type name, e.g. "IFCSPACE".
    public var type: String
    public var parameters: [StepValue]
    public var line: Int

    public subscript(_ index: Int) -> StepValue { index < parameters.count ? parameters[index] : .null }
}

/// A STEP physical file: header entries and data instances by id.
public struct StepFile: Sendable, Hashable {
    public var header: [StepEntity]
    public var entities: [Int: StepEntity]

    public func header(_ type: String) -> StepEntity? { header.first { $0.type == type } }

    public func entities(ofType type: String) -> [StepEntity] {
        entities.values.filter { $0.type == type }.sorted { $0.id < $1.id }
    }
}

/// A minimal STEP physical-file reader: HEADER and DATA sections, simple
/// entity instances, strings with `''` and `\X\`, `\X2\…\X0\` and `\\`
/// escapes, and comments. Complex (multi-type) instances are skipped. No
/// schema is checked; callers read the entities they know by position.
public enum STEP {
    public static func parse(_ text: String) throws -> StepFile {
        var scanner = Scanner(Array(text.unicodeScalars))
        scanner.skipTrivia()
        guard scanner.keyword() == "ISO-10303-21", scanner.consume(";") else {
            throw ArchitectureError.malformedIFC(line: scanner.line, reason: "missing ISO-10303-21 header")
        }
        var header: [StepEntity] = []
        var entities: [Int: StepEntity] = [:]
        var section = ""
        while true {
            scanner.skipTrivia()
            if scanner.atEnd { throw ArchitectureError.malformedIFC(line: scanner.line, reason: "missing END-ISO-10303-21") }
            let line = scanner.line
            if scanner.peek == "#" {
                guard section == "DATA" else { throw ArchitectureError.malformedIFC(line: line, reason: "instance outside DATA") }
                scanner.advance()
                guard let id = scanner.integer() else { throw ArchitectureError.malformedIFC(line: line, reason: "bad instance id") }
                scanner.skipTrivia()
                guard scanner.consume("=") else { throw ArchitectureError.malformedIFC(line: line, reason: "expected '=' after #\(id)") }
                scanner.skipTrivia()
                if scanner.peek == "(" {
                    // Complex instance: skip it, up to its terminating semicolon.
                    try scanner.skipGroup()
                } else {
                    let type = scanner.keyword()
                    scanner.skipTrivia()
                    guard !type.isEmpty, case .list(let parameters) = try scanner.value() else {
                        throw ArchitectureError.malformedIFC(line: line, reason: "bad instance #\(id)")
                    }
                    entities[id] = StepEntity(id: id, type: type.uppercased(), parameters: parameters, line: line)
                }
            } else {
                let word = scanner.keyword().uppercased()
                switch word {
                case "HEADER", "DATA":
                    section = word
                case "ENDSEC":
                    section = ""
                case "END-ISO-10303-21":
                    return StepFile(header: header, entities: entities)
                case "":
                    throw ArchitectureError.malformedIFC(line: line, reason: "unexpected '\(scanner.peek.map(String.init) ?? "end")'")
                default:
                    guard section == "HEADER" else { throw ArchitectureError.malformedIFC(line: line, reason: "unexpected \(word)") }
                    scanner.skipTrivia()
                    guard case .list(let parameters) = try scanner.value() else {
                        throw ArchitectureError.malformedIFC(line: line, reason: "bad header entry \(word)")
                    }
                    header.append(StepEntity(id: 0, type: word, parameters: parameters, line: line))
                }
            }
            scanner.skipTrivia()
            guard scanner.consume(";") else { throw ArchitectureError.malformedIFC(line: scanner.line, reason: "expected ';'") }
        }
    }

    struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }
        var peek: Unicode.Scalar? { atEnd ? nil : scalars[index] }

        mutating func advance() {
            if scalars[index] == "\n" { line += 1 }
            index += 1
        }

        mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
            guard peek == scalar else { return false }
            advance()
            return true
        }

        mutating func skipTrivia() {
            while let scalar = peek {
                if scalar.properties.isWhitespace {
                    advance()
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                    advance()
                    advance()
                    while !atEnd, !(peek == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") { advance() }
                    if !atEnd {
                        advance()
                        advance()
                    }
                } else {
                    return
                }
            }
        }

        /// Skips a parenthesised group, strings included, without reading it.
        mutating func skipGroup() throws {
            var depth = 0
            repeat {
                guard let scalar = peek else { throw ArchitectureError.malformedIFC(line: line, reason: "unterminated group") }
                switch scalar {
                case "'": _ = try string()
                case "(":
                    depth += 1
                    advance()
                case ")":
                    depth -= 1
                    advance()
                default: advance()
                }
            } while depth > 0
        }

        /// Letters, digits, `_` and `-`: a keyword or type name.
        mutating func keyword() -> String {
            var word = ""
            while let scalar = peek, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-" {
                word.unicodeScalars.append(scalar)
                advance()
            }
            return word
        }

        mutating func integer() -> Int? {
            var digits = ""
            while let scalar = peek, ("0"..."9").contains(scalar) {
                digits.unicodeScalars.append(scalar)
                advance()
            }
            return Int(digits)
        }

        mutating func value() throws -> StepValue {
            skipTrivia()
            guard let scalar = peek else { throw ArchitectureError.malformedIFC(line: line, reason: "unexpected end of file") }
            switch scalar {
            case "$":
                advance()
                return .null
            case "*":
                advance()
                return .derived
            case "#":
                advance()
                guard let id = integer() else { throw ArchitectureError.malformedIFC(line: line, reason: "bad reference") }
                return .reference(id)
            case "'":
                return .string(try string())
            case ".":
                advance()
                var word = ""
                while let next = peek, next != "." {
                    word.unicodeScalars.append(next)
                    advance()
                }
                guard consume(".") else { throw ArchitectureError.malformedIFC(line: line, reason: "unterminated enumeration") }
                return .enumeration(word)
            case "(":
                advance()
                var values: [StepValue] = []
                skipTrivia()
                if consume(")") { return .list([]) }
                while true {
                    values.append(try value())
                    skipTrivia()
                    if consume(")") { return .list(values) }
                    guard consume(",") else { throw ArchitectureError.malformedIFC(line: line, reason: "expected ',' or ')'") }
                }
            case "-", "+", "0"..."9":
                var text = ""
                while let next = peek, ("0"..."9").contains(next) || next == "." || next == "E" || next == "e" || next == "-" || next == "+" {
                    text.unicodeScalars.append(next)
                    advance()
                }
                if !text.contains("."), !text.lowercased().contains("e"), let integer = Int(text) { return .integer(integer) }
                guard let real = Double(text.hasSuffix(".") ? text + "0" : text) else {
                    throw ArchitectureError.malformedIFC(line: line, reason: "bad number \(text)")
                }
                return .real(real)
            default:
                let type = keyword()
                guard !type.isEmpty else { throw ArchitectureError.malformedIFC(line: line, reason: "unexpected '\(scalar)'") }
                skipTrivia()
                guard case .list(let values) = try value() else { throw ArchitectureError.malformedIFC(line: line, reason: "bad typed value") }
                return .typed(type.uppercased(), values)
            }
        }

        /// A quoted string, with `''`, `\\`, `\X\hh` and `\X2\hhhh…\X0\` decoded.
        mutating func string() throws -> String {
            let start = line
            advance()
            var result = ""
            while true {
                guard let scalar = peek else { throw ArchitectureError.malformedIFC(line: start, reason: "unterminated string") }
                advance()
                if scalar == "'" {
                    if consume("'") {
                        result.append("'")
                        continue
                    }
                    return result
                }
                guard scalar == "\\" else {
                    result.unicodeScalars.append(scalar)
                    continue
                }
                if consume("\\") {
                    result.append("\\")
                } else if matches("X2\\") {
                    // UTF-16 code units in hex until \X0\.
                    var units: [UInt16] = []
                    while !matches("\\X0\\") {
                        guard let unit = hex(4) else { throw ArchitectureError.malformedIFC(line: line, reason: "bad \\X2\\ escape") }
                        units.append(UInt16(unit))
                    }
                    result += String(decoding: units, as: UTF16.self)
                } else if matches("X\\") {
                    guard let byte = hex(2) else { throw ArchitectureError.malformedIFC(line: line, reason: "bad \\X\\ escape") }
                    result.unicodeScalars.append(Unicode.Scalar(UInt8(byte)))
                } else {
                    result.append("\\")
                }
            }
        }

        /// Consumes `text` when it comes next.
        mutating func matches(_ text: String) -> Bool {
            let wanted = Array(text.unicodeScalars)
            guard index + wanted.count <= scalars.count, Array(scalars[index..<index + wanted.count]) == wanted else { return false }
            for _ in wanted { advance() }
            return true
        }

        mutating func hex(_ count: Int) -> Int? {
            guard index + count <= scalars.count else { return nil }
            var text = ""
            for scalar in scalars[index..<index + count] { text.unicodeScalars.append(scalar) }
            guard let value = Int(text, radix: 16) else { return nil }
            index += count
            return value
        }
    }
}
