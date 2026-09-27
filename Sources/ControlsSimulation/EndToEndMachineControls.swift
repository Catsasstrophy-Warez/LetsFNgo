import Foundation
import ControlsPLC

public enum MachineFieldFaultKind: String, Codable, CaseIterable, Sendable {
    case openWire, shortTo24V, analogDrift, channelFailedLow, channelFailedHigh, networkStale, processBias, highResistanceConnection, referenceShift, intermittentOpen
}

public struct MachineFieldFault: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var target: String
    public var kind: MachineFieldFaultKind
    public var magnitude: Double
    public var active: Bool
    public init(id: String = UUID().uuidString, target: String, kind: MachineFieldFaultKind, magnitude: Double = 0, active: Bool = true) {
        self.id = id; self.target = target; self.kind = kind; self.magnitude = magnitude; self.active = active
    }
}

public struct MachineIOBinding: Identifiable, Codable, Equatable, Sendable {
    public var id: String { ioTag }
    public var ioTag: String
    public var fieldDeviceTag: String
    public var fieldDeviceDescription: String
    public var signalType: ProjectIOSignalType
    public var direction: ProjectIODirection
    public var rack: String
    public var slot: Int
    public var channel: Int
    public var moduleCatalog: String
    public var drawingSheet: String
    public var cableID: String
    public var cableCore: String
    public var terminalStrip: String
    public var terminalNumber: String
    public var fieldTerminal: String
    public var moduleTerminal: String
    public var wireNumber: String
    public var rawTag: String?
    public var scaledTag: String
    public var engineeringLow: Double?
    public var engineeringHigh: Double?
    public var engineeringUnit: String?
    public var networkNode: String?
}

public struct MachineDebugLink: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(sourceKind)|\(sourceID)|\(ioTag ?? "")|\(routine ?? "")|\(rungNumber ?? -1)" }
    public var sourceKind: String
    public var sourceID: String
    public var title: String
    public var ioTag: String?
    public var fieldDeviceTag: String?
    public var drawingSheet: String?
    public var rack: String?
    public var slot: Int?
    public var channel: Int?
    public var networkNode: String?
    public var task: String
    public var program: String
    public var routine: String?
    public var rungNumber: Int?
    public var pidTag: String?
}

public struct ExecutableMachineControlsProject: Codable, Equatable, Sendable {
    public var machine: PlayableMachineKind
    public var controllerProject: ControllerProject
    public var bindings: [MachineIOBinding]
    public var debugLinks: [MachineDebugLink]
    public var sourceProject: HeroMachineControlsProject

    public func binding(for query: String) -> MachineIOBinding? {
        let q = query.uppercased()
        return bindings.first {
            $0.ioTag.uppercased() == q || $0.fieldDeviceTag.uppercased() == q || $0.fieldDeviceDescription.uppercased().contains(q)
        }
    }
    public func links(for query: String) -> [MachineDebugLink] {
        let q = query.uppercased()
        return debugLinks.filter {
            $0.sourceID.uppercased().contains(q) || $0.title.uppercased().contains(q) || ($0.ioTag?.uppercased().contains(q) ?? false) || ($0.fieldDeviceTag?.uppercased().contains(q) ?? false)
        }
    }
}

public enum MachineLadderCompiler {
    public static func compile(_ source: HeroMachineControlsProject) throws -> ExecutableMachineControlsProject {
        let bindings = makeBindings(source)
        var tags = try TagStore()
        try addBaseTags(source: source, bindings: bindings, to: &tags)
        let routines = try compileRoutines(source: source, bindings: bindings, tags: &tags)
        let program = ControllerProgram(name: "MachineControl", mainRoutineName: "MainRoutine", routines: routines, tags: try TagStore())
        let task = ControllerTask(name: "MainTask", kind: .continuous, watchdogMilliseconds: 500, programs: [program])
        let project = ControllerProject(name: source.controllerName, controllerTags: tags, tasks: [task])
        let links = makeDebugLinks(source: source, bindings: bindings, routines: routines)
        return .init(machine: source.machine, controllerProject: project, bindings: bindings, debugLinks: links, sourceProject: source)
    }

