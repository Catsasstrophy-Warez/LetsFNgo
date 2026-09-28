import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation
import Testing

@testable import NexusLearning

private let tech = Origin.user(id: "tech-7")
private let apprentice = Origin.user(id: "apprentice-3")

@Suite struct TutorTests {
    @Test func tutorNeverRevealsTheAnswerEarly() throws {
        let store = try NexusStore(.inMemory)
        let clock = ManualClock(fixtureStart)
        let closed = try ChargingCase.make(store: store, clock: clock, tech: tech)
        let learning = LearningRuntime(store: store, clock: clock)
        let scenario = try learning.makeScenario(from: closed.investigation, by: tech)
        let tutor = try Tutor(learning: learning, scenario: scenario.id, learner: apprentice)

        #expect(throws: TutorError.answerLocked(attempts: 0, required: 3)) { try tutor.revealAnswer() }

        // Progressive hints: question, pointer to the discriminating test, then readings.
        let question = try tutor.hint(testsRun: [])
        let pointer = try tutor.hint(testsRun: [])
        let readings = try tutor.hint(testsRun: [])
        #expect([question.level, pointer.level, readings.level] == [.question, .pointer, .readings])
        #expect(question.test == nil)
        #expect(pointer.test == scenario.expertPath[0] && readings.test == scenario.expertPath[0])
        #expect(readings.healthyReading != nil && readings.candidateBands.count >= 2)
        // Past the first discriminating test, the pointer moves along the expert path.
        let later = try tutor.hint(testsRun: [scenario.expertPath[0]])
        #expect(later.level == .readings && later.test == scenario.expertPath[1])
        let done = try tutor.hint(testsRun: scenario.expertPath)
        #expect(done.test == nil)

        for hint in [question, pointer, readings, later, done] {
            #expect(!hint.text.contains(scenario.cause), "Hint names the cause: \(hint.text)")
            #expect(!hint.text.contains("alternator"), "Hint names the part: \(hint.text)")
            #expect(hint.provenance.truth == .agentInterpretation && hint.provenance.origin == TutorPolicy.agent)
        }
        let stored = try tutor.hints()
        #expect(stored.count == 5 && stored.allSatisfy { $0.provenance.truth == .agentInterpretation })

        // Wrong attempts keep the answer locked until the threshold.
        let wrong = scenario.choices.first { $0 != scenario.cause }!
        let first = try tutor.submit(testsRun: [ChargingTest.restingVoltage.title], diagnosis: wrong)
        #expect(!first.correctDiagnosis)
        #expect(try tutor.attempts().first?.attributes["hintsUsed"]?.value == .int(5), "Hints are charged to the next attempt")
        #expect(throws: TutorError.answerLocked(attempts: 1, required: 3)) { try tutor.revealAnswer() }
        try tutor.submit(testsRun: [], diagnosis: wrong)
        #expect(throws: TutorError.answerLocked(attempts: 2, required: 3)) { try tutor.revealAnswer() }
        try tutor.submit(testsRun: [], diagnosis: wrong)
        let answer = try tutor.revealAnswer()
        #expect(answer.cause == scenario.cause && answer.expertPath == scenario.expertPath)
        #expect(answer.provenance.truth == .agentInterpretation)

        // Another learner who gets it right may see the key at once; their hint count is their own.
        let other = try Tutor(learning: learning, scenario: scenario.id, learner: .user(id: "journeyman"))
        #expect(try other.hints().isEmpty)
        #expect(try other.hint(testsRun: []).level == .question)
        let right = try other.submit(testsRun: scenario.expertPath, diagnosis: scenario.cause)
        #expect(right.score == 95, "One hint costs 5 points")
        #expect(try other.revealAnswer().cause == scenario.cause)
    }

    @Test func progressFollowsTheExpertPath() throws {
        let store = try NexusStore(.inMemory)
        let clock = ManualClock(fixtureStart)
        let closed = try ChargingCase.make(store: store, clock: clock, tech: tech)
        let learning = LearningRuntime(store: store, clock: clock)
        let scenario = try learning.makeScenario(from: closed.investigation, by: tech)
        let tutor = try Tutor(learning: learning, scenario: scenario.id, learner: apprentice)
        let resting = ChargingTest.restingVoltage.title
        let progress = tutor.progress(testsRun: [resting, scenario.expertPath[1]])
        #expect(progress.covered == [scenario.expertPath[1]] && progress.remaining == [scenario.expertPath[0]])
        #expect(progress.offPath == [resting] && progress.fraction == 0.5 && progress.next == scenario.expertPath[0])
    }
}

@Suite struct SpacedReviewTests {
    func intervals(_ grades: [Int]) throws -> (days: [Int], easiness: [Double], final: SM2State) {
        var state = SM2State(due: fixtureStart)
        var days: [Int] = []
        var easiness: [Double] = []
        var at = fixtureStart
        for grade in grades {
            state = try state.reviewed(grade: grade, at: at)
            days.append(state.intervalDays)
            easiness.append(state.easiness)
            #expect(state.due == at.addingTimeInterval(Double(state.intervalDays) * 86_400))
            at = state.due
        }
        return (days, easiness, state)
    }

