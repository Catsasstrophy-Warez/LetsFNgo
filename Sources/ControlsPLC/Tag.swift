import Foundation

public enum TagDataType: String, Codable, Sendable {
    case bool
    case dint
    case real
    case timer
    case counter
}

public enum TagRole: String, Codable, Sendable {
    case input
    case output
    case internalValue
}

public struct TimerValue: Codable, Equatable, Sendable {
    public var PRE: Int32
    public var ACC: Int32
    public var EN: Bool
    public var TT: Bool
    public var DN: Bool

    public init(PRE: Int32 = 0, ACC: Int32 = 0, EN: Bool = false, TT: Bool = false, DN: Bool = false) {
        self.PRE = PRE
        self.ACC = ACC
        self.EN = EN
        self.TT = TT
        self.DN = DN
    }
}

public struct CounterValue: Codable, Equatable, Sendable {
    public var PRE: Int32
    public var ACC: Int32
    public var CU: Bool
    public var CD: Bool
    public var DN: Bool
    public var OV: Bool
    public var UN: Bool

    public init(PRE: Int32 = 0, ACC: Int32 = 0, CU: Bool = false, CD: Bool = false, DN: Bool = false, OV: Bool = false, UN: Bool = false) {
        self.PRE = PRE
        self.ACC = ACC
        self.CU = CU
        self.CD = CD
        self.DN = DN
        self.OV = OV
        self.UN = UN
    }
}

public enum TagValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case dint(Int32)
    case real(Double)
    case timer(TimerValue)
    case counter(CounterValue)

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var numericValue: Double? {
        switch self {
        case let .dint(value): Double(value)
        case let .real(value): value
        default: nil
        }
    }
}

public struct PLCTag: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var dataType: TagDataType
    public var value: TagValue
    public var description: String
    public var role: TagRole

    public init(id: UUID = UUID(), name: String, value: TagValue, description: String = "", role: TagRole = .internalValue) {
        self.id = id
        self.name = name
        self.value = value
        self.description = description
        self.role = role
        switch value {
        case .bool: self.dataType = .bool
        case .dint: self.dataType = .dint
        case .real: self.dataType = .real
        case .timer: self.dataType = .timer
        case .counter: self.dataType = .counter
        }
    }
}

public enum TagStoreError: Error, Equatable {
    case duplicateTag(String)
    case missingTag(String)
    case typeMismatch(tag: String, expected: TagDataType)
    case nonNumericTag(String)
    case numericOverflow(tag: String)
}

public struct TagStore: Codable, Equatable, Sendable {
    private var tagsByName: [String: PLCTag] = [:]

    public init(tags: [PLCTag] = []) throws {
        for tag in tags { try add(tag) }
    }