    private static func addBaseTags(source: HeroMachineControlsProject, bindings: [MachineIOBinding], to tags: inout TagStore) throws {
        try tags.add(.init(name: "System_OK", value: .bool(true), role: .input))
        try tags.add(.init(name: "Machine_Permissive", value: .bool(false)))
        try tags.add(.init(name: "Machine_RunCmd", value: .bool(false)))
        for binding in bindings {
            let role: TagRole = binding.direction == .input ? .input : .output
            if isDiscrete(binding.signalType) {
                if !tags.contains(binding.scaledTag) { try tags.add(.init(name: binding.scaledTag, value: .bool(false), description: binding.fieldDeviceDescription, role: role)) }
            } else {
                if !tags.contains(binding.scaledTag) { try tags.add(.init(name: binding.scaledTag, value: .real(0), description: binding.fieldDeviceDescription, role: role)) }
                if let raw = binding.rawTag, !tags.contains(raw) { try tags.add(.init(name: raw, value: .real(4), description: "Raw 4-20 mA / normalized field signal for \(binding.fieldDeviceTag)", role: .input)) }
                let stem = safe(binding.scaledTag)
                for (name, value) in [("\(stem)_ScaleTmp", 0.0), ("\(stem)_Pct", 0.0)] where !tags.contains(name) { try tags.add(.init(name: name, value: .real(value))) }
            }
        }
        for drive in source.drives {
            for (suffix, value, role) in [("Ready", TagValue.bool(true), TagRole.input), ("Fault", .bool(false), .input), ("RunCmd", .bool(false), .output), ("SpeedCmd", .real(0), .output), ("ActualHz", .real(0), .input)] {
                let name = "\(drive.tag)_\(suffix)"; if !tags.contains(name) { try tags.add(.init(name: name, value: value, description: drive.motor, role: role)) }
            }
        }
        for pid in source.pidLoops {
            for (name, value) in [(pid.setpointTag, 50.0), (pid.outputTag, 0.0), ("\(pid.tag)_Error", 0.0), ("\(pid.tag)_P", 0.0)] where !tags.contains(name) { try tags.add(.init(name: name, value: .real(value))) }
        }
        for alarm in source.alarms where !tags.contains(alarm.tag) { try tags.add(.init(name: alarm.tag, value: .bool(false), description: alarm.message)) }
    }