    @Test func sm2IntervalsAreCorrect() throws {
        let perfect = try intervals([5, 5, 5, 5])
        #expect(perfect.days == [1, 6, 16, 45])
        #expect(zip(perfect.easiness, [2.6, 2.7, 2.8, 2.9]).allSatisfy { abs($0 - $1) < 1e-9 })

        let good = try intervals([4, 4, 4, 4])
        #expect(good.days == [1, 6, 15, 38] && good.easiness.allSatisfy { abs($0 - 2.5) < 1e-9 })

        // Hard recalls shrink EF; a lapse restarts the interval; EF never drops below 1.3.
        let hard = try intervals([3, 3, 3, 1, 0, 4])
        #expect(hard.days == [1, 6, 13, 1, 1, 1])
        #expect(zip(hard.easiness, [2.36, 2.22, 2.08, 1.54, 1.3, 1.3]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(hard.final.lapses == 2 && hard.final.repetitions == 1)

        #expect(throws: ReviewError.invalidGrade(6)) { try SM2State(due: fixtureStart).reviewed(grade: 6, at: fixtureStart) }
        #expect(throws: ReviewError.invalidGrade(-1)) { try SM2State(due: fixtureStart).reviewed(grade: -1, at: fixtureStart) }
    }

    @Test func cardsSurviveAReloadWithTheirCitations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ManualClock(fixtureStart)
        var store = try NexusStore(.file(url), clock: clock)
        let closed = try ChargingCase.make(store: store, clock: clock, tech: tech)
        func recorded() -> Provenance { Provenance(origin: tech, truth: .recorded, timestamp: clock.now()) }
        let project = try store.create(ObjectRecord(type: .project, title: "Honda charging", provenance: recorded())).id
        let manual = try store.create(ObjectRecord(type: .document, title: "Service manual §12", provenance: recorded())).id
        let claim = Claim(
            statement: "Charging voltage below 13.5 V at 2000 rpm means the alternator is not regulating", sources: [manual],
            passages: ["Specified charging voltage: 13.5–14.8 V at 2000 rpm."], sourceClass: .primary,
            provenance: Provenance(origin: tech, truth: .claimed, timestamp: clock.now())
        )
        try store.add(claim)
        for member in [closed.investigation, claim.id, closed.procedure, closed.fault] {
            try store.relate(Relationship(kind: .contains, from: project, to: member, provenance: recorded()))
        }

        let reviews = ReviewRuntime(store: store, clock: clock)
        let cards = try reviews.generateCards(forProject: project, by: tech)
        let kinds = Dictionary(grouping: cards, by: \.kind).mapValues(\.count)
        #expect(kinds == [.cause: 1, .evidence: 2, .claim: 1, .procedureStep: 4, .dtcMeaning: 1])
        let dtc = try #require(cards.first { $0.kind == .dtcMeaning })
        #expect(dtc.front == "What does trouble code P0562 mean?" && dtc.back == "System voltage low" && dtc.sources == [closed.fault])
        let claimCard = try #require(cards.first { $0.kind == .claim })
        #expect(claimCard.sources == [claim.id, manual] && claimCard.back.contains("Service manual §12"))
        #expect(!claimCard.front.contains("not regulating"), "The cloze hides the second half")
        let cause = try #require(cards.first { $0.kind == .cause })
        #expect(cause.back.hasPrefix(ChargingFaultKind.failingAlternator.statement) && cause.sources == [closed.investigation, closed.cause.id])
        let steps = cards.filter { $0.kind == .procedureStep }
        #expect(steps.map(\.back) == ["Disconnect battery negative", "Replace alternator", "Torque B+ nut to 9 N·m", "Verify charging voltage at 2000 rpm"])
        #expect(cards.allSatisfy { $0.provenance.truth == .derived && $0.provenance.dependencies == $0.sources })

        // Generating again reuses the cards.
        #expect(try reviews.generateCards(forProject: project, by: tech).map(\.id) == cards.map(\.id))
        #expect(try store.objects(ofType: .reviewCard).count == cards.count)

        // New cards are due at once, per project.
        #expect(try reviews.dueCards(in: project).count == cards.count)
        #expect(try reviews.dueQueues().keys.sorted() == [project])

        clock.advance(by: 60)
        let reviewed = try reviews.review(dtc.id, grade: 5, by: apprentice)
        #expect(reviewed.schedule.intervalDays == 1 && reviewed.schedule.repetitions == 1)
        #expect(!(try reviews.dueCards(in: project).contains { $0.id == dtc.id }))
        #expect(try reviews.dueCards(in: project, at: clock.now().addingTimeInterval(86_400)).contains { $0.id == dtc.id })
        #expect(throws: ReviewError.invalidGrade(7)) { try reviews.review(dtc.id, grade: 7, by: apprentice) }

