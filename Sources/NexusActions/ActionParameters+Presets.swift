import Foundation
import NexusCore
import NexusModel
import NexusPermissions
import NexusProjects

extension CommandID {
    /// The level a command needs when policy alone runs it, as an automation
    /// does. Mirrors the levels the command providers in `NexusProjects`
    /// offer; a command they don't list is treated as sensitive (P5).
    public var defaultPermission: PermissionLevel {
        switch self {
        case .open, .search: .observe
        case .ask, .analyze, .compare, .runAnalysis, .trace: .analyze
        case .create, .export, .investigate, .measure, .recordMeasurement, .proposeHypothesis, .generateReport,
            .generateTrainingScenario, .extractClaim:
            .createDraft
        case .run, .simulate, .link, .group, .confirmHypothesis, .rejectHypothesis, .markFirstDivergence, .createRepairTask,
            .verifyRepair, .closeInvestigation:
            .modifyInternalState
        default: .sensitive
        }
    }
}

/// A preset that can't become an `ActionParameters` field.
public enum PresetError: Error, Equatable, Sendable {
    case unknownField(String)
    /// The field holds structured values (tests, faults, a loop, file data)
    /// that presets don't carry.
    case unsupportedField(ActionParameters.Field)
    case wrongType(ActionParameters.Field, expected: String)
}

extension ActionParameters {
    /// Fields a preset can fill: strings, numbers, dates, truth classes and
    /// object IDs, alone or in lists.
    public static let presettableFields: Set<Field> = Set(Field.allCases).subtracting([
        .attributes, .tests, .predictions, .owner, .faults, .loop, .data,
    ])

    /// Parameters from stored presets, keyed by `Field` raw value. Used by
    /// automations, whose actions keep their parameters as plain values.
    public init(presets: [String: Value]) throws {
        self.init()
        for key in presets.keys.sorted() {
            guard let field = Field(rawValue: key) else { throw PresetError.unknownField(key) }
            try set(field, presets[key]!)
        }
    }

    // swift-format-ignore
    private mutating func set(_ field: Field, _ value: Value) throws {
        guard Self.presettableFields.contains(field) else { throw PresetError.unsupportedField(field) }
        func text() throws -> String {
            guard case .string(let text) = value else { throw PresetError.wrongType(field, expected: "string") }
            return text
        }
        func number() throws -> Double {
            switch value {
            case .double(let number): return number
            case .int(let number): return Double(number)
            default: throw PresetError.wrongType(field, expected: "number")
            }
        }
        func id() throws -> ObjectID {
            switch value {
            case .reference(let id): return id
            case .string(let text): if let id = ObjectID(text) { return id }
            default: break
            }
            throw PresetError.wrongType(field, expected: "object id")
        }
        func ids() throws -> [ObjectID] {
            guard case .list(let values) = value else { return [try id()] }
            return try values.map { item in
                switch item {
                case .reference(let id): return id
                case .string(let text): if let id = ObjectID(text) { return id }
                default: break
                }
                throw PresetError.wrongType(field, expected: "object ids")
            }
        }
        func texts() throws -> [String] {
            guard case .list(let values) = value else { return [try text()] }
            return try values.map { item in
                guard case .string(let text) = item else { throw PresetError.wrongType(field, expected: "strings") }
                return text
            }
        }
        func date() throws -> Date {
            switch value {
            case .date(let date): return date
            case .double(let seconds): return Date(timeIntervalSinceReferenceDate: seconds)
            default: throw PresetError.wrongType(field, expected: "date")
            }
        }
        func raw<T: RawRepresentable>(_ type: T.Type) throws -> T where T.RawValue == String {
            guard let parsed = T(rawValue: try text()) else { throw PresetError.wrongType(field, expected: String(describing: type)) }
            return parsed
        }

        switch field {
        case .title: title = try text()
        case .type: type = ObjectType(rawValue: try text())
        case .project: project = try id()
        case .target: target = try id()
        case .relation: relation = RelationKind(rawValue: try text())
        case .symptom: symptom = try text()
        case .goal: goal = try text()
        case .query: query = try text()
        case .statement: statement = try text()
        case .reason: reason = try text()
        case .resolution: resolution = try text()
        case .summary: summary = try text()
        case .quantity: quantity = try text()
        case .value:
            if case .quantity(let quantity) = value {
                self.value = quantity.value
                unit = unit ?? quantity.unit
            } else {
                self.value = try number()
            }
        case .unit: unit = try text()
        case .testPoint: testPoint = try id()
        case .instrument: instrument = try id()
        case .uncertainty: uncertainty = try number()
        case .rangeLow: rangeLow = try number()
        case .rangeHigh: rangeHigh = try number()
        case .loading: loading = try text()
        case .sampledAt: sampledAt = try date()
        case .truth: truth = try raw(TruthClass.self)
        case .investigation: investigation = try id()
        case .prior: prior = try number()
        case .safetyNotes: safetyNotes = try texts()
        case .dependsOn: dependsOn = try ids()
        case .procedure: procedure = try id()
        case .steps: steps = try texts()
        case .dueAt: dueAt = try date()
        case .evidence: evidence = try ids()
        case .format: format = try raw(ExportFormat.self)
        case .seconds: seconds = try number()
        case .mediaType: mediaType = try text()
        case .sourceClass: sourceClass = try raw(SourceClass.self)
        case .applicability: applicability = try text()
        case .confidence: confidence = try number()
        case .attributes, .tests, .predictions, .owner, .faults, .loop, .data: throw PresetError.unsupportedField(field)
        }
    }
}
