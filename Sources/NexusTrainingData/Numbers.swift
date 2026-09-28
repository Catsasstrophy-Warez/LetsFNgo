import Foundation
import NexusCore
import NexusSimulation

/// Number formatting and deterministic identifiers shared by the generators.
enum Numbers {
    /// Rounds to two decimals, the resolution of every virtual instrument.
    static func round2(_ value: Double) -> Double {
        let rounded = (value * 100).rounded() / 100
        return rounded == 0 ? 0 : rounded
    }

    /// Two decimals at most, trailing zeros dropped: 12 → "12", 3.70 → "3.7".
    static func text(_ value: Double) -> String {
        var text = String(format: "%.2f", round2(value))
        while text.contains("."), text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text == "-0" ? "0" : text
    }
}

extension SplitMix64 {
    /// A version-4-shaped UUID drawn from the generator, so object IDs replay with the seed.
    mutating func objectID() -> ObjectID {
        let high = next()
        let low = next()
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> (8 * (7 - $0))) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> (8 * (7 - $0))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return ObjectID(uuid: uuid)
    }

    /// A true value with probability `p`.
    mutating func chance(_ p: Double) -> Bool {
        nextUnit() < p
    }
}
