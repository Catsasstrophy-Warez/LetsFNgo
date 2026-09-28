import Foundation

/// An ISO 4217 currency code with its number of minor units (decimal places).
public struct Currency: Hashable, Sendable, Codable, CustomStringConvertible {
    public let code: String

    /// Currencies whose minor unit is not 2 decimal places. Every other
    /// three-letter code uses 2.
    static let minorUnitExceptions: [String: Int] = [
        "BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0, "PYG": 0, "RWF": 0, "UGX": 0,
        "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
        "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
    ]

    /// Validates the code: three ASCII letters, normalised to upper case.
    public init(_ code: String) throws {
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard normalized.count == 3, normalized.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            throw MoneyError.invalidCurrency(code)
        }
        self.code = normalized
    }

    private init(known code: String) { self.code = code }

    public static let usd = Currency(known: "USD")
    public static let eur = Currency(known: "EUR")
    public static let gbp = Currency(known: "GBP")
    public static let chf = Currency(known: "CHF")
    public static let cad = Currency(known: "CAD")
    public static let jpy = Currency(known: "JPY")

    /// Decimal places of the currency's minor unit (2 for USD, 0 for JPY, 3 for KWD).
    public var minorUnits: Int { Self.minorUnitExceptions[code] ?? 2 }

    public var description: String { code }

    public init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

public enum MoneyError: Error, Equatable, Sendable {
    /// Two amounts in different currencies were combined or compared.
    /// Conversion is never implicit.
    case currencyMismatch(Currency, Currency)
    case invalidCurrency(String)
    case invalidAmount(String)
    case divisionByZero
}

/// How an amount is brought to a currency's minor units. Every rule works on
/// the magnitude, so a negative amount rounds like its positive mirror.
public enum RoundingRule: String, Sendable, Codable, CaseIterable {
    /// Half to even (banker's rounding): 2.345 → 2.34, 2.355 → 2.36. The default,
    /// because it has no upward bias when many amounts are summed.
    case halfEven
    /// Half away from zero (commercial rounding): 2.345 → 2.35, −2.345 → −2.35.
    case halfUp
    /// Toward zero (truncation): 2.349 → 2.34, −2.349 → −2.34.
    case towardZero
    /// Away from zero: 2.341 → 2.35.
    case awayFromZero

    var mode: NSDecimalNumber.RoundingMode {
        switch self {
        case .halfEven: .bankers
        case .halfUp: .plain
        case .towardZero: .down
        case .awayFromZero: .up
        }
    }
}

extension Decimal {
    /// `self` rounded to `scale` decimal places by `rule`, on the magnitude.
    public func rounded(scale: Int, _ rule: RoundingRule = .halfEven) -> Decimal {
        var magnitude = self < 0 ? -self : self
        var result = Decimal()
        NSDecimalRound(&result, &magnitude, scale, rule.mode)
        return self < 0 ? -result : result
    }

    /// Parses a plain decimal string ("-1234.5", "+0.25"), rejecting anything
    /// else, including exponents and trailing garbage that `Decimal(string:)`
    /// would silently ignore.
    public init?(exactly text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var body = Substring(trimmed)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !body.isEmpty, parts.count <= 2, !parts[0].isEmpty,
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            parts.count == 1 || !parts[1].isEmpty,
            let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        self = value
    }

    /// A plain string with no grouping and "." as separator, which `init(exactly:)` reads back.
    public var plainString: String {
        var copy = self
        return NSDecimalString(&copy, Locale(identifier: "en_US_POSIX"))
    }
}

/// An amount of money: an exact `Decimal` and its currency.
///
/// Money never uses `Double`. Arithmetic between two amounts throws
/// `MoneyError.currencyMismatch` unless the currencies agree, so a sum can
/// never silently mix dollars and euros. Amounts keep full precision until
/// `rounded` brings them to the currency's minor units.
public struct Money: Hashable, Sendable, Codable, CustomStringConvertible {
    public let amount: Decimal
    public let currency: Currency

    public init(_ amount: Decimal, _ currency: Currency) {
        self.amount = amount
        self.currency = currency
    }

    /// Parses a plain decimal string such as "-12.50".
    public init(_ text: String, _ currency: Currency) throws {
        guard let amount = Decimal(exactly: text) else { throw MoneyError.invalidAmount(text) }
        self.init(amount, currency)
    }

