import Foundation
import ControlsPLC

public enum PhysicalOutputDeviceKind: String, Codable, CaseIterable, Sendable {
    case vfd, servo, solenoid, controlValve, pump, heater, contactor, motorStarter, motor, analogActuator, generic
}

public enum OutputPathFaultKind: String, Codable, CaseIterable, Sendable {
    case outputChannelOpen, outputChannelStuckOn, brokenFieldWire, interposingRelayOpen, weldedContactor, actuatorStuck, driveFault, motorOverload, heaterOpen, valveStiction, pneumaticLeak, highResistanceConnection
}

public struct OutputPathFault: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var target: String
    public var kind: OutputPathFaultKind
    public var magnitude: Double
    public var active: Bool
    public init(id: String = UUID().uuidString, target: String, kind: OutputPathFaultKind, magnitude: Double = 0, active: Bool = true) {
        self.id = id; self.target = target; self.kind = kind; self.magnitude = magnitude; self.active = active
    }
}

public struct PhysicalOutputPath: Identifiable, Codable, Equatable, Sendable {
    public var id: String { commandTag }
    public var commandTag: String
    public var fieldDeviceTag: String
    public var description: String
    public var kind: PhysicalOutputDeviceKind
    public var signalType: ProjectIOSignalType
    public var rack: String
    public var slot: Int
    public var channel: Int
    public var moduleCatalog: String
    public var terminalStrip: String
    public var terminalNumber: String
    public var cableID: String
    public var wireNumber: String
    public var feedbackCandidates: [String]
    public var networkNode: String?
}

public struct OutputElectricalState: Identifiable, Codable, Equatable, Sendable {
    public var id: String { commandTag }
    public var commandTag: String
    public var plcCommand: Double
    public var moduleVoltage: Double
    public var moduleCurrentMilliamps: Double
    public var fieldVoltage: Double
    public var fieldCurrentMilliamps: Double
    public var conductorContinuity: Bool
    public var interposingDeviceEnergized: Bool
    public var faulted: Bool
}

public struct PhysicalActuatorState: Identifiable, Codable, Equatable, Sendable {
    public var id: String { tag }
    public var tag: String
    public var kind: PhysicalOutputDeviceKind
    public var energized: Bool
    public var commandPercent: Double
    public var actualPercent: Double
    public var speedHz: Double
    public var positionPercent: Double
    public var currentAmps: Double
    public var temperatureC: Double
    public var pressurePSI: Double
    public var faulted: Bool
}

public struct ClosedLoopProcessState: Codable, Equatable, Sendable {
    public var elapsedSeconds: Double = 0
    public var speedPercent: Double = 0
    public var flowPercent: Double = 0
    public var pressurePercent: Double = 0
    public var temperaturePercent: Double = 20
    public var levelPercent: Double = 50
    public var positionPercent: Double = 0
    public var productRatePerMinute: Double = 0
    public var producedUnits: Double = 0
    public var productPresent: Bool = false
    public init() {}
}

public struct ClosedLoopPlantSnapshot: Codable, Equatable, Sendable {
    public var electrical: [String: OutputElectricalState]
    public var actuators: [String: PhysicalActuatorState]
    public var process: ClosedLoopProcessState
    public var generatedDigitalFeedback: [String: Bool]
    public var generatedAnalogFeedback: [String: Double]
    public var activeFaults: [OutputPathFault]
}

public struct ClosedLoopPlantRuntime: Codable, Equatable, Sendable {
    public var process = ClosedLoopProcessState()
    public var faults: [OutputPathFault] = []
    public var actuatorMemory: [String: PhysicalActuatorState] = [:]
    public init() {}

    public mutating func inject(_ fault: OutputPathFault) {
        faults.removeAll { $0.id == fault.id }
        faults.append(fault)
    }
    public mutating func clearFault(_ id: String) { faults.removeAll { $0.id == id } }
    public mutating func clearFaults() { faults.removeAll() }

