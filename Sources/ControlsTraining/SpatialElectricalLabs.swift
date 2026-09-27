import Foundation

// MARK: - Spatial schematic/panel geometry

public struct ShopPoint: Codable, Hashable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func distance(to other: ShopPoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

public struct ShopSize: Codable, Hashable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public enum TerminalElectricalRole: String, Codable, CaseIterable, Sendable {
    case source, sink, passive, common, shield, ground, analogPositive, analogNegative, digitalInput, digitalOutput
}

public struct SpatialTerminal: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var label: String
    public var relativePosition: ShopPoint
    public var role: TerminalElectricalRole
    public var nodeID: String
    public var terminalNumber: String
    public init(id: String, label: String, relativePosition: ShopPoint, role: TerminalElectricalRole, nodeID: String, terminalNumber: String) {
        self.id = id; self.label = label; self.relativePosition = relativePosition; self.role = role; self.nodeID = nodeID; self.terminalNumber = terminalNumber
    }
}

public struct SpatialSchematicSymbol: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: SchematicComponentKind
    public var tag: String
    public var label: String
    public var position: ShopPoint
    public var size: ShopSize
    public var terminals: [SpatialTerminal]
    public var rotationDegrees: Double
    public init(id: String, kind: SchematicComponentKind, tag: String, label: String, position: ShopPoint, size: ShopSize = .init(width: 128, height: 70), terminals: [SpatialTerminal], rotationDegrees: Double = 0) {
        self.id = id; self.kind = kind; self.tag = tag; self.label = label; self.position = position; self.size = size; self.terminals = terminals; self.rotationDegrees = rotationDegrees
    }
    public func terminalPosition(_ terminalID: String) -> ShopPoint? {
        guard let terminal = terminals.first(where: { $0.id == terminalID }) else { return nil }
        return .init(x: position.x + terminal.relativePosition.x * size.width,
                     y: position.y + terminal.relativePosition.y * size.height)
    }
}

public enum ConductorColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case black, red, blue, white, gray, orange, yellow, green, greenYellow, violet, brown
    public var id: String { rawValue }
}

public enum WireGauge: String, Codable, CaseIterable, Sendable, Identifiable {
    case awg18 = "18 AWG", awg16 = "16 AWG", awg14 = "14 AWG", awg12 = "12 AWG", awg10 = "10 AWG", awg8 = "8 AWG"
    public var id: String { rawValue }
}

public enum WireFunction: String, Codable, CaseIterable, Sendable {
    case power, dcControl, acControl, analog, network, safety, ground, shield
}

public struct WireEndpoint: Codable, Equatable, Hashable, Sendable {
    public var symbolID: String
    public var terminalID: String
    public init(symbolID: String, terminalID: String) { self.symbolID = symbolID; self.terminalID = terminalID }
}

public struct RoutedConductor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var from: WireEndpoint
    public var to: WireEndpoint
    public var route: [ShopPoint]
    public var wireNumber: String
    public var color: ConductorColor
    public var gauge: WireGauge
    public var function: WireFunction
    public var ferruleFrom: String
    public var ferruleTo: String
    public var state: WireState
    public var currentAmps: Double?
    public init(id: String, from: WireEndpoint, to: WireEndpoint, route: [ShopPoint] = [], wireNumber: String, color: ConductorColor, gauge: WireGauge, function: WireFunction, ferruleFrom: String = "", ferruleTo: String = "", state: WireState = .deenergized, currentAmps: Double? = nil) {
        self.id = id; self.from = from; self.to = to; self.route = route; self.wireNumber = wireNumber; self.color = color; self.gauge = gauge; self.function = function; self.ferruleFrom = ferruleFrom; self.ferruleTo = ferruleTo; self.state = state; self.currentAmps = currentAmps
    }
}

