import Foundation
import NexusCore
import NexusModel
import NexusPersistence

public enum AutomotiveError: Error, Equatable, Sendable {
    case invalidVIN(VIN.ValidationError)
    case duplicateVIN(String)
    case notAVehicle(ObjectID)
    case odometerWentBackwards(previous: Double, new: Double)
    /// PID readings are either what the ECU reports (display) or what a
    /// scan tool measured itself (observed).
    case unsupportedTruth(TruthClass)
}

/// A typed view of a vehicle object and its component topology. The
/// canonical state stays in the store; this struct only reads it.
public struct Vehicle: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord
    public var vin: VIN
    public var components: [VehicleComponentRole: ObjectID]

    public var id: ObjectID { record.id }
    public var title: String { record.title }

    public var odometerKm: Double? {
        if case .quantity(let quantity)? = record.attributes[AutomotiveKey.odometer]?.value { return quantity.value }
        return nil
    }

    public var modelYear: Int? {
        if case .int(let year)? = record.attributes[AutomotiveKey.modelYear]?.value { return Int(year) }
        return nil
    }

    public func component(_ role: VehicleComponentRole) -> ObjectID? { components[role] }
}

/// One maintenance or repair visit.
public struct ServiceEntry: Sendable, Hashable {
    public var title: String
    public var performedAt: Date
    public var odometerKm: Double
    public var steps: [String]
    public var parts: [String]
    public var notes: String?

    public init(title: String, performedAt: Date, odometerKm: Double, steps: [String] = [], parts: [String] = [], notes: String? = nil) {
        self.title = title
        self.performedAt = performedAt
        self.odometerKm = odometerKm
        self.steps = steps
        self.parts = parts
        self.notes = notes
    }
}

/// A service visit as stored: the procedure object and its timeline event.
public struct ServiceRecord: Sendable, Hashable {
    public var procedure: ObjectRecord
    public var event: Event

    public var odometerKm: Double? {
        if case .quantity(let quantity)? = event.payload[AutomotiveKey.odometer] { return quantity.value }
        return nil
    }
}