    public static func outputPaths(for executable: ExecutableMachineControlsProject) -> [PhysicalOutputPath] {
        var paths: [PhysicalOutputPath] = executable.bindings.filter { $0.direction == .output }.map { b in
            .init(commandTag: b.scaledTag, fieldDeviceTag: b.fieldDeviceTag, description: b.fieldDeviceDescription,
                  kind: classify(tag: b.fieldDeviceTag, description: b.fieldDeviceDescription, signalType: b.signalType),
                  signalType: b.signalType, rack: b.rack, slot: b.slot, channel: b.channel, moduleCatalog: b.moduleCatalog,
                  terminalStrip: b.terminalStrip, terminalNumber: b.terminalNumber, cableID: b.cableID, wireNumber: b.wireNumber,
                  feedbackCandidates: feedbackCandidates(for: b.fieldDeviceTag, in: executable), networkNode: b.networkNode)
        }
        // Networked drives/servos are physical outputs even when their run/speed commands do not occupy a local output module channel.
        for drive in executable.sourceProject.drives where !paths.contains(where: { $0.fieldDeviceTag == drive.tag || $0.commandTag == "\(drive.tag)_RunCmd" }) {
            let kind: PhysicalOutputDeviceKind = drive.driveFamily.lowercased().contains("kinetix") || drive.controlMode.lowercased().contains("position") ? .servo : .vfd
            paths.append(.init(commandTag: "\(drive.tag)_RunCmd", fieldDeviceTag: drive.tag, description: "\(drive.driveFamily) • \(drive.motor)", kind: kind,
                               signalType: .networkProduced, rack: "EtherNet/IP", slot: -1, channel: -1, moduleCatalog: drive.driveFamily,
                               terminalStrip: "NET", terminalNumber: drive.networkNode, cableID: "ENET-\(drive.tag)", wireNumber: "CIP", feedbackCandidates: feedbackCandidates(for: drive.tag, in: executable), networkNode: drive.networkNode))
        }
        return paths
    }

    public mutating func propagate(executable: ExecutableMachineControlsProject, controllerValues: [String: TagValue], elapsedMilliseconds: Int32) -> ClosedLoopPlantSnapshot {
        let dt = max(0.001, Double(elapsedMilliseconds) / 1000.0)
        let paths = Self.outputPaths(for: executable)
        var electrical: [String: OutputElectricalState] = [:]
        var actuators: [String: PhysicalActuatorState] = [:]

        for path in paths {
            let command = commandPercent(path: path, values: controllerValues)
            let active = matchingFaults(path: path)
            var modulePercent = command
            if active.contains(where: { $0.kind == .outputChannelOpen }) { modulePercent = 0 }
            if active.contains(where: { $0.kind == .outputChannelStuckOn }) { modulePercent = 100 }
            let analog = !Self.isDiscrete(path.signalType)
            let moduleVoltage = analog ? 24.0 : (modulePercent > 0.5 ? 24.0 : 0.0)
            var fieldPercent = modulePercent
            let continuity = !active.contains(where: { $0.kind == .brokenFieldWire })
            if !continuity || active.contains(where: { $0.kind == .interposingRelayOpen }) { fieldPercent = 0 }
            if active.contains(where: { $0.kind == .weldedContactor }) { fieldPercent = 100 }
            let modulemA = analog ? 4 + 16 * clamp(modulePercent / 100) : (modulePercent > 0.5 ? 8.0 : 0.0)
            var fieldVoltage = analog ? 24.0 : (fieldPercent > 0.5 ? 24.0 : 0.0)
            if let hr = active.first(where: { $0.kind == .highResistanceConnection }), fieldPercent > 0 {
                let estimatedLoadAmps = analog ? max(0.004, modulemA / 1000.0) : 0.20
                fieldVoltage = max(0, fieldVoltage - estimatedLoadAmps * max(0, hr.magnitude))
                fieldPercent *= clamp(fieldVoltage / 24.0)
            }
            let fieldmA = continuity ? (analog ? 4 + 16 * clamp(fieldPercent / 100) : (fieldPercent > 0.5 ? 8.0 : 0.0)) : 0
            electrical[path.commandTag] = .init(commandTag: path.commandTag, plcCommand: command, moduleVoltage: moduleVoltage,
                                                moduleCurrentMilliamps: modulemA, fieldVoltage: fieldVoltage, fieldCurrentMilliamps: fieldmA,
                                                conductorContinuity: continuity, interposingDeviceEnergized: fieldPercent > 0.5,
                                                faulted: !active.isEmpty)

            var previous = actuatorMemory[path.fieldDeviceTag] ?? .init(tag: path.fieldDeviceTag, kind: path.kind, energized: false, commandPercent: 0, actualPercent: 0, speedHz: 0, positionPercent: 0, currentAmps: 0, temperatureC: 25, pressurePSI: 0, faulted: false)
            let mechanicalFault = active.contains(where: { [.actuatorStuck,.driveFault,.motorOverload,.heaterOpen].contains($0.kind) })
            var target = fieldPercent
            if active.contains(where: { $0.kind == .driveFault || $0.kind == .motorOverload || $0.kind == .heaterOpen }) { target = 0 }
            if active.contains(where: { $0.kind == .actuatorStuck }) { target = previous.actualPercent }
            if let stiction = active.first(where: { $0.kind == .valveStiction }), abs(target - previous.actualPercent) < max(5, stiction.magnitude) { target = previous.actualPercent }
            if let leak = active.first(where: { $0.kind == .pneumaticLeak }) { target *= max(0, 1 - max(0.05, leak.magnitude)) }
            let responseRate = responseRate(for: path.kind)
            let actual = approach(previous.actualPercent, target, maxDelta: responseRate * dt)
            previous.energized = fieldPercent > 0.5
            previous.commandPercent = command
            previous.actualPercent = clamp(actual)
            previous.speedHz = (path.kind == .vfd || path.kind == .servo || path.kind == .motorStarter || path.kind == .motor) ? 60 * clamp(actual / 100) : 0
            previous.positionPercent = [.solenoid,.controlValve,.analogActuator,.servo].contains(path.kind) ? clamp(actual) : previous.positionPercent
            previous.currentAmps = motorLike(path.kind) ? (actual > 0 ? 1.5 + actual * 0.06 : 0) : (path.kind == .heater && actual > 0 ? 12 * actual / 100 : 0)
            previous.temperatureC = path.kind == .heater ? 25 + actual * 1.5 : 25 + previous.currentAmps * 2
            previous.pressurePSI = [.pump,.controlValve,.solenoid,.analogActuator].contains(path.kind) ? actual * 0.8 : 0
            previous.faulted = mechanicalFault || !active.isEmpty
            actuatorMemory[path.fieldDeviceTag] = previous
            actuators[path.fieldDeviceTag] = previous
        }

        updateProcess(machine: executable.machine, actuators: actuators, dt: dt)
        let feedback = generateFeedback(executable: executable, actuators: actuators)
        return .init(electrical: electrical, actuators: actuators, process: process, generatedDigitalFeedback: feedback.digital,
                     generatedAnalogFeedback: feedback.analog, activeFaults: faults.filter(\.active))
    }

