import Foundation

// MARK: - Multi-page electrical CAD project

public struct SchematicPage: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var pageNumber: Int
    public var sheetCode: String
    public var title: String
    public var document: SpatialSchematicDocument
    public init(id: String, pageNumber: Int, sheetCode: String, title: String, document: SpatialSchematicDocument) {
        self.id = id; self.pageNumber = pageNumber; self.sheetCode = sheetCode; self.title = title; self.document = document
    }
}

public enum RelayContactForm: String, Codable, CaseIterable, Sendable { case normallyOpen, normallyClosed }

public struct RelayContactReference: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var pageID: String
    public var symbolID: String
    public var form: RelayContactForm
    public var contactNumber: String
    public init(id: String, pageID: String, symbolID: String, form: RelayContactForm, contactNumber: String) {
        self.id=id; self.pageID=pageID; self.symbolID=symbolID; self.form=form; self.contactNumber=contactNumber
    }
}

public struct RelayDeviceRelationship: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var deviceTag: String
    public var coilPageID: String
    public var coilSymbolID: String
    public var contacts: [RelayContactReference]
    public init(id: String, deviceTag: String, coilPageID: String, coilSymbolID: String, contacts: [RelayContactReference]) {
        self.id=id; self.deviceTag=deviceTag; self.coilPageID=coilPageID; self.coilSymbolID=coilSymbolID; self.contacts=contacts
    }
}

public struct CrossReferenceEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(deviceTag)-\(sourcePage)-\(targetPage)-\(targetSymbolID)" }
    public var deviceTag: String
    public var sourcePage: String
    public var sourceSymbolID: String
    public var targetPage: String
    public var targetSymbolID: String
    public var description: String
}

public struct TerminalJumper: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var pageID: String
    public var endpoints: [WireEndpoint]
    public var style: String
    public var removable: Bool
    public init(id: String, pageID: String, endpoints: [WireEndpoint], style: String = "comb", removable: Bool = true) {
        self.id=id; self.pageID=pageID; self.endpoints=endpoints; self.style=style; self.removable=removable
    }
}

public struct CableCore: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var coreNumber: String
    public var color: ConductorColor
    public var gauge: WireGauge
    public var function: WireFunction
    public var from: WireEndpoint?
    public var to: WireEndpoint?
    public var shielded: Bool
    public init(id: String, coreNumber: String, color: ConductorColor, gauge: WireGauge, function: WireFunction, from: WireEndpoint? = nil, to: WireEndpoint? = nil, shielded: Bool = false) {
        self.id=id; self.coreNumber=coreNumber; self.color=color; self.gauge=gauge; self.function=function; self.from=from; self.to=to; self.shielded=shielded
    }
}

public struct CableDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var description: String
    public var sourcePageID: String
    public var destinationPageID: String
    public var cores: [CableCore]
    public var overallShield: Bool
    public init(id: String, tag: String, description: String, sourcePageID: String, destinationPageID: String, cores: [CableCore], overallShield: Bool = false) {
        self.id=id; self.tag=tag; self.description=description; self.sourcePageID=sourcePageID; self.destinationPageID=destinationPageID; self.cores=cores; self.overallShield=overallShield
    }
}

public struct PLCAddressAssignment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var pageID: String
    public var symbolID: String
    public var moduleID: String
    public var slot: Int
    public var channel: Int
    public var mode: IOChannelMode
    public var address: String
    public var tagName: String
    public init(id: String, pageID: String, symbolID: String, moduleID: String, slot: Int, channel: Int, mode: IOChannelMode, address: String, tagName: String) {
        self.id=id; self.pageID=pageID; self.symbolID=symbolID; self.moduleID=moduleID; self.slot=slot; self.channel=channel; self.mode=mode; self.address=address; self.tagName=tagName
    }
}

public struct RevisionCloud: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var pageID: String
    public var revision: String
    public var description: String
    public var points: [ShopPoint]
    public var createdBy: String
    public var createdAt: Date
    public init(id: String, pageID: String, revision: String, description: String, points: [ShopPoint], createdBy: String, createdAt: Date = Date()) {
        self.id=id; self.pageID=pageID; self.revision=revision; self.description=description; self.points=points; self.createdBy=createdBy; self.createdAt=createdAt
    }
}

// MARK: - DIN rails, ducts, and thermal model

