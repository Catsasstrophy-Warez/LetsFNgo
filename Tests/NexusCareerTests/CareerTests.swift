import Foundation
import NexusCareer
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks
import Testing

enum CareerFixtures {
    static let today = CareerCalendar.day(2026, 9, 28)

    static let resume = """
        {
          "basics": {"name": "Ana Silva", "label": "Controls engineer"},
          "work": [
            {"name": "Harbor Automation", "position": "Senior Controls Engineer", "startDate": "2022-03",
             "summary": "Leads PLC commissioning.", "highlights": ["Cut commissioning time by 30%"]},
            {"name": "Tejo Systems", "position": "Controls Engineer", "startDate": "2018-06-01", "endDate": "2022-02-28"}
          ],
          "education": [{"institution": "IST", "area": "Electrical Engineering"}],
          "skills": [{"name": "Languages", "keywords": ["Swift", "Structured Text"]}, {"name": "Commissioning"}],
          "certificates": [
            {"name": "Functional Safety Engineer", "date": "2023-05-01", "issuer": "TÜV Rheinland", "expiryDate": "2026-11-01"},
            {"name": "First Aid", "date": "2022-01-01", "issuer": "Red Cross", "expiryDate": "2025-01-01"},
            {"name": "PMP", "date": "2021", "issuer": "PMI"}
          ],
          "projects": [
            {"name": "Line 4 retrofit", "description": "Replaced relay logic with a safety PLC", "startDate": "2023-01",
             "entity": "Harbor Automation", "keywords": ["Structured Text", "Functional safety"]},
            {"name": "Home weather station", "keywords": ["Swift"]}
          ]
        }
        """

    static func make() throws -> (NexusStore, ManualClock) {
        let clock = ManualClock(today)
        return (try NexusStore(.inMemory, clock: clock), clock)
    }
}

@Suite struct CareerImportTests {
    let person = Origin.user(id: "ana")

    @Test func importsRolesSkillsCertificationsAndProjects() throws {
        let (store, clock) = try CareerFixtures.make()
        let importer = ResumeImporter(store: store, clock: clock)
        let result = try importer.importJSONResume(Data(CareerFixtures.resume.utf8), named: "resume.json", by: person)
        #expect(result.roles.count == 2 && result.certifications.count == 3 && result.projects == 2)
        #expect(result.skills == 4, "Swift, Structured Text, Commissioning, Functional safety")
        let career = CareerRuntime(store: store, clock: clock)
        #expect(try career.roles().map(\.position) == ["Senior Controls Engineer", "Controls Engineer"], "Current role first")
        let harbor = try #require(result.roles.first)
        #expect(harbor.record.provenance.truth == .recorded && harbor.record.provenance.origin == .importer(source: result.document.id))
        #expect(harbor.start == CareerCalendar.day(2022, 3) && harbor.end == nil && harbor.highlights.count == 1)
        #expect(try career.employer(of: harbor.id)?.title == "Harbor Automation")
        #expect(try career.workProjects(of: harbor.id).map(\.title) == ["Line 4 retrofit"], "Matched by entity and date")
        #expect(try store.objects(ofType: .organization).count == 5, "Two employers and three issuers")

        let again = try importer.importJSONResume(Data(CareerFixtures.resume.utf8), named: "resume.json", by: person)
        #expect(again.roles.isEmpty && again.certifications.isEmpty && again.projects == 0 && again.skills == 0 && again.skipped == 7)
        #expect(throws: CareerError.self) { try importer.importJSONResume(Data("[1,2]".utf8), named: "x.json", by: person) }
    }

