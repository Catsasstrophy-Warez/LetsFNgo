import Foundation
import NexusAI
import NexusCore
import NexusModel

// MARK: - Source classification

/// A source's evidence class and why it was given.
public struct SourceClassification: Sendable, Hashable {
    public var sourceClass: SourceClass
    /// "attribute" when the document said so, otherwise the heuristic's cue.
    public var basis: String

    public init(sourceClass: SourceClass, basis: String) {
        self.sourceClass = sourceClass
        self.basis = basis
    }
}

/// Classifies sources by evidence quality: primary (the manufacturer's own
/// datasheet, manual or a standard), secondary (application notes,
/// handbooks, papers), tertiary (overviews, encyclopedias), community
/// (forums, blogs, meeting talk) or unknown.
///
/// A `sourceClass` attribute on the document wins; otherwise the title,
/// media type and `publisher`/`kind` attributes are matched against cue words.
public enum SourceClassifier {
    public static let attribute = "sourceClass"

    static let cues: [(SourceClass, [String])] = [
        (.community, ["forum", "reddit", "blog", "comment", "thread", "stack exchange", "stackexchange", "discord", "community", "post", "chat"]),
        (
            .primary,
            [
                "datasheet", "data sheet", "manual", "specification", "spec sheet", "standard", "iec ", "isa ", "ieee ", "nfpa", "manufacturer",
                "installation guide", "reference manual",
            ]
        ),
        (.secondary, ["application note", "app note", "handbook", "textbook", "paper", "journal", "white paper", "whitepaper", "guide", "report"]),
        (.tertiary, ["encyclopedia", "wiki", "overview", "summary", "glossary", "faq", "cheat sheet"]),
    ]

    public static func classify(_ record: ObjectRecord) -> SourceClassification {
        if case .string(let raw)? = record.attributes[attribute]?.value, let sourceClass = SourceClass(rawValue: raw.lowercased()) {
            return SourceClassification(sourceClass: sourceClass, basis: "attribute")
        }
        if record.type == "meeting" {
            return SourceClassification(sourceClass: .community, basis: "meeting")
        }
        var text = " " + record.title.lowercased() + " "
        for key in ["publisher", "kind", "mediaType", "author"] {
            if case .string(let value)? = record.attributes[key]?.value { text += value.lowercased() + " " }
        }
        for (sourceClass, words) in cues {
            if let cue = words.first(where: { text.contains($0) }) {
                return SourceClassification(sourceClass: sourceClass, basis: "heuristic: \(cue.trimmingCharacters(in: .whitespaces))")
            }
        }
        return SourceClassification(sourceClass: .unknown, basis: "heuristic: no cue")
    }

    /// Confidence a claim starts with, by the class of its source.
    public static func confidence(for sourceClass: SourceClass) -> Double {
        switch sourceClass {
        case .primary: 0.8
        case .secondary: 0.65
        case .tertiary: 0.5
        case .community: 0.35
        case .unknown: 0.25
        }
    }

    /// Order for presenting evidence, strongest first.
    public static func rank(_ sourceClass: SourceClass) -> Int {
        switch sourceClass {
        case .primary: 0
        case .secondary: 1
        case .tertiary: 2
        case .community: 3
        case .unknown: 4
        }
    }
}

// MARK: - Contradictions

public enum ContradictionReason: String, Sendable, Hashable, Codable {
    /// The same quantity, in the same unit, with ranges that cannot both hold.
    case numericRange
    /// One statement denies what the other asserts.
    case negation
}

/// Two claims about the same subject that cannot both be true.
public struct Contradiction: Sendable, Hashable {
    public var first: ObjectID
    public var second: ObjectID
    public var reason: ContradictionReason
    public var detail: String

    public init(first: ObjectID, second: ObjectID, reason: ContradictionReason, detail: String) {
        self.first = first
        self.second = second
        self.reason = reason
        self.detail = detail
    }
}

