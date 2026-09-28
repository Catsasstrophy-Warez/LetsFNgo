import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// Matches text read off equipment (a nameplate, a tag label, a meter face)
/// to canonical objects. Platform-neutral: the Apple layer supplies OCR lines
/// from Vision or Visual Intelligence; this decides what they refer to.
public struct NameplateMatcher: Sendable {
    public struct Match: Sendable, Hashable {
        public var object: ObjectID
        public var title: String
        /// 0–1: how strongly the text points at this object.
        public var confidence: Double
        /// The token that matched, e.g. "LT-101".
        public var evidence: String
    }

    public let engine: SearchEngine

    public init(engine: SearchEngine) {
        self.engine = engine
    }

    /// Instrument-tag-like tokens: letters, a separator, digits, optional suffix
    /// ("LT-101", "FIC 2001A", "PT_17"), plus long alphanumeric serials.
    public static func candidateTokens(in lines: [String]) -> [String] {
        let tag = /\b([A-Z]{1,4})[\s_\-]?(\d{2,5}[A-Z]?)\b/
        let serial = /\b[A-Z0-9]{8,}\b/
        var tokens: [String] = []
        for line in lines.map({ $0.uppercased() }) {
            for match in line.matches(of: tag) {
                tokens.append("\(match.output.1)-\(match.output.2)")
            }
            for match in line.matches(of: serial) where match.output.contains(where: \.isNumber) && match.output.contains(where: \.isLetter) {
                tokens.append(String(match.output))
            }
        }
        var seen: Set<String> = []
        return tokens.filter { seen.insert($0).inserted }
    }

    /// Best matches first. An object whose `tag`, `serial` or title contains a
    /// token exactly scores highest; full-text hits on the token score lower.
    public func match(lines: [String], scope: ObjectID? = nil, limit: Int = 5) throws -> [Match] {
        var best: [ObjectID: Match] = [:]
        for token in Self.candidateTokens(in: lines) {
            for result in try engine.search(SearchQuery(token, scope: scope, limit: 10)) {
                guard let record = try engine.store.object(result.id) else { continue }
                let exact = [record.attributes["tag"]?.value, record.attributes["serial"]?.value].contains { value in
                    if case .string(let text)? = value { return normalize(text) == normalize(token) }
                    return false
                } || normalize(record.title).contains(normalize(token))
                let confidence = exact ? 0.95 : 0.6
                if confidence > (best[record.id]?.confidence ?? 0) {
                    best[record.id] = Match(object: record.id, title: record.title, confidence: confidence, evidence: token)
                }
            }
        }
        return best.values
            .sorted { ($1.confidence, $0.object) < ($0.confidence, $1.object) }
            .prefix(limit)
            .map { $0 }
    }

    private func normalize(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
