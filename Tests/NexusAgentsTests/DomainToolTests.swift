import Foundation
import NexusAI
import NexusArchitecture
import NexusCRM
import NexusCareer
import NexusCore
import NexusModel
import NexusPersistence
import NexusTravel
import Testing

@testable import NexusAgents

@Suite struct DomainToolTests {
    let person = Origin.user(id: "sam")

    @Test func toolsAreRegisteredReadOnlyAndOnTheProjectAgent() {
        let registered = Set(WorldTools.all.map(\.spec.name))
        #expect(DomainTools.names.isSubset(of: registered))
        #expect(DomainTools.all.allSatisfy { $0.spec.permission == .observe }, "Domain tools only read")
        #expect(DomainTools.names.isSubset(of: AgentProfile.project.tools))
        #expect(DomainTools.names.isDisjoint(with: AgentProfile.diagnostician.tools))
    }

    @Test func tripTimelineShowsConnectionsAndConflicts() throws {
        let bench = try Bench()
        let travel = TravelRuntime(store: bench.store, clock: bench.clock)
        let trip = try travel.addTrip("Porto visit", by: person)
        let start = bench.clock.now().addingTimeInterval(86_400)
        try travel.addLeg(
            LegDraft(title: "Flight TP 1947", mode: .flight, start: start, end: start + 3_600, origin: "LIS", destination: "OPO"), to: trip.id, by: person)
        try travel.addLeg(
            LegDraft(title: "Flight TP 1950", mode: .flight, start: start + 4_800, end: start + 8_400, origin: "OPO", destination: "LIS"), to: trip.id,
            by: person)

        let list = try bench.use(TripTimelineTool(), [:])
        #expect(list.content.contains("Porto visit") && list.content.contains("2 legs"))
        let outcome = try bench.use(TripTimelineTool(), ["trip": .string(trip.id.description)])
        #expect(outcome.content.contains("[flight] Flight TP 1947 (LIS → OPO)"))
        #expect(outcome.content.contains("connection: 20 min") && outcome.content.contains("tightConnection"))
        #expect(outcome.touched.count == 3)
        #expect(throws: ToolError.notFound(bench.project.description)) { try bench.use(TripTimelineTool(), ["trip": .string(bench.project.description)]) }
    }

    @Test func contactsCareerAndSpaceTools() throws {
        let bench = try Bench()
        let now = bench.clock.now()
        let contacts = ContactsRuntime(store: bench.store, clock: bench.clock)
        let ana = try contacts.addPerson("Ana Silva", by: person)
        try contacts.logInteraction(with: [ana.id], channel: .call, at: now.addingTimeInterval(-100 * 86_400), summary: "Call", by: person)
        let due = try bench.use(ContactsDueTool(), [:])
        #expect(due.content.contains("Ana Silva") && due.content.contains("100 days ago") && due.touched == [ana.id])
        #expect(try bench.use(ContactsDueTool(), ["default_days": .int(120)]).content == "Nobody is overdue.")

        let career = CareerRuntime(store: bench.store, clock: bench.clock)
        let application = try career.addApplication(position: "Controls Lead", at: "Delta Robotics", by: person)
        try career.move(application.id, to: .applied, by: person)
        let applications = try bench.use(JobApplicationsTool(), [:])
        #expect(applications.content.hasPrefix("applied (1):") && applications.content.contains("Controls Lead at Delta Robotics"))
        try career.addCertification("First Aid", issuer: "Red Cross", issued: nil, expires: now.addingTimeInterval(10 * 86_400), by: person)
        #expect(try bench.use(ExpiringCertificationsTool(), [:]).content.contains("First Aid (Red Cross): expires in 10 days"))

        let spaces = SpaceRuntime(store: bench.store, clock: bench.clock)
        let building = try spaces.add(.building, named: "HQ", by: person)
        let lab = try spaces.addSpace(number: "102", name: "Lab", area: Quantity(40, AreaUnit.squareMetre), in: building.id, by: person)
        try spaces.locate(bench.transmitter, in: lab.id, by: person)
        #expect(try bench.use(SpaceSummaryTool(), [:]).content.contains("HQ: 1 spaces, 40.0 m² (derived)"))
        let summary = try bench.use(SpaceSummaryTool(), ["id": .string(building.id.description)])
        #expect(summary.content.contains("LT-101 level transmitter in 102 Lab"))
        let located = try bench.use(LocateAssetTool(), ["id": .string(bench.transmitter.description)])
        #expect(located.content.hasPrefix("LT-101 level transmitter is in HQ › 102 Lab"))
        let scope = try LocateAssetTool().scope(
            for: ["id": .string(bench.transmitter.description)],
            in: ToolContext(store: bench.store, run: bench.project, agentID: "project", project: nil, clock: bench.clock))
        #expect(scope.objectTypes == [.sensor, .space])
    }
}