public struct DINRail: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var y: Double
    public var xStart: Double
    public var xEnd: Double
    public var snapTolerance: Double
    public init(id: String, tag: String, y: Double, xStart: Double, xEnd: Double, snapTolerance: Double = 26) {
        self.id=id; self.tag=tag; self.y=y; self.xStart=xStart; self.xEnd=xEnd; self.snapTolerance=snapTolerance
    }
}

public struct PanelPlacement: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var part: PanelPart
    public var position: ShopPoint
    public var railID: String?
    public init(id: String, part: PanelPart, position: ShopPoint, railID: String? = nil) {
        self.id=id; self.part=part; self.position=position; self.railID=railID
    }
}

public enum DINRailSnapEngine {
    public static func snap(_ placement: PanelPlacement, to rails: [DINRail]) -> PanelPlacement {
        guard let rail = rails
            .filter({ placement.position.x >= $0.xStart && placement.position.x <= $0.xEnd })
            .min(by: { abs(placement.position.y-$0.y) < abs(placement.position.y-$1.y) }),
              abs(placement.position.y-rail.y) <= rail.snapTolerance else { return placement }
        var result = placement
        result.position.y = rail.y
        result.railID = rail.id
        return result
    }
}

public struct WireDuctSection: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var internalWidthMM: Double
    public var internalHeightMM: Double
    public var fillLimitPercent: Double
    public var conductorIDs: [String]
    public init(id: String, tag: String, internalWidthMM: Double, internalHeightMM: Double, fillLimitPercent: Double = 40, conductorIDs: [String] = []) {
        self.id=id; self.tag=tag; self.internalWidthMM=internalWidthMM; self.internalHeightMM=internalHeightMM; self.fillLimitPercent=fillLimitPercent; self.conductorIDs=conductorIDs
    }
}

public struct DuctFillResult: Codable, Equatable, Sendable {
    public var usedAreaMM2: Double
    public var availableAreaMM2: Double
    public var fillPercent: Double
    public var passes: Bool
}

public enum WireDuctCalculator {
    public static func fill(_ duct: WireDuctSection, conductors: [RoutedConductor]) -> DuctFillResult {
        let selected = conductors.filter { duct.conductorIDs.contains($0.id) }
        let used = selected.reduce(0.0) { $0 + estimatedInstalledAreaMM2($1.gauge) }
        let area = max(0, duct.internalWidthMM * duct.internalHeightMM)
        let pct = area > 0 ? used / area * 100 : 100
        return .init(usedAreaMM2:used, availableAreaMM2:area, fillPercent:pct, passes:pct <= duct.fillLimitPercent)
    }
    private static func estimatedInstalledAreaMM2(_ gauge: WireGauge) -> Double {
        switch gauge {
        case .awg18: return 7.1
        case .awg16: return 9.6
        case .awg14: return 13.0
        case .awg12: return 17.8
        case .awg10: return 25.8
        case .awg8: return 43.0
        }
    }
}

public struct HeatMapCell: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(row)-\(column)" }
    public var row: Int
    public var column: Int
    public var temperatureRiseC: Double
}

public enum EnclosureHeatMapEngine {
    public static func calculate(placements: [PanelPlacement], width: Double, height: Double, columns: Int = 12, rows: Int = 16, ambientC: Double = 25) -> [HeatMapCell] {
        guard columns > 0, rows > 0, width > 0, height > 0 else { return [] }
        return (0..<rows).flatMap { r in
            (0..<columns).map { c in
                let x = (Double(c)+0.5)/Double(columns)*width
                let y = (Double(r)+0.5)/Double(rows)*height
                let rise = placements.reduce(0.0) { sum, p in
                    let dx=x-p.position.x, dy=y-p.position.y
                    let distance=max(24.0,(dx*dx+dy*dy).squareRoot())
                    return sum + p.part.heatWatts * 5.5 / distance
                }
                return HeatMapCell(row:r,column:c,temperatureRiseC:ambientC + rise)
            }
        }
    }
}

// MARK: - BOM

public struct BOMLine: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(category)-\(partNumber)-\(description)" }
    public var category: String
    public var partNumber: String
    public var description: String
    public var quantity: Int
    public var tags: [String]
}