    public var allTags: [PLCTag] {
        tagsByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func add(_ tag: PLCTag) throws {
        guard tagsByName[tag.name] == nil else { throw TagStoreError.duplicateTag(tag.name) }
        tagsByName[tag.name] = tag
    }

    public func contains(_ name: String) -> Bool {
        if tagsByName[name] != nil { return true }
        return (try? memberValue(for: name)) != nil
    }

    public func value(for name: String) throws -> TagValue {
        if let tag = tagsByName[name] { return tag.value }
        return try memberValue(for: name)
    }

    public func dataType(for name: String) throws -> TagDataType {
        if let tag = tagsByName[name] { return tag.dataType }
        let value = try memberValue(for: name)
        switch value {
        case .bool: return .bool
        case .dint: return .dint
        case .real: return .real
        case .timer: return .timer
        case .counter: return .counter
        }
    }

    public func bool(_ name: String) throws -> Bool {
        guard case let .bool(value) = try value(for: name) else {
            throw TagStoreError.typeMismatch(tag: name, expected: .bool)
        }
        return value
    }

    public func dint(_ name: String) throws -> Int32 {
        guard case let .dint(value) = try value(for: name) else {
            throw TagStoreError.typeMismatch(tag: name, expected: .dint)
        }
        return value
    }

    public func real(_ name: String) throws -> Double {
        guard case let .real(value) = try value(for: name) else {
            throw TagStoreError.typeMismatch(tag: name, expected: .real)
        }
        return value
    }

    public func timer(_ name: String) throws -> TimerValue {
        guard case let .timer(value) = try value(for: name) else {
            throw TagStoreError.typeMismatch(tag: name, expected: .timer)
        }
        return value
    }

    public func counter(_ name: String) throws -> CounterValue {
        guard case let .counter(value) = try value(for: name) else {
            throw TagStoreError.typeMismatch(tag: name, expected: .counter)
        }
        return value
    }

    public func numeric(_ name: String) throws -> Double {
        guard let value = try value(for: name).numericValue else { throw TagStoreError.nonNumericTag(name) }
        return value
    }

    public mutating func setBool(_ name: String, _ value: Bool) throws {
        try replace(name, expected: .bool, with: .bool(value))
    }

    public mutating func setDInt(_ name: String, _ value: Int32) throws {
        try replace(name, expected: .dint, with: .dint(value))
    }

    public mutating func setReal(_ name: String, _ value: Double) throws {
        try replace(name, expected: .real, with: .real(value))
    }

    public mutating func setTimer(_ name: String, _ value: TimerValue) throws {
        try replace(name, expected: .timer, with: .timer(value))
    }

    public mutating func setCounter(_ name: String, _ value: CounterValue) throws {
        try replace(name, expected: .counter, with: .counter(value))
    }

    public mutating func setValue(_ name: String, _ value: TagValue) throws {
        let expected = try dataType(for: name)
        let actual: TagDataType
        switch value {
        case .bool: actual = .bool
        case .dint: actual = .dint
        case .real: actual = .real
        case .timer: actual = .timer
        case .counter: actual = .counter
        }
        guard expected == actual else { throw TagStoreError.typeMismatch(tag: name, expected: expected) }
        try replace(name, expected: expected, with: value)
    }

    public mutating func setNumeric(_ name: String, _ value: Double) throws {
        switch try dataType(for: name) {
        case .dint:
            guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else {
                throw TagStoreError.numericOverflow(tag: name)
            }
            try setDInt(name, Int32(value.rounded(.towardZero)))
        case .real:
            try setReal(name, value)
        default:
            throw TagStoreError.nonNumericTag(name)
        }
    }

    private func memberValue(for name: String) throws -> TagValue {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw TagStoreError.missingTag(name) }
        let base = String(parts[0])
        let member = String(parts[1]).uppercased()
        guard let tag = tagsByName[base] else { throw TagStoreError.missingTag(name) }

        switch tag.value {
        case let .timer(timer):
            switch member {
            case "PRE": return .dint(timer.PRE)
            case "ACC": return .dint(timer.ACC)
            case "EN": return .bool(timer.EN)
            case "TT": return .bool(timer.TT)
            case "DN": return .bool(timer.DN)
            default: throw TagStoreError.missingTag(name)
            }
        case let .counter(counter):
            switch member {
            case "PRE": return .dint(counter.PRE)
            case "ACC": return .dint(counter.ACC)
            case "CU": return .bool(counter.CU)
            case "CD": return .bool(counter.CD)
            case "DN": return .bool(counter.DN)
            case "OV": return .bool(counter.OV)
            case "UN": return .bool(counter.UN)
            default: throw TagStoreError.missingTag(name)
            }
        default:
            throw TagStoreError.missingTag(name)
        }
    }

    private mutating func replace(_ name: String, expected: TagDataType, with value: TagValue) throws {
        guard var tag = tagsByName[name] else { throw TagStoreError.missingTag(name) }
        guard tag.dataType == expected else { throw TagStoreError.typeMismatch(tag: name, expected: expected) }
        tag.value = value
        tagsByName[name] = tag
    }
}