/// The garage: vehicles, their component topology, service history, trouble
/// codes and OBD readings, all as canonical objects, relationships, events
/// and measurements in the shared store.
///
/// ## Truth classes for scan-tool data
///
/// - A Mode 01 PID is the ECU's own report of what its sensors read, relayed
///   by the scan tool. By the spec's definitions that is **Display Truth**
///   ("value shown by a device"), not an observation: the ECU may be wrong,
///   and a wrong ECU value is exactly what a diagnosis has to catch. Such
///   readings are stored with `truth: .display` and an `importer(source:)`
///   origin naming the ECU, so they never count as evidence in an
///   investigation and never overwrite a meter reading.
/// - A value the scan tool measures itself, such as the ELM327's `ATRV`
///   supply voltage at the diagnostic connector, is **Observed Truth** with an
///   `instrument` origin. A caller may also label a PID reading observed when
///   it has independently checked that channel, by passing `truth: .observed`.
/// - Stored trouble codes (Mode 03/07/0A) are the ECU's record of its own
///   monitors: **Recorded Truth**. Their generic meanings from the bundled
///   SAE J2012 table are **Claimed Truth**.
public struct VehicleRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Vehicles

    /// Adds a vehicle by VIN and builds its component topology.
    ///
    /// The check digit is enforced for North American VINs unless
    /// `requireCheckDigit` says otherwise. WMI, region, country, manufacturer
    /// and model year are decoded from the VIN and stored as derived values.
    @discardableResult
    public func addVehicle(
        vin text: String,
        title: String? = nil,
        odometerKm: Double? = nil,
        requireCheckDigit: Bool? = nil,
        components roles: [VehicleComponentRole] = VehicleComponentRole.allCases,
        by author: Origin
    ) throws -> Vehicle {
        let vin: VIN
        do {
            vin = try VIN(text)
            if requireCheckDigit ?? (vin.region == "North America"), let expected = VIN.checkDigit(for: vin.rawValue), expected != vin.checkCharacter {
                throw VIN.ValidationError.checkDigitMismatch(expected: expected, found: vin.checkCharacter)
            }
        } catch let error as VIN.ValidationError {
            throw AutomotiveError.invalidVIN(error)
        }
        if try vehicle(vin: vin.rawValue) != nil { throw AutomotiveError.duplicateVIN(vin.rawValue) }

        return try store.batch { store in
            let now = clock.now()
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
            let decoded = Provenance(
                origin: .system, truth: .derived, timestamp: now, method: "VIN decode (ISO 3779 / 49 CFR 565)", transformation: "vin"
            )
            var attributes: [String: Attribute] = [
                AutomotiveKey.vin: Attribute(.string(vin.rawValue)),
                AutomotiveKey.wmi: Attribute(.string(vin.wmi), provenance: decoded),
                AutomotiveKey.region: Attribute(.string(vin.region), provenance: decoded),
            ]
            if let country = vin.country { attributes[AutomotiveKey.country] = Attribute(.string(country), provenance: decoded) }
            if let maker = vin.manufacturer { attributes[AutomotiveKey.manufacturer] = Attribute(.string(maker), provenance: decoded) }
            if let year = vin.modelYear { attributes[AutomotiveKey.modelYear] = Attribute(.int(Int64(year)), provenance: decoded) }
            if let odometerKm { attributes[AutomotiveKey.odometer] = Attribute(.quantity(Quantity(odometerKm, "km"))) }
            let name = title ?? [vin.modelYear.map(String.init), vin.manufacturer, vin.rawValue].compactMap { $0 }.joined(separator: " ")
            let record = try store.create(ObjectRecord(type: .vehicle, title: name, attributes: attributes, provenance: provenance))

            var components: [VehicleComponentRole: ObjectID] = [:]
            for role in roles {
                components[role] = try store.create(
                    ObjectRecord(
                        type: role.objectType, title: "\(role.title) (\(vin.serial))",
                        attributes: [
                            AutomotiveKey.role: Attribute(.string(role.rawValue)),
                            AutomotiveKey.system: Attribute(.string(role.system.rawValue)),
                        ],
                        provenance: provenance
                    )
                ).id
            }
            for (kind, from, to) in Self.topology(record.id, components) {
                try store.relate(Relationship(kind: kind, from: from, to: to, provenance: provenance))
            }
            return Vehicle(record: record, vin: vin, components: components)
        }
    }

    /// Containment and wiring, like the instrument loop: the vehicle contains
    /// its major parts, the engine contains its sensors, and `connectedTo`
    /// follows current and data (alternator → battery → starter, battery →
    /// ground strap → engine block, sensors → ECU → CAN bus).
    static func topology(_ vehicle: ObjectID, _ parts: [VehicleComponentRole: ObjectID]) -> [(RelationKind, ObjectID, ObjectID)] {
        var links: [(RelationKind, ObjectID, ObjectID)] = []
        for role in VehicleComponentRole.allCases {
            guard let id = parts[role] else { continue }
            let parent = role.isSensor && role != .vehicleSpeedSensor ? parts[.engine] ?? vehicle : vehicle
            links.append((.contains, parent, id))
        }
        let wiring: [(VehicleComponentRole, VehicleComponentRole)] = [
            (.alternator, .battery), (.battery, .starter), (.battery, .groundStrap), (.groundStrap, .engine), (.battery, .ecu),
            (.ecu, .canBus),
        ]
        let sensors = VehicleComponentRole.allCases.filter(\.isSensor).map { ($0, VehicleComponentRole.ecu) }
        for (from, to) in wiring + sensors {
            if let a = parts[from], let b = parts[to] {
                links.append((.connectedTo, a, b))
            }
        }
        return links
    }

    public func vehicle(_ id: ObjectID) throws -> Vehicle {
        guard let record = try store.object(id), record.type == .vehicle,
            case .string(let text)? = record.attributes[AutomotiveKey.vin]?.value
        else { throw AutomotiveError.notAVehicle(id) }
        var components: [VehicleComponentRole: ObjectID] = [:]
        var frontier = [id]
        for _ in 0..<2 {
            let children = try frontier.flatMap { try store.relationships(from: $0, kind: .contains).filter { $0.validTo == nil }.map(\.to) }
            for child in try store.objects(children) {
                if case .string(let raw)? = child.attributes[AutomotiveKey.role]?.value, let role = VehicleComponentRole(rawValue: raw) {
                    components[role] = child.id
                }
            }
            frontier = children
        }
        return Vehicle(record: record, vin: try VIN(text), components: components)
    }

    public func vehicle(vin: String) throws -> Vehicle? {
        let normalized = vin.uppercased().filter { !$0.isWhitespace }
        guard let match = try store.objects(ofType: .vehicle).first(where: { $0.attributes[AutomotiveKey.vin]?.value == .string(normalized) }) else {
            return nil
        }
        return try vehicle(match.id)
    }

    public func vehicles() throws -> [Vehicle] {
        try store.objects(ofType: .vehicle).map { try vehicle($0.id) }
    }

    // MARK: Service history and odometer

    /// Stores a service visit as a procedure object linked to the vehicle and
    /// a `service` event on the timeline, and advances the odometer.
    @discardableResult
    public func recordService(_ entry: ServiceEntry, on vehicleID: ObjectID, by author: Origin) throws -> ServiceRecord {
        try store.batch { store in
            let vehicle = try vehicle(vehicleID)
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "service record")
            var attributes: [String: Attribute] = [
                AutomotiveKey.steps: Attribute(.list(entry.steps.map(Value.string))),
                AutomotiveKey.parts: Attribute(.list(entry.parts.map(Value.string))),
                AutomotiveKey.odometer: Attribute(.quantity(Quantity(entry.odometerKm, "km"))),
                AutomotiveKey.performedAt: Attribute(.date(entry.performedAt)),
            ]
            if let notes = entry.notes { attributes["notes"] = Attribute(.string(notes)) }
            let procedure = try store.create(ObjectRecord(type: .procedure, title: entry.title, attributes: attributes, provenance: provenance))
            try store.relate(Relationship(kind: .serviced, from: vehicleID, to: procedure.id, validFrom: entry.performedAt, provenance: provenance))
            let event = Event(
                at: entry.performedAt, kind: .service, subjects: [vehicleID, procedure.id], summary: entry.title,
                payload: [
                    AutomotiveKey.odometer: .quantity(Quantity(entry.odometerKm, "km")),
                    AutomotiveKey.parts: .list(entry.parts.map(Value.string)),
                ],
                provenance: provenance
            )
            try store.record(event)
            try advanceOdometer(vehicle, to: entry.odometerKm, at: entry.performedAt, provenance: provenance, instruction: "Service: \(entry.title)")
            return ServiceRecord(procedure: procedure, event: event)
        }
    }

    /// Service visits, oldest first.
    public func serviceHistory(of vehicleID: ObjectID) throws -> [ServiceRecord] {
        _ = try vehicle(vehicleID)
        return try store.events(about: vehicleID).filter { $0.kind == .service }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.compactMap { event in
            guard event.subjects.count > 1, let procedure = try store.object(event.subjects[1]) else { return nil }
            return ServiceRecord(procedure: procedure, event: event)
        }
    }

    /// Records an odometer reading. Readings never go backwards.
    public func recordOdometer(_ km: Double, at date: Date, on vehicleID: ObjectID, by author: Origin) throws {
        try store.batch { store in
            let vehicle = try vehicle(vehicleID)
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "odometer")
            try store.record(
                Event(
                    at: date, kind: .odometerReading, subjects: [vehicleID], summary: "Odometer \(Int(km)) km",
                    payload: [AutomotiveKey.odometer: .quantity(Quantity(km, "km"))], provenance: provenance
                ))
            try advanceOdometer(vehicle, to: km, at: date, provenance: provenance, instruction: "Odometer reading")
        }
    }

    /// Every dated odometer value: the one given when the vehicle was added,
    /// then service visits and readings, oldest first.
    public func odometerHistory(of vehicleID: ObjectID) throws -> [(at: Date, km: Double)] {
        let vehicle = try vehicle(vehicleID)
        var history: [(at: Date, km: Double)] = []
        if let first = try store.revisions(of: vehicleID).first?.snapshot,
            case .quantity(let quantity)? = first.attributes[AutomotiveKey.odometer]?.value
        {
            history.append((first.createdAt, quantity.value))
        }
        for event in try store.events(about: vehicle.id) where event.kind == .service || event.kind == .odometerReading {
            if case .quantity(let quantity)? = event.payload[AutomotiveKey.odometer] {
                history.append((event.at, quantity.value))
            }
        }
        return history.sorted { $0.at < $1.at }
    }

    /// Odometer values must not decrease with time. Back-filled history is
    /// fine as long as it fits between the readings around it; the vehicle's
    /// odometer attribute follows the latest-dated value.
    private func advanceOdometer(_ vehicle: Vehicle, to km: Double, at date: Date, provenance: Provenance, instruction: String) throws {
        let others = try odometerHistory(of: vehicle.id).filter { !($0.at == date && $0.km == km) }
        if let earlier = others.filter({ $0.at <= date }).map(\.km).max(), earlier > km {
            throw AutomotiveError.odometerWentBackwards(previous: earlier, new: km)
        }
        if let later = others.filter({ $0.at > date }).map(\.km).min(), later < km {
            throw AutomotiveError.odometerWentBackwards(previous: km, new: later)
        }
        guard others.allSatisfy({ $0.at <= date }), vehicle.odometerKm != km else { return }
        try store.update(vehicle.id, by: provenance.origin, instruction: instruction) {
            $0.attributes[AutomotiveKey.odometer] = Attribute(.quantity(Quantity(km, "km")), provenance: provenance)
        }
    }

    // MARK: Trouble codes

    /// Stores trouble codes read from the ECU as `fault` objects linked to the
    /// vehicle (`hasFault`) and to the ECU (`reportedBy`). A code already
    /// active on the vehicle with the same status is not duplicated.
    @discardableResult
    public func recordTroubleCodes(
        _ codes: [DTC],
        status: DTCStatus,
        on vehicleID: ObjectID,
        knowledgeBase: DTCKnowledgeBase = .generic,
        by author: Origin
    ) throws -> [ObjectRecord] {
        try store.batch { store in
            let vehicle = try vehicle(vehicleID)
            let now = clock.now()
            let source = vehicle.component(.ecu) ?? vehicleID
            let recorded = Provenance(
                origin: .importer(source: source), truth: .recorded, timestamp: now, method: "OBD-II mode \(status.mode) read by \(author)"
            )
            let meaning = Provenance(origin: .system, truth: .claimed, timestamp: now, method: "SAE J2012 generic definition")
            let existing = try faults(of: vehicleID)
            var faults: [ObjectRecord] = []
            for code in codes {
                if let match = existing.first(where: {
                    $0.attributes[AutomotiveKey.dtc]?.value == .string(code.code)
                        && $0.attributes[AutomotiveKey.dtcStatus]?.value == .string(status.rawValue) && $0.lifecycle == .active
                }) {
                    faults.append(match)
                    continue
                }
                let definition = knowledgeBase[code]
                var attributes: [String: Attribute] = [
                    AutomotiveKey.dtc: Attribute(.string(code.code)),
                    AutomotiveKey.dtcStatus: Attribute(.string(status.rawValue)),
                    AutomotiveKey.system: Attribute(.string((definition?.system ?? code.system).rawValue)),
                    AutomotiveKey.description: Attribute(.string(knowledgeBase.describe(code)), provenance: meaning),
                ]
                let suspects = (definition?.likelyComponents ?? []).compactMap { vehicle.component($0) }
                if !suspects.isEmpty {
                    attributes["likelyComponents"] = Attribute(.list(suspects.map(Value.reference)), provenance: meaning)
                }
                let title = definition.map { "\(code.code) \($0.description)" } ?? code.code
                let fault = try store.create(ObjectRecord(type: .fault, title: title, attributes: attributes, provenance: recorded))
                try store.relate(Relationship(kind: .hasFault, from: vehicleID, to: fault.id, provenance: recorded))
                if source != vehicleID {
                    try store.relate(Relationship(kind: .reportedBy, from: fault.id, to: source, provenance: recorded))
                }
                faults.append(fault)
            }
            try store.record(
                Event(
                    at: now, kind: .troubleCodesRead, subjects: [vehicleID] + faults.map(\.id),
                    summary: codes.isEmpty
                        ? "No \(status.rawValue) trouble codes" : "\(status.rawValue.capitalized) codes: \(codes.map(\.code).joined(separator: ", "))",
                    payload: ["codes": .list(codes.map { .string($0.code) }), AutomotiveKey.dtcStatus: .string(status.rawValue)], provenance: recorded
                ))
            return faults
        }
    }

    /// Fault objects linked to the vehicle, oldest first.
    public func faults(of vehicleID: ObjectID) throws -> [ObjectRecord] {
        try store.objects(try store.relationships(from: vehicleID, kind: .hasFault).map(\.to)).filter { $0.type == .fault }
    }

    /// Marks a fault cleared (codes erased after a repair). The object and
    /// its history remain; it is archived, not deleted.
    @discardableResult
    public func clearFault(_ faultID: ObjectID, reason: String, by author: Origin) throws -> ObjectRecord {
        try store.update(faultID, by: author, instruction: "Cleared: \(reason)") {
            $0.lifecycle = .archived
            $0.attributes["clearedReason"] = Attribute(.string(reason))
        }
    }

    // MARK: Readings

    /// Stores decoded PIDs as measurements against the component each PID
    /// describes. See the type's documentation for the truth classes.
    @discardableResult
    public func record(
        _ readings: [OBDReading],
        on vehicleID: ObjectID,
        scanTool: ObjectID? = nil,
        truth: TruthClass = .display,
        at date: Date? = nil
    ) throws -> [MeasurementRecord] {
        guard truth == .display || truth == .observed else { throw AutomotiveError.unsupportedTruth(truth) }
        return try store.batch { store in
            let vehicle = try vehicle(vehicleID)
            let when = date ?? clock.now()
            let ecu = vehicle.component(.ecu) ?? vehicleID
            return try readings.map { reading in
                let origin: Origin = truth == .observed ? .instrument(id: scanTool ?? ecu) : .importer(source: ecu)
                let pid = ELM327.hex(reading.pid)
                let measurement = MeasurementRecord(
                    quantityName: reading.quantity, value: Quantity(reading.value, reading.unit),
                    testPoint: vehicle.component(reading.site) ?? ecu, instrument: scanTool, sampledAt: when,
                    provenance: Provenance(
                        origin: origin, truth: truth, timestamp: when,
                        method: "OBD-II mode 01 PID \(pid)\(reading.ecu.map { " from \($0)" } ?? "")", dependencies: [ecu]
                    )
                )
                try store.add(measurement)
                return measurement
            }
        }
    }

    /// The scan tool's own supply-voltage reading at the diagnostic connector
    /// (ELM327 `ATRV`), stored as an observed measurement at the battery.
    @discardableResult
    public func recordAdapterVoltage(_ volts: Double, on vehicleID: ObjectID, scanTool: ObjectID, at date: Date? = nil) throws -> MeasurementRecord {
        let vehicle = try vehicle(vehicleID)
        let when = date ?? clock.now()
        let measurement = MeasurementRecord(
            quantityName: "connectorVoltage", value: Quantity(volts, "V"), uncertainty: 0.1, testPoint: vehicle.component(.battery) ?? vehicleID,
            instrument: scanTool, loading: "key on", sampledAt: when,
            provenance: Provenance(origin: .instrument(id: scanTool), truth: .observed, timestamp: when, method: "ELM327 ATRV at DLC pin 16")
        )
        try store.add(measurement)
        return measurement
    }
}

extension DTCStatus {
    /// The OBD request mode for this list, as written in docs ("03").
    public var mode: String {
        switch self {
        case .stored: "03"
        case .pending: "07"
        case .permanent: "0A"
        }
    }
}
