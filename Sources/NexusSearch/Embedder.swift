import Foundation

/// Turns text into a fixed-length, L2-normalized vector, so the cosine
/// similarity of two texts is the dot product of their vectors.
public protocol Embedder: Sendable {
    /// Identifies the model and its parameters. Vectors from different
    /// models are never compared, and the store keys them by this.
    var modelID: String { get }
    var dimension: Int { get }
    /// Cosine similarity below which a neighbour is noise rather than a
    /// match. Depends on the model: hashed features rarely collide, while
    /// sentence embeddings put unrelated text well above zero.
    var minimumSimilarity: Float { get }
    /// A unit vector of `dimension` values, or all zeros for text with no
    /// usable content.
    func embed(_ text: String) throws -> [Float]
}

extension Embedder {
    public var minimumSimilarity: Float { 0 }
}

public enum EmbeddingMath {
    /// Scales `vector` to unit length in place; a zero vector stays zero.
    public static func normalize(_ vector: inout [Float]) {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0, sum.isFinite else {
            for index in vector.indices { vector[index] = 0 }
            return
        }
        let scale = 1 / sum.squareRoot()
        for index in vector.indices { vector[index] *= scale }
    }

    public static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        precondition(lhs.count == rhs.count, "vectors of different dimension")
        var sum: Float = 0
        for index in lhs.indices { sum += lhs[index] * rhs[index] }
        return sum
    }
}

/// A deterministic embedder built from hashed features, for Linux, tests and
/// devices without a sentence model.
///
/// Features, each hashed with FNV-1a into `dimension` signed buckets:
/// - word stems (a light suffix stripper, so "transmitters" meets "transmitter"),
/// - adjacent stem pairs,
/// - character trigrams of each word, which tolerate typos and tag fragments,
/// - concepts from a field-engineering synonym and abbreviation table, so
///   "xmtr" meets "transmitter" and "PSU" meets "power supply".
///
/// Term frequency is sublinear (1 + ln tf) so a repeated word doesn't drown
/// the rest. The vector is L2-normalized. Same text, same vector, on every
/// platform and run: Swift's `Hasher` is seeded per process, so it isn't used.
public struct HashingEmbedder: Embedder {
    public let dimension: Int
    public var modelID: String { "nexus.hashing.v1.\(dimension)" }
    public var minimumSimilarity: Float { 0.12 }

    static let wordWeight: Float = 1.0
    static let pairWeight: Float = 0.5
    static let trigramWeight: Float = 0.25
    static let conceptWeight: Float = 2.0

    public init(dimension: Int = 256) {
        precondition(dimension > 0, "dimension must be positive")
        self.dimension = dimension
    }

