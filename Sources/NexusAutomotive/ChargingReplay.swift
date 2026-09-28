import Foundation
import NexusCore
import NexusSimulation

extension ChargingFaultKind {
    /// The fault kind whose hypothesis statement this is, as proposed by
    /// `ChargingDiagnosis.open`.
    public init?(statement: String) {
        guard let kind = Self.allCases.first(where: { $0.statement == statement }) else { return nil }
        self = kind
    }
}

extension ChargingTest {
    /// The test stored under a quantity name, if any.
    public init?(quantity: String) {
        self.init(rawValue: quantity)
    }
}

extension ChargingDiagnosis {
    /// Severities tried when fitting a case, 0 to 1 in steps of 0.05.
    public static let fittingGrid: [Double] = (0...20).map { Double($0) / 20 }

    /// The severity of `kind` whose standard check best reproduces the
    /// field readings (least squared error, each test scaled by its
    /// tolerance). Ties go to the lower severity. With no usable reading the
    /// worst case (1) is assumed.
    ///
    /// Deterministic: it only runs `ChargingProtocol` on `system`.
    public func fitSeverity(of kind: ChargingFaultKind, to readings: [ChargingTest: Double], stateOfCharge: Double = 0.75) throws -> Double {
        let usable = readings.filter { $0.value.isFinite }
        guard !usable.isEmpty else { return 1 }
        var best: (severity: Double, error: Double)?
        for severity in Self.fittingGrid {
            let run = try ChargingProtocol.run(system, faults: kind.faults(on: system, severity: severity), stateOfCharge: stateOfCharge)
            var error = 0.0
            for (test, value) in usable {
                guard let replayed = run.readings[test] else { continue }
                let scaled = (replayed - value) / test.tolerance
                error += scaled * scaled
            }
            if let current = best, error >= current.error - 1e-12 { continue }
            best = (severity, error)
        }
        return best?.severity ?? 1
    }
}
