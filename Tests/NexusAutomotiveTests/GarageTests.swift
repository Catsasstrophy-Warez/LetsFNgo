import Foundation
import NexusAutomotive
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusSimulation
import Testing

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct VehicleRuntimeTests {
    let tech = Origin.user(id: "tech")

    func garage() throws -> (VehicleRuntime, NexusStore, ManualClock) {
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        return (VehicleRuntime(store: store, clock: clock), store, clock)
    }

    @Test func addsAVehicleWithItsTopology() throws {
        let (garage, store, clock) = try garage()
        let car = try garage.addVehicle(vin: "1HGCM82633A004352", odometerKm: 100_000, by: tech)
        #expect(car.record.type == .vehicle && car.title == "2003 Honda (USA) 1HGCM82633A004352")
        #expect(car.components.count == VehicleComponentRole.allCases.count)
        #expect(car.record.truth(of: AutomotiveKey.vin) == .recorded && car.record.truth(of: AutomotiveKey.modelYear) == .derived)

        // The engine contains its sensors; current flows alternator → battery → starter.
        let engine = try #require(car.component(.engine))
        let inEngine = Set(try store.relationships(from: engine, kind: .contains).map(\.to))
        #expect(inEngine.contains(try #require(car.component(.coolantTemperatureSensor))))
        #expect(try store.object(try #require(car.component(.massAirflowSensor)))?.type == .sensor)
        #expect(try store.object(try #require(car.component(.canBus)))?.type == .vehicleNetwork)
        let graph = ObjectGraph(store: store, clock: clock)
        let alternator = try #require(car.component(.alternator))
        let path = try #require(try graph.shortestPath(from: alternator, to: engine))
        #expect(path.count >= 2)
        let fromAlternator = try store.relationships(from: alternator, kind: .connectedTo).map(\.to)
        #expect(fromAlternator == [car.component(.battery)])

        // The same identity comes back through the VIN lookup and full-text search.
        #expect(try garage.vehicle(vin: "1hgcm82633a004352")?.components == car.components)
        #expect(try store.search("Honda", types: [.vehicle]).map(\.id) == [car.id])
    }

    @Test func enforcesCheckDigitsAndUniqueVINs() throws {
        let (garage, _, _) = try garage()
        #expect(throws: AutomotiveError.invalidVIN(.checkDigitMismatch(expected: "3", found: "4"))) {
            try garage.addVehicle(vin: "1HGCM82643A004352", by: tech)
        }
        // Outside North America the check digit is optional.
        let european = try garage.addVehicle(vin: "WVWZZZ1KZ6W000001", components: [.battery], by: tech)
        #expect(european.vin.country == "Germany" && european.components.keys.sorted { $0.rawValue < $1.rawValue } == [.battery])
        #expect(throws: AutomotiveError.invalidVIN(.checkDigitMismatch(expected: "3", found: "Z"))) {
            try garage.addVehicle(vin: "WVWZZZ1KZ6W000002", requireCheckDigit: true, by: tech)
        }
        _ = try garage.addVehicle(vin: "1HGCM82633A004352", by: tech)
        #expect(throws: AutomotiveError.duplicateVIN("1HGCM82633A004352")) { try garage.addVehicle(vin: "1HGCM82633A004352", by: tech) }
        #expect(throws: AutomotiveError.invalidVIN(.wrongLength(3))) { try garage.addVehicle(vin: "ABC", by: tech) }
    }

    @Test func serviceHistoryIsEventsPlusProcedures() throws {
        let (garage, store, clock) = try garage()
        let car = try garage.addVehicle(vin: "1HGCM82633A004352", odometerKm: 90_000, by: tech)
        let oil = try garage.recordService(
            ServiceEntry(
                title: "Oil and filter", performedAt: t0, odometerKm: 95_000, steps: ["Drain", "Replace filter", "Fill 4.2 L 0W-20"], parts: ["Filter"]),
            on: car.id, by: tech
        )
        clock.advance(by: 86_400)
        try garage.recordOdometer(97_500, at: clock.now(), on: car.id, by: tech)
        try garage.recordService(ServiceEntry(title: "Front brake pads", performedAt: clock.now(), odometerKm: 97_600), on: car.id, by: tech)

        let history = try garage.serviceHistory(of: car.id)
        #expect(history.map(\.procedure.title) == ["Oil and filter", "Front brake pads"])
        #expect(history.map(\.odometerKm) == [95_000, 97_600])
        #expect(history[0].procedure.type == .procedure && history[0] == oil)
        #expect(try store.relationships(from: car.id, kind: .serviced).count == 2)
        #expect(try garage.vehicle(car.id).odometerKm == 97_600)
        #expect(try store.events(about: car.id).map(\.kind).filter { $0 != .stateChanged } == [.service, .odometerReading, .service])
        #expect(throws: AutomotiveError.odometerWentBackwards(previous: 97_600, new: 50_000)) {
            try garage.recordService(ServiceEntry(title: "Wrong", performedAt: clock.now(), odometerKm: 50_000), on: car.id, by: tech)
        }
        #expect(try garage.serviceHistory(of: car.id).count == 2, "A rejected entry leaves nothing behind")
    }

    @Test func troubleCodesBecomeFaultsAndPIDsBecomeMeasurements() throws {
        let (garage, store, _) = try garage()
        let car = try garage.addVehicle(vin: "1HGCM82633A004352", by: tech)
        let faults = try garage.recordTroubleCodes([DTC("P0303")!, DTC("P1456")!], status: .stored, on: car.id, by: tech)
        #expect(faults.map(\.title) == ["P0303 Cylinder 3 misfire detected", "P1456"])
        #expect(faults.allSatisfy { $0.type == .fault && $0.provenance.truth == .recorded })
        #expect(try store.relationships(from: faults[0].id, kind: .reportedBy).map(\.to) == [car.component(.ecu)])
        #expect(try garage.faults(of: car.id).map(\.id) == faults.map(\.id))
        let pending = try garage.recordTroubleCodes([DTC("P0303")!], status: .pending, on: car.id, by: tech)
        #expect(pending[0].id != faults[0].id, "Pending and stored are distinct records")

        let readings = try OBD.decodeMode01(try ELM327.hexBytes("41 0C 1A F8 05 7B"))
        let display = try garage.record(readings, on: car.id)
        #expect(display.map(\.truth) == [.display, .display])
        #expect(display.map(\.testPoint) == [car.component(.engine), car.component(.coolantTemperatureSensor)])
        #expect(display[0].provenance.origin == .importer(source: try #require(car.component(.ecu))))
        let tool = try store.create(
            ObjectRecord(
                type: .instrument, title: "Scan tool", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
            )
        ).id
        let checked = try garage.record(Array(readings.prefix(1)), on: car.id, scanTool: tool, truth: .observed)
        #expect(checked[0].truth == .observed && checked[0].provenance.origin == .instrument(id: tool))
        #expect(throws: AutomotiveError.unsupportedTruth(.modeled)) { try garage.record(readings, on: car.id, truth: .modeled) }
        #expect(try store.measurements(at: try #require(car.component(.engine))).count == 2)
    }
}

