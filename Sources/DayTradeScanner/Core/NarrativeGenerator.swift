import Foundation

/// Plain-language bull/bear bullets and a one-line "why now" headline, built
/// from score breakdowns every engine already computes.
///
/// This generalizes three things multiple competitors do separately —
/// Stocktwits' "Why It's Trending" explainer, Webull's Vega AI narration of
/// technical signals, and Simply Wall St's Snowflake bull/bear bullets —
/// into one templated generator rather than three bespoke UI features. No
/// new data and no model call: every `Candidate`/`SwingCandidate`/
/// `LongTermCandidate` already exposes a `plainReason` (the positive
/// drivers, already phrased as short fragments joined by ", ") and a
/// `hazardNote` (negatives, joined by " · "). Splitting those apart rather
/// than duplicating each engine's per-component phrasing logic keeps this a
/// pure presentation layer — if a component's wording ever changes, the
/// narrative updates automatically instead of drifting out of sync.
enum NarrativeGenerator {

    struct Narrative: Sendable {
        let headline: String
        let bullish: [String]
        let bearish: [String]

        var isEmpty: Bool { bullish.isEmpty && bearish.isEmpty }
    }

    private static func split(_ text: String, by separator: String) -> [String] {
        text
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Capitalizes a fragment's first letter so a phrase built for a
    /// mid-sentence join ("3.2× normal volume") also reads correctly as the
    /// start of its own bullet.
    private static func sentence(_ fragment: String) -> String {
        guard let first = fragment.first else { return fragment }
        return first.uppercased() + fragment.dropFirst()
    }

    static func forDayTrade(_ candidate: Candidate) -> Narrative {
        let bullish = split(candidate.plainReason, by: ", ")
            .filter { $0 != "No component above threshold" }
            .map(sentence)
        let bearish = split(candidate.hazardNote ?? "", by: " · ").map(sentence)
        let headline = bullish.isEmpty
            ? "\(candidate.symbol) hasn't cleared a strong setup yet."
            : "\(candidate.symbol): \(bullish[0].lowercasedFirst())."
        return Narrative(headline: headline, bullish: bullish, bearish: bearish)
    }

    static func forSwing(_ candidate: SwingCandidate) -> Narrative {
        let bullish = split(candidate.plainReason, by: ", ")
            .filter { $0 != "No component above threshold" }
            .map(sentence)
        let bearish = split(candidate.hazardNote ?? "", by: " · ").map(sentence)
        let headline = bullish.isEmpty
            ? "\(candidate.symbol) is unclassified — no dominant signal yet."
            : "\(candidate.symbol): \(bullish[0].lowercasedFirst())."
        return Narrative(headline: headline, bullish: bullish, bearish: bearish)
    }

    static func forLongTerm(_ candidate: LongTermCandidate) -> Narrative {
        let bullish = split(candidate.plainReason, by: ", ")
            .filter { $0 != "Limited fundamental data available" }
            .map(sentence)
        let bearish = split(candidate.hazardNote ?? "", by: " · ").map(sentence)
        let headline: String
        if bullish.isEmpty {
            headline = "\(candidate.symbol) doesn't have enough filed fundamentals to score confidently yet."
        } else if candidate.score < 0 {
            headline = "\(candidate.symbol) has some strengths, but the balance sheet or valuation currently outweighs them."
        } else {
            headline = "\(candidate.symbol): \(bullish[0].lowercasedFirst())."
        }
        return Narrative(headline: headline, bullish: bullish, bearish: bearish)
    }
}

private extension String {
    func lowercasedFirst() -> String {
        guard let first = self.first else { return self }
        return first.lowercased() + dropFirst()
    }
}
