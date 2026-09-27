import NexusCore
import NexusModel

// Automotive terms on NexusModel's open vocabularies. Vehicles are their own
// object type; their parts reuse the shared `component` and `sensor` types
// (with a `role` attribute), trouble codes are `fault` objects and repairs are
// `procedure` objects, so the graph, search, investigations and the UI treat
// them like any other equipment. Nothing here keeps state of its own.

extension ObjectType {
    /// A road vehicle, identified by its VIN.
    public static let vehicle: ObjectType = "vehicle"
    /// A physical or logical in-vehicle network (CAN, LIN).
    public static let vehicleNetwork: ObjectType = "vehicleNetwork"
}

extension RelationKind {
    /// Vehicle → fault object for a diagnostic trouble code.
    public static let hasFault: RelationKind = "hasFault"
    /// Fault → the control module that reported it.
    public static let reportedBy: RelationKind = "reportedBy"
    /// Vehicle → procedure performed on it (service history).
    public static let serviced: RelationKind = "serviced"
}

extension EventKind {
    /// Maintenance or repair performed on a vehicle. The payload carries the odometer.
    public static let service: EventKind = "service"
    /// Trouble codes read from a control module.
    public static let troubleCodesRead: EventKind = "troubleCodesRead"
    /// An odometer reading outside a service visit.
    public static let odometerReading: EventKind = "odometerReading"
}

/// Attribute keys used on automotive objects.
public enum AutomotiveKey {
    public static let vin = "vin"
    public static let wmi = "wmi"
    public static let manufacturer = "manufacturer"
    public static let region = "region"
    public static let country = "country"
    public static let modelYear = "modelYear"
    public static let odometer = "odometer"
    /// A component's `VehicleComponentRole` raw value.
    public static let role = "role"
    public static let system = "system"
    /// A fault's trouble code, e.g. "P0562".
    public static let dtc = "dtc"
    /// A fault's `DTCStatus` raw value.
    public static let dtcStatus = "dtcStatus"
    public static let description = "description"
    public static let steps = "steps"
    public static let parts = "parts"
    public static let performedAt = "performedAt"
}

/// The vehicle subsystem a component or trouble code belongs to.
public enum VehicleSystem: String, Codable, Sendable, CaseIterable {
    case powertrain
    case charging
    case starting
    case network
    case emissions
    case chassis
    case body
}

/// The parts a vehicle's topology is built from. Components are `component`
/// objects except the sensors, which are `sensor` objects.
public enum VehicleComponentRole: String, Codable, Sendable, CaseIterable {
    case engine
    case battery
    case alternator
    case starter
    case groundStrap
    case ecu
    case canBus
    case coolantTemperatureSensor
    case intakeAirTemperatureSensor
    case massAirflowSensor
    case throttlePositionSensor
    case upstreamOxygenSensor
    case downstreamOxygenSensor
    case crankshaftPositionSensor
    case vehicleSpeedSensor

    public var title: String {
        switch self {
        case .engine: "Engine"
        case .battery: "12 V battery"
        case .alternator: "Alternator"
        case .starter: "Starter motor"
        case .groundStrap: "Engine ground strap"
        case .ecu: "Engine control module"
        case .canBus: "Powertrain CAN bus"
        case .coolantTemperatureSensor: "Coolant temperature sensor"
        case .intakeAirTemperatureSensor: "Intake air temperature sensor"
        case .massAirflowSensor: "Mass airflow sensor"
        case .throttlePositionSensor: "Throttle position sensor"
        case .upstreamOxygenSensor: "O2 sensor bank 1 sensor 1"
        case .downstreamOxygenSensor: "O2 sensor bank 1 sensor 2"
        case .crankshaftPositionSensor: "Crankshaft position sensor"
        case .vehicleSpeedSensor: "Vehicle speed sensor"
        }
    }

    public var objectType: ObjectType {
        isSensor ? .sensor : (self == .canBus ? .vehicleNetwork : .component)
    }

    public var isSensor: Bool {
        switch self {
        case .coolantTemperatureSensor, .intakeAirTemperatureSensor, .massAirflowSensor, .throttlePositionSensor,
            .upstreamOxygenSensor, .downstreamOxygenSensor, .crankshaftPositionSensor, .vehicleSpeedSensor:
            true
        default:
            false
        }
    }

    public var system: VehicleSystem {
        switch self {
        case .battery, .alternator, .groundStrap: .charging
        case .starter: .starting
        case .ecu, .canBus: .network
        case .upstreamOxygenSensor, .downstreamOxygenSensor: .emissions
        default: .powertrain
        }
    }
}
