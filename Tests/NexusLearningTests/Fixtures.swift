import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

let fixtureStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// The automotive slice's case, closed: a 2003 Honda whose alternator is
/// worn to 10 % output. Cranking and charging voltage are measured from the
/// faulted run and assessed, the alternator is confirmed, replaced and
/// verified.
struct ChargingCase {
    var investigation: ObjectID
    var vehicle: ObjectID
    var system: ChargingSystem
    var fault: ObjectID
    var procedure: ObjectID
    var crank: MeasurementRecord
    var charging: MeasurementRecord
    var cause: Hypothesis

    static let vin = "1HGCM82633A004352"

    static func make(store: NexusStore, clock: ManualClock, tech: Origin) throws -> ChargingCase {
        let garage = VehicleRuntime(store: store, clock: clock)
        let investigations = InvestigationRuntime(store: store, clock: clock)
        let car = try garage.addVehicle(vin: vin, odometerKm: 182_400, by: tech)
        let system = try ChargingSystem(car).orFail()
        let meter = try store.create(
            ObjectRecord(type: .instrument, title: "DMM", provenance: Provenance(origin: tech, truth: .recorded, timestamp: clock.now()))
        ).id
        let codes = try garage.recordTroubleCodes([DTC("P0562")!], status: .stored, on: car.id, by: tech)

        let field = try ChargingProtocol.run(system, faults: ChargingFaultKind.failingAlternator.faults(on: system, severity: 1))
        let twin = try ChargingProtocol.run(system)
        let diagnosis = ChargingDiagnosis(system: system)
        let (investigation, hypotheses) = try diagnosis.open(in: investigations, vehicle: car.id, evidence: [codes[0].id], by: tech)

        clock.advance(by: 180)
        let crank = diagnosis.observe(.crankingVoltage, in: field, instrument: meter, at: clock.now())
        try store.add(crank)
        try investigations.assess(crank.id, in: investigation, by: tech)
        clock.advance(by: 240)
        let charging = diagnosis.observe(.chargingVoltage, in: field, instrument: meter, at: clock.now())
        try store.add(charging)
        try investigations.assess(charging.id, in: investigation, by: tech)

        let divergence = try diagnosis.firstDivergence(field: field, twin: twin).orFail()
        let (observed, expected) = diagnosis.readings(at: divergence, twin: twin, instrument: meter, at: clock.now())
        try store.add(observed)
        try store.add(expected)
        try investigations.recordFirstDivergence(
            in: investigation, observed: observed.id, expected: expected.id, summary: "Alternator output departs from the twin at once", by: tech
        )
        let alternator = try hypotheses[.failingAlternator].orFail()
        let cause = try investigations.confirm(alternator.id, in: investigation, by: tech)

        clock.advance(by: 7_200)
        let repair = try garage.recordService(
            ServiceEntry(
                title: "Replace alternator", performedAt: clock.now(), odometerKm: 182_412,
                steps: ["Disconnect battery negative", "Replace alternator", "Torque B+ nut to 9 N·m", "Verify charging voltage at 2000 rpm"]
            ),
            on: car.id, by: tech
        )
        let repaired = try ChargingProtocol.run(system)
        let verified = diagnosis.observe(.chargingVoltage, in: repaired, instrument: meter, at: clock.now())
        try store.add(verified)
        try investigations.close(investigation, resolution: "Alternator replaced; 14.3 V at 2000 rpm", verifiedBy: [verified.id], by: tech)
        return ChargingCase(
            investigation: investigation, vehicle: car.id, system: system, fault: codes[0].id, procedure: repair.procedure.id, crank: crank,
            charging: charging, cause: cause
        )
    }
}

struct Missing: Error {}

extension Optional {
    func orFail() throws -> Wrapped {
        guard let value = self else { throw Missing() }
        return value
    }
}
