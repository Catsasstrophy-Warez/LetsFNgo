import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

/// Plant names for one generated loop, so examples don't all say "LT-101".
public struct LoopNames: Sendable, Hashable {
    public var tag: String
    public var tank: String
    public var transmitter: String
    public var terminal: String
    public var card: String
    public var controller: String
    public var valve: String
    public var highSwitch: String
    public var lowSwitch: String

    init(_ rng: inout SplitMix64) {
        let number = 100 + rng.nextInt(below: 900)
        let pair = 1 + 2 * rng.nextInt(below: 12)
        tag = "LT-\(number)"
        tank = "Tank T-\(1 + rng.nextInt(below: 9))"
        transmitter = "LT-\(number) level transmitter"
        terminal = "TB-\(1 + rng.nextInt(below: 12)) terminals \(pair)/\(pair + 1)"
        card = "AI card slot \(1 + rng.nextInt(below: 8)) ch \(rng.nextInt(below: 8))"
        controller = "LIC-\(number) level controller"
        valve = "LV-\(number) inlet valve"
        highSwitch = "LSH-\(number)"
        lowSwitch = "LSL-\(number)"
    }
}

/// A seeded instrument-loop case, fully worked: the hidden fault, what the
/// operator sees, every hypothesis with its predictions, `TestSelector`'s
/// ranking, the expert path through the tests and the first divergence.
struct DiagnosisCase {
    var seed: UInt64
    var names: LoopNames
    var loop: InstrumentLoop
    var ids: [LoopTest.Site: ObjectID]
    var kind: LoopFaultKind
    var severity: Double
    var faults: [SimulatedFault]
    var point: LoopScenarioFactory.OperatingPoint
    var access: LoopAccess
    var symptom: String
    var observations: [ObservationExample]
    /// Field readings per test, rounded to instrument resolution.
    var readings: [LoopTest: Double]
    /// Healthy-twin values at the end of the run.
    var twin: [String: Double]
    /// Per cause, the interval each test is predicted to read. A missing test
    /// means the cause makes no usable prediction there.
    var predictions: [LoopFaultKind: [LoopTest: ClosedRange<Double>]]
    var ranking: [RankedTestExample]
    var expertPath: [ExpertStepExample]
    var survivors: [LoopFaultKind]
    var divergence: DivergenceExample?

    var nextTest: String? { ranking.first?.title }

    func title(of site: LoopTest.Site) -> String {
        switch site {
        case .tank: names.tank
        case .transmitter: names.transmitter
        case .terminal: names.terminal
        case .card: names.card
        }
    }

    var testExamples: [TestExample] {
        LoopTest.allCases.filter(access.offers).map { test in
            TestExample(
                title: test.title, object: title(of: test.site), quantity: test.quantity, unit: test.unit,
                cost: access.cost(of: test), safety: "\(test.safety)"
            )
        }
    }

    var hypothesisExamples: [HypothesisExample] {
        LoopFaultKind.allCases.map { kind in
            HypothesisExample(
                cause: kind.rawValue, statement: kind.statement,
                predictions: LoopTest.predicted.filter(access.offers).compactMap { test in
                    guard let range = predictions[kind]?[test] else { return nil }
                    return PredictionExample(test: test.title, quantity: test.quantity, unit: test.unit, low: range.lowerBound, high: range.upperBound)
                }
            )
        }
    }

    var scenarioExample: LoopScenarioExample {
        LoopScenarioExample(
            fault: kind.rawValue, severity: (severity * 1000).rounded() / 1000,
            overrides: faults.map { fault in
                let object = [LoopTest.Site.tank, .transmitter, .terminal, .card].first { ids[$0] == fault.parameter.object }
                return ParameterOverrideExample(
                    object: object.map(title(of:)) ?? fault.parameter.object.description,
                    parameter: fault.parameter.quantity, value: (fault.value * 1000).rounded() / 1000
                )
            },
            setpoint: point.setpoint, initialLevel: point.initialLevel, runSeconds: LoopScenarioFactory.runSeconds
        )
    }
}

/// Runs seeded instrument-loop scenarios and works out their answers.
///
/// Hypothesis predictions come from simulation, not from hand-written
/// numbers: for each fault kind the loop is run across a grid of severities
/// (and, for the intermittent contact, schedules) at the scenario's operating
/// point, and each test's interval is the spread of what it would read, padded
/// by the instrument's tolerance. Intervals that overlap cannot be told apart
/// by one reading, so they are merged into one outcome before `TestSelector`
/// sees them; a cause whose interval spans two otherwise separate outcomes
/// predicts almost anything there and makes no prediction for that test.
/// Predictions depend only on the operating point and are cached.
final class LoopScenarioFactory {
    struct OperatingPoint: Hashable, Sendable {
        var setpoint: Double
        var initialLevel: Double
    }

