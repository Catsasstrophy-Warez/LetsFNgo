import Foundation

/// A number written in text, with its character offsets.
public struct NumberMention: Sendable, Hashable {
    public var value: Double
    /// Character offsets of the number in the scanned text.
    public var start: Int
    public var end: Int
}

/// A number followed by a unit ("12.0 V", "86.9%", "4-20 mA").
public struct QuantityMention: Sendable, Hashable {
    public var value: Double
    /// Normalized unit symbol ("V", "mA", "%", "°C", "Ω").
    public var unit: String
    /// Character offsets of the number and its unit.
    public var start: Int
    public var end: Int
}

/// An interval stated in text: "4-20 mA", "between 10 and 12 V", "at least
/// 10.5 V" (open above), "up to 30 V" (open below), or "24 V" (one point).
public struct RangeMention: Sendable, Hashable {
    public var low: Double
    public var high: Double
    public var unit: String
    public var start: Int
    public var end: Int

    /// No value lies in both intervals.
    public func isDisjoint(from other: RangeMention) -> Bool {
        unit == other.unit && (high < other.low || other.high < low)
    }
}

/// Finds numbers, quantities and ranges in free text, the way the evals and
/// verification read model answers.
///
/// Names are not numbers: object IDs (UUIDs), digits glued to a preceding
/// letter ("A7", "v1.2") and tag numbers after a hyphen ("LT-101", "TB-4")
/// are skipped. A hyphen after a space is a minus sign ("at -3 V" is -3); a
/// hyphen between two numbers joins a range ("4-20 mA").
public enum QuantityScanner {
    // MARK: Numbers

    public static func numbers(in text: String) -> [Double] {
        numberMentions(in: text).map(\.value)
    }

    public static func numberMentions(in text: String) -> [NumberMention] {
        numberMentions(in: Array(masked(text)))
    }

    /// UUIDs replaced by spaces of the same length, so offsets are unchanged.
    private static func masked(_ text: String) -> String {
        let uuid = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#
        return text.replacing(uuid) { String(repeating: " ", count: $0.output.count) }
    }

    private static func numberMentions(in characters: [Character]) -> [NumberMention] {
        var found: [NumberMention] = []
        var index = 0
        func isWordCharacter(_ position: Int) -> Bool {
            position >= 0 && position < characters.count && (characters[position].isLetter || characters[position].isNumber)
        }
        func isDigit(_ position: Int) -> Bool {
            position >= 0 && position < characters.count && characters[position].isASCII && characters[position].isNumber
        }
        while index < characters.count {
            guard isDigit(index), !isWordCharacter(index - 1), index == 0 || characters[index - 1] != "." else {
                index += 1
                continue
            }
            var start = index
            let hyphenated = index > 0 && characters[index - 1] == "-"
            // "-3" after a space is negative; "4-20" is a range; "LT-101" is a tag.
            if hyphenated, !isWordCharacter(index - 2) { start = index - 1 }
            let isTag = hyphenated && isWordCharacter(index - 2) && !isDigit(index - 2)
            while isDigit(index) { index += 1 }
            if index + 1 < characters.count, characters[index] == ".", isDigit(index + 1) {
                index += 1
                while isDigit(index) { index += 1 }
            }
            if !isTag, let number = Double(String(characters[start..<index])) {
                found.append(NumberMention(value: number, start: start, end: index))
            }
        }
        return found
    }

    // MARK: Quantities

    /// Numbers followed by a known unit, glued or after one space. Both ends
    /// of a range take the range's unit ("4-20 mA" gives 4 mA and 20 mA).
    public static func quantities(in text: String) -> [QuantityMention] {
        let characters = Array(masked(text))
        let numbers = numberMentions(in: characters)
        var result: [QuantityMention] = []
        for (offset, number) in numbers.enumerated() {
            if let (unit, end) = unit(after: number.end, in: characters) {
                result.append(QuantityMention(value: number.value, unit: unit, start: number.start, end: end))
            } else if offset + 1 < numbers.count, rangeEnd(from: number, to: numbers[offset + 1], in: characters) != nil,
                let (unit, end) = unit(after: numbers[offset + 1].end, in: characters)
            {
                result.append(QuantityMention(value: number.value, unit: unit, start: number.start, end: end))
            }
        }
        return result
    }

    /// Intervals stated in text, each with a unit.
    public static func ranges(in text: String) -> [RangeMention] {
        let characters = Array(masked(text))
        let lower = characters.map { Character($0.lowercased()) }
        let numbers = numberMentions(in: characters)
        var result: [RangeMention] = []
        var skip: Set<Int> = []
        for (offset, number) in numbers.enumerated() where !skip.contains(offset) {
            // Two numbers joined by "-", "to" or "and" (after "between"), sharing the second one's unit.
            if offset + 1 < numbers.count, let joiner = rangeEnd(from: number, to: numbers[offset + 1], in: characters),
                let (unit, end) = unit(after: numbers[offset + 1].end, in: characters)
            {
                if joiner != "and" || preceding(lower, before: number.start).hasSuffix("between") {
                    let other = numbers[offset + 1].value
                    result.append(RangeMention(low: min(number.value, other), high: max(number.value, other), unit: unit, start: number.start, end: end))
                    skip.insert(offset + 1)
                    continue
                }
            }
            guard let (unit, end) = unit(after: number.end, in: characters) else { continue }
            let before = preceding(lower, before: number.start)
            let atLeast = ["at least", "minimum of", "minimum", "min.", "min", "no less than", "not less than", "above", "more than", "over", ">=", "≥", ">"]
            let atMost = [
                "at most", "maximum of", "maximum", "max.", "max", "no more than", "not more than", "up to", "below", "less than", "under", "<=", "≤", "<",
            ]
            if atLeast.contains(where: { before.hasSuffix($0) }) {
                result.append(RangeMention(low: number.value, high: .infinity, unit: unit, start: number.start, end: end))
            } else if atMost.contains(where: { before.hasSuffix($0) }) {
                result.append(RangeMention(low: -.infinity, high: number.value, unit: unit, start: number.start, end: end))
            } else {
                result.append(RangeMention(low: number.value, high: number.value, unit: unit, start: number.start, end: end))
            }
        }
        return result
    }

