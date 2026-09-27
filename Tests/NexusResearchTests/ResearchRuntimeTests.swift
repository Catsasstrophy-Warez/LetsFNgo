import Foundation
import NexusAI
import NexusCore
import NexusDocuments
import NexusInvestigation
import NexusModel
import NexusPersistence
import Testing

@testable import NexusResearch

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let researcher = Origin.agent(id: "research", run: nil)

private let datasheetText = """
    # LT-200 level transmitter

    ## Power

    The LT-200 transmitter requires a minimum supply voltage of 10.5 V at the terminals.

    Loop current is 4-20 mA with HART superimposed on the loop current.

    ## Firmware

    Firmware 7.x adds extended supply voltage diagnostics for model LT-200.
    """

private let forumText = """
    Someone said the LT-200 transmitter requires a minimum supply voltage of 9 V at the terminals.

    In my experience HART is not superimposed on the loop current.
    """

private let appNoteText = """
    The LT-300 transmitter requires a minimum supply voltage of 12 V at the terminals for model LT-300.
    """

private let question = "What is the minimum supply voltage for the LT-200 transmitter?"

/// A library of three fixture documents and one configured transmitter.
private struct Library {
    let clock = ManualClock(t0)
    let store: NexusStore
    let documents: DocumentLibrary
    let datasheet: ObjectID
    let forum: ObjectID
    let appNote: ObjectID
    let transmitter: ObjectID

    init() throws {
        store = try NexusStore(.inMemory, clock: clock)
        documents = DocumentLibrary(store: store, clock: clock)
        datasheet = try documents.ingest(Data(datasheetText.utf8), title: "LT-200 datasheet", mediaType: "text/markdown", by: tech).document.id
        forum = try documents.ingest(Data(forumText.utf8), title: "Forum thread: LT-200 power", mediaType: "text/plain", by: tech).document.id
        appNote = try documents.ingest(Data(appNoteText.utf8), title: "Application note: LT-300", mediaType: "text/plain", by: tech).document.id
        transmitter = try store.create(
            ObjectRecord(
                type: .sensor, title: "LT-101 level transmitter",
                attributes: ["model": Attribute(.string("LT-200")), "firmware": Attribute(.string("7.2"))],
                provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
            )
        ).id
    }

    func runtime(_ model: (any LanguageModelProvider)? = nil) -> ResearchRuntime {
        ResearchRuntime(store: store, clock: clock, model: model)
    }
}

