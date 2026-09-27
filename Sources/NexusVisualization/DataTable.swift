import Foundation
import NexusCore

/// A plain table. Every visualization produces one as its accessible
/// equivalent (spec, Accessibility: "table equivalents for charts"), so
/// VoiceOver, keyboard users and exports all get the same data.
public struct DataTable: Codable, Sendable, Hashable {
    public struct Column: Codable, Sendable, Hashable {
        public var title: String
        public var unit: String?
        /// Set when every value in the column shares one truth class.
        public var truth: TruthClass?

        public init(_ title: String, unit: String? = nil, truth: TruthClass? = nil) {
            self.title = title
            self.unit = unit
            self.truth = truth
        }

        /// "Level (%) · modeled".
        public var header: String {
            var text = title
            if let unit, !unit.isEmpty { text += " (\(unit))" }
            if let truth { text += " · \(truth.rawValue)" }
            return text
        }
    }

    public var caption: String
    public var columns: [Column]
    public var rows: [[TableCell]]

    public init(caption: String, columns: [Column], rows: [[TableCell]]) {
        self.caption = caption
        self.columns = columns
        self.rows = rows
    }

    /// Plain text rows, headers first, for exports and screen readers.
    public func formatted(precision: Int = 4) -> [[String]] {
        [columns.map(\.header)] + rows.map { $0.map { $0.formatted(precision: precision) } }
    }
}

public enum TableCell: Codable, Sendable, Hashable {
    case number(Double)
    case text(String)
    case empty

    public func formatted(precision: Int = 4) -> String {
        switch self {
        case .number(let value):
            guard value.isFinite else { return value.isNaN ? "—" : (value > 0 ? "∞" : "−∞") }
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(format: "%.\(max(0, precision))g", value)
        case .text(let text): return text
        case .empty: return ""
        }
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

extension TableCell: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension Optional where Wrapped == Double {
    var cell: TableCell { map(TableCell.number) ?? .empty }
}

extension Optional where Wrapped == String {
    var cell: TableCell { map(TableCell.text) ?? .empty }
}
