import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation

/// The automotive diagnosis fixture: "cranks slowly / battery light on" on
/// the shared `InvestigationRuntime`, with one hypothesis per
/// `ChargingFaultKind` and predictions computed by the charging solver.
///
/// Predictions are simulated, not hand-written: each fault kind runs the
/// standard check (`ChargingProtocol`) across a severity grid, and each
/// test's interval is the spread of what it would read, padded by the
/// instrument tolerance. Overlapping intervals are merged into one outcome,
/// and a cause whose interval spans two otherwise separate outcomes makes no
/// prediction for that test (it cannot be judged by one reading there).
public struct ChargingDiagnosis: Sendable {
    public static let symptom = "Cranks slowly / battery light on"
    public static let severityGrid: [Double] = [0, 0.25, 0.5, 0.75, 1]

    public var system: ChargingSystem

    public init(system: ChargingSystem) {
        self.system = system
    }

    /// Per cause, the interval each test is predicted to read.
    public static func intervals() throws -> [ChargingFaultKind: [ChargingTest: ClosedRange<Double>]] {
        if let cached = cache.value { return cached }
        let template = ChargingSystem.template()
        var raw: [ChargingFaultKind: [ChargingTest: ClosedRange<Double>]] = [:]
        for kind in ChargingFaultKind.allCases {
            var ranges: [ChargingTest: ClosedRange<Double>] = [:]
            for severity in severityGrid {
                let run = try ChargingProtocol.run(template, faults: kind.faults(on: template, severity: severity))
                for (test, value) in run.readings {
                    ranges[test] = ranges[test].map { min($0.lowerBound, value)...max($0.upperBound, value) } ?? value...value
                }
            }
            raw[kind] = ranges
        }
        let merged = PredictionIntervals.merge(raw, tolerance: { $0.tolerance })
        cache.value = merged
        return merged
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ChargingFaultKind: [ChargingTest: ClosedRange<Double>]]?
        var value: [ChargingFaultKind: [ChargingTest: ClosedRange<Double>]]? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private static let cache = Cache()

    public func predictions(for kind: ChargingFaultKind) throws -> [Prediction] {
        let intervals = try Self.intervals()[kind] ?? [:]
        return ChargingTest.allCases.compactMap { test in
            guard let range = intervals[test] else { return nil }
            return Prediction(testPoint: test.testPoint(in: system), quantity: test.quantity, unit: test.unit, low: range.lowerBound, high: range.upperBound)
        }
    }

    public var testOptions: [TestOption] {
        ChargingTest.allCases.map { test in
            TestOption(
                title: test.title, testPoint: test.testPoint(in: system), quantity: test.quantity, cost: test.cost,
                safety: test.isCaution ? .caution : .routine
            )
        }
    }

    /// Opens the investigation on the vehicle and proposes the four causes.
    /// `evidence` (for example the P0562 fault object) is recorded as what
    /// the hypotheses depend on.
    public func open(
        in runtime: InvestigationRuntime,
        vehicle: ObjectID,
        evidence: [ObjectID] = [],
        by author: Origin
    ) throws -> (investigation: ObjectID, hypotheses: [ChargingFaultKind: Hypothesis]) {
        let investigation = try runtime.open(symptom: Self.symptom, subjects: [vehicle, system.battery, system.alternator], by: author).id
        var hypotheses: [ChargingFaultKind: Hypothesis] = [:]
        for kind in ChargingFaultKind.allCases {
            hypotheses[kind] = try runtime.propose(
                kind.statement, in: investigation, predictions: try predictions(for: kind), dependsOn: evidence, by: author
            )
        }
        return (investigation, hypotheses)
    }

    /// A field reading from a run, taken by an instrument: observed truth.
    public func observe(_ test: ChargingTest, in run: ChargingRun, instrument: ObjectID, at date: Date, uncertainty: Double = 0.01) -> MeasurementRecord {
        MeasurementRecord(
            quantityName: test.quantity, value: Quantity(run.readings[test] ?? .nan, test.unit), uncertainty: uncertainty,
            testPoint: test.testPoint(in: system), instrument: instrument, sampledAt: date,
            provenance: Provenance(origin: .instrument(id: instrument), truth: .observed, timestamp: date, method: test.title)
        )
    }

    /// Where the field first departs from the healthy twin along
    /// `ChargingProtocol.signalPath`.
    public func firstDivergence(field: ChargingRun, twin: ChargingRun) -> Divergence? {
        DivergenceDetector.firstDivergence(
            reference: twin.history, actual: field.history, signalPath: ChargingProtocol.signalPath(system),
            tolerances: ChargingProtocol.tolerances(system)
        )
    }

