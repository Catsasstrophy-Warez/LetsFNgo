import Foundation
import NexusAI
import NexusCore
import NexusDocuments
import NexusInvestigation
import NexusModel
import NexusPersistence

extension RelationKind {
    /// Claim → an object whose configuration the claim applies to.
    public static let appliesTo: RelationKind = "appliesTo"
}

/// What to research, and what to match the findings against.
public struct ResearchQuestion: Sendable, Hashable {
    public var text: String
    /// The object (equipment, component, …) whose configuration the claims
    /// are matched against. Nil skips configuration matching.
    public var subject: ObjectID?
    /// A project to hold the report.
    public var project: ObjectID?
    public var maxSources: Int
    public var maxClaimsPerSource: Int

    public init(_ text: String, subject: ObjectID? = nil, project: ObjectID? = nil, maxSources: Int = 5, maxClaimsPerSource: Int = 3) {
        self.text = text
        self.subject = subject
        self.project = project
        self.maxSources = maxSources
        self.maxClaimsPerSource = maxClaimsPerSource
    }
}

public struct ResearchPlan: Sendable, Hashable {
    public var question: String
    public var subQuestions: [String]
    /// Content words searched for during discovery.
    public var terms: [String]
    /// "deterministic" or "model: <model ID>".
    public var method: String

    public init(question: String, subQuestions: [String], terms: [String], method: String) {
        self.question = question
        self.subQuestions = subQuestions
        self.terms = terms
        self.method = method
    }
}

/// A document found for the question, with its most relevant passages.
public struct DiscoveredSource: Sendable, Hashable {
    public var document: ObjectID
    public var title: String
    public var classification: SourceClassification
    /// Most relevant first.
    public var passages: [Passage]
    public var relevance: Double
}

/// One claim the report rests on, new or already in the ledger.
public struct ResearchEvidence: Sendable, Hashable {
    public var claim: ObjectID
    /// "C1", "C2", … as cited in the summary.
    public var label: String
    public var statement: String
    public var document: ObjectID?
    public var passage: ObjectID?
    public var sourceClass: SourceClass
    public var applicability: String?
    /// Created by this run rather than found in the ledger.
    public var isNew: Bool
}

public struct ResearchResult: Sendable, Hashable {
    public var report: ObjectID
    public var plan: ResearchPlan
    public var sources: [DiscoveredSource]
    public var evidence: [ResearchEvidence]
    public var contradictions: [Contradiction]
    public var applicability: [ApplicabilityMatch]
    public var summary: String
    /// "deterministic" or "model: <model ID>", with the reason a model summary was rejected.
    public var synthesis: String

    public var claims: [ObjectID] { evidence.map(\.claim) }
    public var newClaims: [ObjectID] { evidence.filter(\.isNew).map(\.claim) }
}

public enum ResearchError: Error, Equatable, Sendable {
    case emptyQuestion
    case subjectNotFound(ObjectID)
}

/// Research over local sources: the documents in the `DocumentLibrary` and
/// the claims already in the ledger.
///
/// question → plan (sub-questions and search terms) → source discovery (FTS5
/// BM25 per term, over passages and documents) → source classification →
/// evidence extraction (claims quoting their passage verbatim) →
/// contradiction detection → configuration matching → synthesis (a report
/// citing every claim).
///
/// With a model, planning and synthesis are model-assisted; without one, or
/// when the model's answer is unusable, each stage is deterministic. A model
/// summary is kept only if it cites claim labels that exist and every number
/// in it comes from a claim.
///
/// Truth: new claims are `claimed` (they are what their sources assert);
/// the report, contradiction and applicability links are
/// `agentInterpretation`. Everything is written in one store batch, so a
/// failed run leaves nothing behind. Claims are immutable once stored, so
/// counterevidence is set at creation: a new claim lists every contradicting
/// claim already stored, and the passage of a contradicting claim that is
/// stored after it; `contradicts` relationships link both ways.
public struct ResearchRuntime: Sendable {
    public let store: NexusStore
    public let model: (any LanguageModelProvider)?
    let clock: NexusClock
    let library: DocumentLibrary

    public init(store: NexusStore, clock: NexusClock = SystemClock(), model: (any LanguageModelProvider)? = nil) {
        self.store = store
        self.clock = clock
        self.model = model
        self.library = DocumentLibrary(store: store, clock: clock)
    }