    private mutating func updateProcess(machine: PlayableMachineKind, actuators: [String: PhysicalActuatorState], dt: Double) {
        process.elapsedSeconds += dt
        let values = Array(actuators.values)
        let motor = values.filter { motorLike($0.kind) }.map(\.actualPercent).max() ?? 0
        let pump = values.filter { $0.kind == .pump || $0.kind == .vfd }.map(\.actualPercent).max() ?? motor
        let valves = values.filter { $0.kind == .controlValve || $0.kind == .analogActuator || $0.kind == .solenoid }.map(\.actualPercent)
        let valve = valves.isEmpty ? 100 : valves.reduce(0,+) / Double(valves.count)
        let heat = values.filter { $0.kind == .heater }.map(\.actualPercent).reduce(0,+)
        process.speedPercent = approach(process.speedPercent, motor, maxDelta: 45 * dt)
        let machineName = String(describing: machine).lowercased()
        let targetFlow = clamp((pump * 0.7 + valve * 0.3))
        process.flowPercent = approach(process.flowPercent, targetFlow, maxDelta: 30 * dt)
        process.pressurePercent = approach(process.pressurePercent, clamp(pump * (0.5 + valve/200)), maxDelta: 22 * dt)
        let thermalDemand = heat > 0 ? clamp(heat / max(1, Double(values.filter { $0.kind == .heater }.count))) : (machineName.contains("oven") || machineName.contains("boiler") ? 0 : 20)
        process.temperaturePercent = approach(process.temperaturePercent, thermalDemand, maxDelta: 5 * dt)
        process.positionPercent = values.filter { $0.kind == .servo || $0.kind == .analogActuator }.map(\.positionPercent).max() ?? process.positionPercent
        if machineName.contains("tank") || machineName.contains("batch") || machineName.contains("bioreactor") { process.levelPercent = clamp(process.levelPercent + (process.flowPercent - 35) * 0.01 * dt) }
        let productionMachine = machineName.contains("pack") || machineName.contains("bott") || machineName.contains("sort") || machineName.contains("conveyor") || machineName.contains("pallet") || machineName.contains("molding") || machineName.contains("battery")
        process.productRatePerMinute = productionMachine ? process.speedPercent * 1.2 : process.flowPercent * 0.6
        process.producedUnits += process.productRatePerMinute / 60 * dt
        process.productPresent = productionMachine && process.speedPercent > 15 && (Int(process.elapsedSeconds * max(1, process.speedPercent/30)) % 2 == 0)
    }

