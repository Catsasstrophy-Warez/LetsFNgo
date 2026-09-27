import Foundation
import NexusCore
import NexusDocuments
import NexusGraph
import NexusInvestigation
import NexusLearning
import NexusMeasurement
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSearch
import NexusSimulation
import NexusTasks

extension EventKind {
    /// Someone started an investigation. Payload: `symptom`.
    public static let investigationOpened: EventKind = "investigationOpened"
    /// Someone entered a reading through a command. The store's own
    /// `measured` event covers the measurement itself; this one records the
    /// entry and the investigation it was taken for. Payload: `quantity`,
    /// `value`, `truth`, optional `uncertainty` and `instrument`.
    public static let readingEntered: EventKind = "readingEntered"
}

/// Carries out the commands in `NexusProjects/Commands.swift` against the
/// canonical store, as one person.
///
/// Every operation goes through the domain runtime that owns it (projects,
/// investigations, tasks, documents, learning), so the same rules apply as
/// anywhere else: truth policy, human-only confirmation, task gates. Every
/// write is one store batch, so a failed command leaves nothing half-done,
/// and each one puts an event on the shared timeline.
///
/// Operations return an `ActionResult` with a typed detail, the objects they
/// produced or changed, and the screen and focus to show next. The UI calls
/// `perform(_:selection:parameters:)`, which maps a `CommandID` to an
/// operation and answers `.needsInput` when the person still has to supply
/// something.
public struct ActionExecutor: Sendable {
    public let store: NexusStore
    /// The person the executor acts for. Everything it writes is attributed to them.
    public let actor: Origin
    public let graph: ObjectGraph
    public let projects: ProjectRuntime
    public let investigations: InvestigationRuntime
    public let tasks: TaskRuntime
    public let documents: DocumentLibrary
    public let learning: LearningRuntime
    public let searchEngine: SearchEngine
    /// Loops the executor can simulate by name. Loops wired as
    /// sensor → test point → card → controller → valve in the graph are
    /// found without a binding.
    public var loops: [LoopBinding]
    let clock: NexusClock

    /// An executor with its own runtimes over `store`.
    public init(
        store: NexusStore,
        actor: Origin,
        clock: NexusClock = SystemClock(),
        pdfExtractor: (any PDFTextExtractor)? = nil,
        loops: [LoopBinding] = []
    ) {
        let graph = ObjectGraph(store: store, clock: clock)
        self.init(
            store: store, graph: graph,
            projects: ProjectRuntime(store: store, graph: graph, clock: clock),
            investigations: InvestigationRuntime(store: store, clock: clock),
            tasks: TaskRuntime(store: store, clock: clock),
            documents: DocumentLibrary(store: store, clock: clock, pdfExtractor: pdfExtractor),
            learning: LearningRuntime(store: store, clock: clock),
            searchEngine: SearchEngine(store: store, graph: graph),
            actor: actor, clock: clock, loops: loops
        )
    }

    /// An executor over runtimes the app already holds.
    public init(
        store: NexusStore,
        graph: ObjectGraph,
        projects: ProjectRuntime,
        investigations: InvestigationRuntime,
        tasks: TaskRuntime,
        documents: DocumentLibrary,
        learning: LearningRuntime,
        searchEngine: SearchEngine,
        actor: Origin,
        clock: NexusClock = SystemClock(),
        loops: [LoopBinding] = []
    ) {
        self.store = store
        self.graph = graph
        self.projects = projects
        self.investigations = investigations
        self.tasks = tasks
        self.documents = documents
        self.learning = learning
        self.searchEngine = searchEngine
        self.actor = actor
        self.clock = clock
        self.loops = loops
    }

    // MARK: Objects

    /// The object and the screen family that shows it.
    public func open(_ id: ObjectID) throws -> ActionResult<ObjectRecord> {
        let record = try require(id)
        return ActionResult(detail: record, screen: Self.screen(for: record.type), focus: id, summary: "Opened \(record.title)")
    }

