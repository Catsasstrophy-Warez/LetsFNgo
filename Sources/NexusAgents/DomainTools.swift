import Foundation
import NexusAI
import NexusArchitecture
import NexusCRM
import NexusCareer
import NexusCore
import NexusModel
import NexusPersistence
import NexusTravel

/// Read-only tools over the travel, contacts, career and buildings domains.
/// They read through each domain's runtime, like the UI, and write nothing:
/// every timeline, standing and total they return is derived on the spot and
/// labelled as such.
public enum DomainTools {
    public static var all: [any AgentTool] {
        [TripTimelineTool(), ContactsDueTool(), JobApplicationsTool(), ExpiringCertificationsTool(), SpaceSummaryTool(), LocateAssetTool()]
    }

    /// Tool names, for agent profiles.
    public static var names: Set<String> { Set(all.map(\.spec.name)) }
}

private func day(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
}

private func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// An object ID argument that must name an object of one of `types`.
private func record(_ arguments: [String: Value], _ key: String, types: Set<ObjectType>, in context: ToolContext) throws -> ObjectRecord {
    let id = try arguments.objectID(key)
    guard let record = try context.store.object(id), types.contains(record.type) else { throw ToolError.notFound(id.description) }
    return record
}

private func squareMetres(_ value: Double) -> String { String(format: "%.1f m²", value) }

// MARK: - Travel

/// Trips, or one trip's legs in order with connections and conflicts.
public struct TripTimelineTool: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "trip_timeline",
        description: "Without a trip: list trips. With a trip ID: its legs in order, connection times and conflicts (overlaps, tight connections).",
        parameters: schema(["trip": objectArg("Trip ID (optional)")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.trip, .travelLeg], dataSource: ToolScope.worldModel) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let travel = TravelRuntime(store: context.store, clock: context.clock)
        guard try arguments.optionalObjectID("trip") != nil else {
            let trips = try travel.trips()
            let lines = try trips.map { trip -> String in
                let legs = try travel.legs(of: trip.id)
                let span = legs.first.map { " \(day($0.start)) – \(day(legs.map(\.finish).max()!))" } ?? ""
                return "\(trip.id) \(trip.name):\(span), \(legs.count) legs"
            }
            return ToolOutcome(content: lines.isEmpty ? "No trips." : lines.joined(separator: "\n"), touched: trips.map(\.id))
        }
        let trip = try record(arguments, "trip", types: [.trip], in: context)
        let timeline = try travel.timeline(of: trip.id)
        var lines = ["\(trip.title) (legs \(trip.provenance.truth.rawValue); connections and conflicts derived)"]
        for entry in timeline.entries {
            switch entry {
            case .leg(let leg):
                let route = [leg.origin, leg.destination].compactMap { $0 }.joined(separator: " → ")
                var line = "- \(time(leg.start))\(leg.end.map { " to \(time($0))" } ?? "") [\(leg.mode.rawValue)] \(leg.title)"
                if !route.isEmpty && !leg.title.contains(route) { line += " (\(route))" }
                if let seat = leg.seat { line += ", seat \(seat)" }
                if let confirmation = leg.confirmation { line += ", confirmation \(confirmation)" }
                lines.append(line)
            case .connection(_, _, let duration):
                lines.append("  connection: \(Int(duration / 60)) min")
            }
        }
        lines.append(timeline.conflicts.isEmpty ? "No conflicts." : "Conflicts:")
        lines += timeline.conflicts.map { "- \($0.kind.rawValue): \($0.message)" }
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: [trip.id] + timeline.legs.map(\.id))
    }
}

// MARK: - Contacts

/// People past their keep-in-touch cadence.
public struct ContactsDueTool: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "contacts_due",
        description: "People not contacted within their cadence (default 90 days), most overdue first, with the last interaction date.",
        parameters: schema(["default_days": objectArg("Cadence in days for people without their own (optional, default 90)")], required: []),
        permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.person], dataSource: ToolScope.worldModel) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let days = try arguments.optionalInt("default_days", in: 1...3_650) ?? ContactsRuntime.defaultCadenceDays
        let due = try ContactsRuntime(store: context.store, clock: context.clock).overdue(asOf: context.clock.now(), defaultCadence: days)
        let lines = due.prefix(25).map { standing in
            let last = standing.lastContacted.map { "last contact \(day($0)) (\(standing.daysSince!) days ago)" } ?? "never contacted"
            return "\(standing.contact.id) \(standing.contact.name): \(last), cadence \(standing.cadenceDays) days"
        }
        return ToolOutcome(
            content: lines.isEmpty ? "Nobody is overdue." : (["Overdue contacts (derived from logged interactions):"] + lines).joined(separator: "\n"),
            touched: due.map(\.contact.id))
    }
}

// MARK: - Career

/// Job applications grouped by pipeline stage.
public struct JobApplicationsTool: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "job_applications", description: "Job applications grouped by status (saved, applied, screening, interviewing, offer, closed).",
        parameters: schema([:], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.jobApplication], dataSource: ToolScope.worldModel) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let pipeline = try CareerRuntime(store: context.store, clock: context.clock).pipeline()
        var lines: [String] = []
        for (status, applications) in pipeline {
            lines.append("\(status.rawValue) (\(applications.count)):")
            lines += applications.map { "- \($0.id) \($0.title)\($0.appliedOn.map { ", applied \(day($0))" } ?? "")" }
        }
        return ToolOutcome(
            content: lines.isEmpty ? "No job applications." : lines.joined(separator: "\n"), touched: pipeline.flatMap { $0.applications.map(\.id) })
    }
}