    private func generateFeedback(executable: ExecutableMachineControlsProject, actuators: [String: PhysicalActuatorState]) -> (digital: [String: Bool], analog: [String: Double]) {
        var digital: [String: Bool] = [:], analog: [String: Double] = [:]
        let anyRunning = actuators.values.contains { motorLike($0.kind) && $0.actualPercent > 5 }
        let anyFault = actuators.values.contains { $0.faulted }
        for b in executable.bindings where b.direction == .input {
            let key = "\(b.ioTag) \(b.fieldDeviceTag) \(b.fieldDeviceDescription)".lowercased()
            if Self.isDiscrete(b.signalType) {
                if key.contains("fault") || key.contains("trip") || key.contains("overload") { digital[b.ioTag] = anyFault }
                else if key.contains("run") || key.contains("aux") || key.contains("status") || key.contains("motion") || key.contains("speed") { digital[b.ioTag] = anyRunning }
                else if key.contains("photo") || key.contains("pe") || key.contains("presence") || key.contains("part") { digital[b.ioTag] = process.productPresent }
                else if key.contains("extend") || key.contains("open") { digital[b.ioTag] = actuators.values.contains { $0.positionPercent > 85 } }
                else if key.contains("retract") || key.contains("closed") { digital[b.ioTag] = actuators.values.contains { $0.positionPercent < 15 } }
            } else {
                let lo = b.engineeringLow ?? 0, hi = b.engineeringHigh ?? 100
                let normalized: Double
                if key.contains("press") { normalized = process.pressurePercent }
                else if key.contains("flow") { normalized = process.flowPercent }
                else if key.contains("temp") { normalized = process.temperaturePercent }
                else if key.contains("level") { normalized = process.levelPercent }
                else if key.contains("position") || key.contains("encoder") { normalized = process.positionPercent }
                else if key.contains("speed") || key.contains("hz") { normalized = process.speedPercent }
                else { continue }
                analog[b.ioTag] = lo + (hi - lo) * clamp(normalized / 100)
            }
        }
        return (digital, analog)
    }

    private func matchingFaults(path: PhysicalOutputPath) -> [OutputPathFault] {
        faults.filter { $0.active && [$0.target.uppercased()].contains(where: { target in
            target == path.commandTag.uppercased() || target == path.fieldDeviceTag.uppercased() || target == path.cableID.uppercased() || target == "\(path.rack):\(path.slot):\(path.channel)".uppercased() || target == path.networkNode?.uppercased()
        }) }
    }
    private static func feedbackCandidates(for device: String, in executable: ExecutableMachineControlsProject) -> [String] {
        let stem = device.uppercased().split(separator: "-").first.map(String.init) ?? device.uppercased()
        return executable.bindings.filter { $0.direction == .input && ($0.fieldDeviceTag.uppercased().contains(stem) || $0.fieldDeviceDescription.uppercased().contains(stem)) }.map(\.ioTag)
    }
    private static func classify(tag: String, description: String, signalType: ProjectIOSignalType) -> PhysicalOutputDeviceKind {
        let s = "\(tag) \(description)".lowercased()
        if s.contains("servo") || s.contains("axis") { return .servo }
        if s.contains("vfd") || s.contains("drive") { return .vfd }
        if s.contains("heater") || s.contains("heat") || s.contains("steam") { return .heater }
        if s.contains("pump") { return .pump }
        if s.contains("valve") || s.contains("damper") { return Self.isDiscrete(signalType) ? .solenoid : .controlValve }
        if s.contains("solenoid") || s.contains("cylinder") || s.contains("pneumatic") { return .solenoid }
        if s.contains("contactor") { return .contactor }
        if s.contains("motor") || s.contains("starter") || s.contains("conveyor") || s.contains("fan") { return .motorStarter }
        return Self.isDiscrete(signalType) ? .generic : .analogActuator
    }
    private func commandPercent(path: PhysicalOutputPath, values: [String: TagValue]) -> Double {
        guard let value = values[path.commandTag] else { return 0 }
        switch value {
        case .bool(let v): return v ? 100 : 0
        case .real(let v): return clamp(v)
        case .dint(let v): return clamp(Double(v))
        default: return 0
        }
    }
    private func responseRate(for kind: PhysicalOutputDeviceKind) -> Double {
        switch kind { case .solenoid,.contactor,.motorStarter: return 300; case .servo: return 220; case .vfd,.motor,.pump: return 90; case .controlValve,.analogActuator: return 55; case .heater: return 12; case .generic: return 150 }
    }
    private static func isDiscrete(_ type: ProjectIOSignalType) -> Bool { switch type { case .digital24VDC,.digital120VAC,.safetyDualChannel,.networkProduced,.networkConsumed: return true; default:return false } }
    private func motorLike(_ kind: PhysicalOutputDeviceKind) -> Bool { [.vfd,.servo,.pump,.motorStarter,.motor,.contactor].contains(kind) }
    private func approach(_ current: Double, _ target: Double, maxDelta: Double) -> Double { current + min(max(target-current, -maxDelta), maxDelta) }
    private func clamp(_ value: Double) -> Double { min(100, max(0, value)) }
}