public enum ElectricalBOMGenerator {
    public static func generate(project: ElectricalCADProject) -> [BOMLine] {
        var lines: [String:BOMLine] = [:]
        func add(category:String, part:String, description:String, tag:String) {
            let key="\(category)|\(part)|\(description)"
            if var line=lines[key] { line.quantity += 1; line.tags.append(tag); lines[key]=line }
            else { lines[key] = .init(category:category, partNumber:part, description:description, quantity:1, tags:[tag]) }
        }
        for page in project.pages {
            for s in page.document.symbols { add(category:"Schematic device",part:s.kind.rawValue,description:s.label,tag:s.tag) }
        }
        for p in project.panelPlacements { add(category:"Panel hardware",part:p.part.kind.rawValue,description:p.part.kind.rawValue,tag:p.part.tag) }
        for cable in project.cables { add(category:"Cable",part:"\(cable.cores.count)C",description:cable.description,tag:cable.tag) }
        for jumper in project.jumpers { add(category:"Terminal accessory",part:"jumper-\(jumper.style)",description:"Terminal jumper",tag:jumper.id) }
        return lines.values.sorted { ($0.category,$0.description) < ($1.category,$1.description) }
    }
}

// MARK: - Instructor miswire engine

public enum InstructorMiswireKind: String, Codable, CaseIterable, Sendable {
    case swappedConductors, missingJumper, wrongPLCAddress, wrongCableCore, openConductor, wrongWireGauge, wrongWireColor, deviceOffRail
}

public struct InstructorMiswire: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: InstructorMiswireKind
    public var title: String
    public var symptom: String
    public var pageID: String?
    public var targetIDs: [String]
    public var hiddenFromLearner: Bool
    public var points: Double
    public init(id:String,kind:InstructorMiswireKind,title:String,symptom:String,pageID:String?=nil,targetIDs:[String],hiddenFromLearner:Bool=true,points:Double=10) {
        self.id=id; self.kind=kind; self.title=title; self.symptom=symptom; self.pageID=pageID; self.targetIDs=targetIDs; self.hiddenFromLearner=hiddenFromLearner; self.points=points
    }
}

public struct InstructorFaultSession: Codable, Equatable, Sendable {
    public var injectedFaults: [InstructorMiswire]
    public var learnerFindings: Set<String>
    public var learnerRepairs: Set<String>
    public init(injectedFaults:[InstructorMiswire]=[],learnerFindings:Set<String>=[],learnerRepairs:Set<String>=[]) {
        self.injectedFaults=injectedFaults; self.learnerFindings=learnerFindings; self.learnerRepairs=learnerRepairs
    }
    public var scorePercent: Double {
        let total = injectedFaults.reduce(0) { $0 + $1.points * 2 }
        guard total > 0 else { return 100 }
        let earned = injectedFaults.reduce(0.0) { sum, fault in
            sum + (learnerFindings.contains(fault.id) ? fault.points : 0) + (learnerRepairs.contains(fault.id) ? fault.points : 0)
        }
        return earned/total*100
    }
}

public struct ElectricalCADProject: Codable, Equatable, Sendable {
    public var projectNumber: String
    public var title: String
    public var revision: String
    public var pages: [SchematicPage]
    public var relays: [RelayDeviceRelationship]
    public var jumpers: [TerminalJumper]
    public var cables: [CableDefinition]
    public var plcAssignments: [PLCAddressAssignment]
    public var ioModules: [ConfigurableIOModule]
    public var dinRails: [DINRail]
    public var panelPlacements: [PanelPlacement]
    public var wireDucts: [WireDuctSection]
    public var revisionClouds: [RevisionCloud]
    public var instructorSession: InstructorFaultSession
    public init(projectNumber:String,title:String,revision:String,pages:[SchematicPage],relays:[RelayDeviceRelationship]=[],jumpers:[TerminalJumper]=[],cables:[CableDefinition]=[],plcAssignments:[PLCAddressAssignment]=[],ioModules:[ConfigurableIOModule]=[],dinRails:[DINRail]=[],panelPlacements:[PanelPlacement]=[],wireDucts:[WireDuctSection]=[],revisionClouds:[RevisionCloud]=[],instructorSession: InstructorFaultSession = .init()) {
        self.projectNumber=projectNumber; self.title=title; self.revision=revision; self.pages=pages; self.relays=relays; self.jumpers=jumpers; self.cables=cables; self.plcAssignments=plcAssignments; self.ioModules=ioModules; self.dinRails=dinRails; self.panelPlacements=panelPlacements; self.wireDucts=wireDucts; self.revisionClouds=revisionClouds; self.instructorSession=instructorSession
    }