    @Test func expiringCertificationsBecomeRenewalTasks() throws {
        let (store, clock) = try CareerFixtures.make()
        try ResumeImporter(store: store, clock: clock).importJSONResume(Data(CareerFixtures.resume.utf8), named: "resume.json", by: person)
        let career = CareerRuntime(store: store, clock: clock)
        let safety = try #require(try career.certifications().first { $0.name == "Functional Safety Engineer" })
        #expect(safety.standing(on: CareerFixtures.today) == .expiringSoon(daysLeft: 34))
        #expect(try career.certifications().first { $0.name == "PMP" }?.standing(on: CareerFixtures.today) == .noExpiry)

        let tasks = try career.scheduleRenewals(asOf: CareerFixtures.today, by: .system)
        #expect(Set(tasks.map(\.title)) == ["Renew Functional Safety Engineer", "Renew First Aid"])
        #expect(tasks.first { $0.title == "Renew Functional Safety Engineer" }?.dueAt == CareerCalendar.day(2026, 11, 1))
        #expect(try career.scheduleRenewals(asOf: CareerFixtures.today, by: .system).isEmpty, "One renewal task per certification")

        clock.advance(by: 60)
        let renewed = try career.renew(safety.id, expires: CareerCalendar.day(2029, 11, 1), by: person)
        #expect(renewed.standing(on: CareerFixtures.today) == .valid(daysLeft: 1_130))
        #expect(renewed.record.truth(of: CareerKey.expires) == .observed)
        let task = try TaskRuntime(store: store).task(try #require(tasks.first { $0.title.contains("Safety") }).id)
        #expect(task.status == .done, "Renewing closes the renewal task")
    }

    @Test func agentRenewalsAreDrafts() throws {
        let (store, clock) = try CareerFixtures.make()
        let career = CareerRuntime(store: store, clock: clock)
        try career.addCertification("CompTIA A+", issuer: "CompTIA", issued: nil, expires: CareerCalendar.day(2026, 10, 15), by: person)
        let tasks = try career.scheduleRenewals(asOf: CareerFixtures.today, by: .agent(id: "project", run: nil))
        #expect(tasks.count == 1 && tasks[0].isDraft)
    }

    @Test func applicationPipelineRecordsEachMove() throws {
        let (store, clock) = try CareerFixtures.make()
        let career = CareerRuntime(store: store, clock: clock)
        let application = try career.addApplication(position: "Lead Controls Engineer", at: "Delta Robotics", by: person)
        #expect(application.status == .saved && application.title == "Lead Controls Engineer at Delta Robotics")
        try career.move(application.id, to: .applied, by: person)
        #expect(try career.application(application.id).appliedOn == CareerFixtures.today)
        try career.move(application.id, to: .interviewing, note: "Skipped the screen", by: person)
        #expect(throws: CareerError.invalidTransition(application.id, from: .interviewing, to: .accepted)) {
            try career.move(application.id, to: .accepted, by: person)
        }
        #expect(throws: CareerError.invalidTransition(application.id, from: .interviewing, to: .applied)) {
            try career.move(application.id, to: .applied, by: person)
        }
        try career.move(application.id, to: .offer, by: person)
        let accepted = try career.move(application.id, to: .accepted, by: person)
        #expect(accepted.status == .accepted && accepted.record.truth(of: CareerKey.status) == .observed)
        #expect(!ApplicationStatus.accepted.canMove(to: .withdrawn), "Closed is final")

        let history = try career.history(of: application.id)
        #expect(history.map { $0.payload["to"] } == [.string("applied"), .string("interviewing"), .string("offer"), .string("accepted")])
        #expect(history[1].payload["note"] == .string("Skipped the screen"))
        let delta = try #require(try store.objects(ofType: .organization).first { $0.title == "Delta Robotics" })
        #expect(try store.events(about: delta.id).filter { $0.kind == .applicationStatusChanged }.count == 4)
        #expect(try career.pipeline().map(\.status) == [.accepted])
    }
}

@Suite struct ResumeTests {
    let person = Origin.user(id: "ana")
    let agent = Origin.agent(id: "writing", run: nil)

    @Test func resumeUsesOnlyStatedFactsAndStaysDerived() throws {
        let (store, clock) = try CareerFixtures.make()
        try ResumeImporter(store: store, clock: clock).importJSONResume(Data(CareerFixtures.resume.utf8), named: "resume.json", by: person)
        let career = CareerRuntime(store: store, clock: clock)
        let harbor = try #require(try career.roles().first)
        let suggestion = try career.linkSkill("Leadership", to: harbor.id, by: agent)
        #expect(suggestion.provenance.truth == .agentInterpretation)
        try career.linkSkill("Python", to: harbor.id, by: person)

        let builder = ResumeBuilder(store: store, clock: clock)
        let draft = try builder.draft(name: "Ana Silva", headline: "Controls engineer", asOf: CareerFixtures.today)
        #expect(draft.markdown.hasPrefix("# Ana Silva\n\nControls engineer\n\n## Experience"))
        #expect(draft.markdown.contains("### Senior Controls Engineer — Harbor Automation\n*Mar 2022 – present*"))
        #expect(draft.markdown.contains("*Jun 2018 – Feb 2022*"))
        #expect(draft.markdown.contains("- Project: **Line 4 retrofit** — Replaced relay logic with a safety PLC"))
        #expect(draft.markdown.contains("Skills: Python"))
        #expect(!draft.markdown.contains("Leadership"), "An agent's suggestion is not a fact on the résumé")
        #expect(draft.markdown.contains("## Projects\n\n- **Home weather station** (Swift)"))
        #expect(draft.markdown.contains("- Functional Safety Engineer — TÜV Rheinland (issued May 2023, valid until Nov 2026)"))
        #expect(!draft.markdown.contains("First Aid"), "Expired certifications are left out")
        #expect(draft.sources.contains(harbor.id))

        let artifact = try builder.generate(name: "Ana Silva", asOf: CareerFixtures.today, by: person)
        #expect(artifact.type == .artifact && artifact.provenance.truth == .derived && artifact.provenance.dependencies.contains(harbor.id))

        // A person confirms the suggestion: it becomes observed and appears.
        clock.advance(by: 60)
        let confirmed = try career.linkSkill("Leadership", to: harbor.id, by: person)
        #expect(confirmed.provenance.truth == .observed)
        #expect(try career.skills(of: harbor.id).map(\.skill.title) == ["Leadership", "Python"])
        let regenerated = try builder.generate(name: "Ana Silva", asOf: CareerFixtures.today, by: person)
        #expect(regenerated.id == artifact.id, "Regenerating updates the same artifact")
        if case .string(let body)? = regenerated.attributes[CareerKey.body]?.value {
            #expect(body.contains("Skills: Leadership, Python"))
        } else {
            Issue.record("résumé body missing")
        }
    }
}
