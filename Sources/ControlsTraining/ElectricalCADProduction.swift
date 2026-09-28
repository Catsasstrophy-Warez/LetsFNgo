import Foundation

// MARK: - Drawing zones and production coordinates

public struct DrawingZoneGrid: Codable, Equatable, Sendable {
    public var columns: [String]
    public var rows: Int
    public init(columns: [String] = Array("ABCDEFGH").map(String.init), rows: Int = 8) {
        self.columns = columns; self.rows = max(1, rows)
    }
    public func coordinate(for point: ShopPoint, canvas: ShopSize, pageNumber: Int) -> String {
        guard canvas.width > 0, canvas.height > 0, !columns.isEmpty else { return "\(pageNumber)/?" }
        let c = min(columns.count - 1, max(0, Int(point.x / canvas.width * Double(columns.count))))
        let r = min(rows - 1, max(0, Int(point.y / canvas.height * Double(rows)))) + 1
        return "\(pageNumber)/\(columns[c])\(r)"
    }
    public func coordinate(for symbol: SpatialSchematicSymbol, page: SchematicPage) -> String {
        coordinate(for: .init(x: symbol.position.x + symbol.size.width / 2, y: symbol.position.y + symbol.size.height / 2), canvas: page.document.canvasSize, pageNumber: page.pageNumber)
    }
}

public struct DeviceChildLink: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var parentTag: String
    public var parentPageID: String
    public var parentSymbolID: String
    public var childPageID: String
    public var childSymbolID: String
    public var childRole: String
    public init(id: String, parentTag: String, parentPageID: String, parentSymbolID: String, childPageID: String, childSymbolID: String, childRole: String) {
        self.id=id; self.parentTag=parentTag; self.parentPageID=parentPageID; self.parentSymbolID=parentSymbolID; self.childPageID=childPageID; self.childSymbolID=childSymbolID; self.childRole=childRole
    }
}

public struct PrintedCrossReference: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(deviceTag)-\(symbolID)-\(text)" }
    public var deviceTag: String
    public var pageID: String
    public var symbolID: String
    public var text: String
}

public enum CrossReferencePrinter {
    public static func entries(project: ElectricalCADProject, grid: DrawingZoneGrid = .init()) -> [PrintedCrossReference] {
        var output: [PrintedCrossReference] = []
        for relay in project.relays {
            guard let coilPage = project.pages.first(where: { $0.id == relay.coilPageID }),
                  let coil = coilPage.document.symbols.first(where: { $0.id == relay.coilSymbolID }) else { continue }
            let childCoords = relay.contacts.compactMap { ref -> String? in
                guard let page = project.pages.first(where: { $0.id == ref.pageID }), let symbol = page.document.symbols.first(where: { $0.id == ref.symbolID }) else { return nil }
                return "\(ref.contactNumber)@\(grid.coordinate(for: symbol, page: page))"
            }
            output.append(.init(deviceTag: relay.deviceTag, pageID: coilPage.id, symbolID: coil.id, text: childCoords.joined(separator: "  ")))
            for ref in relay.contacts {
                guard let page = project.pages.first(where: { $0.id == ref.pageID }), let symbol = page.document.symbols.first(where: { $0.id == ref.symbolID }) else { continue }
                output.append(.init(deviceTag: relay.deviceTag, pageID: page.id, symbolID: symbol.id, text: "PARENT@\(grid.coordinate(for: coil, page: coilPage))"))
            }
        }
        return output
    }
}

// MARK: - Configurable title blocks

public struct TitleBlockField: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var value: String
    public var widthWeight: Double
    public init(id: String, label: String, value: String, widthWeight: Double = 1) { self.id=id; self.label=label; self.value=value; self.widthWeight=widthWeight }
}

public struct TitleBlockTemplate: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var company: String
    public var fields: [TitleBlockField]
    public init(id: String, name: String, company: String, fields: [TitleBlockField]) { self.id=id; self.name=name; self.company=company; self.fields=fields }
    public static let training = TitleBlockTemplate(id:"TB-TRAIN", name:"Technician Trainer & Simulator", company:"Training Engineering", fields:[])
    public func resolved(project: ElectricalCADProject, page: SchematicPage) -> [TitleBlockField] {
        var standard = [
            TitleBlockField(id:"project",label:"PROJECT",value:project.projectNumber,widthWeight:1.4),
            TitleBlockField(id:"title",label:"TITLE",value:project.title,widthWeight:2.2),
            TitleBlockField(id:"sheet",label:"SHEET",value:"\(page.pageNumber) / \(project.pages.count)"),
            TitleBlockField(id:"drawing",label:"DRAWING",value:page.sheetCode),
            TitleBlockField(id:"revision",label:"REV",value:project.revision)
        ]
        standard.append(contentsOf: fields)
        return standard
    }
}