    private static func compileRoutines(source: HeroMachineControlsProject, bindings: [MachineIOBinding], tags: inout TagStore) throws -> [LadderRoutine] {
        var compiled: [LadderRoutine] = []
        let jsrs = source.ladderRoutines.enumerated().map { idx, def in Rung(number: idx + 1, comment: "Execute \(def.purpose)", logic: .instruction(.jsr(routine: def.routine))) }
        compiled.append(.init(name: "MainRoutine", rungs: jsrs))
        for def in source.ladderRoutines {
            var rungs: [Rung] = []
            let lname = def.routine.lowercased()
            if lname.contains("io") || lname.contains("condition") {
                for binding in bindings where binding.direction == .input && !isDiscrete(binding.signalType) {
                    guard let raw = binding.rawTag, let lo = binding.engineeringLow, let hi = binding.engineeringHigh else { continue }
                    let stem = safe(binding.scaledTag), span = hi - lo
                    rungs.append(.init(number: rungs.count + 1, comment: "Scale \(binding.fieldDeviceTag) 4-20 mA to \(binding.scaledTag)", logic: .series([
                        .instruction(.sub(.tag(raw), .real(4), destination: "\(stem)_ScaleTmp")),
                        .instruction(.div(.tag("\(stem)_ScaleTmp"), .real(16), destination: "\(stem)_Pct")),
                        .instruction(.mul(.tag("\(stem)_Pct"), .real(span), destination: "\(stem)_ScaleTmp")),
                        .instruction(.add(.tag("\(stem)_ScaleTmp"), .real(lo), destination: binding.scaledTag))
                    ])))
                }
            }
            if lname.contains("permiss") || lname.contains("interlock") || lname.contains("safety") {
                let safetyTags = bindings.filter { $0.signalType == .safetyDualChannel && $0.direction == .input }.map(\.scaledTag)
                let checks = (safetyTags.isEmpty ? ["System_OK"] : safetyTags).map { LogicNode.instruction(.xic(tag: $0)) }
                rungs.append(.init(number: rungs.count + 1, comment: "Machine permissive from safety and field permissives", logic: .series(checks + [.instruction(.ote(tag: "Machine_Permissive"))])))
            }
            if lname.contains("sequence") || lname.contains("mission") || lname.contains("recipe") || lname.contains("demand") {
                rungs.append(.init(number: rungs.count + 1, comment: def.rungSummaries.first ?? "Machine run request", logic: .series([.instruction(.xic(tag: "Machine_Permissive")), .instruction(.ote(tag: "Machine_RunCmd"))])))
            }
            if lname.contains("drive") || lname.contains("motor") || lname.contains("travel") || lname.contains("lift") || lname.contains("pressure_control") || lname.contains("capacity") {
                for drive in source.drives.prefix(3) {
                    rungs.append(.init(number: rungs.count + 1, comment: "\(drive.tag) run command", logic: .series([.instruction(.xic(tag: "Machine_RunCmd")), .instruction(.xic(tag: "\(drive.tag)_Ready")), .instruction(.xio(tag: "\(drive.tag)_Fault")), .instruction(.ote(tag: "\(drive.tag)_RunCmd"))])))
                }
            }
            if lname.contains("pid") || lname.contains("control") || lname.contains("regulat") || lname.contains("trim") {
                for pid in source.pidLoops.prefix(3) {
                    let kp = parseKp(pid.gains)
                    rungs.append(.init(number: rungs.count + 1, comment: "Executable training P-action for \(pid.tag) (configured: \(pid.gains))", logic: .series([
                        .instruction(.sub(.tag(pid.setpointTag), .tag(pid.processVariable), destination: "\(pid.tag)_Error")),
                        .instruction(.mul(.tag("\(pid.tag)_Error"), .real(kp), destination: "\(pid.tag)_P")),
                        .instruction(.mov(source: .tag("\(pid.tag)_P"), destination: pid.outputTag))
                    ])))
                }
            }
            if lname.contains("alarm") || lname.contains("diagn") {
                for alarm in source.alarms.prefix(8) {
                    let analog = bindings.first { !$0.signalType.isDiscreteEquivalent && $0.direction == .input }
                    if let analog, let hi = analog.engineeringHigh {
                        rungs.append(.init(number: rungs.count + 1, comment: alarm.message, logic: .series([.instruction(.grt(.tag(analog.scaledTag), .real(hi * 0.9))), .instruction(.ote(tag: alarm.tag))])))
                    } else {
                        rungs.append(.init(number: rungs.count + 1, comment: alarm.message, logic: .series([.instruction(.xio(tag: "Machine_Permissive")), .instruction(.ote(tag: alarm.tag))])))
                    }
                }
            }
            if rungs.isEmpty {
                let tag = def.primaryTags.first.flatMap { tags.contains($0) ? $0 : nil } ?? "System_OK"
                rungs.append(.init(number: 1, comment: def.rungSummaries.first ?? def.purpose, logic: .instruction(.xic(tag: tag))))
            }
            compiled.append(.init(name: def.routine, rungs: rungs))
        }
        return compiled
    }

