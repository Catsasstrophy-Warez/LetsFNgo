/// A 17-character vehicle identification number (ISO 3779, 49 CFR 565).
///
/// Layout: WMI (1–3), vehicle descriptor (4–8), check digit (9), model year
/// (10), plant (11), serial (12–17). The letters I, O and Q never appear.
public struct VIN: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public enum ValidationError: Error, Equatable, Sendable {
        case wrongLength(Int)
        /// A character outside 0–9 and A–Z, or one of I, O, Q. Carries the 1-based position.
        case invalidCharacter(Character, position: Int)
        /// Position 9 does not match the weighted checksum.
        case checkDigitMismatch(expected: Character, found: Character)
    }

    /// Normalizes case and whitespace and validates the characters.
    /// `requireCheckDigit` also enforces position 9; it is mandatory for
    /// North American vehicles and optional elsewhere.
    public init(_ text: String, requireCheckDigit: Bool = false) throws {
        let normalized = String(text.uppercased().filter { !$0.isWhitespace })
        guard normalized.count == 17 else { throw ValidationError.wrongLength(normalized.count) }
        for (index, character) in normalized.enumerated() where Self.value(of: character) == nil {
            throw ValidationError.invalidCharacter(character, position: index + 1)
        }
        rawValue = normalized
        if requireCheckDigit, let expected = Self.checkDigit(for: normalized), expected != checkCharacter {
            throw ValidationError.checkDigitMismatch(expected: expected, found: checkCharacter)
        }
    }

    public var description: String { rawValue }

    private var characters: [Character] { Array(rawValue) }

    public var wmi: String { String(characters[0..<3]) }
    public var vehicleDescriptor: String { String(characters[3..<8]) }
    public var checkCharacter: Character { characters[8] }
    public var modelYearCode: Character { characters[9] }
    public var plantCode: Character { characters[10] }
    public var serial: String { String(characters[11..<17]) }

    public var isCheckDigitValid: Bool { Self.checkDigit(for: rawValue) == checkCharacter }

    // MARK: Checksum

    static let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

    /// Transliteration value of a VIN character, or nil when it is not allowed.
    static func value(of character: Character) -> Int? {
        switch character {
        case "0"..."9": Int(String(character))
        case "A", "J": 1
        case "B", "K", "S": 2
        case "C", "L", "T": 3
        case "D", "M", "U": 4
        case "E", "N", "V": 5
        case "F", "W": 6
        case "G", "P", "X": 7
        case "H", "Y": 8
        case "R", "Z": 9
        default: nil
        }
    }

    /// The check digit (position 9) the other 16 characters call for: the
    /// weighted sum mod 11, with 10 written as "X".
    public static func checkDigit(for text: String) -> Character? {
        let characters = Array(text.uppercased())
        guard characters.count == 17 else { return nil }
        var sum = 0
        for (index, character) in characters.enumerated() {
            guard let value = value(of: character) else { return nil }
            sum += value * weights[index]
        }
        let remainder = sum % 11
        return remainder == 10 ? "X" : Character(String(remainder))
    }

    // MARK: Decoding

    /// Model year codes in order; the cycle repeats every 30 years (1980, 2010, 2040).
    static let yearCodes = Array("ABCDEFGHJKLMNPRSTVWXY123456789")

    /// Both model years the code can stand for, oldest first.
    public var modelYearCandidates: [Int] {
        guard let index = Self.yearCodes.firstIndex(of: modelYearCode) else { return [] }
        return [1980 + index, 2010 + index]
    }

    /// The model year, using the North American rule for passenger vehicles:
    /// a letter in position 7 means the 2010–2039 cycle, a digit the 1980–2009
    /// cycle. For other markets check `modelYearCandidates`.
    public var modelYear: Int? {
        let candidates = modelYearCandidates
        guard candidates.count == 2 else { return nil }
        return characters[6].isLetter ? candidates[1] : candidates[0]
    }

    /// Continent from the first character.
    public var region: String {
        switch characters[0] {
        case "A"..."H": "Africa"
        case "J"..."R": "Asia"
        case "S"..."Z": "Europe"
        case "1"..."5": "North America"
        case "6", "7": "Oceania"
        default: "South America"
        }
    }

    /// Country of the manufacturer's WMI, when the first two characters name one.
    public var country: String? {
        let first = characters[0]
        let second = characters[1]
        switch first {
        case "1", "4", "5": return "United States"
        case "2": return "Canada"
        case "3": return ("A"..."W").contains(second) ? "Mexico" : nil
        case "J": return "Japan"
        case "K": return ("L"..."R").contains(second) ? "South Korea" : nil
        case "L": return "China"
        case "S": return ("A"..."M").contains(second) ? "United Kingdom" : nil
        case "V": return ("F"..."R").contains(second) ? "France" : (("S"..."W").contains(second) ? "Spain" : nil)
        case "W": return "Germany"
        case "Y": return ("S"..."W").contains(second) ? "Sweden" : nil
        case "Z": return ("A"..."R").contains(second) ? "Italy" : nil
        case "6": return "Australia"
        case "9": return ("A"..."E").contains(second) ? "Brazil" : nil
        default: return nil
        }
    }

    /// Manufacturer for a small table of common WMIs; nil when unknown.
    public var manufacturer: String? { Self.manufacturers[wmi] }

    static let manufacturers: [String: String] = [
        "1FA": "Ford", "1FT": "Ford (truck)", "1G1": "Chevrolet", "1GC": "Chevrolet (truck)", "1HG": "Honda (USA)",
        "1J4": "Jeep", "1M8": "Motor Coach Industries", "1N4": "Nissan (USA)", "2HG": "Honda (Canada)", "2T1": "Toyota (Canada)",
        "3FA": "Ford (Mexico)", "3VW": "Volkswagen (Mexico)", "4T1": "Toyota (USA)", "5YJ": "Tesla", "JHM": "Honda",
        "JM1": "Mazda", "JN1": "Nissan", "JT2": "Toyota", "JTD": "Toyota", "KMH": "Hyundai", "KNA": "Kia", "SAJ": "Jaguar",
        "SAL": "Land Rover", "VF1": "Renault", "VF3": "Peugeot", "WAU": "Audi", "WBA": "BMW", "WDD": "Mercedes-Benz",
        "WP0": "Porsche", "WVW": "Volkswagen", "YV1": "Volvo", "ZFA": "Fiat",
    ]

    /// A VIN with its check digit filled in: `prefix` is the first 8
    /// characters, `suffix` the last 8.
    public static func make(prefix: String, suffix: String) throws -> VIN {
        let draft = prefix.uppercased() + "0" + suffix.uppercased()
        guard let check = checkDigit(for: draft) else { return try VIN(draft) }
        return try VIN(prefix.uppercased() + String(check) + suffix.uppercased(), requireCheckDigit: true)
    }
}
