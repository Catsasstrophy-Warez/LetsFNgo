import Foundation
import NexusModel

/// A site, building, storey or space read from an IFC file.
public struct SpatialNode: Sendable, Hashable {
    public var globalID: String
    public var level: SpatialLevel
    /// IFC Name: a space's number ("101"), a storey's "Level 1".
    public var name: String
    /// IFC LongName: "Open office".
    public var longName: String?
    /// Storey elevation in metres.
    public var elevation: Double?
    /// Net (or else gross) floor area from the space's base quantities.
    public var area: Quantity?
    /// GlobalId of the enclosing node, nil at the top.
    public var parent: String?

    /// "101 Open office" for a numbered space, otherwise the long name or name.
    public var title: String {
        guard let longName, !longName.isEmpty, longName != name else { return name }
        return level == .space ? "\(name) \(longName)" : longName
    }
}

/// The spatial structure of an IFC file: IfcSite, IfcBuilding,
/// IfcBuildingStorey and IfcSpace, nested by IfcRelAggregates, with space
/// areas from IfcElementQuantity. No geometry is read.
public struct IFCSpatialModel: Sendable, Hashable {
    /// FILE_SCHEMA, e.g. "IFC4" or "IFC2X3".
    public var schema: String?
    /// FILE_NAME's name and originating system.
    public var fileName: String?
    public var application: String?
    /// Outermost first, then in file order.
    public var nodes: [SpatialNode]

    public static func read(_ text: String) throws -> IFCSpatialModel {
        try read(STEP.parse(text))
    }

    public static func read(_ file: StepFile) throws -> IFCSpatialModel {
        let kinds: [String: SpatialLevel] = ["IFCSITE": .site, "IFCBUILDING": .building, "IFCBUILDINGSTOREY": .storey, "IFCSPACE": .space]
        let lengthScale = lengthUnitScale(file)
        let areaUnit = areaUnit(file)

        // Parent by child, from IfcRelAggregates (RelatingObject #4, RelatedObjects #5).
        var parentOf: [Int: Int] = [:]
        for relation in file.entities(ofType: "IFCRELAGGREGATES") + file.entities(ofType: "IFCRELNESTS") {
            guard let parent = relation[4].reference else { continue }
            for child in relation[5].references { parentOf[child] = parent }
        }
        // Area by space, from IfcRelDefinesByProperties → IfcElementQuantity → IfcQuantityArea.
        var areaOf: [Int: Double] = [:]
        for relation in file.entities(ofType: "IFCRELDEFINESBYPROPERTIES") {
            guard let definition = relation[5].reference.flatMap({ file.entities[$0] }), definition.type == "IFCELEMENTQUANTITY" else { continue }
            let quantities = definition[5].references.compactMap { file.entities[$0] }.filter { $0.type == "IFCQUANTITYAREA" }
            var byName: [String: Double] = [:]
            for quantity in quantities {
                if let name = quantity[0].string?.lowercased(), let value = quantity[3].number, byName[name] == nil { byName[name] = value }
            }
            guard let area = byName["netfloorarea"] ?? byName["grossfloorarea"] ?? quantities.lazy.compactMap({ $0[3].number }).first else { continue }
            for space in relation[4].references { areaOf[space] = area }
        }

        var nodes: [SpatialNode] = []
        for entity in file.entities.values.sorted(by: { $0.id < $1.id }) {
            guard let level = kinds[entity.type] else { continue }
            guard let globalID = entity[0].string, !globalID.isEmpty else {
                throw ArchitectureError.malformedIFC(line: entity.line, reason: "#\(entity.id) \(entity.type) has no GlobalId")
            }
            // Walk up past anything that is not spatial (IfcProject).
            var parentID = parentOf[entity.id]
            while let id = parentID, let parent = file.entities[id], kinds[parent.type] == nil { parentID = parentOf[id] }
            let parent = parentID.flatMap { file.entities[$0] }?[0].string
            let longName = entity[7].string
            let name = entity[2].string ?? longName ?? "#\(entity.id)"
            nodes.append(
                SpatialNode(
                    globalID: globalID, level: level, name: name, longName: longName,
                    elevation: level == .storey ? entity[9].number.map { $0 * lengthScale } : nil,
                    area: areaOf[entity.id].map { Quantity($0, areaUnit) }, parent: parent
                ))
        }
        nodes.sort { $0.level < $1.level }
        let header = file.header("FILE_NAME")
        let schema = file.header("FILE_SCHEMA").flatMap { entry -> String? in
            if case .list(let names) = entry[0] { return names.first?.string }
            return entry[0].string
        }
        return IFCSpatialModel(schema: schema, fileName: header?[0].string, application: header?[5].string?.nilIfEmpty, nodes: nodes)
    }

    /// Metres per project length unit: 0.001 for millimetres.
    static func lengthUnitScale(_ file: StepFile) -> Double {
        let prefixes: [String: Double] = ["MILLI": 0.001, "CENTI": 0.01, "DECI": 0.1, "KILO": 1_000]
        for unit in file.entities(ofType: "IFCSIUNIT") where unit[1] == .enumeration("LENGTHUNIT") {
            if case .enumeration(let prefix) = unit[2] { return prefixes[prefix] ?? 1 }
            return 1
        }
        return 1
    }

    static func areaUnit(_ file: StepFile) -> String {
        for unit in file.entities(ofType: "IFCCONVERSIONBASEDUNIT") where unit[1] == .enumeration("AREAUNIT") {
            if unit[2].string?.uppercased().contains("FOOT") == true { return AreaUnit.squareFoot }
        }
        return AreaUnit.squareMetre
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
