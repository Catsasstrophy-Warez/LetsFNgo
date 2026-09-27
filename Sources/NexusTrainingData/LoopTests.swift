import Foundation
import NexusCore
import NexusInvestigation
import NexusSimulation

/// How hard each part of one plant is to reach. Test effort is the base cost
/// times the factor for where the test is taken, so the cheapest informative
/// test differs from plant to plant.
public struct LoopAccess: Sendable, Hashable {
    /// Walking to the tank or standing at the HMI with the operator.
    public var field: Double
    /// Transmitter terminals, often up a ladder or on a tank roof.
    public var terminals: Double
    /// The I/O cabinet holding the card and loop supply.
    public var cabinet: Double
    /// Reading configuration needs the engineering laptop and controller access.
    public var controller: Double
    /// Closed or pressurized vessels often have no sight glass to compare with.
    public var sightGlass: Bool

    init(_ rng: inout SplitMix64) {
        sightGlass = rng.chance(0.5)
        field = rng.pick([1, 2, 3])
        terminals = rng.pick([1, 1.5, 2, 3])
        cabinet = rng.pick([1, 2])
        controller = rng.pick([1, 2.5, 5])
    }

    /// Whether the plant allows this test at all.
    public func offers(_ test: LoopTest) -> Bool {
        test != .sightGlass || sightGlass
    }

    /// Effort in minutes, rounded to the half minute.
    public func cost(of test: LoopTest) -> Double {
        let factor: Double
        switch test {
        case .sightGlass, .bumpTest: factor = field
        case .voltageTrend, .loopCurrent, .terminalVoltage, .loopResistance: factor = terminals
        case .supplyVoltage, .calibrator, .busVoltage: factor = cabinet
        case .channelRange: factor = controller
        }
        return (test.baseCost * factor * 2).rounded() / 2
    }
}

/// Measurements a technician can take on the level loop, each computed from
/// the field simulation the way the real instrument would see it.
public enum LoopTest: String, CaseIterable, Sendable {
    case sightGlass
    case channelRange
    case supplyVoltage
    case voltageTrend
    case loopCurrent
    case terminalVoltage
    case bumpTest
    case calibrator
    case loopResistance
    /// Informative but hazardous; `TestSelector` must never recommend it.
    case busVoltage

    /// The object a test is taken at.
    public enum Site: Sendable {
        case tank
        case transmitter
        case terminal
        case card
    }

    public var title: String {
        switch self {
        case .sightGlass: "Compare the sight glass with the HMI"
        case .channelRange: "Read the AI channel range from the controller"
        case .supplyVoltage: "Measure loop supply voltage at the card"
        case .voltageTrend: "Trend terminal voltage for 60 s"
        case .loopCurrent: "Clamp meter on the loop current"
        case .terminalVoltage: "Terminal voltage at the transmitter"
        case .bumpTest: "Bump the level 5 % in manual and compare the HMI change"
        case .calibrator: "Source 12 mA into the card with a loop calibrator"
        case .loopResistance: "Measure field loop resistance with the card isolated"
        case .busVoltage: "Measure the 24 V bus with covers off"
        }
    }

    public var site: Site {
        switch self {
        case .sightGlass: .tank
        case .bumpTest: .transmitter
        case .voltageTrend, .loopCurrent, .terminalVoltage, .loopResistance: .terminal
        case .channelRange, .supplyVoltage, .calibrator, .busVoltage: .card
        }
    }

    public var quantity: String {
        switch self {
        case .sightGlass: "levelError"
        case .channelRange: "configuredRangeHigh"
        case .supplyVoltage: "supplyVolts"
        case .voltageTrend: "terminalVoltageSwing"
        case .loopCurrent: "loopCurrent"
        case .terminalVoltage: "terminalVoltage"
        case .bumpTest: "bumpGain"
        case .calibrator: "calibratedReading"
        case .loopResistance: "loopOhms"
        case .busVoltage: "busVoltage"
        }
    }

