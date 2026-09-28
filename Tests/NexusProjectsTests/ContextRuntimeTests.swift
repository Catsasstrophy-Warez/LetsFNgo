import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusSearch
import Testing
@testable import NexusProjects

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)

@MainActor
private struct Fixture {
    let store: NexusStore
    let graph: ObjectGraph
    let projects: ProjectRuntime
    let context: ContextRuntime

    init() throws {
        store = try NexusStore(.inMemory)
        graph = ObjectGraph(store: store)
        projects = ProjectRuntime(store: store, graph: graph)
        context = ContextRuntime(store: store)
    }

    func make(_ title: String, _ type: ObjectType) throws -> ObjectID {
        try store.create(ObjectRecord(type: type, title: title, provenance: recorded)).id
    }

    func commandIDs() throws -> [String] {
        try context.availableCommands().map(\.id)
    }
}

@MainActor
@Suite struct ContextRuntimeTests {
    /// Acceptance gate 4: the same object reached from project, search, 3D and
    /// investigation views keeps one identity.
    @Test func identityIsIndependentOfWhereTheObjectWasFound() throws {
        let fixture = try Fixture()
        let project = try fixture.projects.createProject(title: "Level loop", by: tech).id
        let transmitter = try fixture.make("LT-101 level transmitter", .sensor)
        try fixture.projects.add(transmitter, to: project, by: tech)

        let fromProject = try #require(try fixture.projects.members(of: project).first?.id)
        let search = SearchEngine(store: fixture.store, graph: fixture.graph)
        let fromSearch = try #require(try search.search(SearchQuery("LT-101")).first?.id)
        let fromSpatial = transmitter // A RealityKit entity carries this ID.

        var seen: [ObjectID] = []
        for (id, source, screen) in [
            (fromProject, SelectionSource.project, ScreenFamily.objectDetail),
            (fromSearch, .search, .objectDetail),
            (fromSpatial, .spatial, .simulation),
            (transmitter, .investigation, .investigation),
        ] {
            try fixture.context.open(id, in: screen, from: source)
            seen.append(try #require(fixture.context.focus))
            #expect(fixture.context.lastSource == source)
        }
        #expect(Set(seen) == [transmitter])
    }

    @Test func contextFollowsTheObjectAcrossScreens() throws {
        let fixture = try Fixture()
        let component = try fixture.make("Injector 3", .component)
        try fixture.context.open(component, from: .collection)
        for screen in [ScreenFamily.document, .simulation, .conversation, .research] {
            fixture.context.open(screen)
            #expect(fixture.context.screen == screen)
            #expect(fixture.context.focus == component)
        }
    }

    @Test func backAndForwardRestoreLocations() throws {
        let fixture = try Fixture()
        let project = try fixture.projects.createProject(title: "P", by: tech).id
        let valve = try fixture.make("Valve", .component)

        try fixture.context.enterProject(project)
        try fixture.context.open(valve, from: .project)
        fixture.context.open(.telemetry)
        #expect(fixture.context.location == Location(screen: .telemetry, focus: valve, project: project))

        fixture.context.back()
        #expect(fixture.context.location == Location(screen: .objectDetail, focus: valve, project: project))
        fixture.context.back()
        #expect(fixture.context.location == Location(screen: .project, focus: nil, project: project))
        #expect(fixture.context.canGoForward)

        fixture.context.forward()
        #expect(fixture.context.screen == .objectDetail)
        fixture.context.open(.document)
        #expect(!fixture.context.canGoForward)

        // Re-opening the current screen is not a navigation step.
        let depth = fixture.context.canGoBack
        fixture.context.open(.document)
        #expect(fixture.context.canGoBack == depth)
    }

    @Test func invalidSelectionsLeaveStateUnchanged() throws {
        let fixture = try Fixture()
        let pump = try fixture.make("Pump", .equipment)
        try fixture.context.select(pump, from: .collection)
        let missing = ObjectID.make()
        #expect(throws: StoreError.notFound(missing)) { try fixture.context.select([pump, missing], from: .collection) }
        #expect(throws: StoreError.notFound(missing)) { try fixture.context.open(missing, from: .search) }
        #expect(throws: ProjectError.notAProject(pump)) { try fixture.context.enterProject(pump) }
        #expect(fixture.context.selection == [pump])
        #expect(fixture.context.screen == .commandCenter)
    }

    @Test func selectionIsOrderedUniqueAndToggles() throws {
        let fixture = try Fixture()
        let a = try fixture.make("A", .component)
        let b = try fixture.make("B", .component)
        try fixture.context.select([a, b, a], from: .collection)
        #expect(fixture.context.selection == [a, b])
        #expect(fixture.context.focus == b)
        try fixture.context.toggle(b, from: .collection)
        #expect(fixture.context.selection == [a])
        try fixture.context.toggle(b, from: .collection)
        #expect(fixture.context.selection == [a, b])
        fixture.context.clearSelection()
        #expect(fixture.context.focus == nil)
    }

    @Test func selectionChangesTheCommandSurface() throws {
        let fixture = try Fixture()
        let sensor = try fixture.make("LT-101", .sensor)
        let terminal = try fixture.make("TB-4", .testPoint)
        let manual = try fixture.make("Manual", .document)

        #expect(try fixture.commandIDs() == ["ask", "create", "search", "run"])

        try fixture.context.select(manual, from: .collection)
        #expect(try fixture.commandIDs() == ["open", "ask", "analyze", "link"])

        try fixture.context.select(sensor, from: .collection)
        #expect(try fixture.commandIDs() == ["open", "ask", "analyze", "link", "trace", "simulate", "investigate"])

        try fixture.context.select(terminal, from: .spatial)
        #expect(try fixture.commandIDs() == [
            "open", "ask", "analyze", "link", "trace", "measure", "recordMeasurement", "simulate", "investigate",
        ])

        try fixture.context.select([sensor, terminal], from: .collection)
        #expect(try fixture.commandIDs() == [
            "compare", "group", "export", "runAnalysis", "trace", "measure", "simulate", "investigate",
        ])

        // A mixed selection only gets commands that make sense for all of it.
        try fixture.context.select([sensor, manual], from: .collection)
        #expect(try fixture.commandIDs() == ["compare", "group", "export", "runAnalysis"])
    }
}
