import Foundation
import NexusCore
import NexusGraph
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSimulation

/// The LT-101 level-loop plant from the Golden Slice, seeded into a store.
///
/// Used for first launch, SwiftUI previews, UI tests (`-demo` launch
/// argument) and screenshots, so every surface shows the same world. The
/// investigation is left open at the point where a technician takes over:
/// four hypotheses, the operator's display value, and the field reading
/// that would expose the fault still to be taken.
public struct DemoWorld: Sendable {
    public static let projectTitle = "LT-101 level loop"

    public var project: ObjectID
    public var loop: InstrumentLoop
    public var manual: ObjectID
    public var claim: ObjectID
    public var dmm: ObjectID
    public var investigation: ObjectID
    public var hypotheses: [ObjectID]
    public var fault: SimulatedFault
    public var tests: [TestOption]

    /// Seeds the world unless a project with the demo title already exists,
    /// in which case the existing one is returned.
    @discardableResult
    public static func seedIfNeeded(into store: NexusStore, clock: NexusClock = SystemClock()) throws -> DemoWorld {
        if let existing = try store.objects(titled: projectTitle).first(where: { $0.type == .project }),
           case .string(let json)? = existing.attributes["demoWorld"]?.value,
           let world = try? JSONDecoder().decode(Manifest.self, from: Data(json.utf8)).world {
            return world
        }
        return try seed(into: store, clock: clock)
    }

