import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence

/// Optional semantic retrieval. Kept modular per the locked decisions: the
/// structured store is the model, vectors are just another way in.
public protocol SemanticIndex: Sendable {
    /// Nearest objects to `text`, most similar first.
    func nearest(to text: String, limit: Int) throws -> [ObjectID]
}

public struct SearchQuery: Sendable, Hashable {
    public var text: String
    public var types: Set<ObjectType>?
    public var truth: Set<TruthClass>?
    public var updatedFrom: Date?
    public var updatedTo: Date?
    /// Restrict to objects a project (or any container) reaches through `scopeKinds`.
    public var scope: ObjectID?
    public var limit: Int

    public init(
        _ text: String,
        types: Set<ObjectType>? = nil,
        truth: Set<TruthClass>? = nil,
        updatedFrom: Date? = nil,
        updatedTo: Date? = nil,
        scope: ObjectID? = nil,
        limit: Int = 50
    ) {
        self.text = text
        self.types = types
        self.truth = truth
        self.updatedFrom = updatedFrom
        self.updatedTo = updatedTo
        self.scope = scope
        self.limit = limit
    }
}

public enum MatchSource: String, Sendable, Hashable, Comparable {
    case exactID
    case exactTitle
    case fullText
    case semantic

    public static func < (lhs: MatchSource, rhs: MatchSource) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SearchResult: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var type: ObjectType
    public var title: String
    /// Fused relevance; higher is better.
    public var score: Double
    public var matchedBy: Set<MatchSource>
}

/// Universal search: exact ID and title, FTS5 full text, optional semantic
/// retrieval, structured and temporal filters, and graph scope.
///
/// Ranking: an exact ID match always ranks first, then exact title matches,
/// then everything else by reciprocal-rank fusion of the full-text and
/// semantic lists, so neither retriever's raw scores need calibrating.
public struct SearchEngine: Sendable {
    public let store: NexusStore
    public let graph: ObjectGraph
    public let semantic: SemanticIndex?
    /// Relationships that define what a scope contains.
    public var scopeKinds: Set<RelationKind>

    private static let fusionK = 60.0
    private static let exactIDBoost = 1_000.0
    private static let exactTitleBoost = 100.0

    public init(
        store: NexusStore,
        graph: ObjectGraph,
        semantic: SemanticIndex? = nil,
        scopeKinds: Set<RelationKind> = [.contains]
    ) {
        self.store = store
        self.graph = graph
        self.semantic = semantic
        self.scopeKinds = scopeKinds
    }

    public func search(_ query: SearchQuery) throws -> [SearchResult] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, query.limit > 0 else { return [] }

        let scope = try query.scope.map { root in
            Set(try graph.traverse(from: root, kinds: scopeKinds, direction: .outgoing).map(\.id))
        }
        let filter = SearchFilter(
            types: query.types, truth: query.truth, updatedFrom: query.updatedFrom, updatedTo: query.updatedTo, scope: scope
        )

        var scores: [ObjectID: Double] = [:]
        var sources: [ObjectID: Set<MatchSource>] = [:]
        func credit(_ id: ObjectID, _ source: MatchSource, _ amount: Double) {
            scores[id, default: 0] += amount
            sources[id, default: []].insert(source)
        }

        if let id = ObjectID(text) {
            credit(id, .exactID, Self.exactIDBoost)
        }
        for record in try store.objects(titled: text) {
            credit(record.id, .exactTitle, Self.exactTitleBoost)
        }

        // Over-fetch each ranked list so fusion has room to reorder.
        let depth = min(max(query.limit * 3, 50), 500)
        for (rank, hit) in try store.search(text, filter: filter, limit: depth).enumerated() {
            credit(hit.id, .fullText, 1 / (Self.fusionK + Double(rank + 1)))
        }
        if let semantic {
            for (rank, id) in try semantic.nearest(to: text, limit: depth).enumerated() {
                credit(id, .semantic, 1 / (Self.fusionK + Double(rank + 1)))
            }
        }

        // Exact and semantic candidates did not pass through SQL filters, so
        // every candidate is checked against the same predicate here.
        let records = try store.objects(Array(scores.keys))
        return records
            .filter { matches($0, query, scope: scope) }
            .map { SearchResult(id: $0.id, type: $0.type, title: $0.title, score: scores[$0.id]!, matchedBy: sources[$0.id]!) }
            .sorted { ($1.score, $0.id) < ($0.score, $1.id) }
            .prefix(query.limit)
            .map { $0 }
    }

    private func matches(_ record: ObjectRecord, _ query: SearchQuery, scope: Set<ObjectID>?) -> Bool {
        if record.lifecycle == .deleted { return false }
        if let types = query.types, !types.isEmpty, !types.contains(record.type) { return false }
        if let truth = query.truth, !truth.isEmpty, !truth.contains(record.provenance.truth) { return false }
        if let from = query.updatedFrom, record.updatedAt < from { return false }
        if let to = query.updatedTo, record.updatedAt > to { return false }
        if let scope, !scope.contains(record.id) { return false }
        return true
    }
}
