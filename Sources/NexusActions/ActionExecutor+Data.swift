import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence

extension ActionExecutor {
    // MARK: Compare

    /// Attribute-by-attribute comparison. Each cell keeps the truth class and
    /// origin of the value it shows, so a modeled value next to an observed
    /// one stays visibly modeled. Measurements add `measurement.*` rows
    /// (value, unit, uncertainty, test point, loading, sampled at).
    public func compare(_ ids: [ObjectID]) throws -> ActionResult<Comparison> {
        guard ids.count >= 2 else { throw ActionError.selectionSize(.compare, expected: "two or more", got: ids.count) }
        let records = try requireAll(ids)
        var tables: [[String: ComparisonCell]] = []
        for record in records {
            var cells: [String: ComparisonCell] = [:]
            func cell(_ value: Value, _ provenance: Provenance) -> ComparisonCell {
                ComparisonCell(
                    value: value, text: Self.text(value), truth: provenance.truth, origin: provenance.origin, timestamp: provenance.timestamp
                )
            }
            cells["title"] = cell(.string(record.title), record.provenance)
            cells["type"] = cell(.string(record.type.rawValue), record.provenance)
            for (key, attribute) in record.attributes {
                cells[key] = cell(attribute.value, attribute.provenance ?? record.provenance)
            }
            if let reading = try store.measurement(record.id) {
                cells["measurement.value"] = cell(.double(reading.value.value), reading.provenance)
                cells["measurement.unit"] = cell(.string(reading.value.unit), reading.provenance)
                cells["measurement.testPoint"] = cell(.reference(reading.testPoint), reading.provenance)
                cells["measurement.sampledAt"] = cell(.date(reading.sampledAt), reading.provenance)
                if let uncertainty = reading.uncertainty { cells["measurement.uncertainty"] = cell(.double(uncertainty), reading.provenance) }
                if let loading = reading.loading { cells["measurement.loading"] = cell(.string(loading), reading.provenance) }
            }
            tables.append(cells)
        }
        let leading = ["title", "type"]
        let keys = leading + Set(tables.flatMap(\.keys)).subtracting(leading).sorted()
        let rows = keys.map { key in
            let cells = tables.map { $0[key] }
            let present = cells.compactMap { $0 }
            return ComparisonRow(
                attribute: key, cells: cells,
                differs: present.count < cells.count || Set(present.map(\.value)).count > 1,
                mixedTruth: Set(present.map(\.truth)).count > 1
            )
        }
        let objects = records.map { ComparedObject(id: $0.id, title: $0.title, type: $0.type, truth: $0.provenance.truth) }
        let differing = rows.filter(\.differs).count
        return ActionResult(
            detail: Comparison(objects: objects, rows: rows), screen: .collection, focus: nil,
            summary: "Compared \(records.count) objects: \(differing) of \(rows.count) attributes differ"
        )
    }

    // MARK: Export

    /// Exports objects with their provenance and truth.
    ///
    /// - JSON: one entry per object with its provenance, every attribute with
    ///   its own truth and origin, the measurement or claim record behind it,
    ///   and its outgoing relationships.
    /// - CSV: one row per value (`title`, each attribute, measurement fields),
    ///   with `truth`, `origin`, `timestamp`, `method`, `confidence` and
    ///   `revision` columns.
    public func export(_ ids: [ObjectID], format: ExportFormat) throws -> ActionResult<ExportedData> {
        guard !ids.isEmpty else { throw ActionError.emptySelection(.export) }
        let records = try requireAll(ids)
        let data: Data
        switch format {
        case .json: data = try exportJSON(records)
        case .csv: data = try exportCSV(records)
        }
        let exported = ExportedData(
            format: format, data: data, mediaType: format.mediaType, suggestedFilename: "nexus-export-\(records.count).\(format.rawValue)"
        )
        return ActionResult(detail: exported, screen: .collection, focus: nil, summary: "Exported \(records.count) objects as \(format.rawValue.uppercased())")
    }