public struct SpatialSchematicDocument: Codable, Equatable, Sendable {
    public var title: String
    public var symbols: [SpatialSchematicSymbol]
    public var conductors: [RoutedConductor]
    public var canvasSize: ShopSize
    public var energized: Bool
    public var selectedFaultWireID: String?
    public init(title: String, symbols: [SpatialSchematicSymbol] = [], conductors: [RoutedConductor] = [], canvasSize: ShopSize = .init(width: 900, height: 560), energized: Bool = false, selectedFaultWireID: String? = nil) {
        self.title = title; self.symbols = symbols; self.conductors = conductors; self.canvasSize = canvasSize; self.energized = energized; self.selectedFaultWireID = selectedFaultWireID
    }
    public mutating func moveSymbol(id: String, to position: ShopPoint) {
        guard let i = symbols.firstIndex(where: { $0.id == id }) else { return }
        symbols[i].position = .init(x: min(max(0, position.x), max(0, canvasSize.width - symbols[i].size.width)), y: min(max(0, position.y), max(0, canvasSize.height - symbols[i].size.height)))
    }
    public mutating func addSymbol(_ symbol: SpatialSchematicSymbol) {
        if !symbols.contains(where: { $0.id == symbol.id }) { symbols.append(symbol) }
    }
    public mutating func connect(_ conductor: RoutedConductor) {
        guard terminalExists(conductor.from), terminalExists(conductor.to), conductor.from != conductor.to else { return }
        if !conductors.contains(where: { $0.id == conductor.id }) { conductors.append(conductor) }
    }
    public func terminalExists(_ endpoint: WireEndpoint) -> Bool {
        symbols.first(where: { $0.id == endpoint.symbolID })?.terminals.contains(where: { $0.id == endpoint.terminalID }) == true
    }
    public func endpointPosition(_ endpoint: WireEndpoint) -> ShopPoint? {
        symbols.first(where: { $0.id == endpoint.symbolID })?.terminalPosition(endpoint.terminalID)
    }
    public func validationIssues() -> [String] {
        var issues: [String] = []
        let wireNumbers = conductors.map(\.wireNumber).filter { !$0.isEmpty }
        let duplicateWireNumbers = Dictionary(grouping: wireNumbers, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        if !duplicateWireNumbers.isEmpty { issues.append("Duplicate wire numbers: \(duplicateWireNumbers.joined(separator: ", "))") }
        for c in conductors {
            if !terminalExists(c.from) || !terminalExists(c.to) { issues.append("Wire \(c.wireNumber) references a missing terminal") }
            if c.ferruleFrom.isEmpty || c.ferruleTo.isEmpty { issues.append("Wire \(c.wireNumber) is missing one or both ferrule IDs") }
            if c.function == .ground && c.color != .green && c.color != .greenYellow { issues.append("Ground wire \(c.wireNumber) should use the project ground conductor color") }
            if c.function == .analog && c.gauge == .awg8 { issues.append("Analog wire \(c.wireNumber) uses an implausibly large training gauge") }
        }
        return Array(Set(issues)).sorted()
    }
}

// MARK: - Probe placement directly on nodes

public enum MeterLead: String, Codable, CaseIterable, Sendable { case red, black }

public struct ProbePlacement: Codable, Equatable, Sendable {
    public var redNodeID: String?
    public var blackNodeID: String?
    public init(redNodeID: String? = nil, blackNodeID: String? = nil) { self.redNodeID = redNodeID; self.blackNodeID = blackNodeID }
    public mutating func place(_ lead: MeterLead, on nodeID: String) {
        switch lead { case .red: redNodeID = nodeID; case .black: blackNodeID = nodeID }
    }
}

public struct SpatialElectricalNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var position: ShopPoint
    public var node: ElectricalNode
    public init(id: String, label: String, position: ShopPoint, node: ElectricalNode) { self.id=id; self.label=label; self.position=position; self.node=node }
}