    private static func makeBindings(_ source: HeroMachineControlsProject) -> [MachineIOBinding] {
        source.ioPoints.enumerated().map { index, p in
            let module = source.racks.first(where: { $0.rackName == p.rack })?.modules.first(where: { $0.slot == p.slot })
            let range = parseRange(p.engineeringRange)
            let deviceTag = extractDeviceTag(p.fieldDevice, fallback: p.tag)
            let sheet = source.drawings.first(where: { $0.referencedTags.contains(p.tag) || $0.referencedTags.contains(deviceTag) })?.sheetNumber ?? source.drawings.first(where: { $0.discipline == .plcIO })?.sheetNumber ?? "E-IO"
            let network = source.ethernetNodes.first(where: { $0.name == p.rack || $0.role.lowercased().contains(p.rack.lowercased()) })?.name
            return .init(ioTag: p.tag, fieldDeviceTag: deviceTag, fieldDeviceDescription: p.fieldDevice, signalType: p.signalType, direction: p.direction, rack: p.rack, slot: p.slot, channel: p.channel, moduleCatalog: module?.catalog ?? "Unknown", drawingSheet: sheet, cableID: "CBL-\(source.projectNumber)-\(String(format: "%03d", index + 1))", cableCore: "\(p.channel + 1)", terminalStrip: "TB-\(p.rack.replacingOccurrences(of: " ", with: ""))", terminalNumber: "\(p.slot).\(p.channel + 1)", fieldTerminal: isDiscrete(p.signalType) ? "OUT" : "+", moduleTerminal: "CH\(p.channel)", wireNumber: "\(1000 + index)", rawTag: isDiscrete(p.signalType) ? nil : "\(safe(p.tag))_RawmA", scaledTag: p.tag, engineeringLow: range?.0, engineeringHigh: range?.1, engineeringUnit: range?.2, networkNode: network)
        }
    }

    private static func makeDebugLinks(source: HeroMachineControlsProject, bindings: [MachineIOBinding], routines: [LadderRoutine]) -> [MachineDebugLink] {
        var links: [MachineDebugLink] = []
        for binding in bindings {
            let refs = routineReferences(tag: binding.scaledTag, routines: routines)
            if refs.isEmpty {
                links.append(.init(sourceKind: "I/O", sourceID: binding.ioTag, title: "\(binding.fieldDeviceTag) → \(binding.rack) Slot \(binding.slot) Ch \(binding.channel)", ioTag: binding.ioTag, fieldDeviceTag: binding.fieldDeviceTag, drawingSheet: binding.drawingSheet, rack: binding.rack, slot: binding.slot, channel: binding.channel, networkNode: binding.networkNode, task: "MainTask", program: "MachineControl", routine: nil, rungNumber: nil, pidTag: source.pidLoops.first(where: { $0.processVariable == binding.ioTag || $0.outputTag == binding.ioTag })?.tag))
            } else {
                for ref in refs { links.append(.init(sourceKind: "I/O", sourceID: binding.ioTag, title: "\(binding.fieldDeviceTag) → \(ref.0) rung \(ref.1)", ioTag: binding.ioTag, fieldDeviceTag: binding.fieldDeviceTag, drawingSheet: binding.drawingSheet, rack: binding.rack, slot: binding.slot, channel: binding.channel, networkNode: binding.networkNode, task: "MainTask", program: "MachineControl", routine: ref.0, rungNumber: ref.1, pidTag: source.pidLoops.first(where: { $0.processVariable == binding.ioTag || $0.outputTag == binding.ioTag })?.tag)) }
            }
        }
        for node in source.ethernetNodes {
            links.append(.init(sourceKind: "Network", sourceID: node.name, title: "\(node.name) • \(node.ipAddress)", ioTag: nil, fieldDeviceTag: nil, drawingSheet: source.drawings.first(where: { $0.discipline == .network })?.sheetNumber, rack: nil, slot: nil, channel: nil, networkNode: node.name, task: "MainTask", program: "MachineControl", routine: nil, rungNumber: nil, pidTag: nil))
        }
        return links
    }

