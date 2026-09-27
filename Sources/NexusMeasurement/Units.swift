import Foundation

/// Physical dimension as exponents of SI base quantities, plus a separate
/// logical dimension for boolean readings, which convert to nothing else.
public struct Dimension: Hashable, Sendable, CustomStringConvertible {
    public var mass: Int
    public var length: Int
    public var time: Int
    public var current: Int
    public var temperature: Int
    public var isLogical: Bool

    public init(mass: Int = 0, length: Int = 0, time: Int = 0, current: Int = 0, temperature: Int = 0, isLogical: Bool = false) {
        self.mass = mass
        self.length = length
        self.time = time
        self.current = current
        self.temperature = temperature
        self.isLogical = isLogical
    }

    public static let none = Dimension()
    public static let logical = Dimension(isLogical: true)

    public var isDimensionless: Bool { self == .none }

    static func * (lhs: Dimension, rhs: Dimension) -> Dimension {
        Dimension(
            mass: lhs.mass + rhs.mass, length: lhs.length + rhs.length, time: lhs.time + rhs.time,
            current: lhs.current + rhs.current, temperature: lhs.temperature + rhs.temperature
        )
    }

    func power(_ exponent: Int) -> Dimension {
        Dimension(
            mass: mass * exponent, length: length * exponent, time: time * exponent,
            current: current * exponent, temperature: temperature * exponent
        )
    }

    public var description: String {
        if isLogical { return "logical" }
        let parts = [("kg", mass), ("m", length), ("s", time), ("A", current), ("K", temperature)]
            .filter { $0.1 != 0 }
            .map { $0.1 == 1 ? $0.0 : "\($0.0)^\($0.1)" }
        return parts.isEmpty ? "1" : parts.joined(separator: "·")
    }
}

public enum UnitError: Error, Equatable, Sendable {
    case unknownUnit(String)
    case syntax(String, position: Int)
    case incompatible(from: String, to: String)
    /// degC has an offset, so it only makes sense on its own, not inside a product.
    case offsetUnitInCompound(String)
    /// `bool` readings are states, not numbers; they take no arithmetic.
    case notNumeric(String)
}

/// A parsed UCUM-style unit code such as "mA", "kOhm", "V/A" or "s-1".
///
/// Supported atoms: V, A, Ohm, W, Pa, bar, s, min, h, Hz, K, degC, %, 1,
/// value (a plain number) and bool (a logical state). V, A, Ohm, W, Pa, bar,
/// s and Hz take the prefixes n, u, m, k and M. Codes combine with `.`
/// (multiply) and `/` (divide), evaluated left to right as in UCUM, with
/// integer exponents (`s-1`, `A2`) and parentheses.
///
/// A value converts to SI as `value × factor + offset`; only degC has an offset.
public struct MeasurementUnit: Hashable, Sendable, CustomStringConvertible {
    /// The code as written.
    public let code: String
    public let dimension: Dimension
    public let factor: Double
    public let offset: Double

    public var description: String { code }

    public init(_ code: String) throws {
        var parser = UnitParser(code)
        let parsed = try parser.parse()
        self.code = code
        dimension = parsed.dimension
        factor = parsed.factor
        offset = parsed.offset
    }

    /// Whether values in the two units can be converted into each other.
    public func isCommensurable(with other: MeasurementUnit) -> Bool {
        dimension == other.dimension
    }

    /// Converts an absolute value, applying offsets (so 0 degC → 273.15 K).
    public func convert(_ value: Double, to target: MeasurementUnit) throws -> Double {
        guard isCommensurable(with: target) else { throw UnitError.incompatible(from: code, to: target.code) }
        if self == target { return value }
        return (value * factor + offset - target.offset) / target.factor
    }

    /// Converts a difference or an uncertainty: offsets cancel, so only the
    /// scale applies (±1 degC is ±1 K, not ±274.15 K).
    public func convertInterval(_ interval: Double, to target: MeasurementUnit) throws -> Double {
        guard isCommensurable(with: target) else { throw UnitError.incompatible(from: code, to: target.code) }
        return interval * factor / target.factor
    }

    public static func == (lhs: MeasurementUnit, rhs: MeasurementUnit) -> Bool {
        lhs.dimension == rhs.dimension && lhs.factor == rhs.factor && lhs.offset == rhs.offset
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dimension)
        hasher.combine(factor)
        hasher.combine(offset)
    }

    /// Code for the product of two units.
    static func productCode(_ lhs: String, _ rhs: String) -> String {
        "\(lhs).\(wrapped(rhs))"
    }

    /// Code for the quotient of two units.
    static func quotientCode(_ lhs: String, _ rhs: String) -> String {
        "\(lhs)/\(wrapped(rhs))"
    }

    private static func wrapped(_ code: String) -> String {
        code.contains(where: { $0 == "." || $0 == "/" }) ? "(\(code))" : code
    }
}

extension MeasurementUnit {
    /// Converts a value between two unit codes.
    public static func convert(_ value: Double, from source: String, to target: String) throws -> Double {
        try MeasurementUnit(source).convert(value, to: MeasurementUnit(target))
    }
}

// MARK: Parser

private struct Atom {
    var dimension: Dimension
    var factor: Double
    var offset: Double = 0
    var prefixable: Bool
}