    public func crossReferences() -> [CrossReferenceEntry] {
        relays.flatMap { relay in relay.contacts.map { c in
            .init(deviceTag:relay.deviceTag,sourcePage:relay.coilPageID,sourceSymbolID:relay.coilSymbolID,targetPage:c.pageID,targetSymbolID:c.symbolID,description:"\(c.form.rawValue) contact \(c.contactNumber)")
        }}
    }

    public func relayContactClosed(relayID:String, contactID:String, energizedCoilSymbolIDs:Set<String>) -> Bool? {
        guard let relay=relays.first(where:{$0.id==relayID}), let contact=relay.contacts.first(where:{$0.id==contactID}) else { return nil }
        let coilOn=energizedCoilSymbolIDs.contains(relay.coilSymbolID)
        return contact.form == .normallyOpen ? coilOn : !coilOn
    }

    public mutating func autoNumberWires(start:Int=100) {
        var next=start
        for pi in pages.indices.sorted(by:{pages[$0].pageNumber < pages[$1].pageNumber}) {
            let pagePrefix=pages[pi].pageNumber * 1000
            for wi in pages[pi].document.conductors.indices {
                if pages[pi].document.conductors[wi].wireNumber.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    pages[pi].document.conductors[wi].wireNumber=String(pagePrefix+next)
                    next += 1
                }
            }
        }
    }

    /// Applies a wire number to the selected conductor and any conductors electrically joined at the same physical
    /// terminal or through a modeled terminal jumper. This mirrors CAD-style potential-number propagation without
    /// incorrectly carrying a number through a relay/contact/device boundary.
    public mutating func propagateWireNumber(pageID: String, from wireID: String, number: String) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }),
              let seed = pages[pageIndex].document.conductors.first(where: { $0.id == wireID }) else { return }
        var frontier = [seed.from, seed.to]
        var visitedEndpoints = Set<WireEndpoint>()
        var affectedWireIDs = Set([wireID])
        let pageJumpers = jumpers.filter { $0.pageID == pageID }
        while let endpoint = frontier.popLast() {
            guard visitedEndpoints.insert(endpoint).inserted else { continue }
            for conductor in pages[pageIndex].document.conductors where conductor.from == endpoint || conductor.to == endpoint {
                if affectedWireIDs.insert(conductor.id).inserted {
                    frontier.append(conductor.from); frontier.append(conductor.to)
                }
            }
            for jumper in pageJumpers where jumper.endpoints.contains(endpoint) {
                frontier.append(contentsOf: jumper.endpoints)
            }
        }
        for i in pages[pageIndex].document.conductors.indices where affectedWireIDs.contains(pages[pageIndex].document.conductors[i].id) {
            pages[pageIndex].document.conductors[i].wireNumber = number
        }
    }

    public mutating func assignPLCAddressesFromDrawing() {
        var generated:[PLCAddressAssignment]=[]
        for page in pages {
            for symbol in page.document.symbols where [.plcInput,.plcOutput,.analogInput].contains(symbol.kind) {
                let used = Set(generated.map { "\($0.slot)-\($0.channel)" })
                let module = ioModules.first { module in
                    switch symbol.kind {
                    case .plcInput: return module.moduleKind == .digitalInput24VDC
                    case .plcOutput: return module.moduleKind == .digitalOutput24VDC
                    case .analogInput: return module.moduleKind == .analogInput
                    default: return false
                    }
                }
                guard let module else { continue }
                guard let channel = module.channelModes.keys.sorted().first(where:{ !used.contains("\(module.slot)-\($0)") }) else { continue }
                let mode=module.channelModes[channel] ?? .disabled
                let direction = module.moduleKind == .digitalOutput24VDC ? "O" : "I"
                let address="Local:\(module.slot):\(direction).Data[\(channel)]"
                generated.append(.init(id:"\(page.id)-\(symbol.id)",pageID:page.id,symbolID:symbol.id,moduleID:module.id,slot:module.slot,channel:channel,mode:mode,address:address,tagName:symbol.tag))
            }
        }
        plcAssignments=generated
    }

    public mutating func inject(_ fault: InstructorMiswire) {
        instructorSession.injectedFaults.append(fault)
        switch fault.kind {
        case .openConductor:
            if let pageID=fault.pageID, let pi=pages.firstIndex(where:{$0.id==pageID}), let wireID=fault.targetIDs.first, let wi=pages[pi].document.conductors.firstIndex(where:{$0.id==wireID}) { pages[pi].document.conductors[wi].state = .open }
        case .wrongWireGauge:
            if let pageID=fault.pageID, let pi=pages.firstIndex(where:{$0.id==pageID}), let wireID=fault.targetIDs.first, let wi=pages[pi].document.conductors.firstIndex(where:{$0.id==wireID}) { pages[pi].document.conductors[wi].gauge = .awg8 }
        case .wrongWireColor:
            if let pageID=fault.pageID, let pi=pages.firstIndex(where:{$0.id==pageID}), let wireID=fault.targetIDs.first, let wi=pages[pi].document.conductors.firstIndex(where:{$0.id==wireID}) { pages[pi].document.conductors[wi].color = .violet }
        case .missingJumper:
            if let id=fault.targetIDs.first { jumpers.removeAll(where:{$0.id==id}) }
        case .wrongPLCAddress:
            if let id=fault.targetIDs.first, let i=plcAssignments.firstIndex(where:{$0.id==id}) { plcAssignments[i].channel += 1; plcAssignments[i].address += "_MISWIRED" }
        case .deviceOffRail:
            if let id=fault.targetIDs.first, let i=panelPlacements.firstIndex(where:{$0.id==id}) { panelPlacements[i].railID=nil; panelPlacements[i].position.y += 55 }
        case .wrongCableCore:
            if let cableID=fault.targetIDs.first, let i=cables.firstIndex(where:{$0.id==cableID}), cables[i].cores.count >= 2 { cables[i].cores.swapAt(0,1) }
        case .swappedConductors:
            if let pageID=fault.pageID, let pi=pages.firstIndex(where:{$0.id==pageID}), fault.targetIDs.count>=2,
               let a=pages[pi].document.conductors.firstIndex(where:{$0.id==fault.targetIDs[0]}), let b=pages[pi].document.conductors.firstIndex(where:{$0.id==fault.targetIDs[1]}) {
                let temp=pages[pi].document.conductors[a].to; pages[pi].document.conductors[a].to=pages[pi].document.conductors[b].to; pages[pi].document.conductors[b].to=temp
            }
        }
    }
}