    /// Creates an object through the runtime that owns its type: projects
    /// through `ProjectRuntime`, tasks through `TaskRuntime`, investigations
    /// through `InvestigationRuntime`, anything else directly. The new object
    /// joins `project` when one is given.
    @discardableResult
    public func create(
        _ type: ObjectType,
        title: String,
        in project: ObjectID? = nil,
        attributes: [String: Attribute] = [:]
    ) throws -> ActionResult<ObjectRecord> {
        let title = try Self.nonEmpty(title, .title)
        return try store.batch { store in
            let now = clock.now()
            var record: ObjectRecord
            switch type {
            case .project:
                var mission: String?
                if case .string(let text)? = attributes["mission"]?.value { mission = text }
                record = try projects.createProject(title: title, mission: mission, by: actor)
                let rest = attributes.filter { $0.key != "mission" }
                if !rest.isEmpty {
                    record = try store.update(record.id, by: actor, instruction: "Set attributes") { $0.attributes.merge(rest) { _, new in new } }
                }
            case .task:
                record = try tasks.create(title, in: project, attributes: attributes, by: actor).record
            case .investigation:
                record = try investigations.open(symptom: title, subjects: [], by: actor)
                if !attributes.isEmpty {
                    record = try store.update(record.id, by: actor, instruction: "Set attributes") { $0.attributes.merge(attributes) { own, _ in own } }
                }
            default:
                record = try store.create(
                    ObjectRecord(
                        type: type, title: title, attributes: attributes,
                        provenance: Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now)
                    ))
            }
            if let project, type != .project, type != .task {
                try projects.add(record.id, to: project, by: actor)
            }
            try note(.userEdit, "Created \(type.rawValue) \(title)", about: [record.id] + (project.map { [$0] } ?? []))
            return ActionResult(
                detail: record, produced: [record.id], screen: Self.screen(for: type), focus: record.id, summary: "Created \(title)"
            )
        }
    }

    /// Links two objects. Idempotent: an identical current link is returned as is.
    @discardableResult
    public func link(_ from: ObjectID, _ to: ObjectID, kind: RelationKind) throws -> ActionResult<Relationship> {
        guard from != to else { throw ActionError.invalidValue(.target, reason: "An object cannot be linked to itself") }
        let source = try require(from)
        let target = try require(to)
        return try store.batch { store in
            if let existing = try graph.edges(of: from, kinds: [kind], direction: .outgoing).first(where: { $0.neighbor == to }) {
                return ActionResult(
                    detail: existing.relationship, screen: .objectDetail, focus: from,
                    summary: "\(source.title) already \(kind.rawValue) \(target.title)"
                )
            }
            let now = clock.now()
            let relationship = try store.relate(
                Relationship(
                    kind: kind, from: from, to: to, validFrom: now,
                    provenance: Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now)
                ))
            try note(.userEdit, "Linked \(source.title) \(kind.rawValue) \(target.title)", about: [from, to])
            return ActionResult(
                detail: relationship, changed: [from, to], screen: .objectDetail, focus: from,
                summary: "Linked \(source.title) → \(target.title)"
            )
        }
    }

    /// A collection that `contains` the objects. They stay where they are;
    /// if they all share a project, the collection joins it too.
    @discardableResult
    public func group(_ ids: [ObjectID], title: String) throws -> ActionResult<ObjectRecord> {
        guard !ids.isEmpty else { throw ActionError.emptySelection(.group) }
        let title = try Self.nonEmpty(title, .title)
        let members = try requireAll(ids)
        return try store.batch { store in
            let now = clock.now()
            let provenance = Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now)
            let collection = try store.create(
                ObjectRecord(
                    type: .collection, title: title, attributes: ["count": Attribute(.int(Int64(members.count)))], provenance: provenance
                ))
            for member in members {
                try store.relate(Relationship(kind: .contains, from: collection.id, to: member.id, validFrom: now, provenance: provenance))
            }
            let shared =
                try members.map { Set(try projects.projects(containing: $0.id).map(\.id)) }.reduce(nil) { (acc: Set<ObjectID>?, next) in
                    acc.map { $0.intersection(next) } ?? next
                } ?? []
            for project in shared.sorted() {
                try projects.add(collection.id, to: project, by: actor)
            }
            try note(.userEdit, "Grouped \(members.count) objects as \(title)", about: [collection.id] + members.map(\.id))
            return ActionResult(
                detail: collection, produced: [collection.id], screen: .collection, focus: collection.id,
                summary: "Grouped \(members.count) objects"
            )
        }
    }

    /// Full-text and structured search, scoped to a project when given.
    public func search(_ text: String, types: Set<ObjectType>? = nil, in project: ObjectID? = nil) throws -> ActionResult<[SearchResult]> {
        let hits = try searchEngine.search(SearchQuery(text, types: types, scope: project))
        return ActionResult(detail: hits, screen: .search, focus: nil, summary: "\(hits.count) results for \(text)")
    }

    /// Hands a question to the agent runtime; nothing is written here.
    public func ask(_ goal: String, about subjects: [ObjectID]) throws -> ActionResult<AgentHandoff> {
        let goal = try Self.nonEmpty(goal, .goal)
        _ = try requireAll(subjects)
        return ActionResult(
            detail: AgentHandoff(goal: goal, subjects: subjects), screen: .agentActivity, focus: subjects.last, summary: "Asked: \(goal)"
        )
    }

    // MARK: Documents

    /// Stores a document and its passages through `DocumentLibrary` (PDFs
    /// through its extractor when it has one).
    @discardableResult
    public func importDocument(_ data: Data, title: String, mediaType: String, in project: ObjectID? = nil) throws -> ActionResult<IngestResult> {
        let title = try Self.nonEmpty(title, .title)
        return try store.batch { _ in
            let result = try documents.ingest(data, title: title, mediaType: mediaType, in: project, by: actor)
            if !result.deduplicated {
                try note(.userEdit, "Imported \(title)", about: [result.document.id])
            }
            return ActionResult(
                detail: result, produced: result.deduplicated ? [] : [result.document.id] + result.passages.map(\.id),
                screen: .document, focus: result.document.id,
                summary: result.deduplicated ? "\(title) was already in the library" : "Imported \(title) (\(result.passages.count) passages)"
            )
        }
    }

    /// A claim quoting a passage verbatim and citing its document.
    @discardableResult
    public func extractClaim(
        from passage: ObjectID,
        statement: String,
        sourceClass: SourceClass,
        applicability: String? = nil,
        confidence: Double? = nil
    ) throws -> ActionResult<Claim> {
        let statement = try Self.nonEmpty(statement, .statement)
        let claim = try documents.extractClaim(
            from: passage, statement: statement, sourceClass: sourceClass, applicability: applicability, confidence: confidence, by: actor
        )
        return ActionResult(detail: claim, produced: [claim.id], screen: .objectDetail, focus: claim.id, summary: "Claim: \(statement)")
    }

    // MARK: Shared helpers

    static func screen(for type: ObjectType) -> ScreenFamily {
        switch type {
        case .project: .project
        case .investigation, .hypothesis: .investigation
        case .document, .passage, .report: .document
        case .task, .procedure, .workflow: .taskWorkflow
        case .collection: .collection
        case .simulation: .simulation
        case "meeting": .meeting
        default: .objectDetail
        }
    }

    func require(_ id: ObjectID) throws -> ObjectRecord {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        return record
    }

    func require(_ id: ObjectID, is types: Set<ObjectType>) throws -> ObjectRecord {
        let record = try require(id)
        guard types.contains(record.type) else { throw ActionError.wrongType(id, expected: types, got: record.type) }
        return record
    }

    func requireAll(_ ids: [ObjectID]) throws -> [ObjectRecord] {
        let records = try store.objects(ids)
        let found = Set(records.map(\.id))
        if let missing = ids.first(where: { !found.contains($0) }) { throw StoreError.notFound(missing) }
        return records
    }

    static func nonEmpty(_ text: String, _ field: ActionParameters.Field) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActionError.missingValue(field) }
        return trimmed
    }

    /// Puts what the person did on the timeline.
    func note(_ kind: EventKind, _ summary: String, about subjects: [ObjectID], payload: [String: Value] = [:]) throws {
        var seen: Set<ObjectID> = []
        let now = clock.now()
        try store.record(
            Event(
                at: now, kind: kind, subjects: subjects.filter { seen.insert($0).inserted }, summary: summary, payload: payload,
                provenance: Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now, method: "command")
            ))
    }

    /// Projects containing `id`, directly or through its containers.
    func enclosingProjects(of id: ObjectID) throws -> [ObjectID] {
        let reached = try graph.traverse(from: id, kinds: [.contains], direction: .incoming, maxDepth: 8)
        return try store.objects(reached.map(\.id)).filter { $0.type == .project }.map(\.id)
    }
}
