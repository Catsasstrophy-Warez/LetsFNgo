/// What a generic trouble code means, per SAE J2012.
public struct DTCDefinition: Hashable, Sendable {
    public var code: DTC
    public var description: String
    public var system: VehicleSystem
    /// Components commonly behind the code, in rough order of likelihood.
    public var likelyComponents: [VehicleComponentRole]
}

/// A small bundled table of generic powertrain codes (P0xxx). Codes outside
/// it are still stored as faults, with no description.
///
/// Descriptions are the generic SAE J2012 titles, which are public. They are
/// claims about what a code means in general; a manufacturer's service
/// information can refine them for a specific vehicle.
public struct DTCKnowledgeBase: Sendable {
    public private(set) var definitions: [DTC: DTCDefinition]

    public init(definitions: [DTCDefinition]) {
        self.definitions = Dictionary(definitions.map { ($0.code, $0) }, uniquingKeysWith: { _, last in last })
    }

    public subscript(code: DTC) -> DTCDefinition? { definitions[code] }

    public func describe(_ code: DTC) -> String {
        definitions[code]?.description ?? (code.isGeneric ? "Generic code, not in the bundled table" : "Manufacturer-specific code")
    }

    public static let generic = DTCKnowledgeBase(
        definitions: genericTable.map { code, description, system, components in
            DTCDefinition(code: DTC(code)!, description: description, system: system, likelyComponents: components)
        })

    // swift-format-ignore
    private static let genericTable: [(String, String, VehicleSystem, [VehicleComponentRole])] = [
        ("P0100", "Mass or volume air flow circuit malfunction", .powertrain, [.massAirflowSensor]),
        ("P0101", "Mass or volume air flow circuit range/performance", .powertrain, [.massAirflowSensor]),
        ("P0102", "Mass or volume air flow circuit low input", .powertrain, [.massAirflowSensor]),
        ("P0103", "Mass or volume air flow circuit high input", .powertrain, [.massAirflowSensor]),
        ("P0106", "Manifold absolute pressure/barometric pressure circuit range/performance", .powertrain, [.engine]),
        ("P0110", "Intake air temperature circuit malfunction", .powertrain, [.intakeAirTemperatureSensor]),
        ("P0113", "Intake air temperature circuit high input", .powertrain, [.intakeAirTemperatureSensor]),
        ("P0115", "Engine coolant temperature circuit malfunction", .powertrain, [.coolantTemperatureSensor]),
        ("P0117", "Engine coolant temperature circuit low input", .powertrain, [.coolantTemperatureSensor]),
        ("P0118", "Engine coolant temperature circuit high input", .powertrain, [.coolantTemperatureSensor]),
        ("P0120", "Throttle/pedal position sensor A circuit malfunction", .powertrain, [.throttlePositionSensor]),
        ("P0121", "Throttle/pedal position sensor A circuit range/performance", .powertrain, [.throttlePositionSensor]),
        ("P0128", "Coolant thermostat (coolant temperature below thermostat regulating temperature)", .powertrain, [.engine, .coolantTemperatureSensor]),
        ("P0130", "O2 sensor circuit malfunction (bank 1 sensor 1)", .emissions, [.upstreamOxygenSensor]),
        ("P0131", "O2 sensor circuit low voltage (bank 1 sensor 1)", .emissions, [.upstreamOxygenSensor]),
        ("P0133", "O2 sensor circuit slow response (bank 1 sensor 1)", .emissions, [.upstreamOxygenSensor]),
        ("P0135", "O2 sensor heater circuit malfunction (bank 1 sensor 1)", .emissions, [.upstreamOxygenSensor]),
        ("P0136", "O2 sensor circuit malfunction (bank 1 sensor 2)", .emissions, [.downstreamOxygenSensor]),
        ("P0141", "O2 sensor heater circuit malfunction (bank 1 sensor 2)", .emissions, [.downstreamOxygenSensor]),
        ("P0171", "System too lean (bank 1)", .powertrain, [.massAirflowSensor, .engine]),
        ("P0172", "System too rich (bank 1)", .powertrain, [.engine, .massAirflowSensor]),
        ("P0174", "System too lean (bank 2)", .powertrain, [.massAirflowSensor, .engine]),
        ("P0175", "System too rich (bank 2)", .powertrain, [.engine, .massAirflowSensor]),
        ("P0300", "Random/multiple cylinder misfire detected", .powertrain, [.engine]),
        ("P0301", "Cylinder 1 misfire detected", .powertrain, [.engine]),
        ("P0302", "Cylinder 2 misfire detected", .powertrain, [.engine]),
        ("P0303", "Cylinder 3 misfire detected", .powertrain, [.engine]),
        ("P0304", "Cylinder 4 misfire detected", .powertrain, [.engine]),
        ("P0305", "Cylinder 5 misfire detected", .powertrain, [.engine]),
        ("P0306", "Cylinder 6 misfire detected", .powertrain, [.engine]),
        ("P0325", "Knock sensor 1 circuit malfunction (bank 1)", .powertrain, [.engine]),
        ("P0335", "Crankshaft position sensor A circuit malfunction", .powertrain, [.crankshaftPositionSensor]),
        ("P0340", "Camshaft position sensor circuit malfunction", .powertrain, [.engine]),
        ("P0401", "Exhaust gas recirculation flow insufficient detected", .emissions, [.engine]),
        ("P0420", "Catalyst system efficiency below threshold (bank 1)", .emissions, [.downstreamOxygenSensor, .engine]),
        ("P0430", "Catalyst system efficiency below threshold (bank 2)", .emissions, [.downstreamOxygenSensor, .engine]),
        ("P0440", "Evaporative emission control system malfunction", .emissions, [.engine]),
        ("P0442", "Evaporative emission control system leak detected (small leak)", .emissions, [.engine]),
        ("P0455", "Evaporative emission control system leak detected (gross leak)", .emissions, [.engine]),
        ("P0456", "Evaporative emission control system leak detected (very small leak)", .emissions, [.engine]),
        ("P0500", "Vehicle speed sensor malfunction", .powertrain, [.vehicleSpeedSensor]),
        ("P0505", "Idle control system malfunction", .powertrain, [.engine]),
        ("P0562", "System voltage low", .charging, [.alternator, .battery, .groundStrap]),
        ("P0563", "System voltage high", .charging, [.alternator]),
        ("P0600", "Serial communication link malfunction", .network, [.ecu, .canBus]),
        ("P0620", "Generator control circuit malfunction", .charging, [.alternator]),
        ("P0622", "Generator field terminal circuit malfunction", .charging, [.alternator]),
        ("P0700", "Transmission control system malfunction", .powertrain, [.ecu]),
    ]
}
