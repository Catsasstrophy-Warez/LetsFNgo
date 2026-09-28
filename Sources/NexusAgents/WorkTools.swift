import Foundation
import NexusAI
import NexusCore
import NexusDocuments
import NexusInvestigation
import NexusMeetings
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusResearch
import NexusTasks

/// Tools over tasks, documents, meetings and research. Like the world
/// tools, they go through the domain runtimes and the one store; what they
/// create is a draft, a claim or an interpretation attributed to the run.
public enum WorkTools {
    public static var all: [any AgentTool] {
        [
            CreateTask(), ListTasks(), UpdateTaskStatus(), SearchDocuments(), ReadPassage(), ExtractClaim(), PromoteNotes(), RunResearch(),
        ]
    }
}

private func enumArg(_ description: String, _ values: [String]) -> Value {
    .map(["type": .string("string"), "description": .string(description), "enum": .list(values.map(Value.string))])
}

private func typedArg(_ type: String, _ description: String) -> Value {
    .map(["type": .string(type), "description": .string(description)])
}

private func snippet(_ text: String, _ limit: Int = 160) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}

// MARK: - Tasks

extension TaskStatus {
    /// Accepts "inProgress", "in_progress" and "in progress".
    init?(argument: String) {
        let key = argument.lowercased().filter { $0.isLetter }
        guard let status = TaskStatus.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = status
    }
}

private func parseDate(_ key: String, _ arguments: [String: Value]) throws -> Date? {
    guard let text = try arguments.optionalText(key, maxLength: 40) else { return nil }
    let full = ISO8601DateFormatter()
    if let date = full.date(from: text) { return date }
    let day = ISO8601DateFormatter()
    day.formatOptions = [.withFullDate]
    guard let date = day.date(from: text) else { throw ToolError.invalidArgument(key) }
    return date
}

/// P2. Drafts a task through `TaskRuntime`. Agent tasks are always drafts
/// that a person approves before work starts.
public struct CreateTask: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "create_task", description: "Draft a task for a person to approve. Returns the task ID.",
        parameters: schema(
            [
                "title": objectArg("What needs doing"), "success_condition": objectArg("How to tell it is done"),
                "due": objectArg("Due date, ISO 8601 (2026-10-01 or 2026-10-01T09:00:00Z)"),
                "depends_on": typedArg("array", "IDs of tasks that must be done first"),
                "project": objectArg("Project ID; defaults to the current project"),
            ], required: ["title"]),
        permission: .createDraft
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.task], dataSource: ToolScope.tasks) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let title = try arguments.text("title", maxLength: 200)
        let condition = try arguments.optionalText("success_condition", maxLength: 1_000)
        let due = try parseDate("due", arguments)
        let dependencies = try arguments.objectIDs("depends_on")
        let project = try arguments.optionalObjectID("project") ?? context.project
        if let project, try context.store.object(project) == nil { throw ToolError.notFound(project.description) }
        let task = try TaskRuntime(store: context.store, clock: context.clock).create(
            title, successCondition: condition, dueAt: due, dependsOn: dependencies, in: project, by: context.origin
        )
        return ToolOutcome(
            content: "Drafted task \(task.id) \"\(title)\"; a person must approve it before work starts.",
            touched: dependencies + (project.map { [$0] } ?? []), produced: [task.id]
        )
    }
}

/// P0. Tasks in a project (or everywhere), optionally filtered.
public struct ListTasks: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "list_tasks", description: "List tasks with status, draft state and due date.",
        parameters: schema(
            [
                "project": objectArg("Project ID; defaults to the current project"),
                "status": enumArg("Only tasks with this status", TaskStatus.allCases.map(\.rawValue)),
                "ready": typedArg("boolean", "Only approved open tasks whose dependencies are done"),
            ], required: []),
        permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.task], dataSource: ToolScope.tasks) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let runtime = TaskRuntime(store: context.store, clock: context.clock)
        let project = try arguments.optionalObjectID("project") ?? context.project
        var status: TaskStatus?
        if let raw = try arguments.optionalText("status", maxLength: 40) {
            guard let parsed = TaskStatus(argument: raw) else { throw ToolError.invalidArgument("status") }
            status = parsed
        }
        var tasks =
            try arguments.optionalBool("ready") == true
            ? try runtime.ready(in: project) : try project.map { try runtime.tasks(in: $0) } ?? runtime.allTasks()
        if let status { tasks = tasks.filter { $0.status == status } }
        let formatter = ISO8601DateFormatter()
        let lines = tasks.prefix(50).map { task in
            var line = "\(task.id) [\(task.status.rawValue)\(task.isDraft ? ", draft" : "")] \(task.title)"
            if let due = task.dueAt { line += " (due \(formatter.string(from: due)))" }
            return line
        }
        return ToolOutcome(content: lines.isEmpty ? "No tasks." : lines.joined(separator: "\n"), touched: tasks.prefix(50).map(\.id))
    }
}