// MARK: - Terminal bridges and cable fan-outs

public struct TerminalBridgeGraphic: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var pageID: String
    public var endpoints: [WireEndpoint]
    public var polyline: [ShopPoint]
}

public enum TerminalBridgeRenderer {
    public static func graphics(project: ElectricalCADProject) -> [TerminalBridgeGraphic] {
        project.jumpers.compactMap { jumper in
            guard let page = project.pages.first(where: { $0.id == jumper.pageID }) else { return nil }
            let pts = jumper.endpoints.compactMap { page.document.endpointPosition($0) }
            guard pts.count >= 2 else { return nil }
            let bridgeY = (pts.map(\.y).min() ?? 0) - 18
            var line: [ShopPoint] = [.init(x:pts[0].x,y:pts[0].y), .init(x:pts[0].x,y:bridgeY)]
            for p in pts.dropFirst() { line.append(.init(x:p.x,y:bridgeY)); line.append(.init(x:p.x,y:p.y)) }
            return .init(id:jumper.id,pageID:jumper.pageID,endpoints:jumper.endpoints,polyline:line)
        }
    }
}

public struct CableFanOutBranch: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var cableID: String
    public var coreID: String
    public var trunkPoint: ShopPoint
    public var endpoint: ShopPoint
}

public enum CableFanOutRenderer {
    public static func branches(cable: CableDefinition, project: ElectricalCADProject, trunk: ShopPoint) -> [CableFanOutBranch] {
        cable.cores.compactMap { core in
            guard let endpointRef = core.to ?? core.from,
                  let page = project.pages.first(where: { $0.id == cable.destinationPageID || $0.id == cable.sourcePageID }),
                  let p = page.document.endpointPosition(endpointRef) else { return nil }
            return .init(id:"\(cable.id)-\(core.id)",cableID:cable.id,coreID:core.id,trunkPoint:trunk,endpoint:p)
        }
    }
}

// MARK: - Intelligent libraries

public struct PanelFootprintDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var family: String
    public var manufacturerStyle: String
    public var widthMM: Double
    public var heightMM: Double
    public var depthMM: Double
    public var dinRailMount: Bool
    public var heatWatts: Double
    public var terminalCount: Int
    public init(id:String,family:String,manufacturerStyle:String,widthMM:Double,heightMM:Double,depthMM:Double,dinRailMount:Bool,heatWatts:Double,terminalCount:Int) {
        self.id=id; self.family=family; self.manufacturerStyle=manufacturerStyle; self.widthMM=widthMM; self.heightMM=heightMM; self.depthMM=depthMM; self.dinRailMount=dinRailMount; self.heatWatts=heatWatts; self.terminalCount=terminalCount
    }
}

public enum PanelFootprintLibrary {
    public static let standard: [PanelFootprintDefinition] = [
        .init(id:"FP-PS-24",family:"24 VDC Power Supply",manufacturerStyle:"DIN rail supply",widthMM:55,heightMM:125,depthMM:125,dinRailMount:true,heatWatts:25,terminalCount:6),
        .init(id:"FP-PLC-CH",family:"ControlLogix Chassis",manufacturerStyle:"1756-style chassis",widthMM:350,heightMM:145,depthMM:140,dinRailMount:false,heatWatts:20,terminalCount:0),
        .init(id:"FP-VFD-2HP",family:"VFD",manufacturerStyle:"2 HP class drive",widthMM:110,heightMM:220,depthMM:160,dinRailMount:false,heatWatts:90,terminalCount:18),
        .init(id:"FP-TB",family:"Feed-through Terminal",manufacturerStyle:"DIN terminal",widthMM:6.2,heightMM:48,depthMM:52,dinRailMount:true,heatWatts:0,terminalCount:2),
        .init(id:"FP-RELAY",family:"Interface Relay",manufacturerStyle:"Slim DIN relay",widthMM:6.2,heightMM:90,depthMM:70,dinRailMount:true,heatWatts:1.2,terminalCount:6)
    ]
}

public struct IntelligentSymbolDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var family: String
    public var kind: SchematicComponentKind
    public var defaultTagPrefix: String
    public var terminalLabels: [String]
    public var childRoles: [String]
    public var description: String
    public init(id:String,family:String,kind:SchematicComponentKind,defaultTagPrefix:String,terminalLabels:[String],childRoles:[String]=[],description:String) {
        self.id=id; self.family=family; self.kind=kind; self.defaultTagPrefix=defaultTagPrefix; self.terminalLabels=terminalLabels; self.childRoles=childRoles; self.description=description
    }
}