public enum ProbeMeasurementEngine {
    public static func reading(mode: MeterMode, placement: ProbePlacement, nodes: [SpatialElectricalNode]) -> MeterReading {
        guard let redID = placement.redNodeID, let blackID = placement.blackNodeID,
              let red = nodes.first(where: { $0.id == redID })?.node,
              let black = nodes.first(where: { $0.id == blackID })?.node else {
            return .init(display:"PLACE", numericValue:nil, unit:"", interpretation:"Place both meter probes directly on schematic nodes.", safetyWarning:nil)
        }
        return VirtualMeter.measure(mode: mode, red: red, black: black)
    }
}

// MARK: - Power-flow solver for training circuits

public struct PowerFlowSnapshot: Codable, Equatable, Sendable {
    public var energizedWireIDs: Set<String>
    public var blockedWireIDs: Set<String>
    public var energizedNodeIDs: Set<String>
    public init(energizedWireIDs: Set<String> = [], blockedWireIDs: Set<String> = [], energizedNodeIDs: Set<String> = []) {
        self.energizedWireIDs=energizedWireIDs; self.blockedWireIDs=blockedWireIDs; self.energizedNodeIDs=energizedNodeIDs
    }
}

public enum TrainingPowerFlowSolver {
    /// Intentionally simple graph propagation for low-energy training diagrams. Source terminals seed the graph;
    /// open/floating conductors block propagation. It is not a protection/arc-flash calculation engine.
    public static func solve(document: SpatialSchematicDocument) -> PowerFlowSnapshot {
        guard document.energized else { return .init() }
        var energizedNodes = Set<String>()
        for s in document.symbols {
            for t in s.terminals where t.role == .source { energizedNodes.insert(t.nodeID) }
        }
        var energizedWires = Set<String>(), blocked = Set<String>()
        var changed = true
        while changed {
            changed = false
            // Propagate through components that are modeled as closed/passive conductive paths in this lesson.
            // A future device-state layer can open/close these paths from pushbutton, relay, overload, and safety state.
            for symbol in document.symbols where internallyConductive(symbol.kind) {
                let nodes = symbol.terminals.map(\.nodeID)
                if nodes.contains(where: { energizedNodes.contains($0) }) {
                    for node in nodes where !energizedNodes.contains(node) { energizedNodes.insert(node); changed = true }
                }
            }
            for wire in document.conductors {
                guard let fromSymbol = document.symbols.first(where: { $0.id == wire.from.symbolID }),
                      let fromTerminal = fromSymbol.terminals.first(where: { $0.id == wire.from.terminalID }),
                      let toSymbol = document.symbols.first(where: { $0.id == wire.to.symbolID }),
                      let toTerminal = toSymbol.terminals.first(where: { $0.id == wire.to.terminalID }) else { continue }
                if wire.state == .open || wire.state == .floating {
                    if energizedNodes.contains(fromTerminal.nodeID) { blocked.insert(wire.id) }
                    continue
                }
                if energizedNodes.contains(fromTerminal.nodeID) && !energizedNodes.contains(toTerminal.nodeID) {
                    energizedNodes.insert(toTerminal.nodeID); energizedWires.insert(wire.id); changed = true
                } else if energizedNodes.contains(fromTerminal.nodeID) {
                    energizedWires.insert(wire.id)
                }
            }
        }
        return .init(energizedWireIDs: energizedWires, blockedWireIDs: blocked, energizedNodeIDs: energizedNodes)
    }
    private static func internallyConductive(_ kind: SchematicComponentKind) -> Bool {
        switch kind {
        case .fuse, .disconnect, .pushbuttonNO, .pushbuttonNC, .relayContactNO, .relayContactNC, .overloadNC, .terminal:
            return true
        default:
            return false
        }
    }
}

// MARK: - Configurable ControlLogix-style terminal diagrams

public enum IOModuleTerminalStyle: String, Codable, CaseIterable, Sendable { case removableTerminalBlock, fieldWiringArm, compactConnector }
public enum IOChannelMode: String, Codable, CaseIterable, Sendable { case disabled, digitalInput, digitalOutput, voltageInput, currentInput, voltageOutput, currentOutput, safetyInput, safetyOutput }