/// P3. Moves a task between statuses through `TaskRuntime`, which refuses
/// what agents may not do: finish work, start unapproved drafts, or change
/// a status a person recorded.
public struct UpdateTaskStatus: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "update_task_status", description: "Change a task's status (open, inProgress, blocked, cancelled). Only people mark tasks done.",
        parameters: schema(
            [
                "id": objectArg("Task ID"), "status": enumArg("New status", TaskStatus.allCases.map(\.rawValue)),
                "reason": objectArg("Why"),
            ], required: ["id", "status"]),
        permission: .modifyInternalState
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.task], dataSource: ToolScope.tasks) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("id")
        guard let status = TaskStatus(argument: try arguments.text("status", maxLength: 40)) else { throw ToolError.invalidArgument("status") }
        let reason = try arguments.optionalText("reason", maxLength: 500)
        let runtime = TaskRuntime(store: context.store, clock: context.clock)
        guard let record = try context.store.object(id) else { throw ToolError.notFound(id.description) }
        guard record.type == .task else { throw ToolError.invalidArgument("id") }
        let before = try runtime.task(id).status
        let task = try runtime.setStatus(status, of: id, reason: reason, by: context.origin)
        return ToolOutcome(content: "Task \(id): \(before.rawValue) → \(task.status.rawValue)", touched: [id])
    }
}

// MARK: - Documents

/// P0. Full-text search over documents and their passages.
public struct SearchDocuments: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "search_documents", description: "Search documents; returns matching passages with their document.",
        parameters: schema(["query": objectArg("Words to search for"), "limit": typedArg("integer", "Most results, 1-20 (default 8)")], required: ["query"]),
        permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.document, .passage], dataSource: ToolScope.documents) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let query = try arguments.text("query", maxLength: 200)
        let limit = try arguments.optionalInt("limit", in: 1...20) ?? 8
        let hits = try DocumentLibrary(store: context.store, clock: context.clock).search(query, limit: limit)
        let titles = Dictionary(
            try context.store.objects(Array(Set(hits.map(\.document)))).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }
        )
        let lines = hits.map { hit in
            let document = "\(hit.document) \"\(titles[hit.document] ?? hit.title)\""
            guard let passage = hit.passage else { return "document \(document)" }
            return "passage \(passage.id) in document \(document): \(snippet(passage.text))"
        }
        let touched = hits.flatMap { hit in [hit.document] + (hit.passage.map { [$0.id] } ?? []) }
        return ToolOutcome(content: lines.isEmpty ? "No matches." : lines.joined(separator: "\n"), touched: touched)
    }
}

/// P0. A passage's exact text, with where it comes from.
public struct ReadPassage: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "read_passage", description: "Read one passage verbatim, with its document and section.",
        parameters: schema(["id": objectArg("Passage ID")], required: ["id"]), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.passage, .document], dataSource: ToolScope.documents) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("id")
        guard try context.store.object(id) != nil else { throw ToolError.notFound(id.description) }
        let library = DocumentLibrary(store: context.store, clock: context.clock)
        let passage = try library.passage(id)
        let document = try context.store.object(passage.document)
        let claims = try library.claims(citing: id)
        var header = "Passage \(id) (¶\(passage.index + 1)) of \"\(document?.title ?? passage.document.description)\" \(passage.document)"
        if let section = passage.section { header += ", section \"\(section)\"" }
        if !claims.isEmpty { header += ", cited by \(claims.count) claim(s)" }
        return ToolOutcome(content: header + ":\n" + passage.text, touched: [id, passage.document])
    }
}