private let atoms: [String: Atom] = [
    "V": Atom(dimension: Dimension(mass: 1, length: 2, time: -3, current: -1), factor: 1, prefixable: true),
    "A": Atom(dimension: Dimension(current: 1), factor: 1, prefixable: true),
    "Ohm": Atom(dimension: Dimension(mass: 1, length: 2, time: -3, current: -2), factor: 1, prefixable: true),
    "W": Atom(dimension: Dimension(mass: 1, length: 2, time: -3), factor: 1, prefixable: true),
    "Pa": Atom(dimension: Dimension(mass: 1, length: -1, time: -2), factor: 1, prefixable: true),
    "bar": Atom(dimension: Dimension(mass: 1, length: -1, time: -2), factor: 100_000, prefixable: true),
    "s": Atom(dimension: Dimension(time: 1), factor: 1, prefixable: true),
    "min": Atom(dimension: Dimension(time: 1), factor: 60, prefixable: false),
    "h": Atom(dimension: Dimension(time: 1), factor: 3_600, prefixable: false),
    "Hz": Atom(dimension: Dimension(time: -1), factor: 1, prefixable: true),
    "K": Atom(dimension: Dimension(temperature: 1), factor: 1, prefixable: false),
    "degC": Atom(dimension: Dimension(temperature: 1), factor: 1, offset: 273.15, prefixable: false),
    "%": Atom(dimension: .none, factor: 0.01, prefixable: false),
    "1": Atom(dimension: .none, factor: 1, prefixable: false),
    "value": Atom(dimension: .none, factor: 1, prefixable: false),
    "bool": Atom(dimension: .logical, factor: 1, prefixable: false),
]

private let prefixes: [Character: Double] = ["n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6]

/// Recursive descent over `term := ['/'] factor (('.' | '/') factor)*`,
/// `factor := (atom | '(' term ')') [exponent]`.
private struct UnitParser {
    struct Parsed {
        var dimension: Dimension
        var factor: Double
        var offset: Double
    }

    let code: String
    let characters: [Character]
    var position = 0

    init(_ code: String) {
        self.code = code
        characters = Array(code)
    }

    mutating func parse() throws -> Parsed {
        guard !characters.isEmpty else { throw UnitError.syntax(code, position: 0) }
        let result = try term()
        guard position == characters.count else { throw UnitError.syntax(code, position: position) }
        return result
    }

    private mutating func term() throws -> Parsed {
        var result: Parsed
        if peek == "/" {
            position += 1
            result = try combine(Parsed(dimension: .none, factor: 1, offset: 0), try factor(), dividing: true)
        } else {
            result = try factor()
        }
        while let op = peek, op == "." || op == "/" {
            position += 1
            result = try combine(result, try factor(), dividing: op == "/")
        }
        return result
    }

    /// Offset (degC) and logical (bool) atoms may not be combined with anything.
    private func combine(_ lhs: Parsed, _ rhs: Parsed, dividing: Bool) throws -> Parsed {
        for side in [lhs, rhs] where side.offset != 0 {
            throw UnitError.offsetUnitInCompound(code)
        }
        if lhs.dimension.isLogical || rhs.dimension.isLogical { throw UnitError.notNumeric(code) }
        return Parsed(
            dimension: lhs.dimension * (dividing ? rhs.dimension.power(-1) : rhs.dimension),
            factor: dividing ? lhs.factor / rhs.factor : lhs.factor * rhs.factor,
            offset: 0
        )
    }

    private mutating func factor() throws -> Parsed {
        var base: Parsed
        if peek == "(" {
            position += 1
            base = try term()
            guard peek == ")" else { throw UnitError.syntax(code, position: position) }
            position += 1
        } else {
            base = try atom()
        }
        guard let exponent = try exponent() else { return base }
        if base.offset != 0 { throw UnitError.offsetUnitInCompound(code) }
        if base.dimension.isLogical { throw UnitError.notNumeric(code) }
        return Parsed(
            dimension: base.dimension.power(exponent), factor: pow(base.factor, Double(exponent)), offset: 0
        )
    }

    private mutating func atom() throws -> Parsed {
        let start = position
        while let character = peek, character.isLetter || character == "%" || (character == "1" && position == start) {
            position += 1
            if character == "1" || character == "%" { break }
        }
        let symbol = String(characters[start..<position])
        guard !symbol.isEmpty else { throw UnitError.syntax(code, position: start) }
        if let atom = atoms[symbol] {
            return Parsed(dimension: atom.dimension, factor: atom.factor, offset: atom.offset)
        }
        if let first = symbol.first, let scale = prefixes[first], let atom = atoms[String(symbol.dropFirst())], atom.prefixable {
            return Parsed(dimension: atom.dimension, factor: scale * atom.factor, offset: 0)
        }
        throw UnitError.unknownUnit(symbol)
    }

    /// An optional signed integer exponent directly after a factor, e.g. `s-1`, `A2`.
    private mutating func exponent() throws -> Int? {
        let start = position
        if peek == "-" || peek == "+" { position += 1 }
        let digitsStart = position
        while let character = peek, character.isASCII, character.isNumber { position += 1 }
        guard position > digitsStart else {
            position = start
            return nil
        }
        guard let value = Int(String(characters[start..<position])) else { throw UnitError.syntax(code, position: start) }
        return value
    }

    private var peek: Character? { position < characters.count ? characters[position] : nil }
}
