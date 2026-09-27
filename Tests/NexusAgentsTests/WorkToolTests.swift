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
import Testing

@testable import NexusAgents

private let manualText = """
    # LT-101 manual

    ## Power

    Minimum lift-off voltage is 12 V at the terminals.

    ## Wiring

    Use shielded twisted pair for the loop.
    """

extension Bench {
    /// Runs one tool the way the runtime does: inside a store batch, as an agent run.
    func use(_ tool: any AgentTool, _ arguments: [String: Value], agent: String = "project") throws -> ToolOutcome {
        let run = try store.create(
            ObjectRecord(
                type: .agentRun, title: "test", provenance: Provenance(origin: .system, truth: .recorded, timestamp: t0)
            )
        ).id
        let context = ToolContext(store: store, run: run, agentID: agent, project: project, clock: clock)
        return try store.batch { _ in try tool.run(arguments, in: context) }
    }

    func ingestManual() throws -> (document: ObjectID, passages: [Passage]) {
        let result = try DocumentLibrary(store: store, clock: clock).ingest(
            Data(manualText.utf8), title: "LT-101 installation manual", mediaType: "text/markdown", by: tech
        )
        return (result.document.id, result.passages)
    }
}

@Suite struct TaskToolTests {
    @Test func createTaskDraftsThroughTheTaskRuntime() throws {
        let bench = try Bench()
        let first = try bench.use(CreateTask(), ["title": .string("Replace TB-4"), "due": .string("2026-10-01")])
        let task = try TaskRuntime(store: bench.store, clock: bench.clock).task(try #require(first.produced.first))
        #expect(task.isDraft && task.status == .open)
        #expect(task.record.provenance.truth == .agentInterpretation)
        #expect(task.dueAt != nil)
        #expect(try bench.store.relationships(from: bench.project, kind: .contains).contains { $0.to == task.id })

        let second = try bench.use(
            CreateTask(),
            [
                "title": .string("Verify loop"), "success_condition": .string("12 V at TB-4"), "depends_on": .list([.string(task.id.description)]),
            ])
        let dependent = try #require(second.produced.first)
        #expect(try TaskRuntime(store: bench.store, clock: bench.clock).dependencies(of: dependent).map(\.id) == [task.id])
    }

    @Test func createTaskValidatesArguments() throws {
        let bench = try Bench()
        #expect(throws: ToolError.missingArgument("title")) { try bench.use(CreateTask(), [:]) }
        #expect(throws: ToolError.invalidArgument("title")) { try bench.use(CreateTask(), ["title": .string("   ")]) }
        #expect(throws: ToolError.invalidArgument("due")) { try bench.use(CreateTask(), ["title": .string("x"), "due": .string("next week")]) }
        #expect(throws: ToolError.invalidArgument("depends_on")) { try bench.use(CreateTask(), ["title": .string("x"), "depends_on": .list([.int(3)])]) }
        let missing = ObjectID.make()
        #expect(throws: ToolError.notFound(missing.description)) { try bench.use(CreateTask(), ["title": .string("x"), "project": .reference(missing)]) }
        #expect(try TaskRuntime(store: bench.store, clock: bench.clock).allTasks().isEmpty)
    }

    @Test func listAndUpdateFollowTheTaskRules() throws {
        let bench = try Bench()
        let runtime = TaskRuntime(store: bench.store, clock: bench.clock)
        let drafted = try #require(try bench.use(CreateTask(), ["title": .string("Replace TB-4")]).produced.first)
        let listed = try bench.use(ListTasks(), [:])
        #expect(listed.content.contains("[open, draft] Replace TB-4"))
        #expect(try bench.use(ListTasks(), ["ready": .bool(true)]).content == "No tasks.", "Drafts are not ready")

        // Agents cannot start their own unapproved draft.
        #expect(throws: TaskError.draftNotApproved(drafted)) {
            try bench.use(UpdateTaskStatus(), ["id": .reference(drafted), "status": .string("in_progress")])
        }
        try runtime.approve(drafted, by: tech)
        let moved = try bench.use(UpdateTaskStatus(), ["id": .reference(drafted), "status": .string("in progress"), "reason": .string("Parts here")])
        #expect(moved.content.hasSuffix("open → inProgress"))
        #expect(try bench.use(ListTasks(), ["status": .string("inProgress")]).content.contains("Replace TB-4"))
        // Only people finish work.
        do {
            _ = try bench.use(UpdateTaskStatus(), ["id": .reference(drafted), "status": .string("done")])
            Issue.record("An agent marked a task done")
        } catch TaskError.requiresHuman {}
        #expect(throws: ToolError.invalidArgument("status")) { try bench.use(UpdateTaskStatus(), ["id": .reference(drafted), "status": .string("finished")]) }
        #expect(throws: ToolError.invalidArgument("id")) {
            try bench.use(UpdateTaskStatus(), ["id": .reference(bench.transmitter), "status": .string("open")])
        }
        #expect(throws: ToolError.invalidArgument("status")) { try bench.use(ListTasks(), ["status": .string("someday")]) }