    /// The two readings behind a divergence: the field value an instrument
    /// saw at that moment (observed) and the twin's value (modeled), at the
    /// same object and quantity, ready for `recordFirstDivergence`.
    public func readings(
        at divergence: Divergence,
        twin: ChargingRun,
        instrument: ObjectID,
        at date: Date
    ) -> (observed: MeasurementRecord, expected: MeasurementRecord) {
        let unit = ChargingSystem.unit(of: divergence.key.quantity)
        let method = "\(divergence.key.quantity) at t = \(Int(divergence.seconds)) s of the standard check"
        let observed = MeasurementRecord(
            quantityName: divergence.key.quantity, value: Quantity(divergence.actual, unit), uncertainty: 0.01, testPoint: divergence.key.object,
            instrument: instrument, sampledAt: date,
            provenance: Provenance(origin: .instrument(id: instrument), truth: .observed, timestamp: date, method: method)
        )
        let expected = MeasurementRecord(
            quantityName: divergence.key.quantity, value: Quantity(divergence.expected, unit), testPoint: divergence.key.object, sampledAt: date,
            provenance: Provenance(origin: .simulation(run: twin.runtime.run), truth: .modeled, timestamp: date, method: "healthy twin: \(method)")
        )
        return (observed, expected)
    }

    /// What a healthy twin reads for the same test: modeled truth.
    public func expect(_ test: ChargingTest, in twin: ChargingRun, at date: Date) -> MeasurementRecord {
        MeasurementRecord(
            quantityName: test.quantity, value: Quantity(twin.readings[test] ?? .nan, test.unit), testPoint: test.testPoint(in: system),
            sampledAt: date,
            provenance: Provenance(origin: .simulation(run: twin.runtime.run), truth: .modeled, timestamp: date, method: "healthy twin: \(test.title)")
        )
    }
}

/// Turns per-cause reading ranges into testable prediction intervals.
public enum PredictionIntervals {
    /// Pads each interval by the test's tolerance, rounds outward to 0.01 and
    /// groups causes per test into outcomes, narrowest interval first. A cause
    /// that overlaps one outcome joins it (the outcome's interval becomes the
    /// union); one that overlaps none starts a new outcome; one that overlaps
    /// several gets no prediction for that test. Outcomes that grow into each
    /// other merge. Every outcome's interval contains each member's own, so a
    /// true cause is never contradicted by a reading it could produce.
    public static func merge<Cause: RawRepresentable & Hashable & CaseIterable, Test: Hashable & CaseIterable>(
        _ raw: [Cause: [Test: ClosedRange<Double>]],
        tolerance: (Test) -> Double
    ) -> [Cause: [Test: ClosedRange<Double>]] where Cause.RawValue == String {
        var result: [Cause: [Test: ClosedRange<Double>]] = [:]
        for test in Test.allCases {
            let padded = Cause.allCases.compactMap { cause -> (Cause, ClosedRange<Double>)? in
                guard let range = raw[cause]?[test] else { return nil }
                let low = ((range.lowerBound - tolerance(test)) * 100).rounded(.down) / 100
                let high = ((range.upperBound + tolerance(test)) * 100).rounded(.up) / 100
                return (cause, low...high)
            }
            .sorted { lhs, rhs in
                let left = lhs.1.upperBound - lhs.1.lowerBound
                let right = rhs.1.upperBound - rhs.1.lowerBound
                return (left, lhs.0.rawValue) < (right, rhs.0.rawValue)
            }

            var groups: [(members: [Cause], range: ClosedRange<Double>)] = []
            for (cause, range) in padded {
                let touching = groups.indices.filter { groups[$0].range.overlaps(range) }
                switch touching.count {
                case 0:
                    groups.append(([cause], range))
                case 1:
                    let index = touching[0]
                    let union = min(groups[index].range.lowerBound, range.lowerBound)...max(groups[index].range.upperBound, range.upperBound)
                    groups[index] = (groups[index].members + [cause], union)
                default:
                    continue
                }
                var merged: [(members: [Cause], range: ClosedRange<Double>)] = []
                for group in groups.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                    if let last = merged.last, last.range.overlaps(group.range) {
                        merged[merged.count - 1] = (last.members + group.members, last.range.lowerBound...max(last.range.upperBound, group.range.upperBound))
                    } else {
                        merged.append(group)
                    }
                }
                groups = merged
            }
            for group in groups {
                for cause in group.members {
                    result[cause, default: [:]][test] = group.range
                }
            }
        }
        return result
    }
}