    private func exportJSON(_ records: [ObjectRecord]) throws -> Data {
        var entries: [ExportJSON.Object] = []
        for record in records {
            let attributes = record.attributes.keys.sorted().map { key in
                let attribute = record.attributes[key]!
                return ExportJSON.Attribute(
                    key: key, value: ExportJSON.Value(attribute.value), provenance: ExportJSON.Provenance(attribute.provenance ?? record.provenance),
                    inherited: attribute.provenance == nil
                )
            }
            let measurement = try store.measurement(record.id).map { reading in
                ExportJSON.Measurement(
                    quantity: reading.quantityName, value: reading.value.value, unit: reading.value.unit, uncertainty: reading.uncertainty,
                    resolution: reading.resolution, rangeLow: reading.rangeLow, rangeHigh: reading.rangeHigh,
                    testPoint: reading.testPoint.description, instrument: reading.instrument?.description, loading: reading.loading,
                    sampledAt: Self.iso(reading.sampledAt), provenance: ExportJSON.Provenance(reading.provenance)
                )
            }
            let claim = try store.claim(record.id).map { claim in
                ExportJSON.Claim(
                    statement: claim.statement, sources: claim.sources.map(\.description), passages: claim.passages,
                    sourceClass: claim.sourceClass.rawValue, applicability: claim.applicability,
                    counterevidence: claim.counterevidence.map(\.description), provenance: ExportJSON.Provenance(claim.provenance)
                )
            }
            let relationships = try store.relationships(from: record.id).map { link in
                ExportJSON.Relationship(
                    id: link.id.description, kind: link.kind.rawValue, from: link.from.description, to: link.to.description,
                    validFrom: link.validFrom.map(Self.iso), validTo: link.validTo.map(Self.iso), provenance: ExportJSON.Provenance(link.provenance)
                )
            }
            entries.append(
                ExportJSON.Object(
                    id: record.id.description, type: record.type.rawValue, title: record.title, lifecycle: record.lifecycle.rawValue,
                    revision: record.revision?.description, createdAt: Self.iso(record.createdAt), updatedAt: Self.iso(record.updatedAt),
                    provenance: ExportJSON.Provenance(record.provenance), attributes: attributes, measurement: measurement, claim: claim,
                    relationships: relationships
                ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ExportJSON.Document(exportedAt: Self.iso(clock.now()), exportedBy: Self.describe(actor), objects: entries))
    }

    private func exportCSV(_ records: [ObjectRecord]) throws -> Data {
        let header = ["object_id", "object_type", "object_title", "field", "value", "unit", "truth", "origin", "timestamp", "method", "confidence", "revision"]
        var lines = [header.map(Self.csv).joined(separator: ",")]
        func row(_ record: ObjectRecord, _ field: String, _ value: String, _ unit: String?, _ provenance: Provenance) {
            let columns = [
                record.id.description, record.type.rawValue, record.title, field, value, unit ?? "", provenance.truth.rawValue,
                Self.describe(provenance.origin), Self.iso(provenance.timestamp), provenance.method ?? "",
                provenance.confidence.map { String($0) } ?? "", record.revision?.description ?? "",
            ]
            lines.append(columns.map(Self.csv).joined(separator: ","))
        }
        for record in records {
            row(record, "title", record.title, nil, record.provenance)
            for key in record.attributes.keys.sorted() {
                let attribute = record.attributes[key]!
                var unit: String?
                if case .quantity(let quantity) = attribute.value { unit = quantity.unit }
                row(record, key, Self.text(attribute.value, withUnit: false), unit, attribute.provenance ?? record.provenance)
            }
            if let reading = try store.measurement(record.id) {
                row(record, "measurement.value", String(reading.value.value), reading.value.unit, reading.provenance)
                if let uncertainty = reading.uncertainty {
                    row(record, "measurement.uncertainty", String(uncertainty), reading.value.unit, reading.provenance)
                }
                row(record, "measurement.testPoint", reading.testPoint.description, nil, reading.provenance)
                row(record, "measurement.sampledAt", Self.iso(reading.sampledAt), nil, reading.provenance)
                if let loading = reading.loading { row(record, "measurement.loading", loading, nil, reading.provenance) }
            }
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: Analyze

    /// What is known about each object: truth mix, relationships, events,
    /// revisions, latest readings and open investigations. Writes nothing.
    public func analyze(_ ids: [ObjectID]) throws -> ActionResult<[ObjectAnalysis]> {
        guard !ids.isEmpty else { throw ActionError.emptySelection(.analyze) }
        let records = try requireAll(ids)
        var analyses: [ObjectAnalysis] = []
        for record in records {
            var truth: [TruthClass: Int] = [:]
            for attribute in record.attributes.values {
                truth[(attribute.provenance ?? record.provenance).truth, default: 0] += 1
            }
            var kinds: [RelationKind: Int] = [:]
            for edge in try graph.edges(of: record.id) {
                kinds[edge.relationship.kind, default: 0] += 1
            }
            let events = try store.events(about: record.id)
            var latest: [String: MeasurementRecord] = [:]
            for reading in try store.measurements(at: record.id) {
                let key = "\(reading.quantityName)|\(reading.truth.rawValue)"
                if latest[key].map({ $0.sampledAt <= reading.sampledAt }) ?? true { latest[key] = reading }
            }
            let investigating = try store.relationships(to: record.id, kind: .investigates).map(\.from)
            let open = try store.objects(investigating).filter { $0.attributes["status"]?.value != .string("closed") }.map(\.id)
            analyses.append(
                ObjectAnalysis(
                    record: record, attributeTruth: truth, relationships: kinds, eventCount: events.count, lastEvent: events.last,
                    revisionCount: try store.revisions(of: record.id).count,
                    latestMeasurements: latest.keys.sorted().map { latest[$0]! }, openInvestigations: open
                ))
        }
        let summary = records.count == 1 ? "Analyzed \(records[0].title)" : "Analyzed \(records.count) objects"
        return ActionResult(
            detail: analyses, screen: records.count == 1 ? .objectDetail : .collection, focus: records.count == 1 ? records[0].id : nil,
            summary: summary
        )
    }

    // MARK: Formatting

    static func text(_ value: Value, withUnit: Bool = true) -> String {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .bool(let flag): flag ? "true" : "false"
        case .date(let date): iso(date)
        case .quantity(let quantity): withUnit ? "\(quantity.value) \(quantity.unit)" : String(quantity.value)
        case .reference(let id): id.description
        case .list(let values): values.map { text($0) }.joined(separator: "; ")
        case .map(let fields): fields.keys.sorted().map { "\($0)=\(text(fields[$0]!))" }.joined(separator: "; ")
        case .null: ""
        }
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func describe(_ origin: Origin) -> String {
        switch origin {
        case .user(let id): "user:\(id)"
        case .agent(let id, let run): "agent:\(id)" + (run.map { "@\($0)" } ?? "")
        case .importer(let source): "importer:\(source)"
        case .simulation(let run): "simulation:\(run)"
        case .instrument(let id): "instrument:\(id)"
        case .model(let ref): "model:\(ref.provider)/\(ref.modelID)"
        case .system: "system"
        }
    }

    static func csv(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The JSON export's shape. Values are plain JSON, not Swift enum encodings.
enum ExportJSON {
    struct Document: Encodable {
        var format = "nexus-export"
        var version = 1
        var exportedAt: String
        var exportedBy: String
        var objects: [Object]
    }

    struct Object: Encodable {
        var id, type, title, lifecycle: String
        var revision: String?
        var createdAt, updatedAt: String
        var provenance: Provenance
        var attributes: [Attribute]
        var measurement: Measurement?
        var claim: Claim?
        var relationships: [Relationship]
    }

    struct Provenance: Encodable {
        var truth: String
        var origin: String
        var timestamp: String
        var method: String?
        var confidence: Double?
        var dependencies: [String]
        var transformation: String?
        var revision: String?

        init(_ provenance: NexusCore.Provenance) {
            truth = provenance.truth.rawValue
            origin = ActionExecutor.describe(provenance.origin)
            timestamp = ActionExecutor.iso(provenance.timestamp)
            method = provenance.method
            confidence = provenance.confidence
            dependencies = provenance.dependencies.map(\.description)
            transformation = provenance.transformation
            revision = provenance.revision?.description
        }
    }

    struct Attribute: Encodable {
        var key: String
        var value: Value
        var provenance: Provenance
        /// True when the attribute carries no provenance of its own and inherits the object's.
        var inherited: Bool
    }

    struct Measurement: Encodable {
        var quantity: String
        var value: Double
        var unit: String
        var uncertainty, resolution, rangeLow, rangeHigh: Double?
        var testPoint: String
        var instrument, loading: String?
        var sampledAt: String
        var provenance: Provenance
    }

    struct Claim: Encodable {
        var statement: String
        var sources: [String]
        var passages: [String]
        var sourceClass: String
        var applicability: String?
        var counterevidence: [String]
        var provenance: Provenance
    }

    struct Relationship: Encodable {
        var id, kind, from, to: String
        var validFrom, validTo: String?
        var provenance: Provenance
    }

    indirect enum Value: Encodable {
        case string(String)
        case number(Double)
        case integer(Int64)
        case bool(Bool)
        case quantity(Double, String)
        case reference(String)
        case list([Value])
        case map([String: Value])
        case null

        init(_ value: NexusModel.Value) {
            switch value {
            case .string(let text): self = .string(text)
            case .int(let number): self = .integer(number)
            case .double(let number): self = .number(number)
            case .bool(let flag): self = .bool(flag)
            case .date(let date): self = .string(ActionExecutor.iso(date))
            case .quantity(let quantity): self = .quantity(quantity.value, quantity.unit)
            case .reference(let id): self = .reference(id.description)
            case .list(let values): self = .list(values.map(Value.init))
            case .map(let fields): self = .map(fields.mapValues(Value.init))
            case .null: self = .null
            }
        }

        private enum Keys: String, CodingKey {
            case value, unit, ref
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let text):
                var container = encoder.singleValueContainer()
                try container.encode(text)
            case .number(let number):
                var container = encoder.singleValueContainer()
                if number.isFinite { try container.encode(number) } else { try container.encode(String(number)) }
            case .integer(let number):
                var container = encoder.singleValueContainer()
                try container.encode(number)
            case .bool(let flag):
                var container = encoder.singleValueContainer()
                try container.encode(flag)
            case .quantity(let value, let unit):
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(value, forKey: .value)
                try container.encode(unit, forKey: .unit)
            case .reference(let id):
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(id, forKey: .ref)
            case .list(let values):
                var container = encoder.singleValueContainer()
                try container.encode(values)
            case .map(let fields):
                var container = encoder.singleValueContainer()
                try container.encode(fields)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }
}
