import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSimulation
import Testing
@testable import NexusReality

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)

private struct Plant {
    let store: NexusStore
    let graph: ObjectGraph
    let tank: ObjectID
    let transmitter: ObjectID
    let terminal: ObjectID
    let valve: ObjectID
    let spare: ObjectID

    init() throws {
        let store = try NexusStore(.inMemory)
        func make(_ title: String, _ type: ObjectType, _ attributes: [String: Attribute] = [:]) throws -> ObjectID {
            try store.create(ObjectRecord(type: type, title: title, attributes: attributes, provenance: recorded)).id
        }
        let tank = try make("Tank T-1", .equipment)
        let transmitter = try make("LT-101", .sensor, ["position": Attribute(.list([.double(0.5), .double(2), .int(0)]))])
        let terminal = try make("TB-4", .testPoint)
        let valve = try make("LV-101", .component)
        let spare = try make("Spare transmitter", .sensor)
        for (parent, child) in [(tank, transmitter), (tank, valve), (transmitter, terminal)] {
            try store.relate(Relationship(kind: .contains, from: parent, to: child, provenance: recorded))
        }
        try store.relate(Relationship(kind: .connectedTo, from: terminal, to: valve, provenance: recorded))
        try store.relate(Relationship(kind: .connectedTo, from: terminal, to: spare, provenance: recorded))
        self.store = store
        graph = ObjectGraph(store: store)
        self.tank = tank
        self.transmitter = transmitter
        self.terminal = terminal
        self.valve = valve
        self.spare = spare
    }
}

@Suite struct SceneTests {
    @Test func sceneProjectsContainmentAndConnections() throws {
        let plant = try Plant()
        let scene = try SceneBuilder.build(root: plant.tank, graph: plant.graph)
        #expect(scene.nodes.map(\.object) == [plant.tank] + [plant.transmitter, plant.valve].sorted() + [plant.terminal])
        #expect(scene.node(scene.entity(for: plant.terminal)!)?.parent == scene.entity(for: plant.transmitter))
        #expect(scene.node(scene.entity(for: plant.transmitter)!)?.position == Position(0.5, 2, 0))
        // Links only between objects in the scene; the spare is outside it.
        #expect(scene.links.count == 1)
        #expect(scene.links.first.map { scene.object(for: $0.to) } == plant.valve)
        #expect(scene.entity(for: plant.spare) == nil)
        #expect(try SceneBuilder.build(root: plant.tank, graph: plant.graph) == scene, "Deterministic")
    }

    @Test func selectionRoundTripsThroughObjectID() throws {
        let plant = try Plant()
        let scene = try SceneBuilder.build(root: plant.tank, graph: plant.graph)
        for node in scene.nodes {
            #expect(scene.object(for: node.entity) == node.object)
            #expect(scene.entity(for: node.object) == node.entity)
        }
        #expect(scene.object(for: EntityHandle(999)) == nil)
    }

    @MainActor
    @Test func tappingAnEntitySelectsTheCanonicalObjectEverywhere() throws {
        let plant = try Plant()
        let scene = try SceneBuilder.build(root: plant.tank, graph: plant.graph)
        let context = ContextRuntime(store: plant.store)
        let tapped = try #require(scene.entity(for: plant.terminal))
        try context.open(try #require(scene.object(for: tapped)), in: .simulation, from: .spatial)
        #expect(context.focus == plant.terminal)
        #expect(try context.availableCommands().map(\.id).contains("measure"))
        context.open(.investigation)
        #expect(context.focus == plant.terminal)
    }

    @Test func overlaysKeepModeledAndObservedApart() throws {
        let plant = try Plant()
        let scene = try SceneBuilder.build(root: plant.tank, graph: plant.graph)
        let key = StateKey(plant.terminal, "terminalVoltage")
        let snapshot = Snapshot(tick: 0, seconds: 0, values: [key: 19.03, StateKey(ObjectID.make(), "elsewhere"): 1])
        let modeled = OverlayBuilder.modeled(snapshot, in: scene, units: ["terminalVoltage": "V"])
        #expect(modeled == [OverlayValue(entity: scene.entity(for: plant.terminal)!, quantity: "terminalVoltage", value: 19.03, unit: "V", truth: .modeled)])

        for (value, offset) in [(11.9, 0.0), (12.0, 60.0)] {
            try plant.store.add(MeasurementRecord(
                quantityName: "terminalVoltage", value: Quantity(value, "V"), testPoint: plant.terminal, sampledAt: t0 + offset,
                provenance: Provenance(origin: .instrument(id: plant.terminal), truth: .observed, timestamp: t0 + offset)
            ))
        }
        let measured = try OverlayBuilder.measured(in: scene, store: plant.store)
        #expect(measured.map(\.value) == [12.0], "Latest observed reading only")
        #expect(measured.first?.truth == .observed)
    }
}