public struct IOTerminalDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var terminalNumber: String
    public var label: String
    public var channel: Int?
    public var role: TerminalElectricalRole
    public init(id: String, terminalNumber: String, label: String, channel: Int?, role: TerminalElectricalRole) { self.id=id; self.terminalNumber=terminalNumber; self.label=label; self.channel=channel; self.role=role }
}

public struct ConfigurableIOModule: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var catalogLabel: String
    public var moduleKind: RackModuleKind
    public var terminalStyle: IOModuleTerminalStyle
    public var slot: Int
    public var channelModes: [Int: IOChannelMode]
    public var terminals: [IOTerminalDefinition]
    public init(id: String, catalogLabel: String, moduleKind: RackModuleKind, terminalStyle: IOModuleTerminalStyle, slot: Int, channelModes: [Int: IOChannelMode], terminals: [IOTerminalDefinition]) {
        self.id=id; self.catalogLabel=catalogLabel; self.moduleKind=moduleKind; self.terminalStyle=terminalStyle; self.slot=slot; self.channelModes=channelModes; self.terminals=terminals
    }
    public mutating func setMode(_ mode: IOChannelMode, channel: Int) { channelModes[channel] = mode }
    public func validationIssues() -> [String] {
        var issues:[String]=[]
        let terminalNumbers=terminals.map(\.terminalNumber)
        if Set(terminalNumbers).count != terminalNumbers.count { issues.append("Duplicate terminal numbers") }
        for (ch, mode) in channelModes where !supports(mode) { issues.append("Channel \(ch) mode \(mode.rawValue) is incompatible with \(moduleKind.rawValue)") }
        return issues
    }
    private func supports(_ mode: IOChannelMode) -> Bool {
        if mode == .disabled { return true }
        switch moduleKind {
        case .digitalInput24VDC: return mode == .digitalInput
        case .digitalOutput24VDC: return mode == .digitalOutput
        case .analogInput: return mode == .voltageInput || mode == .currentInput
        case .analogOutput: return mode == .voltageOutput || mode == .currentOutput
        case .safetyInput: return mode == .safetyInput
        case .safetyOutput: return mode == .safetyOutput
        case .controller, .ethernetBridge: return false
        }
    }
}

// MARK: - Terminal-strip schedule and wire reports

public struct TerminalStripEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(strip)-\(terminal)" }
    public var strip: String
    public var terminal: String
    public var potential: String
    public var internalConnection: String
    public var externalConnection: String
    public var wireNumbers: [String]
    public var notes: String
}

public struct WireFromToRow: Identifiable, Codable, Equatable, Sendable {
    public var id: String { wireNumber }
    public var wireNumber: String
    public var from: String
    public var fromTerminal: String
    public var to: String
    public var toTerminal: String
    public var color: String
    public var gauge: String
    public var ferruleFrom: String
    public var ferruleTo: String
    public var function: String
}

public enum ElectricalDocumentationGenerator {
    public static func wireFromTo(document: SpatialSchematicDocument) -> [WireFromToRow] {
        document.conductors.compactMap { wire in
            guard let fs = document.symbols.first(where: { $0.id == wire.from.symbolID }), let ft = fs.terminals.first(where: { $0.id == wire.from.terminalID }),
                  let ts = document.symbols.first(where: { $0.id == wire.to.symbolID }), let tt = ts.terminals.first(where: { $0.id == wire.to.terminalID }) else { return nil }
            return .init(wireNumber: wire.wireNumber, from: fs.tag, fromTerminal: ft.terminalNumber, to: ts.tag, toTerminal: tt.terminalNumber, color: wire.color.rawValue, gauge: wire.gauge.rawValue, ferruleFrom: wire.ferruleFrom, ferruleTo: wire.ferruleTo, function: wire.function.rawValue)
        }.sorted { $0.wireNumber.localizedStandardCompare($1.wireNumber) == .orderedAscending }
    }