public enum IntelligentSymbolLibrary {
    public static let standard: [IntelligentSymbolDefinition] = [
        .init(id:"SYM-COIL",family:"Relay / Contactor Coil",kind:.relayCoil,defaultTagPrefix:"CR",terminalLabels:["A1","A2"],childRoles:["NO contact","NC contact"],description:"Parent coil that owns child contacts and cross-references."),
        .init(id:"SYM-NO",family:"Normally Open Contact",kind:.relayContactNO,defaultTagPrefix:"CR",terminalLabels:["13","14"],description:"Child contact linked to a parent device tag."),
        .init(id:"SYM-NC",family:"Normally Closed Contact",kind:.relayContactNC,defaultTagPrefix:"CR",terminalLabels:["21","22"],description:"Child contact linked to a parent device tag."),
        .init(id:"SYM-DI",family:"PLC Digital Input",kind:.plcInput,defaultTagPrefix:"DI",terminalLabels:["IN","COM"],description:"Address-aware PLC input point."),
        .init(id:"SYM-DO",family:"PLC Digital Output",kind:.plcOutput,defaultTagPrefix:"DO",terminalLabels:["OUT","COM"],description:"Address-aware PLC output point."),
        .init(id:"SYM-AI",family:"PLC Analog Input",kind:.analogInput,defaultTagPrefix:"AI",terminalLabels:["+","-"],description:"Analog channel with loop polarity metadata."),
        .init(id:"SYM-TB",family:"Terminal Block",kind:.terminal,defaultTagPrefix:"TB",terminalLabels:["1","2"],description:"Physical termination and jumper accessory anchor.")
    ]
}

// MARK: - Wire routing through duct

public struct RoutingDuctGeometry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var centerline: [ShopPoint]
    public var capacityWeight: Double
    public init(id:String,tag:String,centerline:[ShopPoint],capacityWeight:Double=1) { self.id=id; self.tag=tag; self.centerline=centerline; self.capacityWeight=max(0.1,capacityWeight) }
}

public struct OptimizedWireRoute: Codable, Equatable, Sendable {
    public var points: [ShopPoint]
    public var usedDuctIDs: [String]
    public var estimatedLength: Double
}

public enum WireRoutingOptimizer {
    public static func route(from: ShopPoint, to: ShopPoint, ducts: [RoutingDuctGeometry]) -> OptimizedWireRoute {
        var candidates: [OptimizedWireRoute] = []
        let direct = orthogonal(from: from, to: to)
        candidates.append(.init(points:direct,usedDuctIDs:[],estimatedLength:length(direct)))
        for duct in ducts where duct.centerline.count >= 2 {
            let entry = duct.centerline.min(by: { $0.distance(to: from) < $1.distance(to: from) })!
            let exit = duct.centerline.min(by: { $0.distance(to: to) < $1.distance(to: to) })!
            let i1 = duct.centerline.firstIndex(of: entry)!, i2 = duct.centerline.firstIndex(of: exit)!
            let slice = i1 <= i2 ? Array(duct.centerline[i1...i2]) : Array(duct.centerline[i2...i1].reversed())
            let points = orthogonal(from:from,to:entry) + slice.dropFirst() + orthogonal(from:exit,to:to).dropFirst()
            let raw = length(points)
            let weighted = raw / duct.capacityWeight
            candidates.append(.init(points:Array(points),usedDuctIDs:[duct.id],estimatedLength:weighted))
        }
        return candidates.min(by: { $0.estimatedLength < $1.estimatedLength }) ?? .init(points:direct,usedDuctIDs:[],estimatedLength:length(direct))
    }
    private static func orthogonal(from: ShopPoint, to: ShopPoint) -> [ShopPoint] { [from, .init(x:to.x,y:from.y), to] }
    private static func length(_ points:[ShopPoint]) -> Double { zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to:$1.1) } }
}

// MARK: - Undo / redo and cross-sheet clipboard

public struct ElectricalCADHistory: Codable, Equatable, Sendable {
    public var past: [ElectricalCADProject] = []
    public var future: [ElectricalCADProject] = []
    public var limit: Int = 50
    public init() {}
    public mutating func checkpoint(_ project: ElectricalCADProject) {
        past.append(project); if past.count > limit { past.removeFirst(past.count-limit) }; future.removeAll()
    }
    public mutating func undo(current: ElectricalCADProject) -> ElectricalCADProject {
        guard let previous = past.popLast() else { return current }
        future.append(current); return previous
    }
    public mutating func redo(current: ElectricalCADProject) -> ElectricalCADProject {
        guard let next = future.popLast() else { return current }
        past.append(current); return next
    }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
}

