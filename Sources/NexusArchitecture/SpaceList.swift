import Foundation
import NexusModel

/// One row of a space list.
public struct SpaceRow: Sendable, Hashable {
    public var site: String?
    public var building: String?
    public var storey: String?
    public var number: String?
    public var name: String?
    public var area: Quantity?
    public var capacity: Int?
    public var use: String?
    public var line: Int

    /// "101 Open office", or whichever of the two there is.
    public var title: String { [number, name].compactMap { $0 }.joined(separator: " ") }

    /// Site/building/storey/number (or name), lower-cased: the row's identity on re-import.
    public var key: String {
        [site ?? "", building ?? "", storey ?? "", number ?? name ?? ""].map { $0.lowercased() }.joined(separator: "/")
    }
}

/// Reads a space list exported from a CAFM tool or a spreadsheet. Columns are
/// found by header name, case-insensitively:
///
/// | column   | headers accepted                                       |
/// |----------|--------------------------------------------------------|
/// | site     | site, campus                                           |
/// | building | building, bldg                                         |
/// | storey   | floor, level, storey, story                            |
/// | number   | number, room, room number, space, space number, no     |
/// | name     | name, room name, space name, description               |
/// | area     | any header containing "area" or "sq ft"/"sqft"         |
/// | capacity | capacity, seats, occupancy                             |
/// | use      | use, type, function, category                          |
///
/// An area header mentioning feet ("Area (sq ft)", "sqft", "sf") is read in
/// square feet, otherwise square metres. A number or a name is required.
public enum SpaceList {
    static let aliases: [(field: String, headers: [String])] = [
        ("site", ["site", "campus"]),
        ("building", ["building", "bldg", "building name"]),
        ("storey", ["floor", "level", "storey", "story", "floor name"]),
        ("number", ["number", "room", "room number", "room no", "space", "space number", "no", "#"]),
        ("name", ["name", "room name", "space name", "description"]),
        ("capacity", ["capacity", "seats", "occupancy"]),
        ("use", ["use", "type", "function", "category", "space type", "room type"]),
    ]

    public static func parse(_ text: String) throws -> [SpaceRow] {
        let records = try CSVRows.parse(text)
        guard let header = records.first else { return [] }
        var columns: [String: Int] = [:]
        var areaUnit = AreaUnit.squareMetre
        for (index, raw) in header.fields.enumerated() {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if columns["area"] == nil, name.contains("area") || name.contains("sqft") || name.contains("sq ft") {
                columns["area"] = index
                if name.contains("ft") || name.hasSuffix(" sf") || name.contains("(sf)") { areaUnit = AreaUnit.squareFoot }
                continue
            }
            if let field = aliases.first(where: { $0.headers.contains(name) })?.field, columns[field] == nil { columns[field] = index }
        }
        guard columns["number"] != nil || columns["name"] != nil else { throw ArchitectureError.missingColumn("number or name") }
        return try records.dropFirst().compactMap { record in
            func field(_ name: String) -> String? {
                guard let index = columns[name], index < record.fields.count else { return nil }
                let value = record.fields[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard record.fields.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            guard field("number") != nil || field("name") != nil else {
                throw ArchitectureError.malformedCSV(line: record.line, reason: "row has no number or name")
            }
            var area: Quantity?
            if let text = field("area") {
                guard let value = number(text), value >= 0 else { throw ArchitectureError.malformedCSV(line: record.line, reason: "bad area '\(text)'") }
                area = Quantity(value, areaUnit)
            }
            var capacity: Int?
            if let text = field("capacity") {
                guard let value = Int(text), value >= 0 else { throw ArchitectureError.malformedCSV(line: record.line, reason: "bad capacity '\(text)'") }
                capacity = value
            }
            return SpaceRow(
                site: field("site"), building: field("building"), storey: field("storey"), number: field("number"), name: field("name"), area: area,
                capacity: capacity, use: field("use"), line: record.line
            )
        }
    }

    /// "86.5", "1,234.5", "86,5" and "1 234,5". A lone comma followed by
    /// exactly three digits is a thousands separator ("1,234").
    static func number(_ text: String) -> Double? {
        var cleaned = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        for unit in ["m²", "m2", "sqft", "ft²", "sf"] where cleaned.lowercased().hasSuffix(unit) { cleaned.removeLast(unit.count) }
        if cleaned.contains(",") && cleaned.contains(".") {
            let comma = cleaned.lastIndex(of: ",")!
            let dot = cleaned.lastIndex(of: ".")!
            cleaned =
                comma < dot
                ? cleaned.replacingOccurrences(of: ",", with: "")
                : cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if let comma = cleaned.firstIndex(of: ","), cleaned.filter({ $0 == "," }).count == 1 {
            let after = cleaned[cleaned.index(after: comma)...]
            cleaned =
                after.count == 3 && after.allSatisfy(\.isNumber)
                ? cleaned.replacingOccurrences(of: ",", with: "") : cleaned.replacingOccurrences(of: ",", with: ".")
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return Double(cleaned)
    }
}

/// RFC 4180 records: quoted fields, doubled quotes, line breaks inside quotes.
enum CSVRows {
    struct Record {
        var fields: [String]
        var line: Int
    }

    static func parse(_ text: String) throws -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var fieldStarted = false
        var line = 1
        var recordLine = 1
        var characters = text.hasPrefix("\u{FEFF}") ? Substring(text.dropFirst()) : Substring(text)
        func endRecord() {
            fields.append(field)
            if !(fields.count == 1 && fields[0].isEmpty) { records.append(Record(fields: fields, line: recordLine)) }
            fields = []
            field = ""
            fieldStarted = false
        }
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" {
                        field.append("\"")
                        characters.removeFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    if character == "\n" || character == "\r\n" { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                guard !fieldStarted else { throw ArchitectureError.malformedCSV(line: line, reason: "quote inside an unquoted field") }
                quoted = true
                fieldStarted = true
            case ",":
                fields.append(field)
                field = ""
                fieldStarted = false
            case "\n", "\r\n", "\r":
                endRecord()
                line += 1
                recordLine = line
            default:
                field.append(character)
                fieldStarted = true
            }
        }
        if quoted { throw ArchitectureError.malformedCSV(line: recordLine, reason: "unterminated quoted field") }
        if fieldStarted || !fields.isEmpty || !field.isEmpty { endRecord() }
        return records
    }
}