    public static func terminalSchedule(document: SpatialSchematicDocument) -> [TerminalStripEntry] {
        var entries:[TerminalStripEntry]=[]
        for symbol in document.symbols where symbol.kind == .terminal {
            for terminal in symbol.terminals {
                let connected = document.conductors.filter { ($0.from.symbolID == symbol.id && $0.from.terminalID == terminal.id) || ($0.to.symbolID == symbol.id && $0.to.terminalID == terminal.id) }
                let externals = connected.compactMap { wire -> String? in
                    let endpoint = wire.from.symbolID == symbol.id ? wire.to : wire.from
                    return document.symbols.first(where: { $0.id == endpoint.symbolID })?.tag
                }
                entries.append(.init(strip:symbol.tag, terminal:terminal.terminalNumber, potential:terminal.nodeID, internalConnection:symbol.label, externalConnection:externals.joined(separator:", "), wireNumbers:connected.map(\.wireNumber).sorted(), notes:""))
            }
        }
        return entries.sorted { ($0.strip, $0.terminal) < ($1.strip, $1.terminal) }
    }

    public static func csvWireFromTo(document: SpatialSchematicDocument) -> String {
        let header="Wire,From,From Terminal,To,To Terminal,Color,Gauge,Ferrule From,Ferrule To,Function"
        let rows=wireFromTo(document:document).map { [$0.wireNumber,$0.from,$0.fromTerminal,$0.to,$0.toTerminal,$0.color,$0.gauge,$0.ferruleFrom,$0.ferruleTo,$0.function].map(csvEscape).joined(separator:",") }
        return ([header]+rows).joined(separator:"\n")
    }
    private static func csvEscape(_ s:String)->String { "\"" + s.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }
}

// MARK: - Printable vector panel drawing

public struct PanelDrawingDocument: Codable, Equatable, Sendable {
    public var title:String
    public var drawingNumber:String
    public var revision:String
    public var panelWidthMM:Double
    public var panelHeightMM:Double
    public var parts:[PanelPart]
    public var conductors:[RoutedConductor]
    public init(title:String,drawingNumber:String,revision:String,panelWidthMM:Double,panelHeightMM:Double,parts:[PanelPart],conductors:[RoutedConductor]=[]) {
        self.title=title; self.drawingNumber=drawingNumber; self.revision=revision; self.panelWidthMM=panelWidthMM; self.panelHeightMM=panelHeightMM; self.parts=parts; self.conductors=conductors
    }
}

public enum PanelDrawingExporter {
    /// Produces a standalone vector drawing that can be opened in a browser and printed to scale or PDF.
    public static func svg(_ doc:PanelDrawingDocument)->String {
        let w=max(doc.panelWidthMM,100), h=max(doc.panelHeightMM,100)
        var body=""
        for p in doc.parts {
            let x=Double(p.x)*20+10, y=Double(p.y)*20+10, pw=Double(p.width)*20, ph=Double(p.height)*20
            body += "<rect x='\(x)' y='\(y)' width='\(pw)' height='\(ph)' fill='none' stroke='black' stroke-width='1'/><text x='\(x+3)' y='\(y+14)' font-size='10'>\(xml(p.tag))</text><text x='\(x+3)' y='\(y+27)' font-size='8'>\(xml(p.kind.rawValue))</text>"
        }
        let titleY=h-25
        return "<svg xmlns='http://www.w3.org/2000/svg' width='\(w)mm' height='\(h)mm' viewBox='0 0 \(w) \(h)'><rect x='1' y='1' width='\(w-2)' height='\(h-2)' fill='white' stroke='black'/><g>\(body)</g><line x1='1' y1='\(titleY-5)' x2='\(w-1)' y2='\(titleY-5)' stroke='black'/><text x='8' y='\(titleY+5)' font-size='11'>\(xml(doc.title))</text><text x='8' y='\(titleY+17)' font-size='8'>DWG \(xml(doc.drawingNumber)) • REV \(xml(doc.revision))</text></svg>"
    }
    private static func xml(_ s:String)->String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"'",with:"&apos;") }
}