@Suite struct ChargingSystemTests {
    @Test func healthyCircuitMatchesHandCalculation() throws {
        let system = ChargingSystem.template()
        var state = system.healthyState(stateOfCharge: 0.8, mode: .cranking)
        try ChargingSystemSolver.solve(system, &state)
        // EMF 11.8 + 0.9·0.8 = 12.52 V; I = 12.52 / (0.012 + 0.0008 + 0.045) = 216.6 A.
        let current = 12.52 / 0.0578
        #expect(abs(try state.value(system.emf) - 12.52) < 1e-9)
        #expect(abs(try state.value(system.starterAmps) - current) < 1e-6)
        #expect(abs(try state.value(system.batteryVoltage) - (12.52 - current * 0.012)) < 1e-6)
        #expect(abs(try state.value(system.groundDrop) - current * 0.0008) < 1e-6)

        state = system.healthyState(stateOfCharge: 0.8, mode: .running, rpm: 2000)
        try ChargingSystemSolver.solve(system, &state)
        // Regulated: charge current (14.4 − 12.52) / (0.012 + 0.03/0.22 + 0.0008).
        let charge = 1.88 / (0.012 + 0.03 / 0.22 + 0.0008)
        #expect(try state.value(system.alternatorVolts) == 14.4)
        #expect(try state.value(system.batteryLight) == 0)
        #expect(abs(try state.value(system.batteryCurrent) - charge) < 1e-9)
        #expect(abs(try state.value(system.alternatorAmps) - (charge + 30)) < 1e-9)

        #expect(ChargingSystem.outputFraction(rpm: 500) == 0 && ChargingSystem.outputFraction(rpm: 2000) == 1)
        #expect(abs(ChargingSystem.openCircuitVolts(stateOfCharge: 1) - 12.7) < 1e-9)
    }

