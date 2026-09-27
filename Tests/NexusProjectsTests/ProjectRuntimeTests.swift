import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import Testing
@testable import NexusProjects

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)

private struct Fixture {
    let clock = ManualClock(t0)
    let store: NexusStore
    let graph: ObjectGraph
    let projects: ProjectRuntime

    init() throws {
        store = try NexusStore(.inMemory, clock: clock)
        graph = ObjectGraph(store: store, clock: clock)
        projects = ProjectRuntime(store: store, graph: graph, clock: clock)
    }

    func make(_ title: String, _ type: ObjectType) throws -> ObjectID {
        try store.create(ObjectRecord(type: type, title: title, provenance: recorded)).id
    }
}

@Suite struct ProjectRuntimeTests {
    @Test func createsProjectsWithMissionAndObjectives() throws {
        let fixture = try Fixture()
        let project = try fixture.projects.createProject(
            title: "LT-101 investigation", mission: "Restore level control", objectives: ["Find cause", "Verify"], by: tech
        )
        #expect(project.type == .project)
        #expect(project.provenance.truth == .recorded)
        #expect(project.attributes["mission"]?.value == .string("Restore level control"))
        #expect(project.attributes["objectives"]?.value == .list([.string("Find cause"), .string("Verify")]))
    }

    @Test func objectsJoinSeveralProjectsWithoutDuplication() throws {
        let fixture = try Fixture()
        let a = try fixture.projects.createProject(title: "A", by: tech).id
        let b = try fixture.projects.createProject(title: "B", by: tech).id
        let pump = try fixture.make("Pump P-1", .equipment)

        let first = try fixture.projects.add(pump, to: a, by: tech)
        #expect(try fixture.projects.add(pump, to: a, by: tech) == first)
        try fixture.projects.add(pump, to: b, by: tech)

        #expect(try fixture.projects.members(of: a).map(\.id) == [pump])
        #expect(try fixture.projects.members(of: b).map(\.id) == [pump])
        #expect(try Set(fixture.projects.projects(containing: pump).map(\.id)) == [a, b])
        #expect(try fixture.store.objects(ofType: .equipment).count == 1)
    }

    @Test func removingEndsMembershipButKeepsHistory() throws {
        let fixture = try Fixture()
        let project = try fixture.projects.createProject(title: "A", by: tech).id
        let pump = try fixture.make("Pump P-1", .equipment)
        let membership = try fixture.projects.add(pump, to: project, by: tech)
        fixture.clock.advance(by: 60)

        try fixture.projects.remove(pump, from: project, by: tech)
        #expect(try fixture.projects.members(of: project).isEmpty)
        #expect(try fixture.projects.projects(containing: pump).isEmpty)
        #expect(try fixture.store.object(pump) != nil)
        #expect(try fixture.store.relationship(membership.id)?.validTo == t0 + 60)
        let then = try fixture.graph.edges(of: project, kinds: [.contains], validity: .at(t0 + 30))
        #expect(then.map(\.neighbor) == [pump])

        #expect(throws: ProjectError.notAMember(object: pump, project: project)) {
            try fixture.projects.remove(pump, from: project, by: tech)
        }
        // Re-adding creates a fresh membership.
        let again = try fixture.projects.add(pump, to: project, by: tech)
        #expect(again.id != membership.id)
    }

    @Test func membersCanBeFilteredAndFollowedTransitively() throws {
        let fixture = try Fixture()
        let project = try fixture.projects.createProject(title: "Plant", by: tech).id
        let tank = try fixture.make("Tank", .equipment)
        let transmitter = try fixture.make("LT-101", .sensor)
        let manual = try fixture.make("Manual", .document)
        try fixture.projects.add(tank, to: project, by: tech)
        try fixture.projects.add(manual, to: project, by: tech)
        try fixture.store.relate(Relationship(kind: .contains, from: tank, to: transmitter, provenance: recorded))

        #expect(try Set(fixture.projects.members(of: project).map(\.id)) == [tank, manual])
        #expect(try Set(fixture.projects.members(of: project, transitive: true).map(\.id)) == [tank, manual, transmitter])
        #expect(try fixture.projects.members(of: project, types: [.sensor], transitive: true).map(\.id) == [transmitter])
    }

    @Test func agentOrganizingIsAnInterpretation() throws {
        let fixture = try Fixture()
        let agent = Origin.agent(id: "project-agent", run: nil)
        let project = try fixture.projects.createProject(title: "Suggested", by: agent)
        #expect(project.provenance.truth == .agentInterpretation)
        let pump = try fixture.make("Pump", .equipment)
        #expect(try fixture.projects.add(pump, to: project.id, by: agent).provenance.truth == .agentInterpretation)
    }

    @Test func rejectsNonProjects() throws {
        let fixture = try Fixture()
        let pump = try fixture.make("Pump", .equipment)
        let valve = try fixture.make("Valve", .component)
        #expect(throws: ProjectError.notAProject(pump)) { try fixture.projects.add(valve, to: pump, by: tech) }
        #expect(throws: ProjectError.notAProject(pump)) { try fixture.projects.members(of: pump) }
    }
}
