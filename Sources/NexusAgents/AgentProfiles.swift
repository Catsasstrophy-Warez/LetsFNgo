import Foundation

/// The specialist capability bundles. Each is a focused instruction and a
/// tool set over the same world model; none keeps its own state.
extension AgentProfile {
    /// Rules every specialist follows.
    static let groundRules = """
        Values you report must come from tool results; never state a number you did not read. \
        Label anything you estimate or model as estimated or modeled. Say which truth class each value has.
        """

    /// The default assistant for engineering work: reads the world model,
    /// proposes hypotheses, may annotate (asks once per project) and may send
    /// messages (asks every time).
    public static let diagnostician = AgentProfile(
        id: "diagnostic",
        instructions: """
            You help a technician diagnose equipment. Use the tools to read the \
            world model; never state a value you did not read from a tool. \
            Propose hypotheses with testable predictions rather than conclusions.
            """,
        tools: ["search_objects", "get_object", "related_objects", "get_measurements", "propose_hypothesis", "annotate_object", "send_message"],
        summary: "Diagnoses faults: reads measurements, proposes testable hypotheses.",
        keywords: [
            "diagnos", "fault", "troubleshoot", "why does", "why is", "clamp", "fail", "broken", "symptom", "hypothes", "cause", "reading",
            "alarm", "trip",
        ]
    )

    public static let research = AgentProfile(
        id: "research",
        instructions: """
            You research questions from the local library. Run research for broad questions; search documents and \
            read passages for narrow ones. Every statement you make cites a claim or passage. Prefer primary sources, \
            say where sources contradict each other, and say whether findings apply to the selected object's configuration.
            """,
        tools: ["search_objects", "get_object", "search_documents", "read_passage", "extract_claim", "run_research"],
        maxSteps: 10,
        summary: "Answers questions from documents and claims, with citations, contradictions and applicability.",
        keywords: ["research", "source", "evidence", "literature", "contradict", "compare", "claim", "what does", "find out", "applicab", "citation"]
    )

    public static let document = AgentProfile(
        id: "document",
        instructions: """
            You work with documents: find passages, quote them exactly, and record claims that cite the passage they \
            come from. Never paraphrase a number; copy it from the passage.
            """,
        tools: ["search_documents", "read_passage", "extract_claim", "search_objects", "get_object"],
        summary: "Finds and quotes passages in documents and records cited claims.",
        keywords: ["document", "manual", "datasheet", "passage", "pdf", "page", "quote", "cite", "section", "spec"]
    )

    public static let project = AgentProfile(
        id: "project",
        instructions: """
            You organize project work. List tasks before creating new ones; create tasks as drafts for a person to \
            approve; move tasks you created between open, in progress and blocked. Never mark work done: only a person can. \
            Read trips, contacts, job applications, certifications and buildings through their tools; what they \
            compute (connections, conflicts, overdue contacts, areas) is derived.
            """,
        tools: Set(["search_objects", "get_object", "related_objects", "list_tasks", "create_task", "update_task_status"]).union(DomainTools.names),
        summary: "Plans and tracks tasks, trips, contacts, job applications, certifications and spaces.",
        keywords: [
            "task", "todo", "to-do", "project", "plan", "deadline", "due", "assign", "blocked", "milestone", "backlog", "status", "itinerar",
            "travel", "flight", "contacts", "keep in touch", "career", "resume", "résumé", "certification", "job", "room", "building",
        ]
    )

    public static let engineering = AgentProfile(
        id: "engineering",
        instructions: """
            You answer engineering questions about the selected equipment: wiring, ratings, loop budgets and \
            calculations. Read the values you need from measurements, objects and documents. Show your arithmetic and \
            label every computed value as derived and every assumed one as estimated.
            """,
        tools: ["search_objects", "get_object", "related_objects", "get_measurements", "search_documents", "read_passage", "annotate_object"],
        summary: "Engineering analysis and calculations over equipment, measurements and documents.",
        keywords: [
            "calculat", "design", "wiring", "voltage", "current", "resistance", "sizing", "circuit", "pressure", "rating", "budget", "load",
            "compute",
        ]
    )

    public static let meeting = AgentProfile(
        id: "meeting",
        instructions: """
            You handle meetings and scheduling. Promote meeting notes into decisions, draft tasks, claims and open \
            questions, linked to the meeting. Check existing tasks before adding follow-ups. Everything you create is a \
            draft for a person to confirm.
            """,
        tools: ["promote_notes", "list_tasks", "create_task", "search_objects", "get_object"],
        summary: "Turns meeting notes into decisions, tasks and questions; schedules follow-ups.",
        keywords: ["meeting", "notes", "transcript", "minutes", "agenda", "schedule", "calendar", "decided", "action item", "follow-up", "follow up"]
    )

    public static let writing = AgentProfile(
        id: "writing",
        instructions: """
            You write: summaries, reports, messages and explanations about the objects in context. Read what you need \
            first and write only what the sources support. Keep numbers exactly as read.
            """,
        tools: ["search_objects", "get_object", "related_objects", "search_documents", "read_passage"],
        summary: "Writes summaries, reports, messages and explanations grounded in the world model.",
        keywords: ["write", "draft", "summar", "email", "rewrite", "report", "explain", "letter", "post", "describe", "memo"]
    )

    /// Money questions over the finance domain. It reads through P0 tools;
    /// running a forecast or categorising a transaction is P3 and asks first.
    public static let finance = AgentProfile(
        id: "finance",
        instructions: """
            You answer questions about the person's money: balances, spending by category, budgets, recurring charges \
            and forecasts. Read every number from the finance tools and say its truth class: balances and transactions \
            are recorded, totals and budget actuals are derived, forecasts are modeled and scenario assumptions are claimed. \
            Never present a forecast as a balance. Run a forecast or categorise a transaction only when the goal asks for it; \
            a category a person set is never changed.
            """,
        tools: [
            "finance_balances", "finance_spending", "finance_budget_status", "finance_recurring", "finance_forecast", "run_forecast",
            "categorize_transaction", "search_objects", "get_object",
        ],
        summary: "Money: balances, spending by category, budgets, recurring charges and forecasts.",
        keywords: [
            "spend", "spent", "budget", "balance", "bank", "money", "forecast", "recurring", "subscription", "income", "expense", "cash flow",
            "salary", "afford", "saving", "transaction", "categor",
        ]
    )

    /// Routes a goal to specialists through `delegate`.
    public static let coordinator = AgentProfile(
        id: "orchestrator",
        instructions: """
            You coordinate specialist agents. Look at the context, then delegate each part of the goal to the \
            specialist best suited to it, and combine their answers. Do not do specialist work yourself.
            """,
        tools: ["search_objects", "get_object", "delegate"],
        maxSteps: 8,
        summary: "Splits a goal across specialists."
    )

    /// Every specialist the orchestrator can choose, in tie-break order.
    public static var specialists: [AgentProfile] {
        [.diagnostician, .research, .document, .project, .engineering, .meeting, .writing, .finance]
    }
}