    public static func zero(_ currency: Currency) -> Money { Money(0, currency) }

    public var isZero: Bool { amount == 0 }
    public var isNegative: Bool { amount < 0 }
    public var magnitude: Money { Money(amount < 0 ? -amount : amount, currency) }

    /// Rounded to the currency's minor units (or `scale`) by `rule`.
    public func rounded(_ rule: RoundingRule = .halfEven, scale: Int? = nil) -> Money {
        Money(amount.rounded(scale: scale ?? currency.minorUnits, rule), currency)
    }

    /// Whether the amount has no digits beyond the currency's minor units.
    public var isWholeMinorUnits: Bool { rounded(.towardZero) == self }

    func requireSameCurrency(_ other: Money) throws {
        guard currency == other.currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
    }

    public static func + (lhs: Money, rhs: Money) throws -> Money {
        try lhs.requireSameCurrency(rhs)
        return Money(lhs.amount + rhs.amount, lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) throws -> Money {
        try lhs.requireSameCurrency(rhs)
        return Money(lhs.amount - rhs.amount, lhs.currency)
    }

    public static prefix func - (value: Money) -> Money { Money(-value.amount, value.currency) }

    public static func * (lhs: Money, rhs: Decimal) -> Money { Money(lhs.amount * rhs, lhs.currency) }

    public func divided(by divisor: Decimal) throws -> Money {
        guard divisor != 0 else { throw MoneyError.divisionByZero }
        return Money(amount / divisor, currency)
    }

    /// The ratio of two amounts in the same currency.
    public func ratio(to other: Money) throws -> Decimal {
        try requireSameCurrency(other)
        guard other.amount != 0 else { throw MoneyError.divisionByZero }
        return amount / other.amount
    }

    public func compare(_ other: Money) throws -> ComparisonResult {
        try requireSameCurrency(other)
        return amount < other.amount ? .orderedAscending : amount > other.amount ? .orderedDescending : .orderedSame
    }

    public func isLess(than other: Money) throws -> Bool { try compare(other) == .orderedAscending }

    /// Sums amounts that must all be in `currency`. An empty list is zero.
    public static func sum(_ values: some Sequence<Money>, in currency: Currency) throws -> Money {
        try values.reduce(.zero(currency)) { try $0 + $1 }
    }

    /// Splits the amount into parts proportional to `ratios`, in whole minor
    /// units, handing leftover minor units to the first parts so the parts
    /// always add up exactly to the rounded total.
    public func allocate(_ ratios: [Decimal], rule: RoundingRule = .halfEven) throws -> [Money] {
        let total = ratios.reduce(0, +)
        guard total != 0 else { throw MoneyError.divisionByZero }
        let whole = rounded(rule)
        let unit = Decimal(sign: .plus, exponent: -currency.minorUnits, significand: 1)
        var parts = ratios.map { Money((whole.amount * $0 / total).rounded(scale: currency.minorUnits, .towardZero), currency) }
        var remainder = whole.amount - parts.reduce(0) { $0 + $1.amount }
        let step = remainder < 0 ? -unit : unit
        var index = 0
        while remainder != 0, !parts.isEmpty {
            parts[index] = Money(parts[index].amount + step, currency)
            remainder -= step
            index = (index + 1) % parts.count
        }
        return parts
    }

    /// "-12.50 USD", rounded half-even to the currency's minor units.
    public var description: String {
        let value = rounded()
        var text = value.amount.magnitude.plainString
        let places = currency.minorUnits
        if places > 0 {
            let fraction = text.split(separator: ".").dropFirst().first?.count ?? 0
            if fraction == 0 { text += "." }
            text += String(repeating: "0", count: places - fraction)
        }
        return "\(value.amount < 0 ? "-" : "")\(text) \(currency.code)"
    }

    enum CodingKeys: String, CodingKey { case amount, currency }

    /// Encodes the amount as a string so no JSON coder turns it into a binary float.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .amount)
        try self.init(text, try container.decode(Currency.self, forKey: .currency))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount.plainString, forKey: .amount)
        try container.encode(currency, forKey: .currency)
    }
}