    private static func routineReferences(tag: String, routines: [LadderRoutine]) -> [(String, Int)] {
        routines.flatMap { routine in routine.rungs.compactMap { rung in logicTags(rung.logic).contains(tag) ? (routine.name, rung.number) : nil } }
    }
    private static func logicTags(_ node: LogicNode) -> Set<String> {
        switch node {
        case .instruction(let i): return Set(i.readTagNames + i.writeTagNames)
        case .series(let nodes), .parallel(let nodes): return nodes.reduce(into: Set<String>()) { $0.formUnion(logicTags($1)) }
        }
    }
    private static func parseKp(_ gains: String) -> Double {
        let lower = gains.lowercased(); guard let r = lower.range(of: "kp") else { return 1 }
        let tail = lower[r.upperBound...].replacingOccurrences(of: "=", with: " ").replacingOccurrences(of: ":", with: " ")
        return tail.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).compactMap { Double($0) }.first ?? 1
    }
    private static func extractDeviceTag(_ text: String, fallback: String) -> String {
        let tokens = text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        return tokens.first(where: { token in token.range(of: #"[A-Za-z]+[-]?[0-9]{2,}"#, options: .regularExpression) != nil }) ?? fallback
    }
    private static func parseRange(_ text: String?) -> (Double, Double, String)? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: "−", with: "-")
        let pattern = #"(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)), match.numberOfRanges >= 4,
              let r1 = Range(match.range(at: 1), in: normalized), let r2 = Range(match.range(at: 2), in: normalized), let ru = Range(match.range(at: 3), in: normalized), let lo = Double(normalized[r1]), let hi = Double(normalized[r2]) else { return nil }
        return (lo, hi, String(normalized[ru]).trimmingCharacters(in: .whitespaces))
    }
    private static func isDiscrete(_ type: ProjectIOSignalType) -> Bool {
        switch type { case .digital24VDC, .digital120VAC, .safetyDualChannel, .networkProduced, .networkConsumed: true; default: false }
    }
    private static func safe(_ value: String) -> String { value.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") }
}

private extension ProjectIOSignalType {
    var isDiscreteEquivalent: Bool {
        switch self { case .digital24VDC, .digital120VAC, .safetyDualChannel, .networkProduced, .networkConsumed: true; default: false }
    }
}

public struct MachineFieldState: Codable, Equatable, Sendable {
    public var digital: [String: Bool] = [:]
    public var analogEngineering: [String: Double] = [:]
    public var lastGoodDigital: [String: Bool] = [:]
    public var lastGoodAnalog: [String: Double] = [:]
    public init() {}
}

public struct EndToEndMachineSnapshot: Codable, Equatable, Sendable {
    public var scanNumber: UInt64
    public var fieldDigital: [String: Bool]
    public var fieldAnalog: [String: Double]
    public var rawSignals: [String: Double]
    public var plcValues: [String: TagValue]
    public var outputValues: [String: TagValue]
    public var trace: ControllerScanTrace
}

public struct EndToEndMachineRuntime: Sendable {
    public private(set) var executable: ExecutableMachineControlsProject
    public private(set) var controller: ControllerRuntime
    public var field = MachineFieldState()
    public var faults: [MachineFieldFault] = []

    public init(machine: PlayableMachineKind) throws {
        let executable = try MachineLadderCompiler.compile(HeroMachineControlsProjectCatalog.project(for: machine))
        self.executable = executable
        self.controller = ControllerRuntime(project: executable.controllerProject)
        try self.controller.setMode(.run)
    }

    public mutating func setDigital(_ tagOrDevice: String, value: Bool) { if let b = executable.binding(for: tagOrDevice) { field.digital[b.ioTag] = value } else { field.digital[tagOrDevice] = value } }
    public mutating func setAnalog(_ tagOrDevice: String, engineeringValue: Double) { if let b = executable.binding(for: tagOrDevice) { field.analogEngineering[b.ioTag] = engineeringValue } else { field.analogEngineering[tagOrDevice] = engineeringValue } }
    public mutating func inject(_ fault: MachineFieldFault) { faults.removeAll { $0.id == fault.id }; faults.append(fault) }
    public mutating func clearFault(_ id: String) { faults.removeAll { $0.id == id } }

    @discardableResult
    public mutating func scan(elapsedMilliseconds: Int32 = 10) throws -> EndToEndMachineSnapshot {
        var raw: [String: Double] = [:]
        for binding in executable.bindings where binding.direction == .input {
            let active = faults.filter { $0.active && ($0.target == binding.ioTag || $0.target == binding.fieldDeviceTag || $0.target == binding.cableID || $0.target == "\(binding.rack):\(binding.slot):\(binding.channel)" || $0.target == binding.networkNode) }
            if binding.signalType.isDiscreteEquivalent {
                let physical = field.digital[binding.ioTag] ?? false
                var observed = physical
                for f in active { switch f.kind { case .openWire, .channelFailedLow: observed = false; case .shortTo24V, .channelFailedHigh: observed = true; case .networkStale: observed = field.lastGoodDigital[binding.ioTag] ?? observed; case .highResistanceConnection: if f.magnitude >= 4 { observed = false }; case .intermittentOpen: observed = (Int(f.magnitude.rounded()) % 2 == 0) ? false : observed; case .referenceShift: break; default: break } }
                try controller.setControllerTagValue(binding.scaledTag, to: .bool(observed))
                if !active.contains(where: { $0.kind == .networkStale }) { field.lastGoodDigital[binding.ioTag] = observed }
            } else {
                let lo = binding.engineeringLow ?? 0, hi = binding.engineeringHigh ?? 100
                let physical = field.analogEngineering[binding.ioTag] ?? lo
                var observedEU = physical
                for f in active { switch f.kind { case .analogDrift, .processBias: observedEU += f.magnitude; case .channelFailedLow, .openWire: observedEU = lo; case .channelFailedHigh, .shortTo24V: observedEU = hi; case .networkStale: observedEU = field.lastGoodAnalog[binding.ioTag] ?? observedEU; case .highResistanceConnection: observedEU -= abs(f.magnitude); case .referenceShift: observedEU += f.magnitude; case .intermittentOpen: if Int(f.magnitude.rounded()) % 2 == 0 { observedEU = lo } } }
                let ma = 4 + 16 * ((observedEU - lo) / max(hi - lo, 0.000001))
                if let rawTag = binding.rawTag { try controller.setControllerTagValue(rawTag, to: .real(ma)); raw[rawTag] = ma }
                if !active.contains(where: { $0.kind == .networkStale }) { field.lastGoodAnalog[binding.ioTag] = observedEU }
            }
        }
        let trace = try controller.scan(elapsedMilliseconds: elapsedMilliseconds)
        var plc: [String: TagValue] = [:], outputs: [String: TagValue] = [:]
        for binding in executable.bindings { if let value = try? controller.project.controllerTags.value(for: binding.scaledTag) { plc[binding.scaledTag] = value; if binding.direction == .output { outputs[binding.scaledTag] = value } } }
        return .init(scanNumber: trace.scanNumber, fieldDigital: field.digital, fieldAnalog: field.analogEngineering, rawSignals: raw, plcValues: plc, outputValues: outputs, trace: trace)
    }

    public func controllerValue(_ tag: String) throws -> TagValue { try controller.project.controllerTags.value(for: tag) }
    public mutating func setControllerValue(_ tag: String, value: TagValue) throws { try controller.setControllerTagValue(tag, to: value) }
    public func debugLink(for query: String) -> MachineDebugLink? { executable.links(for: query).first }
}