// MARK: - Scored commissioning work orders

public enum CommissioningActionKind: String, Codable, CaseIterable, Sendable {
    case verifyDrawing, inspectPanel, verifyTorque, verifyGrounding, pointToPoint, insulationCheck, energizeControlPower, verifyIO, bumpMotor, verifyRotation, parameterizeDrive, validateInterlocks, validateSafety, runLoadedCycle, captureBaseline, updateDocumentation, proveRepair
}

public struct CommissioningWorkOrderStep: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var action:CommissioningActionKind
    public var instruction:String
    public var points:Double
    public var critical:Bool
    public var requiresBefore:[String]
    public init(id:String,action:CommissioningActionKind,instruction:String,points:Double,critical:Bool=false,requiresBefore:[String]=[]) { self.id=id; self.action=action; self.instruction=instruction; self.points=points; self.critical=critical; self.requiresBefore=requiresBefore }
}

public struct CommissioningWorkOrder: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var title:String
    public var machine:String
    public var timeLimitMinutes:Int
    public var steps:[CommissioningWorkOrderStep]
    public var passingPercent:Double
    public init(id:String,title:String,machine:String,timeLimitMinutes:Int,steps:[CommissioningWorkOrderStep],passingPercent:Double=85) { self.id=id; self.title=title; self.machine=machine; self.timeLimitMinutes=timeLimitMinutes; self.steps=steps; self.passingPercent=passingPercent }
}

public struct CommissioningAttempt: Codable, Equatable, Sendable {
    public var completedStepIDs:Set<String>=[]
    public var sequenceViolations:[String]=[]
    public var criticalFailures:Set<String>=[]
    public var documentationPenalty:Double=0
    public init() {}
    public mutating func complete(stepID:String, workOrder:CommissioningWorkOrder) {
        guard let step=workOrder.steps.first(where:{$0.id==stepID}), !completedStepIDs.contains(stepID) else { return }
        let missing=step.requiresBefore.filter { !completedStepIDs.contains($0) }
        if !missing.isEmpty {
            sequenceViolations.append("\(stepID) completed before prerequisite(s): \(missing.joined(separator:", "))")
            if step.critical { criticalFailures.insert(stepID) }
        }
        completedStepIDs.insert(stepID)
    }
    public func score(workOrder:CommissioningWorkOrder)->CommissioningScore {
        let total=workOrder.steps.reduce(0){$0+$1.points}
        let earned=workOrder.steps.filter{completedStepIDs.contains($0.id)}.reduce(0){$0+$1.points}
        let sequencePenalty=Double(sequenceViolations.count)*5
        let raw=total>0 ? earned/total*100 : 0
        let final=max(0,raw-sequencePenalty-documentationPenalty)
        let missingCritical=workOrder.steps.filter{$0.critical && !completedStepIDs.contains($0.id)}.map(\.id)
        let passed=final>=workOrder.passingPercent && missingCritical.isEmpty && criticalFailures.isEmpty
        return .init(percent:final,passed:passed,missingCriticalSteps:missingCritical,sequencePenalty:sequencePenalty,reason:passed ? "Commissioning work order passed with required critical evidence." : "Work order requires remediation: complete critical steps, preserve safe sequence, and reach the passing score.")
    }
}

public struct CommissioningScore: Codable, Equatable, Sendable {
    public var percent:Double
    public var passed:Bool
    public var missingCriticalSteps:[String]
    public var sequencePenalty:Double
    public var reason:String
}

// MARK: - Authored spatial shop content

public enum SpatialElectricalLabCatalog {
    private static let analogInputTerminals: [IOTerminalDefinition] = {
        var result: [IOTerminalDefinition] = []
        for channel in 0..<8 {
            result.append(.init(id:"IN\(channel)+",terminalNumber:"\(channel)+",label:"CH\(channel) +",channel:channel,role:.analogPositive))
            result.append(.init(id:"IN\(channel)-",terminalNumber:"\(channel)-",label:"CH\(channel) -",channel:channel,role:.analogNegative))
        }
        return result
    }()