    @Test func eachFaultMovesItsOwnReading() throws {
        let system = ChargingSystem.template()
        let healthy = try ChargingProtocol.run(system)
        func run(_ kind: ChargingFaultKind) throws -> ChargingRun {
            try ChargingProtocol.run(system, faults: kind.faults(on: system, severity: 0.5))
        }
        #expect(healthy.readings[.chargingVoltage]! > 14.3 && healthy.readings[.crankingVoltage]! > 9.6 && healthy.crankingSpeed > 200)
        #expect(try run(.weakBattery).readings[.crankingVoltage]! < 8)
        #expect(try run(.weakBattery).crankingSpeed < 200)
        #expect(try run(.failingAlternator).readings[.chargingVoltage]! < 13)
        #expect(try run(.failingAlternator).lightWhileDriving == 1)
        #expect(try run(.highResistanceGround).readings[.groundDrop]! > 2)
        #expect(try run(.highResistanceGround).crankingSpeed < 200)
        #expect(try run(.parasiticDraw).readings[.keyOffDraw]! > 0.5)
        #expect(try run(.parasiticDraw).readings[.restingVoltage]! < healthy.readings[.restingVoltage]! - 0.2)
    }

    @Test func predictionsNeverContradictTheirOwnCause() throws {
        let intervals = try ChargingDiagnosis.intervals()
        let system = ChargingSystem.template()
        for kind in ChargingFaultKind.allCases {
            for severity in stride(from: 0.0, through: 1.0, by: 0.1) {
                let run = try ChargingProtocol.run(system, faults: kind.faults(on: system, severity: severity))
                for (test, range) in intervals[kind]! {
                    #expect(range.contains(run.readings[test]!), "\(kind) at \(severity): \(test) \(run.readings[test]!) outside \(range)")
                }
            }
        }
        // Each discriminating test separates at least two outcomes.
        for test in [ChargingTest.crankingVoltage, .groundDrop, .chargingVoltage, .keyOffDraw] {
            #expect(Set(ChargingFaultKind.allCases.compactMap { intervals[$0]?[test] }).count >= 2, "\(test)")
        }
    }

    @Test func firstDivergenceIsWhereEachFaultEnters() throws {
        let system = ChargingSystem.template()
        let diagnosis = ChargingDiagnosis(system: system)
        let twin = try ChargingProtocol.run(system)
        let expected: [ChargingFaultKind: StateKey] = [
            .failingAlternator: system.alternatorVolts, .highResistanceGround: system.groundDrop,
            .weakBattery: system.alternatorAmps, .parasiticDraw: system.batteryCurrent,
        ]
        for (kind, key) in expected {
            let field = try ChargingProtocol.run(system, faults: kind.faults(on: system, severity: 0.5))
            let divergence = try #require(diagnosis.firstDivergence(field: field, twin: twin))
            #expect(divergence.key == key, "\(kind)")
        }
        #expect(diagnosis.firstDivergence(field: try ChargingProtocol.run(system), twin: twin) == nil)
    }
}

extension ChargingSystemSolver {
    /// Settles the solver at t = 0, the way `SimulationRuntime.start()` does.
    static func solve(_ system: ChargingSystem, _ state: inout WorldState) throws {
        for solver in system.solvers {
            try solver.step(&state, dt: 0)
        }
    }
}