        store = try NexusStore(.file(url), clock: clock)
        let reloaded = ReviewRuntime(store: store, clock: clock)
        #expect(try reloaded.card(dtc.id) == reviewed)
        for card in cards {
            let again = try reloaded.card(card.id)
            #expect(again.sources == card.sources && again.front == card.front && again.back == card.back)
            #expect(try store.relationships(from: card.id, kind: .cites).map(\.to).sorted() == card.sources.sorted())
        }
        let record = try #require(try store.object(dtc.id))
        #expect(record.truth(of: "intervalDays") == .derived)
        let events = try reloaded.reviews(of: dtc.id)
        #expect(events.count == 1 && events[0].payload["grade"] == .int(5) && events[0].provenance.truth == .recorded)
        #expect(record.attributes["intervalDays"]?.provenance?.dependencies == [events[0].id])
    }
}

@Suite struct LearnerRecordTests {
    @Test func masteryUpdates() throws {
        let store = try NexusStore(.inMemory)
        let clock = ManualClock(fixtureStart)
        let records = LearnerRecords(store: store, clock: clock)
        let source = try store.create(
            ObjectRecord(type: .task, title: "Practice", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now()))
        ).id
        var mastery = try records.recordPractice(["ohms law": 1], source: source, learner: apprentice, method: "test", summary: "1")
        #expect(abs(mastery["ohms law"]!.mastery - 0.35) < 1e-12)
        mastery = try records.recordPractice(["ohms law": 1], source: source, learner: apprentice, method: "test", summary: "2")
        #expect(abs(mastery["ohms law"]!.mastery - 0.5775) < 1e-12)
        mastery = try records.recordPractice(["ohms law": 0], source: source, learner: apprentice, method: "test", summary: "3")
        #expect(abs(mastery["ohms law"]!.mastery - 0.375375) < 1e-12 && mastery["ohms law"]!.attempts == 3)
        #expect(try records.mastery(of: apprentice) == mastery)
        let record = try records.record(for: apprentice)
        #expect(record.truth(of: "mastery") == .derived)
        #expect(try store.events(about: record.id).filter { $0.kind == .practiceRecorded }.count == 3)
        #expect(try records.mastery(of: tech).isEmpty, "Each learner has their own record")
    }

    @Test func attemptsAndReviewsFeedTheNextBestThing() throws {
        let store = try NexusStore(.inMemory)
        let clock = ManualClock(fixtureStart)
        let closed = try ChargingCase.make(store: store, clock: clock, tech: tech)
        let learning = LearningRuntime(store: store, clock: clock)
        let scenario = try learning.makeScenario(from: closed.investigation, by: tech)
        let records = LearnerRecords(store: store, clock: clock)
        let reviews = ReviewRuntime(store: store, clock: clock)
        let project = try store.create(
            ObjectRecord(type: .project, title: "Garage", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now()))
        ).id
        try store.relate(
            Relationship(
                kind: .contains, from: project, to: closed.fault, provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now())))
        try store.relate(
            Relationship(
                kind: .contains, from: project, to: closed.investigation,
                provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now())))

        // Nothing practised: the scenario on the unpractised topic.
        guard case .scenario(let first, let topic, let level, _) = try records.nextBestThing(for: apprentice, in: project) else {
            Issue.record("Expected a scenario")
            return
        }
        #expect(first == scenario.id && topic == "chargingSystem" && level == 0)

        // Due cards come first.
        let cards = try reviews.generateCards(from: [closed.fault], in: project, by: tech)
        guard case .review(let due, _) = try records.nextBestThing(for: apprentice, in: project) else {
            Issue.record("Expected a review")
            return
        }
        #expect(due == cards.map(\.id))
        try reviews.review(cards[0].id, grade: 4, by: apprentice)
        #expect(abs(try records.mastery(of: apprentice)["cards/dtcMeaning"]!.mastery - 0.35 * 0.8) < 1e-12)

        // A scenario attempt scores the topic and its skills.
        let tutor = try Tutor(learning: learning, scenario: scenario.id, learner: apprentice)
        try tutor.submit(testsRun: scenario.expertPath, diagnosis: scenario.cause)
        var mastery = try records.mastery(of: apprentice)
        #expect(abs(mastery["chargingSystem"]!.mastery - 0.35) < 1e-12)
        #expect(mastery["chargingSystem/diagnosis"]!.lastScore == 1 && mastery["chargingSystem/safety"]!.lastScore == 1)
        guard case .scenario(_, _, let after, let reason) = try records.nextBestThing(for: apprentice, in: project) else {
            Issue.record("Expected a scenario")
            return
        }
        #expect(abs(after - 0.35) < 1e-12 && reason.contains("weakest"))

        // Mastered and nothing due: up to date until the card comes back.
        for _ in 0..<4 {
            try tutor.submit(testsRun: scenario.expertPath, diagnosis: scenario.cause)
        }
        mastery = try records.mastery(of: apprentice)
        #expect(mastery["chargingSystem"]!.mastery >= LearnerRecords.masteredAt)
        guard case .upToDate(let next, _) = try records.nextBestThing(for: apprentice, in: project) else {
            Issue.record("Expected up to date")
            return
        }
        #expect(next == (try reviews.card(cards[0].id)).schedule.due)
    }
}