public enum ElectricalCADProjectCatalog {
    public static let trainingProject: ElectricalCADProject = {
        let control = SpatialElectricalLabCatalog.starterDocument
        var ioDoc = SpatialSchematicDocument(title:"PLC I/O field wiring",canvasSize:.init(width:900,height:560),energized:true)
        let sensor=SpatialSchematicSymbol(id:"PE203",kind:.sensorPNP,tag:"PE203",label:"Infeed photoeye",position:.init(x:80,y:120),terminals:[
            .init(id:"OUT",label:"OUT",relativePosition:.init(x:1,y:0.5),role:.source,nodeID:"PE203-OUT",terminalNumber:"BK")])
        let input=SpatialSchematicSymbol(id:"DI0",kind:.plcInput,tag:"Local_DI_PE203",label:"PLC digital input",position:.init(x:560,y:120),terminals:[
            .init(id:"IN",label:"IN0",relativePosition:.init(x:0,y:0.5),role:.digitalInput,nodeID:"DI0-IN",terminalNumber:"0")])
        ioDoc.symbols=[sensor,input]
        ioDoc.conductors=[.init(id:"WDI0",from:.init(symbolID:"PE203",terminalID:"OUT"),to:.init(symbolID:"DI0",terminalID:"IN"),wireNumber:"",color:.blue,gauge:.awg18,function:.dcControl,ferruleFrom:"PE203-BK",ferruleTo:"DI0-0")]

        let aux=SpatialSchematicSymbol(id:"M1AUX",kind:.relayContactNO,tag:"M1",label:"M1 aux contact",position:.init(x:300,y:180),terminals:[
            .init(id:"13",label:"13",relativePosition:.init(x:0,y:0.5),role:.passive,nodeID:"M1AUX-13",terminalNumber:"13"),
            .init(id:"14",label:"14",relativePosition:.init(x:1,y:0.5),role:.passive,nodeID:"M1AUX-14",terminalNumber:"14")])
        var statusDoc=SpatialSchematicDocument(title:"Motor status and permissives",symbols:[aux],canvasSize:.init(width:900,height:560),energized:true)
        statusDoc.conductors=[]

        let pages=[
            SchematicPage(id:"P1",pageNumber:1,sheetCode:"E-101",title:"Control power and starter",document:control),
            SchematicPage(id:"P2",pageNumber:2,sheetCode:"E-201",title:"PLC I/O wiring",document:ioDoc),
            SchematicPage(id:"P3",pageNumber:3,sheetCode:"E-301",title:"Motor status",document:statusDoc)
        ]
        let relay=RelayDeviceRelationship(id:"REL-M1",deviceTag:"M1",coilPageID:"P1",coilSymbolID:"M1",contacts:[.init(id:"M1-13-14",pageID:"P3",symbolID:"M1AUX",form:.normallyOpen,contactNumber:"13-14")])
        let modules=SpatialElectricalLabCatalog.ioModules
        let rails=[DINRail(id:"DR1",tag:"DIN-1",y:120,xStart:40,xEnd:760),DINRail(id:"DR2",tag:"DIN-2",y:290,xStart:40,xEnd:760)]
        let placements=[
            PanelPlacement(id:"PP-PS1",part:.init(id:"PS1",kind:.powerSupply,tag:"PS1",x:0,y:0,width:3,height:2,heatWatts:25),position:.init(x:130,y:120),railID:"DR1"),
            PanelPlacement(id:"PP-PLC1",part:.init(id:"PLC1",kind:.plcRack,tag:"PLC1",x:0,y:0,width:5,height:2,heatWatts:20),position:.init(x:340,y:120),railID:"DR1"),
            PanelPlacement(id:"PP-VFD1",part:.init(id:"VFD1",kind:.vfd,tag:"VFD1",x:0,y:0,width:3,height:4,heatWatts:90),position:.init(x:610,y:290),railID:"DR2")
        ]
        let cable=CableDefinition(id:"C1",tag:"CBL-PE203",description:"3-core sensor cable",sourcePageID:"P2",destinationPageID:"P2",cores:[
            .init(id:"C1-1",coreNumber:"1",color:.brown,gauge:.awg18,function:.dcControl),
            .init(id:"C1-2",coreNumber:"2",color:.blue,gauge:.awg18,function:.dcControl),
            .init(id:"C1-3",coreNumber:"3",color:.black,gauge:.awg18,function:.dcControl)
        ])
        var project=ElectricalCADProject(projectNumber:"CTT-1001",title:"Packaging Cell Training Panel",revision:"A",pages:pages,relays:[relay],cables:[cable],ioModules:modules,dinRails:rails,panelPlacements:placements,wireDucts:[.init(id:"WD1",tag:"WD-1",internalWidthMM:40,internalHeightMM:60,conductorIDs:["W101","W102","W103","W104"])])
        project.autoNumberWires()
        project.assignPLCAddressesFromDrawing()
        project.revisionClouds=[.init(id:"RC-A1",pageID:"P2",revision:"A",description:"Added PE203 field input and PLC channel assignment",points:[.init(x:40,y:70),.init(x:720,y:70),.init(x:720,y:250),.init(x:40,y:250)],createdBy:"Training Engineering")]
        return project
    }()

    public static let instructorFaultBank:[InstructorMiswire] = [
        .init(id:"F-OPEN-PE",kind:.openConductor,title:"Open PE203 signal conductor",symptom:"Photoeye LED changes but PLC input never changes.",pageID:"P2",targetIDs:["WDI0"],points:15),
        .init(id:"F-WRONG-ADDR",kind:.wrongPLCAddress,title:"Wrong PLC channel assignment",symptom:"Field voltage is correct at the module but the expected tag remains false.",targetIDs:["P2-DI0"],points:18),
        .init(id:"F-CABLE-SWAP",kind:.wrongCableCore,title:"Sensor cable cores transposed",symptom:"Sensor power and output behavior disagree with the cable schedule.",targetIDs:["C1"],points:18),
        .init(id:"F-OFF-RAIL",kind:.deviceOffRail,title:"Device improperly mounted",symptom:"Panel inspection reveals a component that violates the drawing and DIN-rail mounting intent.",targetIDs:["PP-PS1"],points:10),
        .init(id:"F-WIRE-COLOR",kind:.wrongWireColor,title:"Incorrect conductor identification",symptom:"Point-to-point continuity works, but construction does not match the approved conductor standard.",pageID:"P1",targetIDs:["W101"],points:8)
    ]
}