    // MARK: Running

    /// The full pipeline, model-assisted when the runtime has a model.
    public func research(_ question: ResearchQuestion, by author: Origin) async throws -> ResearchResult {
        try validate(question)
        let plan = await plan(question.text)
        let analysis = try analyze(question, plan: plan)
        let (summary, synthesis) = await synthesize(analysis)
        return try persist(analysis, summary: summary, synthesis: synthesis, by: author)
    }

    /// The deterministic pipeline, with no model. Synchronous, so an agent
    /// tool can run it inside its store batch.
    public func researchLocally(_ question: ResearchQuestion, by author: Origin) throws -> ResearchResult {
        try validate(question)
        let analysis = try analyze(question, plan: Self.plan(question.text))
        return try persist(analysis, summary: Self.summary(analysis), synthesis: "deterministic", by: author)
    }

    private func validate(_ question: ResearchQuestion) throws {
        guard !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResearchError.emptyQuestion }
        if let subject = question.subject, try store.object(subject) == nil { throw ResearchError.subjectNotFound(subject) }
    }

    // MARK: Plan

    /// Sub-questions split at "?", ";", line breaks and " and " (when both
    /// halves have content words), plus the question's content words.
    public static func plan(_ question: String) -> ResearchPlan {
        var parts: [String] = []
        for piece in question.split(whereSeparator: { "?;\n".contains($0) }) {
            let text = piece.trimmingCharacters(in: .whitespaces)
            let halves = text.components(separatedBy: " and ")
            if halves.count > 1, halves.allSatisfy({ ResearchText.terms($0).count >= 2 }) {
                parts += halves.map { $0.trimmingCharacters(in: .whitespaces) }
            } else if !ResearchText.terms(text).isEmpty {
                parts.append(text)
            }
        }
        let subQuestions = parts.isEmpty ? [question.trimmingCharacters(in: .whitespacesAndNewlines)] : parts.map { $0.hasSuffix("?") ? $0 : $0 + "?" }
        return ResearchPlan(question: question, subQuestions: subQuestions, terms: ResearchText.terms(question), method: "deterministic")
    }

    static let planSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "subQuestions": .object([
                "type": .string("array"), "items": .object(["type": .string("string"), "minLength": .int(3)]), "minItems": .int(1), "maxItems": .int(6),
            ])
        ]),
        "required": .array([.string("subQuestions")]),
        "additionalProperties": .bool(false),
    ])

    /// Asks the model for sub-questions; falls back to `plan(_:)`.
    public func plan(_ question: String) async -> ResearchPlan {
        let fallback = Self.plan(question)
        guard let model else { return fallback }
        let request = GenerationRequest(
            messages: [
                .system("Break a research question into 1 to 6 focused sub-questions answerable from technical documents. Reply with JSON."),
                .user(question),
            ],
            maxOutputTokens: 512, responseSchema: Self.planSchema
        )
        guard let response = try? await model.respond(to: request), response.stopReason == .endTurn,
            let structured = response.structured ?? (try? JSONValue(parsing: response.message.text)),
            JSONSchema.conforms(structured, to: Self.planSchema),
            let subQuestions = structured["subQuestions"]?.arrayValue?.compactMap(\.stringValue)
        else { return fallback }
        var terms = fallback.terms
        for term in subQuestions.flatMap(ResearchText.terms) where !terms.contains(term) && terms.count < 12 {
            terms.append(term)
        }
        return ResearchPlan(question: question, subQuestions: subQuestions, terms: terms, method: "model: \(model.descriptor.ref.modelID)")
    }

    // MARK: Discovery

    /// Documents whose passages match the plan's terms, most relevant first.
    ///
    /// Each term is a separate FTS5 query, so a passage matching some but not
    /// all terms still ranks. A passage scores the sum of its BM25 weights,
    /// scaled by the share of terms it matched; a document scores its best
    /// passage plus half its own title matches.
    public func discover(_ plan: ResearchPlan, limit: Int = 5) throws -> [DiscoveredSource] {
        guard !plan.terms.isEmpty, limit > 0 else { return [] }
        let passageScores = try scores(for: plan.terms, types: [.passage])
        let documentScores = try scores(for: plan.terms, types: [.document])
        var byDocument: [ObjectID: [(passage: Passage, score: Double)]] = [:]
        for record in try store.objects(Array(passageScores.keys)) where record.lifecycle != .deleted {
            guard let passage = try? Passage(record: record), let entry = passageScores[record.id] else { continue }
            let coverage = Double(entry.terms) / Double(plan.terms.count)
            byDocument[passage.document, default: []].append((passage, entry.score * coverage))
        }
        let documents = try store.objects(Array(byDocument.keys)).filter { $0.type == .document && $0.lifecycle != .deleted }
        let sources = documents.map { document -> DiscoveredSource in
            let ranked = byDocument[document.id, default: []].sorted { ($0.score, $1.passage.index) > ($1.score, $0.passage.index) }
            let relevance = (ranked.first?.score ?? 0) + 0.5 * (documentScores[document.id]?.score ?? 0)
            return DiscoveredSource(
                document: document.id, title: document.title, classification: SourceClassifier.classify(document),
                passages: Array(ranked.prefix(3).map(\.passage)), relevance: relevance
            )
        }
        return Array(sources.sorted { ($0.relevance, $1.document) > ($1.relevance, $0.document) }.prefix(limit))
    }

    /// Summed BM25 weight (higher is better) and matched-term count per object.
    private func scores(for terms: [String], types: Set<ObjectType>) throws -> [ObjectID: (score: Double, terms: Int)] {
        var scores: [ObjectID: (score: Double, terms: Int)] = [:]
        for term in terms {
            for hit in try store.search(term, types: types, limit: 100) {
                let weight = max(-hit.score, 1e-6)
                scores[hit.id, default: (0, 0)].score += weight
                scores[hit.id, default: (0, 0)].terms += 1
            }
        }
        return scores
    }

    // MARK: Analysis

    struct Item {
        var evidence: ResearchEvidence
        var passageText: String?
        var blobKey: String?
        var confidence: Double
        var relevance: Double
    }

    struct Analysis {
        var question: ResearchQuestion
        var plan: ResearchPlan
        var sources: [DiscoveredSource]
        var items: [Item]
        var contradictions: [Contradiction]
        var applicability: [ApplicabilityMatch]
        var subject: ObjectRecord?
    }

    /// Everything up to synthesis, in memory.
    func analyze(_ question: ResearchQuestion, plan: ResearchPlan) throws -> Analysis {
        let sources = try discover(plan, limit: question.maxSources)
        let subject = try question.subject.flatMap { try store.object($0) }

        // Claims already in the ledger that match the question.
        var items: [Item] = []
        var known: Set<String> = []
        for (claim, relevance) in try existingClaims(matching: plan.terms) {
            let passage = try store.relationships(from: claim.id, kind: .cites).first?.to
            items.append(
                Item(
                    evidence: ResearchEvidence(
                        claim: claim.id, label: "", statement: claim.statement, document: claim.sources.first, passage: passage,
                        sourceClass: claim.sourceClass, applicability: claim.applicability, isNew: false
                    ),
                    passageText: nil, blobKey: nil, confidence: claim.provenance.confidence ?? SourceClassifier.confidence(for: claim.sourceClass),
                    relevance: relevance
                ))
            known.insert(Self.normalized(claim.statement))
        }

        // New claims from the discovered passages.
        for source in sources {
            let document = try store.object(source.document)
            let digest: String? = if case .string(let blob)? = document?.attributes["blob"]?.value { blob } else { nil }
            let documentApplicability: String? =
                if case .string(let text)? = document?.attributes["applicability"]?.value { text } else { nil }
            for (sentence, passage, score) in Self.extract(from: source, terms: plan.terms, limit: question.maxClaimsPerSource) {
                guard known.insert(Self.normalized(sentence)).inserted else { continue }
                let sourceClass = source.classification.sourceClass
                items.append(
                    Item(
                        evidence: ResearchEvidence(
                            claim: .make(), label: "", statement: sentence, document: source.document, passage: passage.id, sourceClass: sourceClass,
                            applicability: documentApplicability ?? ConfigurationMatcher.applicability(in: sentence), isNew: true
                        ),
                        passageText: passage.text, blobKey: digest.map(passage.key(blob:)), confidence: SourceClassifier.confidence(for: sourceClass),
                        relevance: source.relevance * score
                    ))
            }
        }

        // Strongest sources first, then relevance; label in that order.
        items.sort {
            let left = (SourceClassifier.rank($0.evidence.sourceClass), -$0.relevance)
            let right = (SourceClassifier.rank($1.evidence.sourceClass), -$1.relevance)
            return left < right
        }
        for index in items.indices { items[index].evidence.label = "C\(index + 1)" }

        var contradictions: [Contradiction] = []
        for (i, first) in items.enumerated() {
            for second in items[(i + 1)...]
            where ConfigurationMatcher.compatible(first.evidence.applicability, second.evidence.applicability) {
                if let (reason, detail) = ContradictionDetector.conflict(between: first.evidence.statement, and: second.evidence.statement) {
                    contradictions.append(Contradiction(first: first.evidence.claim, second: second.evidence.claim, reason: reason, detail: detail))
                }
            }
        }

        var applicability: [ApplicabilityMatch] = []
        if let subject {
            for item in items {
                let (verdict, detail) = ConfigurationMatcher.match(item.evidence.applicability, against: subject)
                applicability.append(ApplicabilityMatch(claim: item.evidence.claim, verdict: verdict, detail: detail))
            }
        }

        return Analysis(
            question: question, plan: plan, sources: sources, items: items, contradictions: contradictions, applicability: applicability,
            subject: subject
        )
    }

    /// Sentences of the source's passages that mention the plan's terms,
    /// best first: more terms matched, then sentences stating a quantity.
    static func extract(from source: DiscoveredSource, terms: [String], limit: Int) -> [(String, Passage, Double)] {
        var candidates: [(sentence: String, passage: Passage, score: Double, order: Int)] = []
        var order = 0
        for passage in source.passages {
            for sentence in ResearchText.sentences(passage.text) {
                order += 1
                let words = ResearchText.terms(sentence)
                let matched = terms.filter { term in words.contains { Self.related(term, $0) } }.count
                guard matched > 0, ResearchText.words(sentence).count >= 4 else { continue }
                let quantitative = QuantityScanner.quantities(in: sentence).isEmpty ? 0 : 0.5
                candidates.append((sentence, passage, Double(matched) + quantitative, order))
            }
        }
        var seen: Set<String> = []
        return
            candidates
            .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
            .filter { seen.insert(normalized($0.sentence)).inserted }
            .prefix(limit)
            .map { ($0.sentence, $0.passage, $0.score) }
    }

    /// Same word, or one a prefix of the other ("voltage", "voltages").
    static func related(_ term: String, _ word: String) -> Bool {
        if term == word { return true }
        let (short, long) = term.count <= word.count ? (term, word) : (word, term)
        return short.count >= 4 && long.hasPrefix(short)
    }

    /// Stored claims whose text matches at least two terms (or all, if fewer).
    private func existingClaims(matching terms: [String]) throws -> [(Claim, Double)] {
        guard !terms.isEmpty else { return [] }
        let needed = min(2, terms.count)
        let scored = try scores(for: terms, types: [.claim]).filter { $0.value.terms >= needed }
        let records = try store.objects(Array(scored.keys)).filter { $0.lifecycle != .deleted }
        return try records.compactMap { record in
            try store.claim(record.id).map { ($0, scored[record.id]!.score) }
        }
        .sorted { ($0.1, $1.0.id) > ($1.1, $0.0.id) }
        .prefix(10)
        .map { $0 }
    }

    static func normalized(_ text: String) -> String {
        ResearchText.words(text).joined(separator: " ")
    }

    // MARK: Synthesis

    /// A plain report: findings by strength of source, contradictions, then
    /// applicability, each citing claim labels.
    static func summary(_ analysis: Analysis) -> String {
        var lines = ["Question: \(analysis.plan.question)"]
        if analysis.plan.subQuestions.count > 1 {
            lines.append("Sub-questions: " + analysis.plan.subQuestions.joined(separator: " "))
        }
        guard !analysis.items.isEmpty else {
            lines.append("No local sources address this question.")
            return lines.joined(separator: "\n")
        }
        let titles = Dictionary(analysis.sources.map { ($0.document, $0.title) }, uniquingKeysWith: { first, _ in first })
        lines.append("Findings:")
        for item in analysis.items {
            let evidence = item.evidence
            let source = evidence.document.flatMap { titles[$0] }.map { " — \($0)" } ?? ""
            lines.append("[\(evidence.label)] \(evidence.statement)\(source) (\(evidence.sourceClass.rawValue)\(evidence.isNew ? "" : ", existing claim"))")
        }
        let labels = Dictionary(analysis.items.map { ($0.evidence.claim, $0.evidence.label) }, uniquingKeysWith: { first, _ in first })
        if !analysis.contradictions.isEmpty {
            lines.append("Contradictions:")
            for contradiction in analysis.contradictions {
                lines.append("[\(labels[contradiction.first] ?? "?")] vs [\(labels[contradiction.second] ?? "?")]: \(contradiction.detail)")
            }
        }
        if let subject = analysis.subject, !analysis.applicability.isEmpty {
            lines.append("Applicability to \(subject.title):")
            for match in analysis.applicability {
                lines.append("[\(labels[match.claim] ?? "?")] \(match.verdict.rawValue): \(match.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The model's summary when it passes the checks, else the plain one.
    func synthesize(_ analysis: Analysis) async -> (summary: String, method: String) {
        let fallback = Self.summary(analysis)
        guard let model, !analysis.items.isEmpty else { return (fallback, "deterministic") }
        let labels = Dictionary(analysis.items.map { ($0.evidence.claim, $0.evidence.label) }, uniquingKeysWith: { first, _ in first })
        var prompt = "Question: \(analysis.plan.question)\nClaims:\n"
        prompt += analysis.items.map { "[\($0.evidence.label)] (\($0.evidence.sourceClass.rawValue) source) \($0.evidence.statement)" }
            .joined(separator: "\n")
        if !analysis.contradictions.isEmpty {
            prompt += "\nContradictions:\n"
            prompt += analysis.contradictions.map { "[\(labels[$0.first] ?? "?")] vs [\(labels[$0.second] ?? "?")]: \($0.detail)" }
                .joined(separator: "\n")
        }
        let request = GenerationRequest(
            messages: [
                .system(
                    """
                    Write a short research synthesis answering the question. Use only the numbered claims. Cite every point \
                    with its label, like [C1]. Prefer primary sources and point out contradictions. Do not introduce numbers \
                    that are not in the claims.
                    """
                ),
                .user(prompt),
            ],
            maxOutputTokens: 1_024
        )
        let method = "model: \(model.descriptor.ref.modelID)"
        guard let response = try? await model.respond(to: request), response.stopReason == .endTurn else {
            return (fallback, "deterministic (\(method) gave no answer)")
        }
        let text = response.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cited = Self.citedLabels(in: text)
        let valid = Set(analysis.items.map(\.evidence.label))
        guard !cited.isEmpty, cited.isSubset(of: valid) else {
            return (fallback, "deterministic (\(method) summary rejected: cited \(cited.isEmpty ? "no claims" : "unknown claims"))")
        }
        let known = analysis.items.flatMap { QuantityScanner.numbers(in: $0.evidence.statement) }
        let unsupported = QuantityScanner.quantities(in: text).filter { quantity in
            !known.contains { abs($0 - quantity.value) <= max(1e-9, 0.01 * abs($0)) }
        }
        guard unsupported.isEmpty else {
            return (fallback, "deterministic (\(method) summary rejected: values not in the claims)")
        }
        return (text, method)
    }

    static func citedLabels(in text: String) -> Set<String> {
        let pattern = #/\[(C\d+)\]/#
        return Set(text.matches(of: pattern).map { String($0.output.1) })
    }

    // MARK: Persisting

    func persist(_ analysis: Analysis, summary: String, synthesis: String, by author: Origin) throws -> ResearchResult {
        try store.batch { store in
            let now = clock.now()
            func interpretation(_ method: String, _ dependencies: [ObjectID], confidence: Double? = nil) -> Provenance {
                Provenance(origin: author, truth: .agentInterpretation, timestamp: now, method: method, confidence: confidence, dependencies: dependencies)
            }
            let passages = Dictionary(analysis.items.map { ($0.evidence.claim, $0.evidence.passage) }, uniquingKeysWith: { first, _ in first })
            var stored = Set(analysis.items.filter { !$0.evidence.isNew }.map(\.evidence.claim))

            for item in analysis.items where item.evidence.isNew {
                let evidence = item.evidence
                guard let document = evidence.document, let passage = evidence.passage, let text = item.passageText else { continue }
                var counterevidence: [ObjectID] = []
                for contradiction in analysis.contradictions where contradiction.first == evidence.claim || contradiction.second == evidence.claim {
                    let other = contradiction.first == evidence.claim ? contradiction.second : contradiction.first
                    if stored.contains(other) {
                        counterevidence.append(other)
                    } else if let otherPassage = passages[other] ?? nil {
                        counterevidence.append(otherPassage)
                    }
                }
                let claim = Claim(
                    id: evidence.claim, statement: evidence.statement, sources: [document], passages: [text], sourceClass: evidence.sourceClass,
                    applicability: evidence.applicability, counterevidence: Array(Set(counterevidence)).sorted(),
                    provenance: Provenance(
                        origin: author, truth: .claimed, timestamp: now, method: "research: evidence extraction", confidence: item.confidence,
                        dependencies: [passage, document], transformation: item.blobKey.map { "verbatim \($0)" }
                    )
                )
                try store.add(claim)
                try store.relate(Relationship(kind: .cites, from: claim.id, to: passage, provenance: interpretation("research: citation", [passage])))
                stored.insert(claim.id)
            }

            for contradiction in analysis.contradictions {
                let related = try store.relationships(from: contradiction.first, kind: .contradicts).contains { $0.to == contradiction.second }
                guard !related else { continue }
                let attributes: [String: Attribute] = [
                    "reason": Attribute(.string(contradiction.reason.rawValue)), "detail": Attribute(.string(contradiction.detail)),
                ]
                let provenance = interpretation("contradiction detection: \(contradiction.reason.rawValue)", [contradiction.first, contradiction.second])
                for (from, to) in [(contradiction.first, contradiction.second), (contradiction.second, contradiction.first)] {
                    try store.relate(Relationship(kind: .contradicts, from: from, to: to, attributes: attributes, provenance: provenance))
                }
            }

            if let subject = analysis.subject {
                for match in analysis.applicability where match.verdict == .applies {
                    try store.relate(
                        Relationship(
                            kind: .appliesTo, from: match.claim, to: subject.id, attributes: ["detail": Attribute(.string(match.detail))],
                            provenance: interpretation("configuration matching", [match.claim, subject.id])
                        ))
                }
            }

            let claims = analysis.items.map(\.evidence.claim)
            var attributes: [String: Attribute] = [
                "question": Attribute(.string(analysis.plan.question)),
                "subQuestions": Attribute(.list(analysis.plan.subQuestions.map(Value.string))),
                "plan": Attribute(.string(analysis.plan.method)),
                "summary": Attribute(.string(summary)),
                "synthesis": Attribute(.string(synthesis)),
                "claims": Attribute(.list(claims.map(Value.reference))),
                "sources": Attribute(
                    .list(
                        analysis.sources.map { source in
                            .map([
                                "document": .reference(source.document), "title": .string(source.title),
                                "sourceClass": .string(source.classification.sourceClass.rawValue), "basis": .string(source.classification.basis),
                            ])
                        })),
                "contradictions": Attribute(
                    .list(
                        analysis.contradictions.map { contradiction in
                            .map([
                                "first": .reference(contradiction.first), "second": .reference(contradiction.second),
                                "reason": .string(contradiction.reason.rawValue), "detail": .string(contradiction.detail),
                            ])
                        })),
                "applicability": Attribute(
                    .list(
                        analysis.applicability.map { match in
                            .map(["claim": .reference(match.claim), "verdict": .string(match.verdict.rawValue), "detail": .string(match.detail)])
                        })),
            ]
            if let subject = analysis.subject { attributes["subject"] = Attribute(.reference(subject.id)) }
            let title = analysis.plan.question.count > 90 ? String(analysis.plan.question.prefix(89)) + "…" : analysis.plan.question
            let report = try store.create(
                ObjectRecord(
                    type: .report, title: "Research: \(title)", attributes: attributes,
                    provenance: interpretation("research synthesis (\(synthesis))", claims)
                ))
            for claim in claims {
                try store.relate(Relationship(kind: .cites, from: report.id, to: claim, provenance: interpretation("research synthesis", [claim])))
            }
            if let project = analysis.question.project {
                try store.relate(Relationship(kind: .contains, from: project, to: report.id, provenance: interpretation("research synthesis", [])))
            }

            return ResearchResult(
                report: report.id, plan: analysis.plan, sources: analysis.sources, evidence: analysis.items.map(\.evidence),
                contradictions: analysis.contradictions, applicability: analysis.applicability, summary: summary, synthesis: synthesis
            )
        }
    }
}