public struct SchematicClipboard: Codable, Equatable, Sendable {
    public var sourcePageID: String
    public var symbols: [SpatialSchematicSymbol]
    public var conductors: [RoutedConductor]
    public init(sourcePageID:String,symbols:[SpatialSchematicSymbol],conductors:[RoutedConductor]) { self.sourcePageID=sourcePageID; self.symbols=symbols; self.conductors=conductors }
    public static func copy(project: ElectricalCADProject, pageID: String, symbolIDs: Set<String>) -> SchematicClipboard? {
        guard let page=project.pages.first(where:{$0.id==pageID}) else { return nil }
        let symbols=page.document.symbols.filter{symbolIDs.contains($0.id)}
        guard !symbols.isEmpty else { return nil }
        let conductors=page.document.conductors.filter{symbolIDs.contains($0.from.symbolID) && symbolIDs.contains($0.to.symbolID)}
        return .init(sourcePageID:pageID,symbols:symbols,conductors:conductors)
    }
    public func paste(into project: inout ElectricalCADProject, pageID: String, offset: ShopPoint = .init(x:40,y:40), idSuffix:String = "-COPY") {
        guard let pi=project.pages.firstIndex(where:{$0.id==pageID}) else{return}
        let existing=Set(project.pages[pi].document.symbols.map(\.id))
        var map:[String:String]=[:]
        for symbol in symbols {
            var candidate=symbol.id+idSuffix; var n=2
            while existing.contains(candidate) || map.values.contains(candidate) { candidate=symbol.id+idSuffix+"\(n)"; n+=1 }
            map[symbol.id]=candidate
            let s=symbol
            // IDs are immutable, so recreate.
            let rebuilt=SpatialSchematicSymbol(id:candidate,kind:s.kind,tag:s.tag+idSuffix,label:s.label,position:.init(x:s.position.x+offset.x,y:s.position.y+offset.y),size:s.size,terminals:s.terminals.map{ t in SpatialTerminal(id:t.id,label:t.label,relativePosition:t.relativePosition,role:t.role,nodeID:"\(candidate)-\(t.id)",terminalNumber:t.terminalNumber)},rotationDegrees:s.rotationDegrees)
            project.pages[pi].document.addSymbol(rebuilt)
        }
        for wire in conductors {
            guard let f=map[wire.from.symbolID], let t=map[wire.to.symbolID] else {continue}
            let w=wire
            let rebuilt=RoutedConductor(id:wire.id+idSuffix,from:.init(symbolID:f,terminalID:wire.from.terminalID),to:.init(symbolID:t,terminalID:wire.to.terminalID),route:w.route.map{.init(x:$0.x+offset.x,y:$0.y+offset.y)},wireNumber:"",color:w.color,gauge:w.gauge,function:w.function,ferruleFrom:"",ferruleTo:"",state:.deenergized,currentAmps:nil)
            project.pages[pi].document.connect(rebuilt)
        }
    }
}

// MARK: - Revision comparison

public enum RevisionChangeKind: String, Codable, Sendable { case added, removed, modified }
public struct RevisionChange: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: RevisionChangeKind
    public var category: String
    public var pageID: String?
    public var summary: String
}