        // A person's task keeps its recorded status.
        let personal = try runtime.create("Calibrate LT-101", in: bench.project, by: tech)
        #expect(throws: StoreError.self) { try bench.use(UpdateTaskStatus(), ["id": .reference(personal.id), "status": .string("blocked")]) }
    }
}

@Suite struct DocumentToolTests {
    @Test func searchAndReadPassages() throws {
        let bench = try Bench()
        let (document, passages) = try bench.ingestManual()
        let power = try #require(passages.first { $0.text.contains("lift-off") })
        let found = try bench.use(SearchDocuments(), ["query": .string("lift-off voltage")])
        #expect(found.content.contains("passage \(power.id) in document \(document) \"LT-101 installation manual\""))
        #expect(found.touched.contains(power.id) && found.touched.contains(document))
        #expect(try bench.use(SearchDocuments(), ["query": .string("zebra")]).content == "No matches.")
        #expect(throws: ToolError.invalidArgument("limit")) { try bench.use(SearchDocuments(), ["query": .string("x"), "limit": .int(50)]) }

        let read = try bench.use(ReadPassage(), ["id": .reference(power.id)])
        #expect(read.content.hasSuffix(":\n" + power.text))
        #expect(read.content.contains("section \"Power\""))
        #expect(throws: DocumentError.notAPassage(bench.transmitter)) { try bench.use(ReadPassage(), ["id": .reference(bench.transmitter)]) }
    }

    @Test func extractClaimCitesThePassageVerbatimAndRejectsInventedNumbers() throws {
        let bench = try Bench()
        let (document, passages) = try bench.ingestManual()
        let power = try #require(passages.first { $0.text.contains("lift-off") })
        let outcome = try bench.use(
            ExtractClaim(),
            [
                "passage": .reference(power.id), "statement": .string("LT-101 needs at least 12 V at its terminals"),
                "quote": .string("Minimum lift-off voltage is 12 V"), "confidence": .double(0.9),
            ])
        let claimID = try #require(outcome.produced.first)
        let claim = try #require(try bench.store.claim(claimID))
        #expect(claim.passages == [power.text] && claim.sources == [document])
        #expect(claim.sourceClass == .primary, "A manual is a primary source")
        #expect(claim.provenance.truth == .claimed)
        #expect(try bench.store.relationships(from: claim.id, kind: .cites).map(\.to) == [power.id])

        #expect(throws: ToolError.invalidArgument("statement")) {
            try bench.use(ExtractClaim(), ["passage": .reference(power.id), "statement": .string("LT-101 needs 10.5 V")])
        }
        #expect(throws: ToolError.invalidArgument("quote")) {
            try bench.use(ExtractClaim(), ["passage": .reference(power.id), "statement": .string("Needs lift-off"), "quote": .string("24 V")])
        }
        #expect(throws: ToolError.invalidArgument("source_class")) {
            try bench.use(ExtractClaim(), ["passage": .reference(power.id), "statement": .string("x y"), "source_class": .string("gossip")])
        }
        #expect(throws: ToolError.invalidArgument("confidence")) {
            try bench.use(ExtractClaim(), ["passage": .reference(power.id), "statement": .string("x y"), "confidence": .double(1.5)])
        }
        #expect(try DocumentLibrary(store: bench.store, clock: bench.clock).claims(citing: power.id).count == 1)
    }

    @Test func documentAgentRunsVerifyClaimsAsAttributedOutputs() async throws {
        let bench = try Bench()
        let (_, passages) = try bench.ingestManual()
        let power = try #require(passages.first { $0.text.contains("lift-off") })
        let model = ScriptedModel(script: [
            toolTurn(call("search_documents", ["query": .string("lift-off")])),
            toolTurn(call("extract_claim", ["passage": .reference(power.id), "statement": .string("Minimum lift-off voltage is 12 V")])),
            finalTurn("The manual says the minimum lift-off voltage is 12 V (claimed, primary source)."),
        ])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "What lift-off voltage?"), as: .document, approver: ScriptedApprover())
        #expect(result.status == .completed)
        #expect(result.produced.count == 1)
        #expect(try bench.store.object(result.produced[0])?.type == .claim)
    }
}