/// P2. Records a claim from a passage through `DocumentLibrary`: it cites
/// the passage and stores its text verbatim. The statement may not contain a
/// number the passage lacks, and a quote, when given, must be in the passage.
public struct ExtractClaim: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "extract_claim",
        description: "Record what a passage asserts as a claim citing that passage. Numbers must be copied from the passage.",
        parameters: schema(
            [
                "passage": objectArg("Passage ID"), "statement": objectArg("What the passage claims"),
                "quote": objectArg("Exact words from the passage that support it"),
                "source_class": enumArg("Evidence class of the source; default from the document", SourceClass.allCases.map(\.rawValue)),
                "applicability": objectArg("Configuration it applies to, e.g. model or firmware"),
                "confidence": typedArg("number", "0 to 1"),
            ], required: ["passage", "statement"]),
        permission: .createDraft
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.claim, .passage, .document], dataSource: ToolScope.documents) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let passageID = try arguments.objectID("passage")
        guard try context.store.object(passageID) != nil else { throw ToolError.notFound(passageID.description) }
        let library = DocumentLibrary(store: context.store, clock: context.clock)
        let passage = try library.passage(passageID)
        let statement = try arguments.text("statement", maxLength: 500)
        if let quote = try arguments.optionalText("quote", maxLength: 2_000), !passage.text.contains(quote) {
            throw ToolError.invalidArgument("quote")
        }
        let available = QuantityScanner.numbers(in: passage.text)
        for number in QuantityScanner.numbers(in: statement) where !available.contains(where: { abs($0 - number) <= max(1e-9, 1e-6 * abs($0)) }) {
            throw ToolError.invalidArgument("statement")
        }
        var sourceClass: SourceClass
        if let raw = try arguments.optionalText("source_class", maxLength: 20) {
            guard let parsed = SourceClass(rawValue: raw.lowercased()) else { throw ToolError.invalidArgument("source_class") }
            sourceClass = parsed
        } else {
            let document = try context.store.object(passage.document)
            sourceClass = document.map { SourceClassifier.classify($0).sourceClass } ?? .unknown
        }
        let claim = try library.extractClaim(
            from: passageID, statement: statement, sourceClass: sourceClass,
            applicability: try arguments.optionalText("applicability", maxLength: 200),
            confidence: try arguments.optionalDouble("confidence", in: 0...1), by: context.origin
        )
        return ToolOutcome(
            content: "Recorded claim \(claim.id) (\(sourceClass.rawValue) source) citing passage \(passageID)",
            touched: [passageID, passage.document], produced: [claim.id]
        )
    }
}

// MARK: - Meetings

/// P2. Promotes meeting notes into decisions, draft tasks, claims and
/// questions, using `NotePromotion`'s extraction. What the agent creates is
/// a draft or a claim, never a record: decisions and questions are draft
/// interpretations, tasks are `TaskRuntime` drafts, and statements of fact are
/// claims attributed to the speaker. Each links back to the meeting.
public struct PromoteNotes: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "promote_notes",
        description: "Turn meeting notes into decisions, draft tasks, claims and questions. Give a meeting ID, or a transcript and title.",
        parameters: schema(
            [
                "meeting": objectArg("Meeting ID whose transcript to promote"), "transcript": objectArg("Notes, one statement per line"),
                "title": objectArg("Meeting title, with a transcript"), "about": typedArg("array", "IDs of objects the meeting was about"),
            ], required: []),
        permission: .createDraft
    )

    public var declaredScope: ToolScope {
        ToolScope(objectTypes: [.meeting, .decision, .task, .claim, .question], dataSource: ToolScope.meetings)
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let store = context.store
        var produced: [ObjectID] = []
        let meeting: ObjectID
        let transcript: String
        if let id = try arguments.optionalObjectID("meeting") {
            guard let record = try store.object(id) else { throw ToolError.notFound(id.description) }
            guard record.type == .meeting, case .string(let text)? = record.attributes["transcript"]?.value else {
                throw ToolError.invalidArgument("meeting")
            }
            meeting = id
            transcript = text
        } else {
            transcript = try arguments.text("transcript", maxLength: 50_000)
            meeting = try store.create(
                ObjectRecord(
                    type: .meeting, title: try arguments.text("title", maxLength: 200),
                    attributes: ["transcript": Attribute(.string(transcript))],
                    provenance: context.provenance(method: "meeting notes given to agent")
                )
            ).id
            produced.append(meeting)
            if let project = context.project {
                try store.relate(Relationship(kind: .contains, from: project, to: meeting, provenance: context.provenance()))
            }
        }
        for subject in try arguments.objectIDs("about") {
            guard try store.object(subject) != nil else { throw ToolError.notFound(subject.description) }
            try store.relate(Relationship(kind: .dependsOn, from: meeting, to: subject, provenance: context.provenance()))
        }

        // Items promoted before (by anyone) are not promoted twice.
        let earlier = Set(try store.objects(try store.relationships(from: meeting, kind: .produced).map(\.to)).map(\.title))
        let tasks = TaskRuntime(store: store, clock: context.clock)
        var lines: [String] = []
        for item in NotePromotion.extract(from: transcript) where !earlier.contains(item.text) {
            let provenance = context.provenance(method: "note promotion, line \(item.line + 1)", dependencies: [meeting])
            var attributes: [String: Attribute] = ["line": Attribute(.int(Int64(item.line)))]
            if let speaker = item.speaker { attributes["speaker"] = Attribute(.string(speaker)) }
            let id: ObjectID
            switch item.kind {
            case .decision, .question:
                id = try store.create(
                    ObjectRecord(
                        type: item.kind == .decision ? .decision : .question, title: item.text, attributes: attributes, lifecycle: .draft,
                        provenance: provenance
                    )
                ).id
            case .task:
                id = try tasks.create(item.text, in: context.project, by: context.origin).id
            case .claim:
                let claim = Claim(
                    statement: item.text, sources: [meeting], passages: [item.text], sourceClass: .community,
                    provenance: Provenance(
                        origin: context.origin, truth: .claimed, timestamp: context.clock.now(),
                        method: "said in meeting by \(item.speaker ?? "unknown")", dependencies: [meeting]
                    )
                )
                try store.add(claim)
                id = claim.id
            }
            try store.relate(Relationship(kind: .produced, from: meeting, to: id, provenance: provenance))
            produced.append(id)
            lines.append("\(item.kind.rawValue) \(id): \(item.text)")
        }
        let header = "Promoted \(lines.count) item(s) from meeting \(meeting)"
        return ToolOutcome(content: ([header] + lines).joined(separator: "\n"), touched: [meeting], produced: produced)
    }
}

