import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A typed view of a space object. The canonical state stays in the store.
public struct Space: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public init(record: ObjectRecord) { self.record = record }

    public var id: ObjectID { record.id }
    public var title: String { record.title }
    public var number: String? { record.string(SpaceKey.number) }
    public var area: Quantity? { record.quantity(SpaceKey.area) }
    public var capacity: Int? { record.int(SpaceKey.capacity) }
    public var use: String? { record.string(SpaceKey.use) }
}

/// A booking of a space.
public struct SpaceReservation: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var title: String { record.title }
    public var start: Date { record.date(SpaceKey.start) ?? record.createdAt }
    public var end: Date { record.date(SpaceKey.end) ?? start }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    public var organizer: String? { record.string(SpaceKey.organizer) }
}

/// Total floor area under a spatial object. Derived; never stored.
public struct AreaSummary: Sendable, Hashable {
    /// Sum of the spaces' areas, in square metres.
    public var squareMetres: Double
    public var spaces: Int
    /// Spaces with no area, which the total leaves out.
    public var spacesWithoutArea: Int
    public var truth: TruthClass { .derived }
}

/// Sites, buildings, storeys and spaces, assets located in them, and room
/// bookings, all as objects and relationships in the shared store.
public struct SpaceRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    func provenance(_ author: Origin, method: String? = nil) -> Provenance {
        Provenance(origin: author, truth: author.entryTruth, timestamp: clock.now(), method: method)
    }

    // MARK: Hierarchy

    /// Adds a site, building, storey or space, inside `parent` when given.
    /// A child must sit below its parent's level: a space in a storey or a
    /// building, a storey in a building, a building in a site.
    @discardableResult
    public func add(
        _ level: SpatialLevel, named name: String, in parent: ObjectID? = nil, attributes: [String: Attribute] = [:], by author: Origin
    ) throws -> ObjectRecord {
        try add(level, named: name, in: parent, attributes: attributes, provenance: provenance(author, method: "entered"))
    }

    func add(_ level: SpatialLevel, named name: String, in parent: ObjectID?, attributes: [String: Attribute], provenance: Provenance) throws
        -> ObjectRecord
    {
        try store.batch { store in
            if let parent {
                guard let container = try store.object(parent) else { throw ArchitectureError.notFound(parent, expected: .building) }
                guard let parentLevel = SpatialLevel(container.type), parentLevel < level else {
                    throw ArchitectureError.invalidNesting(child: level, parent: container.type)
                }
            }
            let record = try store.create(ObjectRecord(type: level.objectType, title: name, attributes: attributes, provenance: provenance))
            if let parent { try store.relate(Relationship(kind: .contains, from: parent, to: record.id, provenance: provenance)) }
            return record
        }
    }

    /// A person adds a room: number, name, area, capacity and use.
    @discardableResult
    public func addSpace(
        number: String?, name: String?, area: Quantity? = nil, capacity: Int? = nil, use: String? = nil, in parent: ObjectID, by author: Origin
    ) throws -> Space {
        var attributes: [String: Attribute] = [:]
        if let number, !number.isEmpty { attributes[SpaceKey.number] = Attribute(.string(number)) }
        if let area { attributes[SpaceKey.area] = Attribute(.quantity(area)) }
        if let capacity { attributes[SpaceKey.capacity] = Attribute(.int(Int64(capacity))) }
        if let use, !use.isEmpty { attributes[SpaceKey.use] = Attribute(.string(use)) }
        let title = [number, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        return Space(record: try add(.space, named: title.isEmpty ? "Space" : title, in: parent, attributes: attributes, by: author))
    }

    /// Live objects of one level, by title.
    public func all(_ level: SpatialLevel) throws -> [ObjectRecord] {
        try store.objects(ofType: level.objectType).filter { $0.lifecycle != .deleted }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Spatial objects directly inside `id`, by title.
    public func children(of id: ObjectID) throws -> [ObjectRecord] {
        let ids = try store.relationships(from: id, kind: .contains).filter { $0.validTo == nil }.map(\.to)
        return try store.objects(ids).filter { SpatialLevel($0.type) != nil && $0.lifecycle != .deleted }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// The spatial object directly containing `id`.
    public func parent(of id: ObjectID) throws -> ObjectRecord? {
        let ids = try store.relationships(to: id, kind: .contains).filter { $0.validTo == nil }.map(\.from)
        return try store.objects(ids).first { SpatialLevel($0.type) != nil }
    }

    /// Site › building › storey › space, outermost first, ending with `id`.
    public func path(of id: ObjectID) throws -> [ObjectRecord] {
        guard let record = try store.object(id) else { return [] }
        var path = [record]
        var seen: Set<ObjectID> = [id]
        while let parent = try parent(of: path[0].id), seen.insert(parent.id).inserted { path.insert(parent, at: 0) }
        return path
    }

    /// Every space at or under `id`.
    public func spaces(in id: ObjectID) throws -> [Space] {
        guard let record = try store.object(id) else { throw ArchitectureError.notFound(id, expected: .building) }
        if record.type == .space { return [Space(record: record)] }
        return try children(of: id).flatMap { try spaces(in: $0.id) }
    }

    /// Total area of the spaces at or under `id`, in square metres.
    public func area(of id: ObjectID) throws -> AreaSummary {
        let spaces = try spaces(in: id)
        let areas = spaces.compactMap { $0.area.flatMap(AreaUnit.squareMetres) }
        return AreaSummary(squareMetres: areas.reduce(0, +), spaces: spaces.count, spacesWithoutArea: spaces.count - areas.count)
    }

    // MARK: Assets

    /// Places an asset in a space from now on, ending where it was before.
    @discardableResult
    public func locate(_ asset: ObjectID, in space: ObjectID, by author: Origin) throws -> Relationship {
        try store.batch { store in
            guard let record = try store.object(asset) else { throw StoreError.notFound(asset) }
            guard SpatialLevel(record.type) == nil, record.type != .spaceReservation else { throw ArchitectureError.notAnAsset(asset) }
            guard let target = try store.object(space), target.type == .space else { throw ArchitectureError.notFound(space, expected: .space) }
            let now = clock.now()
            let current = try store.relationships(from: asset, kind: .locatedIn).filter { $0.validTo == nil }
            if let same = current.first(where: { $0.to == space }) { return same }
            for edge in current { try store.end(edge.id, at: now, by: author, instruction: "Moved to \(target.title)") }
            return try store.relate(
                Relationship(kind: .locatedIn, from: asset, to: space, validFrom: now, provenance: provenance(author, method: "located")))
        }
    }

    /// The space an asset is in now.
    public func location(of asset: ObjectID) throws -> ObjectRecord? {
        guard let edge = try store.relationships(from: asset, kind: .locatedIn).first(where: { $0.validTo == nil }) else { return nil }
        return try store.object(edge.to)
    }

    /// Every space the asset has been in, oldest first, with when.
    public func locationHistory(of asset: ObjectID) throws -> [Relationship] {
        try store.relationships(from: asset, kind: .locatedIn).sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
    }

    /// Assets now in the spaces at or under `id`.
    public func assets(in id: ObjectID) throws -> [ObjectRecord] {
        let ids = try spaces(in: id).flatMap { space in
            try store.relationships(to: space.id, kind: .locatedIn).filter { $0.validTo == nil }.map(\.from)
        }
        return try store.objects(ids).filter { $0.lifecycle != .deleted }
    }

    // MARK: Schedules

    /// Books a space. Throws `doubleBooked` when the time overlaps another booking.
    @discardableResult
    public func reserve(_ space: ObjectID, title: String, from start: Date, to end: Date, organizer: String? = nil, by author: Origin) throws
        -> SpaceReservation
    {
        guard end > start else { throw ArchitectureError.invalidInterval(start: start, end: end) }
        return try store.batch { store in
            guard let target = try store.object(space), target.type == .space else { throw ArchitectureError.notFound(space, expected: .space) }
            let clashes = try reservations(of: space).filter { $0.start < end && start < $0.end }
            guard clashes.isEmpty else { throw ArchitectureError.doubleBooked(space: space, conflictsWith: clashes.map(\.id)) }
            let stamp = provenance(author, method: "reserved")
            var attributes: [String: Attribute] = [SpaceKey.start: Attribute(.date(start)), SpaceKey.end: Attribute(.date(end))]
            if let organizer, !organizer.isEmpty { attributes[SpaceKey.organizer] = Attribute(.string(organizer)) }
            let record = try store.create(ObjectRecord(type: .spaceReservation, title: title, attributes: attributes, provenance: stamp))
            try store.relate(Relationship(kind: .reserves, from: record.id, to: space, validFrom: start, validTo: end, provenance: stamp))
            return SpaceReservation(record: record)
        }
    }

    /// A space's live bookings, by start, optionally within an interval.
    public func reservations(of space: ObjectID, during interval: DateInterval? = nil) throws -> [SpaceReservation] {
        let ids = try store.relationships(to: space, kind: .reserves).map(\.from)
        return try store.objects(ids).filter { $0.lifecycle == .active }.map(SpaceReservation.init).filter { reservation in
            guard let interval else { return true }
            return reservation.start < interval.end && interval.start < reservation.end
        }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Spaces at or under `id` with no booking during `interval` and at least
    /// `capacity` seats (spaces without a capacity count only when none is asked).
    public func freeSpaces(in id: ObjectID, during interval: DateInterval, capacity: Int? = nil) throws -> [Space] {
        try spaces(in: id).filter { space in
            if let capacity, (space.capacity ?? 0) < capacity { return false }
            return try reservations(of: space.id, during: interval).isEmpty
        }
    }
}