    public func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        for (hash, weight) in Self.features(of: text) {
            let bucket = Int(hash % UInt64(dimension))
            vector[bucket] += (hash >> 63) == 0 ? weight : -weight
        }
        EmbeddingMath.normalize(&vector)
        return vector
    }

    /// Kinds of feature, mixed into each feature's hash so a word and a
    /// concept of the same spelling stay distinct.
    enum Feature: UInt8 {
        case word = 1
        case pair = 2
        case trigram = 3
        case concept = 4
    }

    /// Hashed features of `text` with their weights after sublinear TF, in
    /// hash order so floating-point sums come out bit-identical every run.
    /// Features are hashed straight from UTF-8 bytes, never built as strings.
    static func features(of text: String) -> [(hash: UInt64, weight: Float)] {
        let stems = tokens(of: text).map(stem)
        let words = stems.map { Array($0.utf8) }
        var raw: [(hash: UInt64, weight: Float)] = []
        raw.reserveCapacity(stems.count * 10)
        func add(_ hash: UInt64, _ weight: Float) {
            raw.append((hash, weight))
        }
        let boundary = UInt8(ascii: "#")
        for (index, word) in words.enumerated() {
            var hasher = FNV(.word)
            hasher.add(word)
            add(hasher.value, wordWeight)
            if index > 0 {
                var pair = FNV(.pair)
                pair.add(words[index - 1])
                pair.add(boundary)
                pair.add(word)
                add(pair.value, pairWeight)
            }
            let padded = [boundary] + word + [boundary]
            for start in 0...(padded.count - 3) {
                var trigram = FNV(.trigram)
                trigram.add(padded[start])
                trigram.add(padded[start + 1])
                trigram.add(padded[start + 2])
                add(trigram.value, trigramWeight)
            }
        }
        for concept in concepts(in: stems) {
            var hasher = FNV(.concept)
            hasher.add(Array(concept.utf8))
            add(hasher.value, conceptWeight)
        }
        // Equal hashes are the same feature (the kind is part of the hash),
        // so they carry the same weight; count each run once.
        raw.sort { $0.hash < $1.hash }
        var features: [(hash: UInt64, weight: Float)] = []
        var start = 0
        while start < raw.count {
            var end = start + 1
            while end < raw.count, raw[end].hash == raw[start].hash { end += 1 }
            features.append((raw[start].hash, raw[start].weight * (1 + log(Float(end - start)))))
            start = end
        }
        return features
    }

    // MARK: Tokens

    /// Lowercased, diacritic-free alphanumeric words. Loop-current ranges
    /// ("4-20 mA", "4–20mA", "4 to 20") become one token first, since
    /// splitting them would leave two meaningless numbers.
    static func tokens(of text: String) -> [String] {
        let ascii = text.utf8.allSatisfy { $0 < 0x80 }
        var folded = ascii ? text.lowercased() : text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        if folded.contains("20") {
            folded = folded.replacing(loopRange, with: " loopcurrent ")
        }
        guard ascii, folded.utf8.allSatisfy({ $0 < 0x80 }) else {
            return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        // ASCII fast path: split on bytes, skipping Character segmentation.
        var tokens: [String] = []
        var current: [UInt8] = []
        for byte in folded.utf8 {
            if (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39) {
                current.append(byte)
            } else if !current.isEmpty {
                tokens.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { tokens.append(String(decoding: current, as: UTF8.self)) }
        return tokens
    }

    nonisolated(unsafe) private static let loopRange = /\b4\s*(?:-|–|—|to|\.\.)\s*20(?!\d)\s*(?:ma\b)?/

    private static let suffixes: [(String, String)] = [
        ("ations", "ate"), ("ation", "ate"), ("ments", ""), ("ment", ""), ("ings", ""), ("ing", ""), ("ies", "y"),
        ("ers", ""), ("er", ""), ("ed", ""), ("es", ""), ("s", ""),
    ]

    /// A deliberately small stemmer: one suffix off, then a trailing "e", and
    /// never below three letters. Numbers and short words pass through.
    static func stem(_ word: String) -> String {
        guard word.count > 3, word.contains(where: \.isLetter), !word.contains(where: \.isNumber) else { return word }
        var result = word
        for (suffix, replacement) in suffixes where result.hasSuffix(suffix) {
            let base = String(result.dropLast(suffix.count)) + replacement
            if base.count >= 3, !(suffix == "s" && result.hasSuffix("ss")) {
                result = base
            }
            break
        }
        if result.count > 4, result.hasSuffix("e") { result.removeLast() }
        return result
    }

    // MARK: Concepts

    /// Concept → the ways field notes write it. Multi-word variants match
    /// runs of words; everything is compared after stemming.
    static let synonymTable: [String: [String]] = [
        "transmitter": ["transmitter", "xmtr", "xmitter", "xmtter", "xtmr"],
        "terminal block": ["terminal block", "tb", "term block", "term blk", "terminal strip", "terminals"],
        "power supply": ["power supply", "psu", "pwr supply", "power pack", "pwr"],
        "multimeter": ["multimeter", "dmm", "digital multimeter", "voltmeter", "multi meter"],
        "loop current": ["loopcurrent", "loop current", "current loop", "milliamp loop", "ma loop", "4 20", "420ma"],
        "milliamp": ["ma", "milliamp", "milliamps", "milliampere"],
        "voltage": ["v", "vdc", "vac", "volt", "volts", "voltage"],
        "ground": ["ground", "gnd", "earth", "grd", "pe"],
        "variable frequency drive": ["vfd", "vsd", "variable frequency drive", "variable speed drive", "ac drive", "inverter drive"],
        "programmable logic controller": ["plc", "programmable logic controller"],
        "motor control center": ["mcc", "motor control center", "motor control centre"],
        "junction box": ["junction box", "jb", "jbox", "j box"],
        "circuit breaker": ["circuit breaker", "breaker", "cb", "mcb"],
        "thermocouple": ["thermocouple", "tc"],
        "rtd": ["rtd", "resistance temperature detector", "pt100"],
        "temperature": ["temperature", "temp"],
        "pressure": ["pressure", "press"],
        "calibration": ["calibration", "calibrate", "cal", "calib"],
        "solenoid valve": ["solenoid", "solenoid valve", "sol", "sov"],
        "relay": ["relay", "control relay", "cr"],
        "overload": ["overload", "ol", "overload relay"],
        "disconnect": ["disconnect", "isolator", "disc", "isolation switch"],
        "hmi": ["hmi", "operator panel", "human machine interface", "operator interface"],
        "cable": ["cable", "wire", "wiring", "conductor"],
        "instrument": ["instrument", "inst", "instr"],
        "fuse": ["fuse", "fu"],
        "motor": ["motor", "mtr"],
        "level": ["level", "lvl"],
        "flow": ["flow"],
        // ISA tag letters: the first letter is the variable, a trailing T a transmitter.
        "level transmitter": ["lt", "level transmitter"],
        "pressure transmitter": ["pt", "pressure transmitter"],
        "flow transmitter": ["ft", "flow transmitter"],
        "temperature transmitter": ["tt", "temperature transmitter"],
    ]

    /// Tag-letter concepts imply their parts, so "LT-101" also means
    /// "level" and "transmitter".
    static let impliedConcepts: [String: [String]] = [
        "level transmitter": ["level", "transmitter"],
        "pressure transmitter": ["pressure", "transmitter"],
        "flow transmitter": ["flow", "transmitter"],
        "temperature transmitter": ["temperature", "transmitter"],
        "loop current": ["milliamp"],
        "thermocouple": ["temperature"],
        "rtd": ["temperature"],
    ]

    /// Stemmed variant (words joined by a space) → concepts.
    private static let variants: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (concept, forms) in synonymTable {
            for form in forms {
                let key = tokens(of: form).map(stem).joined(separator: " ")
                if !key.isEmpty, !(map[key]?.contains(concept) ?? false) { map[key, default: []].append(concept) }
            }
        }
        return map
    }()

    private static let longestVariant = variants.keys.map { $0.split(separator: " ").count }.max() ?? 1

    /// First words of multi-word variants; only these start a longer match.
    private static let phraseStarts = Set(variants.keys.compactMap { key in key.contains(" ") ? key.split(separator: " ").first.map(String.init) : nil })

    /// Concepts found in `stems`, longest variant first at each position.
    static func concepts(in stems: [String]) -> [String] {
        var found: [String] = []
        var index = 0
        while index < stems.count {
            var matched = 1
            let longest = phraseStarts.contains(stems[index]) ? min(longestVariant, stems.count - index) : 1
            for length in stride(from: longest, through: 1, by: -1) {
                let key = stems[index..<index + length].joined(separator: " ")
                if let concepts = variants[key] {
                    for concept in concepts {
                        found.append(concept)
                        found += impliedConcepts[concept] ?? []
                    }
                    matched = length
                    break
                }
            }
            index += matched
        }
        return found
    }

    // MARK: Hashing

    /// FNV-1a over bytes, finished with a murmur-style avalanche so
    /// neighbouring features spread across buckets and signs.
    struct FNV {
        private var hash: UInt64 = 0xcbf2_9ce4_8422_2325

        init(_ kind: Feature) {
            add(kind.rawValue)
        }

        init(seed: UInt8) {
            add(seed)
        }

        mutating func add(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }

        mutating func add(_ bytes: [UInt8]) {
            for byte in bytes { add(byte) }
        }

        var value: UInt64 {
            var result = hash
            result ^= result >> 33
            result &*= 0xff51_afd7_ed55_8ccd
            result ^= result >> 33
            return result
        }
    }

    /// A 128-bit fingerprint of `text` as 32 hex digits, for telling
    /// whether embedded text changed. Not cryptographic, and much cheaper
    /// than SHA-256 when every object is checked.
    public static func fingerprint(_ text: String) -> String {
        var low = FNV(seed: 0x5a)
        var high = FNV(seed: 0xa5)
        for byte in text.utf8 {
            low.add(byte)
            high.add(byte)
        }
        high.add(0xff)
        let hex = [low.value, high.value].map { value in
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }
        return hex.joined()
    }
}