@Suite struct ResearchRuntimeTests {
    @Test func deterministicPipelineCitesClassifiesAndLinksContradictions() throws {
        let library = try Library()
        let result = try library.runtime().researchLocally(ResearchQuestion(question), by: researcher)

        // Discovery and classification.
        let classes = Dictionary(uniqueKeysWithValues: result.sources.map { ($0.document, $0.classification.sourceClass) })
        #expect(classes[library.datasheet] == .primary)
        #expect(classes[library.forum] == .community)
        #expect(classes[library.appNote] == .secondary)

        // Evidence: new claims quote their passage verbatim and cite it; the primary source comes first.
        #expect(result.evidence.first?.sourceClass == .primary)
        #expect(result.evidence.map(\.label) == result.evidence.indices.map { "C\($0 + 1)" })
        for evidence in result.evidence where evidence.isNew {
            let claim = try #require(try library.store.claim(evidence.claim))
            let passage = try library.documents.passage(try #require(evidence.passage))
            #expect(claim.provenance.truth == .claimed)
            #expect(claim.passages == [passage.text])
            #expect(try library.documents.sourceText(of: passage) == passage.text)
            #expect(passage.text.contains(claim.statement))
            #expect(try library.store.relationships(from: claim.id, kind: .cites).map(\.to) == [passage.id])
        }

        // 10.5 V (datasheet) vs 9 V (forum) contradict; the LT-300 note is a different model.
        let high = try #require(result.evidence.first { $0.statement.contains("10.5 V") })
        let low = try #require(result.evidence.first { $0.statement.contains("9 V") })
        let other = try #require(result.evidence.first { $0.statement.contains("LT-300") })
        let pair = try #require(result.contradictions.first { Set([$0.first, $0.second]) == Set([high.claim, low.claim]) })
        #expect(pair.reason == .numericRange)
        #expect(!result.contradictions.contains { [$0.first, $0.second].contains(other.claim) })
        #expect(try library.store.relationships(from: high.claim, kind: .contradicts).map(\.to) == [low.claim])
        #expect(try library.store.relationships(from: low.claim, kind: .contradicts).map(\.to) == [high.claim])
        let stored = try [#require(try library.store.claim(high.claim)), #require(try library.store.claim(low.claim))]
        let counterevidence = Set(stored.flatMap(\.counterevidence))
        #expect(counterevidence.contains(high.claim) || counterevidence.contains(low.claim))
        #expect(stored.allSatisfy { !$0.counterevidence.isEmpty })

        // The report is an interpretation citing every claim.
        let report = try #require(try library.store.object(result.report))
        #expect(report.type == .report && report.provenance.truth == .agentInterpretation)
        #expect(Set(try library.store.relationships(from: report.id, kind: .cites).map(\.to)) == Set(result.claims))
        #expect(result.summary.contains("[C1]") && result.summary.contains("Contradictions:"))
        #expect(report.attributes["synthesis"]?.value == .string("deterministic"))
    }

    @Test func claimsAreMatchedToTheObjectsConfiguration() throws {
        let library = try Library()
        let result = try library.runtime().researchLocally(
            ResearchQuestion("Which firmware adds supply voltage diagnostics for the transmitter model?", subject: library.transmitter),
            by: researcher
        )
        let firmware = try #require(result.evidence.first { $0.statement.contains("Firmware 7.x") })
        #expect(firmware.applicability == "firmware 7.x, model LT-200")
        let verdicts = Dictionary(uniqueKeysWithValues: result.applicability.map { ($0.claim, $0.verdict) })
        #expect(verdicts[firmware.claim] == .applies)
        #expect(try library.store.relationships(from: firmware.claim, kind: .appliesTo).map(\.to) == [library.transmitter])
        if let other = result.evidence.first(where: { $0.statement.contains("LT-300") }) {
            #expect(verdicts[other.claim] == .conflicts)
        }
    }

    @Test func existingClaimsAreReusedNotDuplicated() throws {
        let library = try Library()
        let passage = try #require(try library.documents.passages(of: library.datasheet).first { $0.text.contains("10.5 V") })
        let existing = try library.documents.extractClaim(
            from: passage.id, statement: "The LT-200 transmitter requires a minimum supply voltage of 10.5 V at the terminals.",
            sourceClass: .primary, by: tech
        )
        let result = try library.runtime().researchLocally(ResearchQuestion(question), by: researcher)
        let matching = result.evidence.filter { $0.statement.contains("10.5 V") }
        #expect(matching.count == 1)
        #expect(matching.first?.claim == existing.id && matching.first?.isNew == false)
        // The new forum claim lists the existing claim it contradicts.
        let forum = try #require(result.evidence.first { $0.statement.contains("9 V") })
        #expect(try library.store.claim(forum.claim)?.counterevidence.contains(existing.id) == true)
    }

    @Test func modelAssistsPlanningAndSynthesis() async throws {
        let library = try Library()
        let model = ScriptedModel { request in
            if request.responseSchema != nil {
                return ModelResponse(
                    message: ChatMessage(role: .assistant, text: #"{"subQuestions": ["What supply voltage does the LT-200 transmitter need?"]}"#),
                    stopReason: .endTurn
                )
            }
            return ModelResponse(
                message: ChatMessage(role: .assistant, text: "The datasheet gives 10.5 V [C1]; a forum post disagrees [C2]."), stopReason: .endTurn
            )
        }
        let result = try await library.runtime(model).research(ResearchQuestion(question), by: researcher)
        #expect(result.plan.method == "model: scripted-1")
        #expect(result.plan.subQuestions == ["What supply voltage does the LT-200 transmitter need?"])
        #expect(result.synthesis == "model: scripted-1")
        #expect(result.summary.hasPrefix("The datasheet gives 10.5 V [C1]"))
        #expect(model.requests.count == 2)
    }

    @Test func unusableModelAnswersFallBackToDeterministicStages() async throws {
        let library = try Library()
        let model = ScriptedModel { request in
            if request.responseSchema != nil {
                return ModelResponse(message: ChatMessage(role: .assistant, text: "Sure! Here are some ideas."), stopReason: .endTurn)
            }
            return ModelResponse(message: ChatMessage(role: .assistant, text: "It needs 14 V [C1] per [C99]."), stopReason: .endTurn)
        }
        let result = try await library.runtime(model).research(ResearchQuestion(question), by: researcher)
        #expect(result.plan.method == "deterministic")
        #expect(result.synthesis.hasPrefix("deterministic (model: scripted-1 summary rejected"))
        #expect(result.summary.hasPrefix("Question:"))

        let invented = ScriptedModel { request in
            if request.responseSchema != nil { throw AIError.scriptExhausted }
            return ModelResponse(message: ChatMessage(role: .assistant, text: "It needs 14 V [C1]."), stopReason: .endTurn)
        }
        let second = try await library.runtime(invented).research(ResearchQuestion(question), by: researcher)
        #expect(second.synthesis.contains("values not in the claims"))
    }

    @Test func questionsWithNoSourcesStillGetAReport() throws {
        let library = try Library()
        let result = try library.runtime().researchLocally(ResearchQuestion("How do I bake sourdough bread?"), by: researcher)
        #expect(result.evidence.isEmpty)
        #expect(result.summary.contains("No local sources"))
        #expect(try library.store.object(result.report) != nil)
        #expect(throws: ResearchError.emptyQuestion) { try library.runtime().researchLocally(ResearchQuestion("  "), by: researcher) }
        let missing = ObjectID.make()
        #expect(throws: ResearchError.subjectNotFound(missing)) {
            try library.runtime().researchLocally(ResearchQuestion(question, subject: missing), by: researcher)
        }
    }

    @Test func projectsContainTheirReports() throws {
        let library = try Library()
        let project = try library.store.create(
            ObjectRecord(
                type: .project, title: "Level loop", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
            )
        ).id
        let result = try library.runtime().researchLocally(ResearchQuestion(question, project: project), by: researcher)
        #expect(try library.store.relationships(from: project, kind: .contains).contains { $0.to == result.report })
    }
}

@Suite struct ResearchStageTests {
    @Test func plansSplitCompoundQuestions() {
        let plan = ResearchRuntime.plan("What supply voltage does the LT-200 need and which firmware adds diagnostics? Is HART supported")
        #expect(plan.subQuestions == ["What supply voltage does the LT-200 need?", "which firmware adds diagnostics?", "Is HART supported?"])
        #expect(plan.terms.contains("lt-200") && plan.terms.contains("firmware") && !plan.terms.contains("the"))
    }

    @Test func contradictionsNeedTheSameSubject() {
        let conflict = ContradictionDetector.conflict(
            between: "The loop current range is 4-20 mA.", and: "The loop current range is 0 to 3 mA."
        )
        #expect(conflict?.reason == .numericRange)
        #expect(conflict?.detail == "4–20 mA vs 0–3 mA")
        #expect(ContradictionDetector.conflict(between: "The loop current range is 4-20 mA.", and: "The loop current range is 10 to 30 mA.") == nil)
        #expect(ContradictionDetector.conflict(between: "Supply voltage is at least 10.5 V.", and: "Supply voltage is 24 V.") == nil)
        #expect(ContradictionDetector.conflict(between: "Supply voltage is at least 10.5 V.", and: "Supply voltage is up to 9 V.")?.reason == .numericRange)
        #expect(ContradictionDetector.conflict(between: "The pump runs at 1450 rpm.", and: "The valve is 30 % open.") == nil)
        #expect(
            ContradictionDetector.conflict(between: "The LT-200 needs a supply of 10.5 V.", and: "The LT-300 needs a supply of 12 V.") == nil,
            "Different parts are different subjects"
        )

        let negation = ContradictionDetector.conflict(
            between: "HART is superimposed on the loop current.", and: "HART is not superimposed on the loop current."
        )
        #expect(negation?.reason == .negation)
        #expect(ContradictionDetector.conflict(between: "HART is not used here.", and: "The valve is not open.") == nil)
    }

    @Test func sourcesAreClassifiedByAttributeThenCues() {
        func document(_ title: String, _ attributes: [String: Attribute] = [:]) -> ObjectRecord {
            ObjectRecord(type: .document, title: title, attributes: attributes, provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0))
        }
        #expect(SourceClassifier.classify(document("LT-200 datasheet")).sourceClass == .primary)
        #expect(SourceClassifier.classify(document("Forum thread")).sourceClass == .community)
        #expect(SourceClassifier.classify(document("Instrumentation handbook")).sourceClass == .secondary)
        #expect(SourceClassifier.classify(document("Glossary of terms")).sourceClass == .tertiary)
        #expect(SourceClassifier.classify(document("notes.txt")).sourceClass == .unknown)
        let tagged = SourceClassifier.classify(document("Forum thread", ["sourceClass": Attribute(.string("primary"))]))
        #expect(tagged == SourceClassification(sourceClass: .primary, basis: "attribute"))
    }