@Suite struct MeetingToolTests {
    private let transcript = """
        Ana: We decided to replace TB-4 on Friday.
        Ben: I will order a new terminal block.
        Ana: According to the manual the loop needs 12 V.
        Ben: Who signs off the repair?
        Ana: Thanks everyone.
        """

    @Test func notesArePromotedAsDraftsAndClaims() throws {
        let bench = try Bench()
        let outcome = try bench.use(
            PromoteNotes(),
            [
                "transcript": .string(transcript), "title": .string("Loop review"), "about": .list([.reference(bench.transmitter)]),
            ], agent: "meeting")
        #expect(outcome.produced.count == 5, "The meeting plus four items")
        let records = try bench.store.objects(outcome.produced)
        let meeting = try #require(records.first { $0.type == .meeting })
        #expect(meeting.provenance.truth == .agentInterpretation)
        let byType = Dictionary(grouping: records.filter { $0.type != .meeting }, by: \.type)
        #expect(byType[.decision]?.first?.lifecycle == .draft)
        #expect(byType[.question]?.first?.lifecycle == .draft)
        #expect(byType[.task]?.first?.lifecycle == .draft)
        let claimID = try #require(byType[.claim]?.first?.id)
        let claim = try #require(try bench.store.claim(claimID))
        #expect(claim.sources == [meeting.id] && claim.sourceClass == .community && claim.provenance.truth == .claimed)
        #expect(Set(try bench.store.relationships(from: meeting.id, kind: .produced).map(\.to)) == Set(outcome.produced.dropFirst()))
        #expect(try bench.store.relationships(from: meeting.id, kind: .dependsOn).map(\.to) == [bench.transmitter])
        for record in records where record.type != .claim {
            #expect(AgentRuntime.acceptableTruth(of: record))
        }

        // Promoting the stored meeting again adds nothing.
        let again = try bench.use(PromoteNotes(), ["meeting": .reference(meeting.id)], agent: "meeting")
        #expect(again.produced.isEmpty)
        #expect(throws: ToolError.invalidArgument("meeting")) { try bench.use(PromoteNotes(), ["meeting": .reference(bench.transmitter)]) }
        #expect(throws: ToolError.missingArgument("transcript")) { try bench.use(PromoteNotes(), [:]) }
        #expect(throws: ToolError.missingArgument("title")) { try bench.use(PromoteNotes(), ["transcript": .string("Decision: go")]) }
    }

    @Test func meetingAgentRunsComplete() async throws {
        let bench = try Bench()
        let model = ScriptedModel(script: [
            toolTurn(call("promote_notes", ["transcript": .string(transcript), "title": .string("Loop review")])),
            finalTurn("Recorded one decision, one draft task, one claim and one open question."),
        ])
        let result = try await bench.runtime(model).run(AgentRequest(goal: "Promote the meeting notes"), as: .meeting, approver: ScriptedApprover())
        #expect(result.status == .completed)
        #expect(result.produced.count == 5)
    }
}

@Suite struct ResearchToolTests {
    @Test func runResearchWritesACitedReport() async throws {
        let bench = try Bench()
        _ = try bench.ingestManual()
        let model = ScriptedModel(script: [
            toolTurn(call("run_research", ["question": .string("What lift-off voltage does LT-101 need?"), "subject": .reference(bench.transmitter)])),
            finalTurn("The manual gives a minimum lift-off voltage of 12 V [C1]."),
        ])
        let result = try await bench.runtime(model).run(
            AgentRequest(goal: "Research the LT-101 supply", project: bench.project), as: .research, approver: ScriptedApprover()
        )
        #expect(result.status == .completed)
        let records = try bench.store.objects(result.produced)
        let report = try #require(records.first { $0.type == .report })
        #expect(report.provenance.origin == .agent(id: "research", run: result.run))
        #expect(records.filter { $0.type == .claim }.allSatisfy { $0.provenance.truth == .claimed })
        #expect(try bench.store.relationships(from: bench.project, kind: .contains).contains { $0.to == report.id })
        let toolResult = try #require(model.requests.last?.messages.last?.toolResults.first)
        #expect(toolResult.content.hasPrefix("Report \(report.id)") && toolResult.content.contains("C1 = claim"))
    }

    @Test func runResearchValidatesArguments() throws {
        let bench = try Bench()
        #expect(throws: ToolError.missingArgument("question")) { try bench.use(RunResearch(), [:]) }
        #expect(throws: ToolError.invalidArgument("max_sources")) {
            try bench.use(RunResearch(), ["question": .string("x"), "max_sources": .int(0)])
        }
        let missing = ObjectID.make()
        #expect(throws: ToolError.notFound(missing.description)) {
            try bench.use(RunResearch(), ["question": .string("x"), "subject": .reference(missing)])
        }
    }
}