    public var unit: String {
        switch self {
        case .sightGlass, .channelRange, .calibrator: "%"
        case .supplyVoltage, .voltageTrend, .terminalVoltage, .busVoltage: "V"
        case .loopCurrent: "mA"
        case .bumpTest: "ratio"
        case .loopResistance: "Ω"
        }
    }

    /// Effort in minutes at an easy-to-reach site. Scenarios scale it by how
    /// hard the site is to reach (see `LoopAccess`).
    public var baseCost: Double {
        switch self {
        case .sightGlass: 3
        case .channelRange: 2
        case .supplyVoltage: 3
        case .voltageTrend: 3
        case .loopCurrent: 4
        case .terminalVoltage: 5
        case .bumpTest: 8
        case .calibrator: 10
        case .loopResistance: 15
        case .busVoltage: 1
        }
    }

    public var safety: TestSafety {
        switch self {
        case .bumpTest, .calibrator, .loopResistance: .caution
        case .busVoltage: .hazardous
        default: .routine
        }
    }

    /// A configuration read from the controller is recorded; everything else is a field observation.
    public var truth: TruthClass {
        self == .channelRange ? .recorded : .observed
    }

    /// Reading uncertainty, used to pad predicted intervals.
    var tolerance: Double {
        switch self {
        case .sightGlass: 1
        case .channelRange: 0.05
        case .supplyVoltage, .voltageTrend, .terminalVoltage: 0.1
        case .loopCurrent: 0.05
        case .bumpTest: 0.03
        case .calibrator: 0.2
        case .loopResistance, .busVoltage: 5
        }
    }

    /// Tests hypotheses make predictions for. The bus check is left out so it
    /// only shows up as an excluded hazardous option.
    public static var predicted: [LoopTest] {
        allCases.filter { $0 != .busVoltage }
    }

    /// Meter reading for an open loop resistance measurement ("OL").
    public static let overloadOhms = 1_000_000.0

    /// What the instrument reads on the field simulation's current state.
    public func measure(_ field: SimulationRuntime, loop: InstrumentLoop) throws -> Double {
        let state = field.state
        switch self {
        case .sightGlass:
            return try state.value(loop.measuredLevel) - state.value(loop.level)
        case .channelRange:
            return state.parameter(loop.cardRangeHigh, default: try state.parameter(loop.transmitterRangeHigh))
        case .supplyVoltage, .busVoltage:
            return try state.parameter(loop.supplyVolts)
        case .voltageTrend:
            let since = field.seconds - 60
            let recent = field.history.filter { $0.seconds >= since }.compactMap { $0.values[loop.terminalVoltage] }
            return (recent.max() ?? 0) - (recent.min() ?? 0)
        case .loopCurrent:
            return try state.value(loop.loopCurrent)
        case .terminalVoltage:
            return try state.value(loop.terminalVoltage)
        case .bumpTest:
            let base = min(90, max(0, try state.value(loop.level)))
            let before = try Self.reading(atLevel: base, state, loop)
            let after = try Self.reading(atLevel: base + 5, state, loop)
            return (after - before) / 5
        case .calibrator:
            return try AnalogInputSolver.level(forInjected: 12, in: state, loop: loop)
        case .loopResistance:
            // Measured at rest with the loop de-energized. An intermittent
            // contact usually closes at rest, so only the steady contact
            // resistance shows; that is the classic trap this test carries.
            if state.parameter(loop.openCircuit, default: 0) >= 0.5 {
                return Self.overloadOhms
            }
            return try state.parameter(loop.wireOhms) + state.parameter(loop.contactOhms)
        }
    }

    /// The HMI reading the loop would settle to instantly at `level`, holding
    /// everything else (faults, contact state) as it is now.
    private static func reading(atLevel level: Double, _ state: WorldState, _ loop: InstrumentLoop) throws -> Double {
        var probe = state
        probe.values[loop.level] = level
        for solver in loop.solvers where solver.name == "current loop" || solver.name == "analog input" {
            try solver.step(&probe, dt: 0)
        }
        return try probe.value(loop.measuredLevel)
    }
}