public enum ElectricalRevisionComparer {
    public static func compare(old: ElectricalCADProject, new: ElectricalCADProject) -> [RevisionChange] {
        var changes:[RevisionChange]=[]
        let oldPages=Dictionary(uniqueKeysWithValues:old.pages.map{($0.id,$0)}), newPages=Dictionary(uniqueKeysWithValues:new.pages.map{($0.id,$0)})
        for id in Set(oldPages.keys).union(newPages.keys).sorted() {
            switch (oldPages[id],newPages[id]) {
            case (nil,let n?): changes.append(.init(id:"page+\(id)",kind:.added,category:"Sheet",pageID:id,summary:"Added \(n.sheetCode) — \(n.title)"))
            case (let o?,nil): changes.append(.init(id:"page-\(id)",kind:.removed,category:"Sheet",pageID:id,summary:"Removed \(o.sheetCode) — \(o.title)"))
            case (let o?,let n?):
                compareSymbols(o,n,&changes); compareWires(o,n,&changes)
                if o.title != n.title || o.sheetCode != n.sheetCode { changes.append(.init(id:"page~\(id)",kind:.modified,category:"Sheet",pageID:id,summary:"Sheet metadata changed")) }
            default: break
            }
        }
        if old.revision != new.revision { changes.append(.init(id:"revision",kind:.modified,category:"Project",pageID:nil,summary:"Revision \(old.revision) → \(new.revision)")) }
        if old.plcAssignments != new.plcAssignments { changes.append(.init(id:"plc",kind:.modified,category:"PLC",pageID:nil,summary:"PLC address assignment set changed")) }
        return changes
    }
    private static func compareSymbols(_ old:SchematicPage,_ new:SchematicPage,_ changes:inout[RevisionChange]) {
        let a=Dictionary(uniqueKeysWithValues:old.document.symbols.map{($0.id,$0)}),b=Dictionary(uniqueKeysWithValues:new.document.symbols.map{($0.id,$0)})
        for id in Set(a.keys).union(b.keys).sorted() {
            if a[id] == nil { changes.append(.init(id:"sym+\(new.id)-\(id)",kind:.added,category:"Symbol",pageID:new.id,summary:"Added symbol \(b[id]!.tag)")) }
            else if b[id] == nil { changes.append(.init(id:"sym-\(old.id)-\(id)",kind:.removed,category:"Symbol",pageID:old.id,summary:"Removed symbol \(a[id]!.tag)")) }
            else if a[id] != b[id] { changes.append(.init(id:"sym~\(new.id)-\(id)",kind:.modified,category:"Symbol",pageID:new.id,summary:"Modified symbol \(b[id]!.tag)")) }
        }
    }
    private static func compareWires(_ old:SchematicPage,_ new:SchematicPage,_ changes:inout[RevisionChange]) {
        let a=Dictionary(uniqueKeysWithValues:old.document.conductors.map{($0.id,$0)}),b=Dictionary(uniqueKeysWithValues:new.document.conductors.map{($0.id,$0)})
        for id in Set(a.keys).union(b.keys).sorted() {
            if a[id] == nil { changes.append(.init(id:"wire+\(new.id)-\(id)",kind:.added,category:"Wire",pageID:new.id,summary:"Added wire \(b[id]!.wireNumber)")) }
            else if b[id] == nil { changes.append(.init(id:"wire-\(old.id)-\(id)",kind:.removed,category:"Wire",pageID:old.id,summary:"Removed wire \(a[id]!.wireNumber)")) }
            else if a[id] != b[id] { changes.append(.init(id:"wire~\(new.id)-\(id)",kind:.modified,category:"Wire",pageID:new.id,summary:"Modified wire \(b[id]!.wireNumber)")) }
        }
    }
}

// MARK: - Seeded randomized instructor exams

public struct MiswireExam: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var seed: UInt64
    public var title: String
    public var faults: [InstructorMiswire]
    public var timeLimitMinutes: Int
    public var passingPercent: Double
}

public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

public enum RandomizedMiswireExamGenerator {
    public static func generate(seed: UInt64, difficulty: Int, bank:[InstructorMiswire]=ElectricalCADProjectCatalog.instructorFaultBank) -> MiswireExam {
        var rng=SeededGenerator(seed:seed)
        let count=min(max(1,difficulty+1),bank.count)
        var pool=bank, selected:[InstructorMiswire]=[]
        while selected.count<count && !pool.isEmpty { let i=Int(rng.next()%UInt64(pool.count)); selected.append(pool.remove(at:i)) }
        return .init(id:"EXAM-\(seed)-D\(difficulty)",seed:seed,title:"Randomized Miswire Exam D\(difficulty)",faults:selected,timeLimitMinutes:15+difficulty*10,passingPercent:difficulty>=3 ? 85:80)
    }
    public static func apply(_ exam: MiswireExam, to project: inout ElectricalCADProject) { for fault in exam.faults { project.inject(fault) } }
}

// MARK: - Production helpers

public enum DrawingProductionEngine {
    public static func childLinks(project: ElectricalCADProject) -> [DeviceChildLink] {
        project.relays.flatMap { relay in relay.contacts.map { c in .init(id:"\(relay.id)-\(c.id)",parentTag:relay.deviceTag,parentPageID:relay.coilPageID,parentSymbolID:relay.coilSymbolID,childPageID:c.pageID,childSymbolID:c.symbolID,childRole:"\(c.form.rawValue) \(c.contactNumber)") } }
    }
    public static func zoneIndex(project: ElectricalCADProject, grid:DrawingZoneGrid = .init()) -> [String:String] {
        var result:[String:String]=[:]
        for page in project.pages { for symbol in page.document.symbols { result["\(page.id):\(symbol.id)"] = grid.coordinate(for:symbol,page:page) } }
        return result
    }
}
