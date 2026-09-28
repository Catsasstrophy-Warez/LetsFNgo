import Foundation
import NexusCore

/// The physical faults the instrument loop can express, each as parameter
/// overrides that the solvers turn into honest physics.
///
/// Severity runs from 0 (barely there) to 1 (worst case). The mappings are
/// chosen so that, over the usual 0.25–1 range, every fault is visible at the
/// loop's normal operating points (setpoints 55–90 %).
public enum LoopFaultKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// Corroded or loose terminal: `contactOhms` = 700 + 1300·s Ω, which caps
    /// loop current at (V_supply − V_liftoff) / R_total.
    case contactResistance
    /// Broken wire: `openCircuit` = 1. Loop current 0 mA, the card sees
    /// underrange (< 3.6 mA). Severity is ignored.
    case openWire
    /// Transmitter drift: `outputGain` = 1 − 0.3·s and `outputOffset` = −0.8·s mA
    /// on the requested current, so the loop reads low.
    case transmitterDrift
    /// AI channel frozen: `channelStuck` = 1 and it reports
    /// `channelStuckMilliamps` = 20 − 4·s mA (frozen high) whatever the loop does.
    case cardChannelStuck
    /// AI channel converter gain error: `channelGain` = 1 − 0.4·s, the card
    /// reports that fraction of the true loop current.
    case cardReadsLow
    /// Card range high configured as 100 + 40·s % while the transmitter
    /// spans 0–100 %, so the card reads high.
    case wrongScaling
    /// Barrier or supply sag: `supplyVolts` = 16 − 6·s V, leaving less
    /// compliance headroom above lift-off.
    case supplySag
    /// Intermittent contact: `intermittentOhms` = 1000 + 3000·s Ω added during
    /// the open windows of a seeded 2 s schedule with 35 % duty.
    case intermittentContact

    /// A short statement of the cause, as a technician would propose it.
    public var statement: String {
        switch self {
        case .contactResistance: "Corroded or loose terminal adds series resistance and starves the transmitter of compliance voltage"
        case .openWire: "Open circuit in the loop wiring: no loop current flows"
        case .transmitterDrift: "Transmitter output has drifted (span and zero error on the 4–20 mA signal)"
        case .cardChannelStuck: "AI card channel is frozen and reports a fixed value"
        case .cardReadsLow: "AI card channel converter reads low (gain error)"
        case .wrongScaling: "AI channel range high does not match the transmitter range"
        case .supplySag: "Loop supply or barrier voltage has sagged"
        case .intermittentContact: "Intermittent contact at the terminals makes the loop current drop out"
        }
    }
}

extension InstrumentLoop {
    /// The parameter overrides that realize `kind` at `severity` (clamped to
    /// 0…1). `seed` only matters for the intermittent contact's schedule.
    public func faults(_ kind: LoopFaultKind, severity: Double, seed: UInt64 = 0) -> [SimulatedFault] {
        let s = min(1, max(0, severity))
        func fault(_ key: StateKey, _ value: Double, _ summary: String) -> SimulatedFault {
            SimulatedFault(parameter: key, value: value, summary: summary)
        }
        switch kind {
        case .contactResistance:
            let ohms = 700 + 1300 * s
            return [fault(contactOhms, ohms, "Corroded terminal adds \(Self.format(ohms)) Ω")]
        case .openWire:
            return [fault(openCircuit, 1, "Open circuit in the loop wiring")]
        case .transmitterDrift:
            let gain = 1 - 0.3 * s
            let offset = -0.8 * s
            return [
                fault(outputGain, gain, "Transmitter span error, gain \(Self.format(gain))"),
                fault(outputOffset, offset, "Transmitter zero error, \(Self.format(offset)) mA"),
            ]
        case .cardChannelStuck:
            let milliamps = 20 - 4 * s
            return [
                fault(channelStuck, 1, "AI channel frozen"),
                fault(channelStuckMilliamps, milliamps, "AI channel reports \(Self.format(milliamps)) mA"),
            ]
        case .cardReadsLow:
            let gain = 1 - 0.4 * s
            return [fault(channelGain, gain, "AI channel reads \(Self.format(gain * 100)) % of the loop current")]
        case .wrongScaling:
            let high = 100 + 40 * s
            return [fault(cardRangeHigh, high, "AI channel range high set to \(Self.format(high)) %")]
        case .supplySag:
            let volts = 16 - 6 * s
            return [fault(supplyVolts, volts, "Loop supply sagged to \(Self.format(volts)) V")]
        case .intermittentContact:
            let ohms = 1000 + 3000 * s
            return [
                fault(intermittentOhms, ohms, "Intermittent contact adds \(Self.format(ohms)) Ω when open"),
                fault(intermittentSeed, Double(seed % (1 << 52)), "Intermittent contact schedule"),
            ]
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