    @Test func applicabilityIsMatchedAgainstAttributes() {
        let object = ObjectRecord(
            type: .sensor, title: "LT-101", attributes: ["model": Attribute(.string("LT-200")), "firmwareVersion": Attribute(.string("7.2"))],
            provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        )
        #expect(ConfigurationMatcher.match(nil, against: object).verdict == .general)
        #expect(ConfigurationMatcher.match("model LT-200", against: object).verdict == .applies)
        #expect(ConfigurationMatcher.match("firmware 7.x", against: object).verdict == .applies)
        #expect(ConfigurationMatcher.match("firmware 8.x, model LT-200", against: object).verdict == .conflicts)
        #expect(ConfigurationMatcher.match("revision C", against: object).verdict == .unknown)
        #expect(ConfigurationMatcher.applicability(in: "Applies to model LT-200 with firmware 7.x only.") == "model LT-200, firmware 7.x")
        #expect(ConfigurationMatcher.applicability(in: "The model of the pump matters.") == nil)
        #expect(!ConfigurationMatcher.compatible("model LT-200", "model LT-300"))
        #expect(ConfigurationMatcher.compatible("firmware 7.x", "firmware 7.2"))
    }

    @Test func sentencesKeepDecimals() {
        #expect(ResearchText.sentences("Supply is 10.5 V. Current is 4-20 mA!\nDone") == ["Supply is 10.5 V.", "Current is 4-20 mA!", "Done"])
    }
}