// MARK: - Research

/// P1. Runs the research pipeline over local documents and claims and
/// stores a report citing the claims it rests on.
public struct RunResearch: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "run_research",
        description: "Research a question from local documents and claims: finds and classifies sources, extracts cited claims, "
            + "flags contradictions, checks applicability to a subject, and writes a report.",
        parameters: schema(
            [
                "question": objectArg("The research question"),
                "subject": objectArg("Object ID whose configuration findings are matched against"),
                "max_sources": typedArg("integer", "Most documents to use, 1-10 (default 5)"),
            ], required: ["question"]),
        permission: .analyze
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.document, .passage, .claim, .report], dataSource: ToolScope.documents) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let question = ResearchQuestion(
            try arguments.text("question", maxLength: 500), subject: try arguments.optionalObjectID("subject"), project: context.project,
            maxSources: try arguments.optionalInt("max_sources", in: 1...10) ?? 5
        )
        if let subject = question.subject, try context.store.object(subject) == nil { throw ToolError.notFound(subject.description) }
        let result = try ResearchRuntime(store: context.store, clock: context.clock).researchLocally(question, by: context.origin)
        let labels = result.evidence.map { "\($0.label) = claim \($0.claim)" }
        let content = (["Report \(result.report)", result.summary] + (labels.isEmpty ? [] : ["Claims: " + labels.joined(separator: "; ")]))
            .joined(separator: "\n")
        return ToolOutcome(
            content: content, touched: result.sources.map(\.document) + result.evidence.filter { !$0.isNew }.map(\.claim),
            produced: [result.report] + result.newClaims
        )
    }
}

// MARK: - Delegation

/// P1. Hands part of a goal to a specialist. The specialist runs as its own
/// agent run, under its own agent ID (so its own permissions apply), linked
/// `delegatedTo` from this run, and its answer comes back as the result.
public struct DelegateTool: DelegatingTool {
    public var profiles: [AgentProfile]
    /// How deep delegation may nest.
    public var maxDepth: Int

    public init(profiles: [AgentProfile] = AgentProfile.specialists, maxDepth: Int = 2) {
        self.profiles = profiles
        self.maxDepth = maxDepth
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "delegate",
            description: "Ask a specialist agent to do part of the goal. Specialists: "
                + profiles.map { "\($0.id) (\($0.summary))" }.joined(separator: "; "),
            parameters: schema(
                [
                    "agent": enumArg("Specialist ID", profiles.map(\.id)), "goal": objectArg("What the specialist should do"),
                ], required: ["agent", "goal"]),
            permission: .analyze
        )
    }

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.agentRun]) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        throw ToolError.refused("delegate runs only inside an agent runtime")
    }

    public func delegate(_ arguments: [String: Value], in context: ToolContext, via delegation: Delegation) async throws -> ToolOutcome {
        let id = try arguments.text("agent", maxLength: 80)
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ToolError.invalidArgument("agent") }
        guard profile.id != context.agentID else { throw ToolError.refused("an agent cannot delegate to itself") }
        guard delegation.depth <= maxDepth else { throw ToolError.refused("delegation deeper than \(maxDepth) levels") }
        let goal = try arguments.text("goal", maxLength: 4_000)
        let result = try await delegation.run(goal, as: profile)
        let output = result.output.isEmpty ? "(no answer)" : result.output
        return ToolOutcome(content: "\(profile.id) run \(result.run) \(result.status.rawValue): \(output)", touched: [result.run])
    }
}