/// Finds statements that contradict each other.
///
/// Two statements are on the same subject when their content words
/// (`ResearchText.terms`) overlap enough. They then contradict when, for some
/// unit, every range one states is disjoint from every range the other
/// states ("10.5 V" vs "9 V"; "4-20 mA" vs "0-10 mA"), or when they say
/// nearly the same thing and exactly one of them is negated.
public enum ContradictionDetector {
    /// Content-word overlap needed for a numeric comparison.
    public static let subjectOverlap = 0.5
    /// Content-word overlap needed for a negation to count.
    public static let negationOverlap = 0.6

    public static func sameSubject(_ a: String, _ b: String) -> Bool {
        ResearchText.overlap(ResearchText.terms(a), ResearchText.terms(b)) >= subjectOverlap
    }

    /// Why `a` and `b` contradict, or nil when they don't.
    public static func conflict(between a: String, and b: String) -> (reason: ContradictionReason, detail: String)? {
        let (termsA, termsB) = (ResearchText.terms(a), ResearchText.terms(b))
        let overlap = ResearchText.overlap(termsA, termsB)
        guard overlap >= subjectOverlap else { return nil }
        // Statements naming different parts ("LT-200" vs "LT-300") are about different things.
        let (namesA, namesB) = (Set(termsA.filter(isIdentifier)), Set(termsB.filter(isIdentifier)))
        if !namesA.isEmpty, !namesB.isEmpty, namesA.isDisjoint(with: namesB) { return nil }

        let left = QuantityScanner.ranges(in: a)
        let right = QuantityScanner.ranges(in: b)
        for unit in Set(left.map(\.unit)).intersection(right.map(\.unit)).sorted() {
            let ours = left.filter { $0.unit == unit }
            let theirs = right.filter { $0.unit == unit }
            if ours.allSatisfy({ range in theirs.allSatisfy(range.isDisjoint) }) {
                return (.numericRange, "\(describe(ours)) vs \(describe(theirs))")
            }
        }

        if overlap >= negationOverlap, ResearchText.isNegated(a) != ResearchText.isNegated(b) {
            return (.negation, ResearchText.isNegated(a) ? "the first denies the second" : "the second denies the first")
        }
        return nil
    }

    /// A tag or model number: letters and digits together.
    static func isIdentifier(_ term: String) -> Bool {
        term.contains(where: \.isLetter) && term.contains(where: \.isNumber)
    }

