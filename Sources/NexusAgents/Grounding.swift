import Foundation
import NexusAI

/// The outcome of checking a final answer against what the run read.
public struct GroundingReport: Sendable, Hashable {
    /// Quantities (numbers with units) found in the answer.
    public var checked: Int
    /// Quantities matching a value the run read through a tool.
    public var grounded: [String]
    /// Quantities the answer labels as modeled or estimated.
    public var labeled: [String]
    /// Quantities neither read nor labeled, e.g. "14.2 mA".
    public var ungrounded: [String]

    public var passed: Bool { ungrounded.isEmpty }

    public var summary: String {
        var parts = ["\(checked) value(s) checked", "\(grounded.count) grounded"]
        if !labeled.isEmpty { parts.append("\(labeled.count) labeled modeled/estimated") }
        if !ungrounded.isEmpty { parts.append("ungrounded: " + ungrounded.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// Checks that every quantity in an answer was read, not invented.
///
/// A quantity is a number with a unit (`QuantityScanner`; tag numbers such as
/// "LT-101" and IDs are not numbers). It is grounded when it equals, within
/// tolerance, a number in what the run read: tool results and the goal the
/// person wrote. Otherwise it passes only if the answer labels it modeled,
/// simulated or estimated in the same sentence, next to the value. This is
/// the runtime form of the evals' hallucinated-number check.
public struct GroundingCheck: Sendable {
    public var relativeTolerance: Double
    public var absoluteTolerance: Double

    public init(relativeTolerance: Double = 0.01, absoluteTolerance: Double = 1e-9) {
        self.relativeTolerance = relativeTolerance
        self.absoluteTolerance = absoluteTolerance
    }

    static let labels = ["modeled", "modelled", "simulated", "estimate"]

    public func check(_ answer: String, against sources: [String]) -> GroundingReport {
        let known = sources.flatMap(QuantityScanner.numbers(in:))
        let quantities = QuantityScanner.quantities(in: answer)
        let characters = Array(answer)
        var report = GroundingReport(checked: quantities.count, grounded: [], labeled: [], ungrounded: [])
        for (index, quantity) in quantities.enumerated() {
            let text = "\(Self.format(quantity.value)) \(quantity.unit)"
            if known.contains(where: { abs($0 - quantity.value) <= max(absoluteTolerance, relativeTolerance * abs($0)) }) {
                report.grounded.append(text)
                continue
            }
            let previousEnd = index > 0 ? quantities[index - 1].end : 0
            let nextStart = index + 1 < quantities.count ? quantities[index + 1].start : characters.count
            let before = Self.clause(characters, from: max(previousEnd, quantity.start - 40), to: quantity.start, keepingEnd: true)
            let after = Self.clause(characters, from: quantity.end, to: min(nextStart, quantity.end + 48), keepingEnd: false)
            let window = (before + " " + after).lowercased()
            if Self.labels.contains(where: window.contains) {
                report.labeled.append(text)
            } else {
                report.ungrounded.append(text)
            }
        }
        return report
    }

    /// Text between two offsets, cut at a sentence end so a label in the
    /// previous or next sentence does not count.
    static func clause(_ characters: [Character], from start: Int, to end: Int, keepingEnd: Bool) -> String {
        guard start < end else { return "" }
        var slice = Array(characters[start..<end])
        func isStop(_ offset: Int) -> Bool {
            let character = slice[offset]
            if character.isNewline || character == "!" || character == "?" { return true }
            guard character == "." else { return false }
            let next = offset + 1 < slice.count ? slice[offset + 1] : " "
            return next.isWhitespace
        }
        if keepingEnd {
            if let stop = slice.indices.last(where: isStop) { slice = Array(slice[(stop + 1)...]) }
        } else if let stop = slice.indices.first(where: isStop) {
            slice = Array(slice[..<stop])
        }
        return String(slice)
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}