    /// The joining word when `second` continues a range started by `first`:
    /// "-", "–", "to" or "and".
    private static func rangeEnd(from first: NumberMention, to second: NumberMention, in characters: [Character]) -> String? {
        let gap = String(characters[first.end..<second.start]).lowercased()
        let trimmed = gap.trimmingCharacters(in: .whitespaces)
        if second.start > 0, characters[second.start - 1] == "-" || characters[second.start - 1] == "–", second.start - 1 == first.end {
            return "-"
        }
        switch trimmed {
        case "-", "–", "to", "...", "..": return trimmed == "to" ? "to" : "-"
        case "and": return "and"
        default: return nil
        }
    }

    /// Up to 24 lowercased characters before `position`, trimmed.
    private static func preceding(_ lower: [Character], before position: Int) -> String {
        String(lower[max(0, position - 24)..<position]).trimmingCharacters(in: .whitespaces)
    }

    /// The unit starting at `position` (after at most one space), normalized,
    /// and where it ends. A unit must end at a word boundary.
    private static func unit(after position: Int, in characters: [Character]) -> (String, Int)? {
        var start = position
        if start < characters.count, characters[start] == " " { start += 1 }
        guard start < characters.count else { return nil }
        var word = ""
        var index = start
        while index < characters.count, index - start < 8 {
            let character = characters[index]
            guard character.isLetter || "%°Ωµ/²³".contains(character) || (character.isNumber && !word.isEmpty) else { break }
            word.append(character)
            index += 1
        }
        // Longest known unit that is a prefix of the word and ends at a boundary.
        var candidate = word
        while !candidate.isEmpty {
            let end = start + candidate.count
            let atBoundary = end >= characters.count || !(characters[end].isLetter || characters[end].isNumber)
            if atBoundary, let symbol = normalizedUnit(candidate) { return (symbol, end) }
            candidate.removeLast()
        }
        return nil
    }

    // MARK: Units

    /// The canonical symbol for a unit as written, or nil if it is not a unit.
    public static func normalizedUnit(_ raw: String) -> String? {
        if let symbol = units[raw] { return symbol }
        return wordUnits[raw.lowercased()]
    }

    /// Case-sensitive symbols.
    private static let units: [String: String] = {
        var table: [String: String] = [:]
        for symbol in [
            "V", "mV", "kV", "µV", "A", "mA", "µA", "kA", "W", "mW", "kW", "MW", "Ω", "kΩ", "MΩ", "mΩ", "Hz", "kHz", "MHz",
            "%", "°C", "°F", "K", "bar", "mbar", "psi", "psig", "psia", "Pa", "kPa", "MPa", "s", "ms", "µs", "min", "h", "m", "mm", "cm",
            "km", "ft", "kg", "g", "mg", "lb", "N", "Nm", "rpm", "L", "mL", "gpm", "lpm", "VA", "kVA", "VAC", "VDC", "dB", "Wh",
            "kWh", "S", "mS", "µS", "F", "µF", "nF", "pF", "H", "mH", "m/s", "m³/h", "m3/h", "l/min", "L/min", "inH2O", "mmHg",
        ] {
            table[symbol] = symbol
        }
        table["uV"] = "µV"
        table["uA"] = "µA"
        table["us"] = "µs"
        table["uS"] = "µS"
        table["uF"] = "µF"
        table["Vdc"] = "V"
        table["Vac"] = "V"
        table["VDC"] = "V"
        table["VAC"] = "V"
        table["degC"] = "°C"
        table["degF"] = "°F"
        table["kohm"] = "kΩ"
        table["Mohm"] = "MΩ"
        table["Ohm"] = "Ω"
        table["mbar"] = "mbar"
        return table
    }()

    /// Spelled-out units, matched case-insensitively.
    private static let wordUnits: [String: String] = [
        "volt": "V", "volts": "V", "millivolt": "mV", "millivolts": "mV", "amp": "A", "amps": "A", "ampere": "A", "amperes": "A",
        "milliamp": "mA", "milliamps": "mA", "watt": "W", "watts": "W", "ohm": "Ω", "ohms": "Ω", "hertz": "Hz", "percent": "%",
        "second": "s", "seconds": "s", "sec": "s", "secs": "s", "minute": "min", "minutes": "min", "mins": "min", "hour": "h", "hours": "h",
        "hr": "h", "hrs": "h", "meter": "m", "meters": "m", "metre": "m", "metres": "m", "millimeter": "mm", "millimeters": "mm",
        "inch": "in", "inches": "in", "foot": "ft", "feet": "ft", "degc": "°C", "celsius": "°C", "fahrenheit": "°F", "kilogram": "kg",
        "kilograms": "kg", "pound": "lb", "pounds": "lb", "liter": "L", "liters": "L", "litre": "L", "litres": "L",
    ]
}