public struct FullyClosedLoopSnapshot: Codable, Equatable, Sendable {
    public var plc: EndToEndMachineSnapshot
    public var physical: ClosedLoopPlantSnapshot
}

public struct FullyClosedLoopMachineRuntime: Sendable {
    public private(set) var controls: EndToEndMachineRuntime
    public var plant = ClosedLoopPlantRuntime()
    public var authoredCycle: AuthoredMachineCycleRuntime
    public var latest: FullyClosedLoopSnapshot?
    public var latestCycle: AuthoredMachineCycleSnapshot?
    public var materialFlow: MachineMaterialFlowRuntime
    public var latestMaterialFlow: MaterialFlowSnapshot?
    public init(machine: PlayableMachineKind) throws {
        controls = try EndToEndMachineRuntime(machine: machine)
        authoredCycle = AuthoredMachineCycleRuntime(machine: machine)
        materialFlow = MachineMaterialFlowRuntime(machine: machine)
    }
    public var executable: ExecutableMachineControlsProject { controls.executable }
    public mutating func setDigitalProcessInput(_ tag: String, value: Bool) { controls.setDigital(tag, value: value) }
    public mutating func setAnalogProcessInput(_ tag: String, value: Double) { controls.setAnalog(tag, engineeringValue: value) }
    public mutating func injectInputFault(_ fault: MachineFieldFault) { controls.inject(fault) }
    public mutating func injectOutputFault(_ fault: OutputPathFault) { plant.inject(fault) }
    public mutating func clearFaults() { controls.faults.removeAll(); plant.clearFaults() }
    public mutating func forceControllerValue(_ tag: String, _ value: TagValue) throws { try controls.setControllerValue(tag, value: value) }

    @discardableResult
    public mutating func cycle(elapsedMilliseconds: Int32 = 20) throws -> FullyClosedLoopSnapshot {
        // First scan consumes the feedback produced by the previous physical step.
        let first = try controls.scan(elapsedMilliseconds: elapsedMilliseconds)
        var controllerValues = first.plcValues
        for path in ClosedLoopPlantRuntime.outputPaths(for: controls.executable) {
            if let v = try? controls.controllerValue(path.commandTag) { controllerValues[path.commandTag] = v }
        }
        for drive in controls.executable.sourceProject.drives {
            for suffix in ["RunCmd","SpeedCmd"] { let tag="\(drive.tag)_\(suffix)"; if let v=try? controls.controllerValue(tag){controllerValues[tag]=v} }
        }
        let physical = plant.propagate(executable: controls.executable, controllerValues: controllerValues, elapsedMilliseconds: elapsedMilliseconds)
        for (tag, value) in physical.generatedDigitalFeedback { controls.setDigital(tag, value: value) }
        for (tag, value) in physical.generatedAnalogFeedback { controls.setAnalog(tag, engineeringValue: value) }
        // Publish drive actual behavior immediately to the controller image; input feedback is consumed on the next scan.
        for drive in controls.executable.sourceProject.drives {
            if let a = physical.actuators[drive.tag] {
                try? controls.setControllerValue("\(drive.tag)_ActualHz", value: .real(a.speedHz))
                try? controls.setControllerValue("\(drive.tag)_Fault", value: .bool(a.faulted))
            }
        }
        let result = FullyClosedLoopSnapshot(plc: first, physical: physical)
        latest = result
        latestCycle = authoredCycle.step(plant: physical, deltaTime: Double(elapsedMilliseconds) / 1000.0)
        if let cycle = latestCycle { latestMaterialFlow = materialFlow.step(plant: physical, cycle: cycle, deltaTime: Double(elapsedMilliseconds) / 1000.0) }
        return result
    }
}