    static let setpoints: [Double] = [60, 75, 90]
    static let initialLevels: [Double] = [40, 60]
    static let severityRange: ClosedRange<Double> = 0.25...1
    static let severityGrid: [Double] = [0.25, 0.4375, 0.625, 0.8125, 1]
    static let scheduleSeeds: [UInt64] = Array(1...8)
    static let dt = 0.5
    static let runSeconds = 600.0
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Watched signals, upstream first, for the first divergence.
    static let divergenceUnits = ["terminalVoltage": "V", "loopCurrent": "mA", "readCurrent": "mA", "measuredLevel": "%", "output": "%", "level": "%"]

    /// Predictions are pure functions of the operating point, so every
    /// factory in the process shares one cache.
    private final class PredictionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [OperatingPoint: [LoopFaultKind: [LoopTest: ClosedRange<Double>]]] = [:]

        subscript(point: OperatingPoint) -> [LoopFaultKind: [LoopTest: ClosedRange<Double>]]? {
            get { lock.withLock { entries[point] } }
            set { lock.withLock { entries[point] = newValue } }
        }
    }

    private static let predictionCache = PredictionCache()
    private let template = InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())

    // MARK: Simulation

    func run(_ loop: InstrumentLoop, faults: [SimulatedFault], at point: OperatingPoint) throws -> SimulationRuntime {
        let runtime = try SimulationRuntime(
            dt: Self.dt, state: loop.healthyState(initialLevel: point.initialLevel, setpoint: point.setpoint), solvers: loop.solvers
        )
        for fault in faults {
            runtime.inject(fault)
        }
        try runtime.start()
        try runtime.run(for: Self.runSeconds)
        return runtime
    }

    func predictions(at point: OperatingPoint) throws -> [LoopFaultKind: [LoopTest: ClosedRange<Double>]] {
        if let cached = Self.predictionCache[point] {
            return cached
        }
        var raw: [LoopFaultKind: [LoopTest: ClosedRange<Double>]] = [:]
        for kind in LoopFaultKind.allCases {
            let severities = kind == .openWire ? [1.0] : Self.severityGrid
            let seeds = kind == .intermittentContact ? Self.scheduleSeeds : [0]
            var ranges: [LoopTest: ClosedRange<Double>] = [:]
            for severity in severities {
                for seed in seeds {
                    let field = try run(template, faults: template.faults(kind, severity: severity, seed: seed), at: point)
                    for test in LoopTest.predicted {
                        let value = try test.measure(field, loop: template)
                        ranges[test] = ranges[test].map { min($0.lowerBound, value)...max($0.upperBound, value) } ?? value...value
                    }
                }
            }
            raw[kind] = ranges
        }
        let merged = Self.mergeOverlaps(raw)
        Self.predictionCache[point] = merged
        return merged
    }

    /// Pads each interval by the test's tolerance, rounds outward to 0.01 and
    /// groups the causes per test into outcomes.
    ///
    /// Causes are placed narrowest interval first. One that overlaps a single
    /// existing outcome joins it (the outcome's interval becomes the union);
    /// one that overlaps none starts a new outcome; one that overlaps two or
    /// more is left without a prediction for this test. Outcomes that grow
    /// into each other are merged. An outcome's interval always contains each
    /// member's own interval, so a true cause is never contradicted by a
    /// reading it could produce.
    static func mergeOverlaps(_ raw: [LoopFaultKind: [LoopTest: ClosedRange<Double>]]) -> [LoopFaultKind: [LoopTest: ClosedRange<Double>]] {
        var result: [LoopFaultKind: [LoopTest: ClosedRange<Double>]] = [:]
        for test in LoopTest.predicted {
            let padded = LoopFaultKind.allCases.map { kind -> (LoopFaultKind, ClosedRange<Double>) in
                let range = raw[kind]![test]!
                let low = ((range.lowerBound - test.tolerance) * 100).rounded(.down) / 100
                let high = ((range.upperBound + test.tolerance) * 100).rounded(.up) / 100
                return (kind, low...high)
            }
            .sorted { lhs, rhs in
                let left = lhs.1.upperBound - lhs.1.lowerBound
                let right = rhs.1.upperBound - rhs.1.lowerBound
                return (left, lhs.0.rawValue) < (right, rhs.0.rawValue)
            }

            var groups: [(members: [LoopFaultKind], range: ClosedRange<Double>)] = []
            for (kind, range) in padded {
                let touching = groups.indices.filter { groups[$0].range.overlaps(range) }
                switch touching.count {
                case 0:
                    groups.append(([kind], range))
                case 1:
                    let index = touching[0]
                    let union = min(groups[index].range.lowerBound, range.lowerBound)...max(groups[index].range.upperBound, range.upperBound)
                    groups[index] = (groups[index].members + [kind], union)
                default:
                    continue
                }
                groups = Self.coalesce(groups)
            }
            for group in groups {
                for kind in group.members {
                    result[kind, default: [:]][test] = group.range
                }
            }
        }
        return result
    }

    /// Merges outcome groups whose intervals overlap after one of them grew.
    private static func coalesce(_ groups: [(members: [LoopFaultKind], range: ClosedRange<Double>)]) -> [(members: [LoopFaultKind], range: ClosedRange<Double>)] {
        var merged: [(members: [LoopFaultKind], range: ClosedRange<Double>)] = []
        for group in groups.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = merged.last, last.range.overlaps(group.range) {
                merged[merged.count - 1] = (last.members + group.members, last.range.lowerBound...max(last.range.upperBound, group.range.upperBound))
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    // MARK: Cases

    /// Builds the case for one scenario seed. Faults too mild to show any
    /// symptom at the drawn operating point are redrawn, so every case has
    /// something for the operator to report. `forced` pins the fault kind
    /// (tests use it); the seed still draws everything else.
    func makeCase(seed: UInt64, forcing forced: LoopFaultKind? = nil) throws -> DiagnosisCase {
        var rng = SplitMix64(seed: SplitMix64.mix(seed))
        let names = LoopNames(&rng)
        let ids: [LoopTest.Site: ObjectID] = [.tank: rng.objectID(), .transmitter: rng.objectID(), .terminal: rng.objectID(), .card: rng.objectID()]
        let loop = InstrumentLoop(
            tank: ids[.tank]!, transmitter: ids[.transmitter]!, terminal: ids[.terminal]!, card: ids[.card]!,
            controller: rng.objectID(), valve: rng.objectID()
        )
        let access = LoopAccess(&rng)
        let drawn = rng.pick(LoopFaultKind.allCases)
        let kind = forced ?? drawn
        let scheduleSeed = rng.next() >> 12

        var attempt = 0
        while true {
            attempt += 1
            let severity = kind == .openWire ? 1 : rng.nextDouble(in: Self.severityRange)
            let point = OperatingPoint(setpoint: rng.pick(Self.setpoints), initialLevel: rng.pick(Self.initialLevels))
            let faults = loop.faults(kind, severity: severity, seed: scheduleSeed)
            let field = try run(loop, faults: faults, at: point)
            if attempt < 20, !(try Self.isSymptomatic(field, loop: loop)) {
                continue
            }
            let twin = try run(loop, faults: [], at: point)
            return try work(
                seed: seed, names: names, ids: ids, loop: loop, kind: kind, severity: severity,
                faults: faults, point: point, access: access, field: field, twin: twin, rng: &rng
            )
        }
    }

    static func isSymptomatic(_ field: SimulationRuntime, loop: InstrumentLoop) throws -> Bool {
        let error = abs(try LoopTest.sightGlass.measure(field, loop: loop))
        let overflowing = try field.value(loop.overflowing) == 1
        let empty = try field.value(loop.level) <= 1
        let underrange = try field.value(loop.underrange) == 1
        let jumpy = try hmiSwing(field, loop: loop) >= 2
        return error >= 3 || overflowing || empty || underrange || jumpy
    }

    static func hmiSwing(_ field: SimulationRuntime, loop: InstrumentLoop) throws -> Double {
        let since = field.seconds - 60
        let recent = field.history.filter { $0.seconds >= since }.compactMap { $0.values[loop.measuredLevel] }
        return (recent.max() ?? 0) - (recent.min() ?? 0)
    }

    private func work(
        seed: UInt64, names: LoopNames, ids: [LoopTest.Site: ObjectID], loop: InstrumentLoop, kind: LoopFaultKind, severity: Double,
        faults: [SimulatedFault], point: OperatingPoint, access: LoopAccess, field: SimulationRuntime, twin: SimulationRuntime,
        rng: inout SplitMix64
    ) throws -> DiagnosisCase {
        let r = Numbers.round2
        var readings: [LoopTest: Double] = [:]
        for test in LoopTest.allCases {
            readings[test] = r(try test.measure(field, loop: loop))
        }
        let hmi = r(try field.value(loop.measuredLevel))
        let valve = r(try field.value(loop.valvePosition))
        let high = try field.value(loop.overflowing)
        let low = try field.value(loop.level) <= 1 ? 1.0 : 0
        let underrange = try field.value(loop.underrange)
        let swing = r(try Self.hmiSwing(field, loop: loop))
        let twinValues = [
            "terminalVoltage": r(try twin.value(loop.terminalVoltage)),
            "loopCurrent": r(try twin.value(loop.loopCurrent)),
            "level": r(try twin.value(loop.level)),
        ]

        var observations = [
            ObservationExample(name: "measuredLevel", object: names.card, value: hmi, unit: "%", truth: .display, source: "HMI"),
            ObservationExample(name: "setpoint", object: names.controller, value: point.setpoint, unit: "%", truth: .recorded, source: "controller"),
            ObservationExample(name: "valvePosition", object: names.valve, value: valve, unit: "%", truth: .display, source: "HMI"),
            ObservationExample(name: "measuredLevelSwing60s", object: names.card, value: swing, unit: "%", truth: .display, source: "HMI trend"),
            ObservationExample(name: "highLevelAlarm", object: names.highSwitch, value: high, unit: "bool", truth: .recorded, source: "alarm log"),
            ObservationExample(name: "lowLevelAlarm", object: names.lowSwitch, value: low, unit: "bool", truth: .recorded, source: "alarm log"),
            ObservationExample(name: "underrange", object: names.card, value: underrange, unit: "bool", truth: .recorded, source: "card diagnostics"),
        ]
        observations += [
            ObservationExample(name: "terminalVoltage", object: names.terminal, value: twinValues["terminalVoltage"]!, unit: "V", truth: .modeled, source: "healthy twin"),
            ObservationExample(name: "loopCurrent", object: names.terminal, value: twinValues["loopCurrent"]!, unit: "mA", truth: .modeled, source: "healthy twin"),
            ObservationExample(name: "level", object: names.tank, value: twinValues["level"]!, unit: "%", truth: .modeled, source: "healthy twin"),
        ]

        var symptom = "\(names.tag) reads \(Numbers.text(hmi)) % on the HMI against a \(Numbers.text(point.setpoint)) % setpoint; "
            + "\(names.valve.components(separatedBy: " ").first!) is \(Numbers.text(valve)) % open."
        if high == 1 {
            symptom += " High-level switch \(names.highSwitch) is in alarm and the tank is overflowing."
        }
        if low == 1 {
            symptom += " Low-level switch \(names.lowSwitch) is in alarm."
        }
        if underrange == 1 {
            symptom += " The AI card reports an underrange diagnostic on the channel."
        }
        if swing >= 2 {
            symptom += " The HMI trend has jumped by \(Numbers.text(swing)) % over the last minute."
        }
        if high == 0, low == 0, underrange == 0, swing < 2 {
            symptom += access.sightGlass
                ? " The operator says the sight glass does not agree with the HMI."
                : " A manual dip of the tank does not agree with the HMI."
        }

        let predictions = try predictions(at: point)
        let (ranking, path, survivors) = try investigate(
            names: names, ids: ids, access: access, predictions: predictions, readings: readings, rng: &rng
        )

        let watched = [loop.terminalVoltage, loop.loopCurrent, loop.readCurrent, loop.measuredLevel, loop.controllerOutput, loop.level]
        let divergence = DivergenceDetector.firstDivergence(
            reference: twin.history, actual: field.history, signalPath: watched, defaultTolerance: 0.05
        ).map { found -> DivergenceExample in
            let site = [LoopTest.Site.tank, .transmitter, .terminal, .card].first { ids[$0] == found.key.object }
            let object = site.map { site in
                switch site {
                case .tank: names.tank
                case .transmitter: names.transmitter
                case .terminal: names.terminal
                case .card: names.card
                }
            } ?? names.controller
            return DivergenceExample(
                object: object, quantity: found.key.quantity, unit: Self.divergenceUnits[found.key.quantity] ?? "",
                tick: found.tick, seconds: found.seconds, expected: r(found.expected), actual: r(found.actual)
            )
        }

        return DiagnosisCase(
            seed: seed, names: names, loop: loop, ids: ids, kind: kind, severity: severity, faults: faults, point: point, access: access,
            symptom: symptom, observations: observations, readings: readings, twin: twinValues, predictions: predictions,
            ranking: ranking, expertPath: path, survivors: survivors, divergence: divergence
        )
    }

    /// Opens an investigation in an in-memory store, proposes one hypothesis
    /// per fault kind, ranks the tests and then follows the top-ranked test,
    /// assessing the field's reading each time, until one cause is left or no
    /// test can split the survivors.
    private func investigate(
        names: LoopNames, ids: [LoopTest.Site: ObjectID], access: LoopAccess,
        predictions: [LoopFaultKind: [LoopTest: ClosedRange<Double>]], readings: [LoopTest: Double], rng: inout SplitMix64
    ) throws -> ([RankedTestExample], [ExpertStepExample], [LoopFaultKind]) {
        let clock = ManualClock(Self.t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let tech = Origin.user(id: "dataset-tech")
        let recorded = Provenance(origin: tech, truth: .recorded, timestamp: Self.t0)
        let sites: [(LoopTest.Site, ObjectType, String)] = [
            (.tank, .equipment, names.tank), (.transmitter, .sensor, names.transmitter),
            (.terminal, .testPoint, names.terminal), (.card, .component, names.card),
        ]
        for (site, type, title) in sites {
            try store.create(ObjectRecord(id: ids[site]!, type: type, title: title, provenance: recorded))
        }
        let meter = try store.create(ObjectRecord(id: rng.objectID(), type: .instrument, title: "Virtual DMM", provenance: recorded)).id

        let runtime = InvestigationRuntime(store: store, clock: clock)
        let investigation = try runtime.open(symptom: "\(names.tag) reading disagrees with the process", subjects: [ids[.transmitter]!], by: tech).id
        var causes: [ObjectID: LoopFaultKind] = [:]
        for kind in LoopFaultKind.allCases {
            let hypothesis = try runtime.propose(
                kind.statement, in: investigation,
                predictions: LoopTest.predicted.filter(access.offers).compactMap { test in
                    guard let range = predictions[kind]?[test] else { return nil }
                    return Prediction(testPoint: ids[test.site]!, quantity: test.quantity, unit: test.unit, low: range.lowerBound, high: range.upperBound)
                },
                by: tech
            )
            causes[hypothesis.id] = kind
        }
        let options = LoopTest.allCases.filter(access.offers).map { test in
            TestOption(title: test.title, testPoint: ids[test.site]!, quantity: test.quantity, cost: access.cost(of: test), safety: test.safety)
        }
        func label(_ group: [ObjectID]) -> [String] {
            group.map { causes[$0]!.rawValue }.sorted()
        }
        func live() throws -> [LoopFaultKind] {
            try runtime.hypotheses(of: investigation).filter(\.state.isLive).map { causes[$0.id]! }.sorted { $0.rawValue < $1.rawValue }
        }

        let first = try runtime.rankTests(options, for: investigation)
        let ranking = first.map { recommendation in
            RankedTestExample(
                title: recommendation.option.title, informationGain: (recommendation.informationGain * 1000).rounded() / 1000,
                score: (recommendation.score * 1000).rounded() / 1000, outcomes: recommendation.outcomes.map(label)
            )
        }

        var path: [ExpertStepExample] = []
        var remaining = try live()
        while remaining.count > 1, path.count < LoopTest.allCases.count {
            guard let best = try runtime.rankTests(options, for: investigation).first(where: { $0.informationGain > 1e-9 }),
                  let test = LoopTest.allCases.first(where: { $0.title == best.option.title })
            else { break }
            clock.advance(by: access.cost(of: test) * 60)
            let origin: Origin = test.truth == .recorded ? .importer(source: ids[.card]!) : .instrument(id: meter)
            let reading = MeasurementRecord(
                id: rng.objectID(), quantityName: test.quantity, value: Quantity(readings[test]!, test.unit), uncertainty: 0,
                testPoint: ids[test.site]!, instrument: test.truth == .observed ? meter : nil, sampledAt: clock.now(),
                provenance: Provenance(origin: origin, truth: test.truth, timestamp: clock.now(), method: test.title)
            )
            try store.add(reading)
            try runtime.assess(reading.id, in: investigation, by: tech)
            remaining = try live()
            path.append(ExpertStepExample(test: test.title, value: readings[test]!, unit: test.unit, truth: test.truth, remaining: remaining.map(\.rawValue)))
        }
        return (ranking, path, remaining)
    }
}
