import Foundation
import NexusAI

/// Word-level text helpers shared by the research stages.
public enum ResearchText {
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "because", "been",
        "before", "being", "between", "both", "but", "by", "can", "could", "did", "do", "does", "doing", "down", "during", "each", "few",
        "for", "from", "further", "had", "has", "have", "having", "he", "her", "here", "hers", "him", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "itself", "just", "may", "me", "might", "more", "most", "must", "my", "of", "off", "on", "once", "only", "or",
        "other", "our", "ours", "out", "over", "own", "same", "shall", "she", "should", "so", "some", "such", "than", "that", "the", "their",
        "theirs", "them", "then", "there", "these", "they", "this", "those", "through", "to", "too", "under", "until", "up", "use", "used",
        "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would", "you", "your",
        "yours", "says", "said", "according", "per", "within", "via", "tell", "find", "know", "need", "needs", "required", "requires",
    ]

    static let negations: Set<String> = [
        "not", "no", "never", "cannot", "without", "neither", "nor", "none", "nothing", "nowhere",
    ]

    /// Lowercased words: letters and digits, with inner hyphens and
    /// apostrophes kept ("lt-200", "can't").
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
            if !trimmed.isEmpty { words.append(trimmed.lowercased()) }
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "-" || character == "'" || character == "’" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// Content words, in order and without repeats: no stopwords, negations,
    /// bare numbers or units. These name what a text is about.
    public static func terms(_ text: String) -> [String] {
        var seen: Set<String> = []
        return words(text).filter { word in
            guard !stopwords.contains(word), !isNegation(word), word.contains(where: \.isLetter) else { return false }
            guard word.count >= 3 || word.contains(where: \.isNumber) else { return false }
            guard QuantityScanner.normalizedUnit(word) == nil else { return false }
            return seen.insert(word).inserted
        }
    }

    static func isNegation(_ word: String) -> Bool {
        negations.contains(word) || word.hasSuffix("n't") || word.hasSuffix("n’t")
    }

    /// Whether the text negates what it says ("is not", "never", "can't").
    public static func isNegated(_ text: String) -> Bool {
        words(text).contains(where: isNegation)
    }

    /// Sentences, trimmed, verbatim otherwise. A period ends a sentence only
    /// before whitespace or the end, so "12.5 V" stays whole.
    public static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                append(&sentences, current)
                current = ""
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if ".!?".contains(character), next.isWhitespace {
                append(&sentences, current)
                current = ""
            }
        }
        append(&sentences, current)
        return sentences
    }

    private static func append(_ sentences: inout [String], _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*•#> "))
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }

    /// Shared share of two word sets: |a ∩ b| / |a ∪ b|.
    public static func overlap(_ a: [String], _ b: [String]) -> Double {
        let left = Set(a)
        let right = Set(b)
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }
}