    static func describe(_ ranges: [RangeMention]) -> String {
        ranges.map { range in
            if range.low == range.high { return "\(format(range.low)) \(range.unit)" }
            if range.high == .infinity { return "≥ \(format(range.low)) \(range.unit)" }
            if range.low == -.infinity { return "≤ \(format(range.high)) \(range.unit)" }
            return "\(format(range.low))–\(format(range.high)) \(range.unit)"
        }.joined(separator: ", ")
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

// MARK: - Configuration matching

public enum ApplicabilityVerdict: String, Sendable, Hashable, Codable {
    /// The claim names this configuration.
    case applies
    /// The claim names a different model, firmware, revision, ….
    case conflicts
    /// The claim is limited to something the object doesn't say.
    case unknown
    /// The claim states no applicability.
    case general
}

public struct ApplicabilityMatch: Sendable, Hashable {
    public var claim: ObjectID
    public var verdict: ApplicabilityVerdict
    public var detail: String

    public init(claim: ObjectID, verdict: ApplicabilityVerdict, detail: String) {
        self.claim = claim
        self.verdict = verdict
        self.detail = detail
    }
}

/// Compares a claim's applicability ("model LT-200, firmware 7.x") with an
/// object's attributes.
///
/// Each "key value" pair (model, series, firmware, revision, version,
/// hardware, part) is checked against an attribute whose name contains the
/// key: equal values (or a wildcard "7.x" / "7.*" prefix) apply, different
/// values conflict. A pair with no such attribute, and any bare identifier
/// with a digit, applies when it appears in the object's title or attribute
/// text. Any conflict wins, then any match; otherwise the verdict is unknown.
public enum ConfigurationMatcher {
    static let keys = ["model", "series", "firmware", "revision", "rev", "version", "hardware", "part"]

    public static func match(_ applicability: String?, against object: ObjectRecord) -> (verdict: ApplicabilityVerdict, detail: String) {
        guard let applicability, !applicability.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (.general, "no stated applicability")
        }
        let words = tokens(applicability)
        var applies: [String] = []
        var conflicts: [String] = []
        var consumed: Set<Int> = []
        let haystack = Set(tokens(([object.title] + stringValues(of: object)).joined(separator: " ")))

        var index = 0
        while index < words.count {
            let word = words[index]
            guard keys.contains(word), index + 1 < words.count else {
                index += 1
                continue
            }
            var valueIndex = index + 1
            if ["no", "number", "#"].contains(words[valueIndex]), valueIndex + 1 < words.count { valueIndex += 1 }
            let value = words[valueIndex]
            consumed.formUnion([index, valueIndex])
            let attributes = object.attributes.filter { $0.key.lowercased().contains(word == "rev" ? "revision" : word) }
                .compactMap { entry -> String? in
                    if case .string(let text) = entry.value.value { return text.lowercased() }
                    return nil
                }
            if attributes.isEmpty {
                if haystack.contains(value) { applies.append("\(word) \(value) named on the object") }
            } else if attributes.contains(where: { fits(value, $0) }) {
                applies.append("\(word) \(value) matches")
            } else {
                conflicts.append("\(word) \(value) ≠ \(attributes.sorted().joined(separator: "/"))")
            }
            index = valueIndex + 1
        }
        for (offset, word) in words.enumerated() where !consumed.contains(offset) && word.contains(where: \.isNumber) && word.contains(where: \.isLetter) {
            if haystack.contains(word) { applies.append("\(word) named on the object") }
        }

        if !conflicts.isEmpty { return (.conflicts, conflicts.joined(separator: "; ")) }
        if !applies.isEmpty { return (.applies, applies.joined(separator: "; ")) }
        return (.unknown, "object does not state \(applicability)")
    }

    /// Equal, or a wildcard prefix ("7.x", "7.*", "7x").
    static func fits(_ pattern: String, _ value: String) -> Bool {
        if pattern == value { return true }
        for suffix in [".x", ".*", "x", "*"] where pattern.hasSuffix(suffix) && pattern.count > suffix.count {
            let prefix = String(pattern.dropLast(suffix.count))
            if value.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Lowercased whitespace-separated tokens with edge punctuation removed;
    /// inner dots and hyphens stay ("7.2", "lt-200").
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || ",;:()[]\"'".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?-")).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func stringValues(of object: ObjectRecord) -> [String] {
        object.attributes.values.compactMap { attribute in
            if case .string(let text) = attribute.value { return text }
            return nil
        }
    }

    /// Whether two applicability statements can describe the same
    /// configuration: false when both name the same key (model, firmware, …)
    /// with values that don't fit each other.
    public static func compatible(_ a: String?, _ b: String?) -> Bool {
        let left = pairs(a)
        let right = pairs(b)
        for (key, value) in left {
            if let other = right[key], !fits(value, other), !fits(other, value) { return false }
        }
        return true
    }

    static func pairs(_ text: String?) -> [String: String] {
        guard let text else { return [:] }
        let words = tokens(text)
        var pairs: [String: String] = [:]
        for (index, word) in words.enumerated() where keys.contains(word) && index + 1 < words.count {
            pairs[word == "rev" ? "revision" : word] = words[index + 1]
        }
        return pairs
    }

    /// Applicability stated in a sentence: "for model LT-200", "firmware 7.x
    /// and later", "rev B only". Nil when the sentence names none.
    public static func applicability(in sentence: String) -> String? {
        let words = sentence.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",;:()")) }
        var pairs: [String] = []
        var index = 0
        while index + 1 < words.count {
            let key = words[index].lowercased()
            let value = words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if keys.contains(key), value.contains(where: { $0.isNumber || $0.isUppercase }), !value.isEmpty {
                pairs.append("\(key) \(value)")
                index += 2
            } else {
                index += 1
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ", ")
    }
}
