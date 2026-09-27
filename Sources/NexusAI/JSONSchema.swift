import Foundation

/// A validator for the subset of JSON Schema that structured output uses:
/// `type` (one name or a list), `properties`, `required`,
/// `additionalProperties: false`, `items`, `enum`, `minimum`, `maximum`,
/// `minItems`, `maxItems`, `minLength` and `maxLength`. Unknown keywords are
/// ignored, so a schema written for a provider still validates here.
public enum JSONSchema {
    /// Every violation, as "path: problem". Empty when `value` conforms.
    public static func violations(of value: JSONValue, against schema: JSONValue, at path: String = "$") -> [String] {
        guard case .object(let rules) = schema else { return [] }
        var problems: [String] = []

        if let expected = rules["type"] {
            let names: [String] =
                switch expected {
                case .string(let name): [name]
                case .array(let items): items.compactMap(\.stringValue)
                default: []
                }
            if !names.isEmpty, !names.contains(where: { matches(value, type: $0) }) {
                return ["\(path): expected \(names.joined(separator: " or ")), got \(typeName(of: value))"]
            }
        }
        if case .array(let allowed)? = rules["enum"], !allowed.contains(where: { equal($0, value) }) {
            problems.append("\(path): \(value.serialized) is not one of \(JSONValue.array(allowed).serialized)")
        }

        switch value {
        case .object(let members):
            let properties = rules["properties"]?.objectValue ?? [:]
            for name in (rules["required"]?.arrayValue ?? []).compactMap(\.stringValue) where members[name] == nil || members[name] == .null {
                problems.append("\(path).\(name): required")
            }
            for (name, member) in members.sorted(by: { $0.key < $1.key }) {
                if let rule = properties[name] {
                    problems += violations(of: member, against: rule, at: "\(path).\(name)")
                } else if rules["additionalProperties"] == .bool(false) {
                    problems.append("\(path).\(name): not allowed")
                }
            }
        case .array(let items):
            if let minimum = rules["minItems"]?.number, Double(items.count) < minimum {
                problems.append("\(path): fewer than \(Int(minimum)) item(s)")
            }
            if let maximum = rules["maxItems"]?.number, Double(items.count) > maximum {
                problems.append("\(path): more than \(Int(maximum)) item(s)")
            }
            if let rule = rules["items"] {
                for (index, item) in items.enumerated() {
                    problems += violations(of: item, against: rule, at: "\(path)[\(index)]")
                }
            }
        case .string(let text):
            if let minimum = rules["minLength"]?.number, Double(text.count) < minimum {
                problems.append("\(path): shorter than \(Int(minimum)) character(s)")
            }
            if let maximum = rules["maxLength"]?.number, Double(text.count) > maximum {
                problems.append("\(path): longer than \(Int(maximum)) character(s)")
            }
        case .int, .double:
            let number = value.number ?? .nan
            if let minimum = rules["minimum"]?.number, number < minimum {
                problems.append("\(path): below minimum \(minimum)")
            }
            if let maximum = rules["maximum"]?.number, number > maximum {
                problems.append("\(path): above maximum \(maximum)")
            }
        case .null, .bool:
            break
        }
        return problems
    }

    public static func conforms(_ value: JSONValue, to schema: JSONValue) -> Bool {
        violations(of: value, against: schema).isEmpty
    }

    private static func matches(_ value: JSONValue, type name: String) -> Bool {
        switch (name, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("number", .int), ("number", .double): value.number?.isFinite ?? false
        case ("integer", .int): true
        case ("integer", .double(let number)): number.rounded() == number
        default: false
        }
    }

    private static func typeName(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Numbers compare by value, so 1 equals 1.0.
    private static func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        if let left = lhs.number, let right = rhs.number { return left == right }
        return lhs == rhs
    }
}

extension JSONValue {
    /// The value of a JSON number, integer or not.
    public var number: Double? {
        switch self {
        case .int(let number): Double(number)
        case .double(let number): number
        default: nil
        }
    }
}
