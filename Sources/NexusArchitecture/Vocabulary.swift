import Foundation
import NexusCore
import NexusModel

// Building and space terms on NexusModel's open vocabularies. Sites,
// buildings, storeys and spaces are ordinary objects nested with the core
// `contains` relationship, so a project that contains a building reaches its
// rooms and everything located in them. Equipment and other assets keep their
// own types and point at a space with `locatedIn`. Room bookings are
// `spaceReservation` objects. Areas are quantities; totals are derived on
// read. There is no geometry. Nothing here keeps state of its own.

extension ObjectType {
    /// A plot of land holding one or more buildings (IfcSite).
    public static let site: ObjectType = "site"
    /// A building (IfcBuilding).
    public static let building: ObjectType = "building"
    /// A floor or level of a building (IfcBuildingStorey).
    public static let storey: ObjectType = "storey"
    /// A room or other bounded area (IfcSpace).
    public static let space: ObjectType = "space"
    /// A booking of a space for a time.
    public static let spaceReservation: ObjectType = "spaceReservation"
}

extension RelationKind {
    /// Asset (equipment, instrument, vehicle…) → the space it is in. Moving
    /// the asset ends the old relationship and starts a new one, so the
    /// history of where it was stays.
    public static let locatedIn: RelationKind = "locatedIn"
    /// Reservation → the space it books.
    public static let reserves: RelationKind = "reserves"
}

extension EventKind {
    /// A space list or IFC file was imported. Payload: counts.
    public static let spacesImported: EventKind = "spacesImported"
}

/// Attribute keys used on spatial objects.
public enum SpaceKey {
    /// A space's room number, e.g. "101".
    public static let number = "number"
    /// IFC LongName, e.g. "Open office".
    public static let longName = "longName"
    /// Floor area, as a quantity in "m2" or "[sft_i]".
    public static let area = "area"
    public static let capacity = "capacity"
    /// What a space is for: office, meeting, lab, storage…
    public static let use = "use"
    /// A storey's elevation above the building's datum, in metres.
    public static let elevation = "elevation"
    /// The IFC GlobalId an object was imported from, for re-import.
    public static let ifcGlobalID = "ifcGlobalId"
    /// A space's path from a space list (site/building/storey/number), for re-import.
    public static let listKey = "listKey"
    public static let start = "start"
    public static let end = "end"
    public static let organizer = "organizer"
    public static let blob = "blob"
    public static let mediaType = "mediaType"
    public static let format = "format"
}

/// The levels of the spatial hierarchy, outermost first.
public enum SpatialLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case site
    case building
    case storey
    case space

    public var objectType: ObjectType {
        switch self {
        case .site: .site
        case .building: .building
        case .storey: .storey
        case .space: .space
        }
    }

    public init?(_ type: ObjectType) {
        guard let level = Self.allCases.first(where: { $0.objectType == type }) else { return nil }
        self = level
    }

    public static func < (lhs: SpatialLevel, rhs: SpatialLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Area units: square metres and international square feet (UCUM).
public enum AreaUnit {
    public static let squareMetre = "m2"
    public static let squareFoot = "[sft_i]"
    public static let squareMetresPerSquareFoot = 0.09290304

    /// The area in square metres, or nil for a quantity that is not an area.
    public static func squareMetres(_ quantity: Quantity) -> Double? {
        switch quantity.unit {
        case squareMetre: quantity.value
        case squareFoot: quantity.value * squareMetresPerSquareFoot
        default: nil
        }
    }
}

public enum ArchitectureError: Error, Equatable, Sendable {
    case notFound(ObjectID, expected: ObjectType)
    /// A child placed under something that cannot hold it (a building in a room).
    case invalidNesting(child: SpatialLevel, parent: ObjectType)
    /// A spatial object is not an asset that can be located.
    case notAnAsset(ObjectID)
    case invalidInterval(start: Date, end: Date)
    case doubleBooked(space: ObjectID, conflictsWith: [ObjectID])
    case malformedCSV(line: Int, reason: String)
    case missingColumn(String)
    case malformedIFC(line: Int, reason: String)
}

extension Origin {
    /// The truth class of a value this author enters: a person's entry is an
    /// observation, an importer's a record, an agent's an interpretation.
    var entryTruth: TruthClass {
        if case .user = self { return .observed }
        return defaultTruth
    }
}

extension ObjectRecord {
    func string(_ key: String) -> String? {
        if case .string(let text)? = attributes[key]?.value { return text }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let date)? = attributes[key]?.value { return date }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let number)? = attributes[key]?.value { return Int(number) }
        return nil
    }

    func quantity(_ key: String) -> Quantity? {
        if case .quantity(let quantity)? = attributes[key]?.value { return quantity }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case .double(let number)? = attributes[key]?.value { return number }
        return nil
    }
}
