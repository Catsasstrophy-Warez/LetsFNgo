import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// What one space import did.
public struct SpaceImportResult: Sendable, Hashable {
    /// The `document` object holding the file (its bytes are a blob).
    public var document: ObjectRecord
    public var created: [ObjectRecord]
    public var updated: [ObjectRecord]
    public var unchanged: Int
}

/// Imports space lists (CSV) and the spatial structure of IFC files.
///
/// The file is stored first, as a blob behind a `document` object. Every
/// site, building, storey and space is **recorded** truth from
/// `importer(source:)` naming that document. Re-importing matches IFC
/// objects by GlobalId and list rows by their site/building/storey/number
/// path, and updates what changed, except values a person entered (observed).
public struct SpaceImporter: Sendable {
    public let store: NexusStore
    public let spaces: SpaceRuntime
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.spaces = SpaceRuntime(store: store, clock: clock)
        self.clock = clock
    }

    // MARK: CSV

    /// Imports a space list. Rows without a site, building or storey go
    /// into a building named after the file.
    @discardableResult
    public func importSpaceList(_ data: Data, named fileName: String, by author: Origin) throws -> SpaceImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ArchitectureError.malformedCSV(line: 0, reason: "not text")
        }
        let rows = try SpaceList.parse(text)
        return try store.batch { store in
            let document = try storeDocument(data, named: fileName, mediaType: "text/csv", format: "Space list", by: author)
            var tally = Tally()
            var byKey = Dictionary(
                try spaces.all(.space).compactMap { record in record.string(SpaceKey.listKey).map { ($0, record) } }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                let provenance = provenance(document, author: author, method: "space list line \(row.line)")
                var attributes: [String: Attribute] = [SpaceKey.listKey: Attribute(.string(row.key))]
                if let number = row.number { attributes[SpaceKey.number] = Attribute(.string(number)) }
                if let area = row.area { attributes[SpaceKey.area] = Attribute(.quantity(area)) }
                if let capacity = row.capacity { attributes[SpaceKey.capacity] = Attribute(.int(Int64(capacity))) }
                if let use = row.use { attributes[SpaceKey.use] = Attribute(.string(use)) }
                if let existing = byKey[row.key] {
                    try refresh(existing, title: row.title, attributes: attributes, provenance: provenance, tally: &tally)
                    continue
                }
                var parent: ObjectID?
                let chain: [(SpatialLevel, String?)] = [(.site, row.site), (.building, row.building), (.storey, row.storey)]
                for (level, name) in chain {
                    guard let name else { continue }
                    parent = try container(level, named: name, in: parent, provenance: provenance, tally: &tally).id
                }
                if parent == nil {
                    let building = (fileName as NSString).deletingPathExtension
                    parent = try container(.building, named: building.isEmpty ? "Building" : building, in: nil, provenance: provenance, tally: &tally).id
                }
                let space = try spaces.add(.space, named: row.title, in: parent, attributes: attributes, provenance: provenance)
                byKey[row.key] = space
                tally.created.append(space)
            }
            try recordImport(document: document, tally: tally, format: "Space list", by: author)
            return SpaceImportResult(document: document, created: tally.created, updated: tally.updated, unchanged: tally.unchanged)
        }
    }

    // MARK: IFC

    /// Imports IfcSite, IfcBuilding, IfcBuildingStorey and IfcSpace entities
    /// with their nesting and space areas. Geometry is not read.
    @discardableResult
    public func importIFC(_ data: Data, named fileName: String, by author: Origin) throws -> SpaceImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ArchitectureError.malformedIFC(line: 0, reason: "not text")
        }
        let model = try IFCSpatialModel.read(text)
        return try store.batch { store in
            let document = try storeDocument(data, named: fileName, mediaType: "application/x-step", format: "IFC", by: author)
            var tally = Tally()
            var ids: [String: ObjectID] = [:]
            for level in SpatialLevel.allCases {
                for record in try spaces.all(level) {
                    if let globalID = record.string(SpaceKey.ifcGlobalID) { ids[globalID] = record.id }
                }
            }
            let method = "IFC \(model.schema ?? "file")" + (model.application.map { " from \($0)" } ?? "")
            for node in model.nodes {
                let provenance = provenance(document, author: author, method: "\(method), \(node.level.rawValue) \(node.globalID)")
                var attributes: [String: Attribute] = [SpaceKey.ifcGlobalID: Attribute(.string(node.globalID))]
                if node.level == .space { attributes[SpaceKey.number] = Attribute(.string(node.name)) }
                if let longName = node.longName, !longName.isEmpty { attributes[SpaceKey.longName] = Attribute(.string(longName)) }
                if let elevation = node.elevation { attributes[SpaceKey.elevation] = Attribute(.double(elevation)) }
                if let area = node.area { attributes[SpaceKey.area] = Attribute(.quantity(area)) }
                if let existing = ids[node.globalID], let record = try store.object(existing) {
                    try refresh(record, title: node.title, attributes: attributes, provenance: provenance, tally: &tally)
                    continue
                }
                let record = try spaces.add(node.level, named: node.title, in: node.parent.flatMap { ids[$0] }, attributes: attributes, provenance: provenance)
                ids[node.globalID] = record.id
                tally.created.append(record)
            }
            try recordImport(document: document, tally: tally, format: "IFC", by: author)
            return SpaceImportResult(document: document, created: tally.created, updated: tally.updated, unchanged: tally.unchanged)
        }
    }

    // MARK: Helpers

    struct Tally {
        var created: [ObjectRecord] = []
        var updated: [ObjectRecord] = []
        var unchanged = 0
    }

    private func provenance(_ document: ObjectRecord, author: Origin, method: String) -> Provenance {
        Provenance(origin: .importer(source: document.id), truth: .recorded, timestamp: clock.now(), method: method, dependencies: [document.id])
    }

    /// The site, building or storey with this name in `parent`, created when there is none.
    private func container(_ level: SpatialLevel, named name: String, in parent: ObjectID?, provenance: Provenance, tally: inout Tally) throws
        -> ObjectRecord
    {
        let candidates = try parent.map { try spaces.children(of: $0) } ?? spaces.all(level).filter { try spaces.parent(of: $0.id) == nil }
        if let existing = candidates.first(where: { $0.type == level.objectType && $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let record = try spaces.add(level, named: name, in: parent, attributes: [:], provenance: provenance)
        tally.created.append(record)
        return record
    }

    /// Applies a file's newer values, leaving values a person entered alone.
    private func refresh(_ record: ObjectRecord, title: String, attributes: [String: Attribute], provenance: Provenance, tally: inout Tally) throws {
        let changed = attributes.keys.filter { key in
            record.attributes[key]?.value != attributes[key]!.value && record.truth(of: key) != .observed
        }
        guard !changed.isEmpty || record.title != title else {
            tally.unchanged += 1
            return
        }
        tally.updated.append(
            try store.update(record.id, by: provenance.origin, instruction: "Re-imported") {
                $0.title = title
                for key in changed { $0.attributes[key] = Attribute(attributes[key]!.value, provenance: provenance) }
            })
    }

    private func recordImport(document: ObjectRecord, tally: Tally, format: String, by author: Origin) throws {
        try store.record(
            Event(
                at: clock.now(), kind: .spacesImported, subjects: [document.id],
                summary: "Imported \(tally.created.count) spatial objects (\(tally.updated.count) updated) from \(document.title)",
                payload: [
                    "created": .int(Int64(tally.created.count)), "updated": .int(Int64(tally.updated.count)),
                    "unchanged": .int(Int64(tally.unchanged)), SpaceKey.format: .string(format),
                ],
                provenance: Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "\(format) import")
            ))
    }

    /// Stores the file's bytes as a blob and returns its document object,
    /// reusing the document when the same bytes were imported before.
    func storeDocument(_ data: Data, named fileName: String, mediaType: String, format: String, by author: Origin) throws -> ObjectRecord {
        let blob = try store.putBlob(data, mediaType: mediaType)
        if let existing = try store.objects(ofType: .document).first(where: { $0.string(SpaceKey.blob) == blob.sha256 }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .document, title: fileName,
                attributes: [
                    SpaceKey.blob: Attribute(.string(blob.sha256)),
                    SpaceKey.mediaType: Attribute(.string(mediaType)),
                    SpaceKey.format: Attribute(.string(format)),
                    "byteCount": Attribute(.int(Int64(blob.byteCount))),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "\(format) import")
            ))
    }
}