/// Certifications expiring soon or already expired.
public struct ExpiringCertificationsTool: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "expiring_certifications", description: "Certifications that have expired or expire within a number of days (default 60).",
        parameters: schema(["within_days": objectArg("Days ahead to look (optional, default 60)")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: [.certification], dataSource: ToolScope.worldModel) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let within = try arguments.optionalInt("within_days", in: 0...3_650) ?? 60
        let now = context.clock.now()
        let career = CareerRuntime(store: context.store, clock: context.clock)
        var touched: [ObjectID] = []
        var lines: [String] = []
        for certification in try career.certifications() {
            let text: String
            switch certification.standing(on: now, soon: within) {
            case .expired(let ago): text = "expired \(ago) days ago"
            case .expiringSoon(let left): text = "expires in \(left) days"
            case .valid, .noExpiry: continue
            }
            touched.append(certification.id)
            let issuer = try career.issuer(of: certification.id).map { " (\($0.title))" } ?? ""
            let expiry = certification.expires.map { " on \(day($0))" } ?? ""
            lines.append("- \(certification.id) \(certification.name)\(issuer): \(text)\(expiry)")
        }
        return ToolOutcome(content: lines.isEmpty ? "No certifications expire within \(within) days." : lines.joined(separator: "\n"), touched: touched)
    }
}

// MARK: - Buildings

/// Buildings with their area, or one site, building, storey or space in detail.
public struct SpaceSummaryTool: AgentTool {
    public init() {}

    static let spatial: Set<ObjectType> = [.site, .building, .storey, .space]

    public let spec = ToolSpec(
        name: "space_summary",
        description:
            "Without an ID: buildings with total floor area. With a site, building, storey or space ID: its contents, area, and the assets located there.",
        parameters: schema(["id": objectArg("Site, building, storey or space ID (optional)")], required: []), permission: .observe
    )

    public var declaredScope: ToolScope { ToolScope(objectTypes: Self.spatial, dataSource: ToolScope.worldModel) }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let spaces = SpaceRuntime(store: context.store, clock: context.clock)
        guard try arguments.optionalObjectID("id") != nil else {
            let buildings = try spaces.all(.building)
            let lines = try buildings.map { building in
                let area = try spaces.area(of: building.id)
                return "\(building.id) \(building.title): \(area.spaces) spaces, \(squareMetres(area.squareMetres)) (derived)"
            }
            return ToolOutcome(content: lines.isEmpty ? "No buildings." : lines.joined(separator: "\n"), touched: buildings.map(\.id))
        }
        let target = try record(arguments, "id", types: Self.spatial, in: context)
        let area = try spaces.area(of: target.id)
        var lines = [try spaces.path(of: target.id).map(\.title).joined(separator: " › ")]
        lines.append(
            "Area: \(squareMetres(area.squareMetres)) over \(area.spaces) spaces (derived)"
                + (area.spacesWithoutArea > 0 ? "; \(area.spacesWithoutArea) without an area" : ""))
        let children = try spaces.children(of: target.id)
        lines += children.prefix(40).map { "- \($0.id) [\($0.type)] \($0.title)" }
        let assets = try spaces.assets(in: target.id)
        if !assets.isEmpty {
            lines.append("Assets:")
            lines += try assets.prefix(40).map { "- \($0.id) [\($0.type)] \($0.title) in \(try spaces.location(of: $0.id)?.title ?? "?")" }
        }
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: [target.id] + children.map(\.id) + assets.map(\.id))
    }
}

/// Where an asset is, and where it has been.
public struct LocateAssetTool: AgentTool {
    public init() {}

    public let spec = ToolSpec(
        name: "locate_asset", description: "The space an asset (equipment, instrument…) is in, with its building path and past locations.",
        parameters: schema(["id": objectArg("Asset ID")], required: ["id"]), permission: .observe
    )

    public func scope(for arguments: [String: Value], in context: ToolContext) throws -> ToolScope {
        ToolScope(objectTypes: try targetTypes(arguments, "id", in: context).union([.space]), dataSource: ToolScope.worldModel)
    }

    public func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let id = try arguments.objectID("id")
        guard let asset = try context.store.object(id) else { throw ToolError.notFound(id.description) }
        let spaces = SpaceRuntime(store: context.store, clock: context.clock)
        let history = try spaces.locationHistory(of: id)
        guard !history.isEmpty else { return ToolOutcome(content: "\(asset.title) has no recorded location.", touched: [id]) }
        var lines: [String] = []
        if let current = try spaces.location(of: id) {
            lines.append("\(asset.title) is in \(try spaces.path(of: current.id).map(\.title).joined(separator: " › "))")
        } else {
            lines.append("\(asset.title) has no current location.")
        }
        let rooms = Dictionary(uniqueKeysWithValues: try context.store.objects(history.map(\.to)).map { ($0.id, $0.title) })
        lines.append("History (\(history.first!.provenance.truth.rawValue)):")
        lines += history.map { edge in
            "- \(rooms[edge.to] ?? "?") from \(edge.validFrom.map(time) ?? "?")\(edge.validTo.map { " to \(time($0))" } ?? " (current)")"
        }
        return ToolOutcome(content: lines.joined(separator: "\n"), touched: [id] + history.map(\.to))
    }
}