    public static let starterDocument:SpatialSchematicDocument = {
        let src=SpatialSchematicSymbol(id:"PS1",kind:.powerSource,tag:"PS1",label:"24 VDC Power Supply",position:.init(x:40,y:150),terminals:[
            .init(id:"P",label:"+24",relativePosition:.init(x:1,y:0.35),role:.source,nodeID:"P24",terminalNumber:"+") ,
            .init(id:"N",label:"COM",relativePosition:.init(x:1,y:0.75),role:.common,nodeID:"COM",terminalNumber:"-")])
        let stop=SpatialSchematicSymbol(id:"PB1",kind:.pushbuttonNC,tag:"PB1",label:"STOP",position:.init(x:230,y:90),terminals:[
            .init(id:"1",label:"1",relativePosition:.init(x:0,y:0.5),role:.passive,nodeID:"PB1-1",terminalNumber:"1"),.init(id:"2",label:"2",relativePosition:.init(x:1,y:0.5),role:.passive,nodeID:"PB1-2",terminalNumber:"2")])
        let start=SpatialSchematicSymbol(id:"PB2",kind:.pushbuttonNO,tag:"PB2",label:"START",position:.init(x:430,y:90),terminals:[
            .init(id:"1",label:"1",relativePosition:.init(x:0,y:0.5),role:.passive,nodeID:"PB2-1",terminalNumber:"1"),.init(id:"2",label:"2",relativePosition:.init(x:1,y:0.5),role:.passive,nodeID:"PB2-2",terminalNumber:"2")])
        let coil=SpatialSchematicSymbol(id:"M1",kind:.contactorCoil,tag:"M1",label:"Motor Contactor",position:.init(x:650,y:90),terminals:[
            .init(id:"A1",label:"A1",relativePosition:.init(x:0,y:0.5),role:.sink,nodeID:"M1-A1",terminalNumber:"A1"),.init(id:"A2",label:"A2",relativePosition:.init(x:1,y:0.5),role:.common,nodeID:"M1-A2",terminalNumber:"A2")])
        let tb=SpatialSchematicSymbol(id:"TB1",kind:.terminal,tag:"TB1",label:"Field Terminal Strip",position:.init(x:420,y:300),size:.init(width:180,height:90),terminals:[
            .init(id:"1",label:"1",relativePosition:.init(x:0.15,y:0.5),role:.passive,nodeID:"N201",terminalNumber:"1"),.init(id:"2",label:"2",relativePosition:.init(x:0.5,y:0.5),role:.passive,nodeID:"N202",terminalNumber:"2"),.init(id:"3",label:"3",relativePosition:.init(x:0.85,y:0.5),role:.passive,nodeID:"N203",terminalNumber:"3")])
        var d=SpatialSchematicDocument(title:"Three-wire starter spatial lab",symbols:[src,stop,start,coil,tb],energized:true)
        d.conductors=[
            .init(id:"W101",from:.init(symbolID:"PS1",terminalID:"P"),to:.init(symbolID:"PB1",terminalID:"1"),wireNumber:"101",color:.red,gauge:.awg16,function:.dcControl,ferruleFrom:"101-PS1",ferruleTo:"101-PB1",state:.energized),
            .init(id:"W102",from:.init(symbolID:"PB1",terminalID:"2"),to:.init(symbolID:"PB2",terminalID:"1"),wireNumber:"102",color:.blue,gauge:.awg16,function:.dcControl,ferruleFrom:"102-PB1",ferruleTo:"102-PB2",state:.energized),
            .init(id:"W103",from:.init(symbolID:"PB2",terminalID:"2"),to:.init(symbolID:"M1",terminalID:"A1"),wireNumber:"103",color:.blue,gauge:.awg16,function:.dcControl,ferruleFrom:"103-PB2",ferruleTo:"103-M1",state:.energized),
            .init(id:"W104",from:.init(symbolID:"M1",terminalID:"A2"),to:.init(symbolID:"PS1",terminalID:"N"),wireNumber:"104",color:.white,gauge:.awg16,function:.dcControl,ferruleFrom:"104-M1",ferruleTo:"104-PS1",state:.deenergized)
        ]
        return d
    }()

