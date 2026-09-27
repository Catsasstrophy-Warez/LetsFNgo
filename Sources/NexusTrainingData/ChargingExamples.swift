import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

/// The hidden setup of an automotive charging-system scenario.
public struct VehicleScenarioExample: Codable, Sendable, Hashable {
    public var fault: String
    public var severity: Double
    public var overrides: [ParameterOverrideExample]
    public var vin: String
    public var odometerKm: Double
}

/// "Cranks slowly / battery light on" cases from the automotive charging
/// solver (`NexusAutomotive.ChargingSystemSolver`), worked the same way as
/// the loop diagnosis examples: symptom and scan data, hypotheses with
/// simulated predictions, `TestSelector`'s ranking, the expert path through
/// an in-memory investigation, and the first divergence from a healthy twin.
///
/// Truth classes follow `VehicleRuntime`: ECU PIDs and the dash lamp are
/// display, stored codes and the odometer are recorded, twin values are
/// modeled and meter readings are observed.
enum ChargingExamples {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// North American WMIs, so every generated VIN carries a valid check digit.
    static let wmis = ["1HG", "1FA", "1G1", "2T1", "3VW", "4T1", "5YJ", "1N4", "2HG", "3FA"]
    static let vinAlphabet = Array("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
    static let vinLetters = Array("ABCDEFGHJKLMNPRSTUVWXYZ")
    static let vinDigits = Array("0123456789")
    static let names: [ChargingTest.Site: String] = [.battery: "Battery", .groundStrap: "Engine ground strap"]

    /// How hard the parts are to reach on this car, in cost multipliers.
    struct Access {
        /// Battery under a seat or in the trunk.
        var battery: Double
        /// The engine ground strap behind the intake or under the car.
        var strap: Double
        /// Minutes to wait for the modules to sleep before reading the draw.
        var drawWait: Double
        /// Tests taken while cranking need a helper or a remote starter switch.
        var cranking: Double

        init(_ rng: inout SplitMix64) {
            battery = rng.pick([1, 1.5, 3])
            strap = rng.pick([1, 2, 4])
            drawWait = rng.pick([15, 25, 40])
            cranking = rng.pick([1, 2, 4])
        }

        func cost(of test: ChargingTest) -> Double {
            switch test {
            case .keyOffDraw: drawWait
            case .groundDrop: test.cost * strap * cranking
            case .crankingVoltage: test.cost * battery * cranking
            default: test.cost * battery
            }
        }
    }

    static func vin(_ rng: inout SplitMix64) throws -> VIN {
        let year = 2005 + rng.nextInt(below: 18)
        var vds = (0..<5).map { _ in rng.pick(vinAlphabet) }
        // Position 7 tells the model-year cycle apart: a letter for 2010 on.
        vds[3] = year >= 2010 ? rng.pick(vinLetters) : rng.pick(vinDigits)
        let yearCode = Array("ABCDEFGHJKLMNPRSTVWXY123456789")[(year - 1980) % 30]
        let serial = String((0..<6).map { _ in rng.pick(vinDigits) })
        return try VIN.make(prefix: rng.pick(wmis) + String(vds), suffix: String(yearCode) + String(rng.pick(vinLetters)) + serial)
    }

    static func example(seed: UInt64, id: String, split: DatasetSplit) throws -> TrainingExample {
        var rng = SplitMix64(seed: SplitMix64.mix(seed ^ 0x6368_6172_6765))
        let vin = try vin(&rng)
        let odometer = Double(20_000 + rng.nextInt(below: 280) * 1_000)
        let access = Access(&rng)
        let kind = rng.pick(ChargingFaultKind.allCases)
        let severity = rng.nextUnit()
        let system = ChargingSystem(
            vehicle: rng.objectID(), battery: rng.objectID(), alternator: rng.objectID(), starter: rng.objectID(),
            groundStrap: rng.objectID(), engine: rng.objectID()
        )
        let faults = kind.faults(on: system, severity: severity)
        let field = try ChargingProtocol.run(system, faults: faults)
        let twin = try ChargingProtocol.run(system)
        let r = Numbers.round2
        let readings = Dictionary(uniqueKeysWithValues: field.readings.map { ($0.key, r($0.value)) })

        // What is known before any test.
        let pid42 = r(field.drivingOutputVolts)
        let crankRPM = r(field.crankingSpeed)
        let lowVoltageCode = field.drivingOutputVolts < 12.5
        let car = "\(vin.modelYear.map(String.init) ?? "") \(vin.manufacturer ?? vin.wmi) \(vin.rawValue)"
        var observations = [
            ObservationExample(name: "odometer", object: car, value: odometer, unit: "km", truth: .recorded, source: "odometer"),
            ObservationExample(name: "batteryLight", object: car, value: field.lightWhileDriving, unit: "bool", truth: .display, source: "instrument cluster"),
            ObservationExample(
                name: "controlModuleVoltage", object: "Engine control module", value: pid42, unit: "V", truth: .display, source: "OBD-II PID 42"),
            ObservationExample(name: "crankingSpeed", object: "Engine", value: crankRPM, unit: "rpm", truth: .display, source: "OBD-II PID 0C while cranking"),
            ObservationExample(
                name: "P0562", object: "Engine control module", value: lowVoltageCode ? 1 : 0, unit: "bool", truth: .recorded, source: "OBD-II mode 03"),
        ]
        for test in [ChargingTest.crankingVoltage, .chargingVoltage] {
            observations.append(
                ObservationExample(
                    name: test.quantity, object: names[test.site]!, value: r(twin.readings[test]!), unit: test.unit, truth: .modeled, source: "healthy twin"
                ))
        }

        var complaints: [String] = []
        if field.crankingSpeed < 200 { complaints.append("the engine cranks slowly") }
        if field.readings[.restingVoltage]! < 12.3 { complaints.append("the battery was weak after the car sat over the weekend") }
        if field.lightWhileDriving == 1 { complaints.append("the battery light comes on while driving") }
        if complaints.isEmpty { complaints.append("the car sometimes starts slowly") }
        var prompt = "\(car), \(Numbers.text(odometer)) km. The customer says \(complaints.joined(separator: " and ")). "
        prompt += "The scan tool shows PID 42 at \(Numbers.text(pid42)) V and \(Numbers.text(crankRPM)) rpm while cranking"
        prompt += lowVoltageCode ? "; P0562 (system voltage low) is stored." : "; no codes are stored."

        // Hypotheses, ranking and the expert path, on the shared investigation runtime.
        let intervals = try ChargingDiagnosis.intervals()
        let clock = ManualClock(t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let tech = Origin.user(id: "dataset-tech")
        let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)
        try store.create(ObjectRecord(id: system.vehicle, type: .vehicle, title: car, provenance: recorded))
        try store.create(ObjectRecord(id: system.battery, type: .component, title: names[.battery]!, provenance: recorded))
        try store.create(ObjectRecord(id: system.groundStrap, type: .component, title: names[.groundStrap]!, provenance: recorded))
        let meter = try store.create(ObjectRecord(id: rng.objectID(), type: .instrument, title: "DMM with clamp", provenance: recorded)).id
        let runtime = InvestigationRuntime(store: store, clock: clock)
        let investigation = try runtime.open(symptom: ChargingDiagnosis.symptom, subjects: [system.vehicle], by: tech).id
        var causes: [ObjectID: ChargingFaultKind] = [:]
        for cause in ChargingFaultKind.allCases {
            let hypothesis = try runtime.propose(
                cause.statement, in: investigation, predictions: try ChargingDiagnosis(system: system).predictions(for: cause), by: tech
            )
            causes[hypothesis.id] = cause
        }
        let options = ChargingTest.allCases.map { test in
            TestOption(
                title: test.title, testPoint: test.testPoint(in: system), quantity: test.quantity, cost: access.cost(of: test),
                safety: test.isCaution ? .caution : .routine
            )
        }
        func label(_ group: [ObjectID]) -> [String] { group.map { causes[$0]!.rawValue }.sorted() }
        func live() throws -> [ChargingFaultKind] {
            try runtime.hypotheses(of: investigation).filter(\.state.isLive).map { causes[$0.id]! }.sorted()
        }
        let ranking = try runtime.rankTests(options, for: investigation).map { recommendation in
            RankedTestExample(
                title: recommendation.option.title, informationGain: (recommendation.informationGain * 1000).rounded() / 1000,
                score: (recommendation.score * 1000).rounded() / 1000, outcomes: recommendation.outcomes.map(label)
            )
        }
        var path: [ExpertStepExample] = []
        var remaining = try live()
        while remaining.count > 1, path.count < ChargingTest.allCases.count {
            guard let best = try runtime.rankTests(options, for: investigation).first(where: { $0.informationGain > 1e-9 }),
                let test = ChargingTest.allCases.first(where: { $0.title == best.option.title })
            else { break }
            clock.advance(by: access.cost(of: test) * 60)
            let reading = MeasurementRecord(
                id: rng.objectID(), quantityName: test.quantity, value: Quantity(readings[test]!, test.unit), uncertainty: 0,
                testPoint: test.testPoint(in: system), instrument: meter, sampledAt: clock.now(),
                provenance: Provenance(origin: .instrument(id: meter), truth: .observed, timestamp: clock.now(), method: test.title)
            )
            try store.add(reading)
            try runtime.assess(reading.id, in: investigation, by: tech)
            remaining = try live()
            path.append(ExpertStepExample(test: test.title, value: readings[test]!, unit: test.unit, truth: .observed, remaining: remaining.map(\.rawValue)))
        }

        let divergence = ChargingDiagnosis(system: system).firstDivergence(field: field, twin: twin).map { found -> DivergenceExample in
            let object: String
            switch found.key.object {
            case system.alternator: object = "Alternator"
            case system.groundStrap: object = names[.groundStrap]!
            case system.starter: object = "Starter motor"
            default: object = names[.battery]!
            }
            return DivergenceExample(
                object: object, quantity: found.key.quantity, unit: ChargingSystem.unit(of: found.key.quantity), tick: found.tick,
                seconds: found.seconds, expected: r(found.expected), actual: r(found.actual)
            )
        }

        // The reference answer; every figure carries its truth class.
        var text: [String] = []
        if let top = ranking.first, let test = ChargingTest.allCases.first(where: { $0.title == top.title }) {
            text.append(
                "Next test: \(top.title). TestSelector ranks it first with \(Numbers.text(top.informationGain)) bits of expected information "
                    + "for \(Numbers.text(access.cost(of: test))) min."
            )
        }
        if !path.isEmpty {
            text.append("Expert path: " + path.map { "\($0.test): \(DiagnosisCase.cite($0.value, $0.unit, $0.truth))" }.joined(separator: "; ") + ".")
        }
        if remaining == [kind] {
            text.append("Cause: \(kind.statement) [\(kind.rawValue)].")
        } else {
            text.append(
                "Still indistinguishable: \(remaining.map(\.rawValue).joined(separator: ", ")). Most likely cause: \(kind.statement) [\(kind.rawValue)].")
        }
        if let divergence {
            text.append(
                "First divergence from the healthy twin: \(divergence.quantity) at \(divergence.object), t = \(Numbers.text(divergence.seconds)) s, "
                    + "\(DiagnosisCase.cite(divergence.actual, divergence.unit, .observed)) where the model expects "
                    + "\(DiagnosisCase.cite(divergence.expected, divergence.unit, .modeled)).")
        }

        let testExamples = ChargingTest.allCases.map { test in
            TestExample(
                title: test.title, object: names[test.site]!, quantity: test.quantity, unit: test.unit, cost: access.cost(of: test),
                safety: test.isCaution ? "caution" : "routine"
            )
        }
        let hypotheses = ChargingFaultKind.allCases.map { cause in
            HypothesisExample(
                cause: cause.rawValue, statement: cause.statement,
                predictions: ChargingTest.allCases.compactMap { test in
                    guard let range = intervals[cause]?[test] else { return nil }
                    return PredictionExample(test: test.title, quantity: test.quantity, unit: test.unit, low: range.lowerBound, high: range.upperBound)
                }
            )
        }
        let objectNames: [ObjectID: String] = [
            system.battery: names[.battery]!, system.groundStrap: names[.groundStrap]!, system.alternator: "Alternator",
            system.vehicle: car,
        ]
        let scenario = VehicleScenarioExample(
            fault: kind.rawValue, severity: (severity * 1000).rounded() / 1000,
            overrides: faults.map { fault in
                ParameterOverrideExample(
                    object: objectNames[fault.parameter.object] ?? fault.parameter.object.description, parameter: fault.parameter.quantity,
                    value: (fault.value * 1000).rounded() / 1000
                )
            },
            vin: vin.rawValue, odometerKm: odometer
        )

        return TrainingExample(
            id: id, kind: .chargingDiagnosis, split: split, seed: seed, prompt: prompt, observations: observations, tests: testExamples,
            hypotheses: hypotheses, scenario: nil, messages: nil, ladder: nil,
            answer: AnswerKey(
                cause: kind.rawValue, nextTest: ranking.first?.title, text: text.joined(separator: " "), ranking: ranking, expertPath: path,
                firstDivergence: divergence, trail: nil, blockers: nil
            ),
            vehicle: scenario
        )
    }
}