    public static func seed(into store: NexusStore, clock: NexusClock = SystemClock()) throws -> DemoWorld {
        try store.batch { store in
            let author = Origin.system
            func recorded() -> Provenance { Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "demo world") }
            func object(_ title: String, _ type: ObjectType, _ attributes: [String: Attribute] = [:]) throws -> ObjectID {
                try store.create(ObjectRecord(type: type, title: title, attributes: attributes, provenance: recorded())).id
            }

            let graph = ObjectGraph(store: store, clock: clock)
            let projects = ProjectRuntime(store: store, graph: graph, clock: clock)
            let project = try projects.createProject(
                title: projectTitle, mission: "Restore reliable level control on tank T-1",
                objectives: ["Find why LT-101 reads low at high level", "Repair and verify", "Capture the case for training"],
                by: author
            ).id

            let tank = try object("Tank T-1", .equipment, ["position": Attribute(.list([.double(0), .double(0), .double(0)]))])
            let transmitter = try object("LT-101 level transmitter", .sensor, [
                "tag": Attribute(.string("LT-101")), "range": Attribute(.string("0–100 %")),
                "position": Attribute(.list([.double(0.6), .double(0.9), .double(0)])),
            ])
            let terminal = try object("TB-4 terminals 7/8", .testPoint, ["position": Attribute(.list([.double(1.2), .double(0.9), .double(0)]))])
            let card = try object("AI card slot 3 ch 0", .component, ["position": Attribute(.list([.double(2.2), .double(0.9), .double(0)]))])
            let controller = try object("LIC-101 level controller", .component, ["position": Attribute(.list([.double(2.2), .double(0.2), .double(0)]))])
            let valve = try object("LV-101 inlet valve", .component, ["position": Attribute(.list([.double(-0.8), .double(0.9), .double(0)]))])
            let dmm = try object("Fluke 87V multimeter", .instrument, ["accuracy": Attribute(.string("±(0.05% + 1)"))])
            for id in [tank, card, controller, valve, dmm] {
                try projects.add(id, to: project, by: author)
            }
            try store.relate(Relationship(kind: .contains, from: tank, to: transmitter, provenance: recorded()))
            try store.relate(Relationship(kind: .contains, from: transmitter, to: terminal, provenance: recorded()))
            for (from, to) in [(transmitter, terminal), (terminal, card), (card, controller), (controller, valve)] {
                try store.relate(Relationship(kind: .connectedTo, from: from, to: to, provenance: recorded()))
            }

            let manual = try object("LT-101 installation manual", .document, [
                "body": Attribute(.string("The transmitter needs at least 12 V between its terminals (minimum lift-off voltage).")),
            ])
            try projects.add(manual, to: project, by: author)
            let claim = Claim(
                statement: "LT-101 needs at least 12 V at its terminals to regulate loop current",
                sources: [manual], passages: ["minimum lift-off voltage 12 V"], sourceClass: .primary,
                provenance: Provenance(origin: author, truth: .claimed, timestamp: clock.now())
            )
            try store.add(claim)

            let loop = InstrumentLoop(tank: tank, transmitter: transmitter, terminal: terminal, card: card, controller: controller, valve: valve)
            let fault = SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded terminal at TB-4")

            // The operator's screen, from a field run with the fault present.
            let field = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
            field.inject(fault)
            try field.start()
            try field.run(for: 600)
            try store.add(MeasurementRecord(
                quantityName: "measuredLevel", value: Quantity(try field.value(loop.measuredLevel), "%"), testPoint: card,
                sampledAt: clock.now(), provenance: Provenance(origin: .importer(source: card), truth: .display, timestamp: clock.now(), method: "HMI")
            ))

            let investigations = InvestigationRuntime(store: store, clock: clock)
            let investigation = try investigations.open(
                symptom: "LT-101 reads 86.9 % while T-1 overflows", subjects: [transmitter, tank], by: author
            ).id
            try projects.add(investigation, to: project, by: author)
            func volts(_ low: Double, _ high: Double) -> Prediction {
                Prediction(testPoint: terminal, quantity: "terminalVoltage", unit: "V", low: low, high: high, condition: "high level")
            }
            func span(_ low: Double, _ high: Double) -> Prediction {
                Prediction(testPoint: card, quantity: "configuredSpan", unit: "%", low: low, high: high)
            }
            let hypotheses = [
                try investigations.propose("Transmitter failed and no longer draws loop current", in: investigation,
                                           predictions: [volts(22, 24.5), span(99.9, 100.1)], by: author),
                try investigations.propose("Excess loop resistance starves the transmitter of compliance voltage", in: investigation,
                                           predictions: [volts(10.5, 12.5), span(99.9, 100.1)], dependsOn: [claim.id], by: author),
                try investigations.propose("AI card channel reads low", in: investigation,
                                           predictions: [volts(17, 21.9), span(99.9, 100.1)], by: author),
                try investigations.propose("Channel scaled 0–120 % instead of 0–100 %", in: investigation,
                                           predictions: [volts(17, 21.9), span(119.9, 120.1)], by: author),
            ].map(\.id)

            let tests = standardTests(for: loop)
            let world = DemoWorld(
                project: project, loop: loop, manual: manual, claim: claim.id, dmm: dmm, investigation: investigation,
                hypotheses: hypotheses, fault: fault, tests: tests
            )
            let manifest = String(decoding: try JSONEncoder().encode(Manifest(world: world)), as: UTF8.self)
            try store.update(project, by: author, instruction: "Demo world manifest") {
                $0.attributes["demoWorld"] = Attribute(.string(manifest), provenance: recorded())
            }
            return world
        }
    }

    /// The checks a technician can make on this loop.
    public static func standardTests(for loop: InstrumentLoop) -> [TestOption] {
        [
            TestOption(title: "Read channel span from controller", testPoint: loop.card, quantity: "configuredSpan", cost: 2),
            TestOption(title: "Terminal voltage at TB-4 under load", testPoint: loop.terminal, quantity: "terminalVoltage", condition: "high level", cost: 5),
            TestOption(title: "Measure 24 V bus with covers off", testPoint: loop.card, quantity: "busVoltage", cost: 1, safety: .hazardous),
        ]
    }

    /// The field with the demo fault, settled at the symptom's operating point.
    public func makeField() throws -> SimulationRuntime {
        let runtime = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        runtime.inject(fault)
        try runtime.start()
        try runtime.run(for: 600)
        return runtime
    }

    /// A healthy twin run to the same point, for modeled expectations.
    public func makeTwin() throws -> SimulationRuntime {
        let runtime = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        try runtime.start()
        try runtime.run(for: 600)
        return runtime
    }

    /// Persisted IDs so a relaunch finds the same world.
    private struct Manifest: Codable {
        var project, tank, transmitter, terminal, card, controller, valve, manual, claim, dmm, investigation, faultID: ObjectID
        var hypotheses: [ObjectID]

        init(world: DemoWorld) {
            project = world.project
            tank = world.loop.tank
            transmitter = world.loop.transmitter
            terminal = world.loop.terminal
            card = world.loop.card
            controller = world.loop.controller
            valve = world.loop.valve
            manual = world.manual
            claim = world.claim
            dmm = world.dmm
            investigation = world.investigation
            faultID = world.fault.id
            hypotheses = world.hypotheses
        }

        var world: DemoWorld {
            let loop = InstrumentLoop(tank: tank, transmitter: transmitter, terminal: terminal, card: card, controller: controller, valve: valve)
            return DemoWorld(
                project: project, loop: loop, manual: manual, claim: claim, dmm: dmm, investigation: investigation, hypotheses: hypotheses,
                fault: SimulatedFault(id: faultID, parameter: loop.contactOhms, value: 400, summary: "Corroded terminal at TB-4"),
                tests: DemoWorld.standardTests(for: loop)
            )
        }
    }
}