    public static let ioModules:[ConfigurableIOModule] = [
        .init(id:"1756-IB16",catalogLabel:"1756-IB16-style 16 pt 24 VDC input",moduleKind:.digitalInput24VDC,terminalStyle:.removableTerminalBlock,slot:2,channelModes:Dictionary(uniqueKeysWithValues:(0..<16).map{($0,.digitalInput)}),terminals:(0..<16).map{.init(id:"IN\($0)",terminalNumber:String($0),label:"IN \($0)",channel:$0,role:.digitalInput)} + [.init(id:"COM",terminalNumber:"COM",label:"DC COM",channel:nil,role:.common)]),
        .init(id:"1756-IF8",catalogLabel:"1756-IF8-style 8 ch analog input",moduleKind:.analogInput,terminalStyle:.removableTerminalBlock,slot:3,channelModes:Dictionary(uniqueKeysWithValues:(0..<8).map{($0,.currentInput)}),terminals:analogInputTerminals)
    ]

    public static let commissioningOrders:[CommissioningWorkOrder] = [
        .init(id:"wo-pack-cell",title:"Commission Packaging Cell Panel",machine:"Packaging Cell: Dark Conveyor",timeLimitMinutes:60,steps:[
            .init(id:"dwg",action:.verifyDrawing,instruction:"Verify drawing revision, device tags, and field changes before touching wiring.",points:6,critical:true),
            .init(id:"inspect",action:.inspectPanel,instruction:"Inspect panel construction, segregation, labels, ferrules, duct, and terminal condition.",points:7,requiresBefore:["dwg"]),
            .init(id:"ground",action:.verifyGrounding,instruction:"Verify protective bonding and low-voltage commons per the training design.",points:8,critical:true,requiresBefore:["inspect"]),
            .init(id:"p2p",action:.pointToPoint,instruction:"Complete point-to-point wiring verification against the from/to report.",points:9,critical:true,requiresBefore:["ground"]),
            .init(id:"power",action:.energizeControlPower,instruction:"Energize modeled control power after pre-power checks pass.",points:8,critical:true,requiresBefore:["p2p"]),
            .init(id:"io",action:.verifyIO,instruction:"Verify every field input/output at terminal, module LED, and PLC tag boundaries.",points:10,requiresBefore:["power"]),
            .init(id:"drive",action:.parameterizeDrive,instruction:"Confirm VFD motor data, command/reference source, limits, and protection parameters.",points:9,requiresBefore:["power"]),
            .init(id:"bump",action:.bumpMotor,instruction:"Perform controlled bump test and verify expected direction.",points:8,critical:true,requiresBefore:["drive"]),
            .init(id:"safe",action:.validateSafety,instruction:"Validate modeled safety permissives and reset behavior before automatic motion.",points:10,critical:true,requiresBefore:["io"]),
            .init(id:"interlocks",action:.validateInterlocks,instruction:"Challenge process permissives and interlocks one at a time.",points:8,requiresBefore:["safe"]),
            .init(id:"loaded",action:.runLoadedCycle,instruction:"Run ten loaded production cycles and verify repeatability.",points:9,requiresBefore:["bump","interlocks"]),
            .init(id:"baseline",action:.captureBaseline,instruction:"Capture healthy electrical/PLC/drive baseline evidence.",points:4,requiresBefore:["loaded"]),
            .init(id:"docs",action:.updateDocumentation,instruction:"Update terminal schedule, wire from/to, as-built notes, and commissioning record.",points:4,critical:true,requiresBefore:["baseline"])
        ])
    ]
}
