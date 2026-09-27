import Foundation

// MARK: - Drawing issue / approval lifecycle

public enum DrawingIssueState: String, Codable, CaseIterable, Sendable, Identifiable {
    case preliminary = "Preliminary"
    case ifr = "IFR"
    case ifc = "IFC"
    case asBuilt = "As-Built"
    case superseded = "Superseded"
    public var id: String { rawValue }
}

public enum EngineeringApprovalRole: String, Codable, CaseIterable, Sendable {
    case designer = "Designer"
    case checker = "Checker"
    case controlsEngineer = "Controls Engineer"
    case electricalEngineer = "Electrical Engineer"
    case projectEngineer = "Project Engineer"
    case client = "Client / Owner"
}

public enum ApprovalDecision: String, Codable, CaseIterable, Sendable {
    case pending = "Pending"
    case approved = "Approved"
    case approvedWithComments = "Approved with comments"
    case rejected = "Rejected"
}

public struct EngineeringApproval: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var revision: String
    public var issueState: DrawingIssueState
    public var role: EngineeringApprovalRole
    public var reviewer: String
    public var decision: ApprovalDecision
    public var comments: String
    public var timestamp: Date?
    public init(id: String, revision: String, issueState: DrawingIssueState, role: EngineeringApprovalRole, reviewer: String = "", decision: ApprovalDecision = .pending, comments: String = "", timestamp: Date? = nil) {
        self.id=id; self.revision=revision; self.issueState=issueState; self.role=role; self.reviewer=reviewer; self.decision=decision; self.comments=comments; self.timestamp=timestamp
    }
}

public struct DrawingIssueRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var revision: String
    public var state: DrawingIssueState
    public var issuedBy: String
    public var issuedAt: Date
    public var purpose: String
    public var approvalIDs: [String]
    public init(id: String, revision: String, state: DrawingIssueState, issuedBy: String, issuedAt: Date = Date(), purpose: String, approvalIDs: [String] = []) {
        self.id=id; self.revision=revision; self.state=state; self.issuedBy=issuedBy; self.issuedAt=issuedAt; self.purpose=purpose; self.approvalIDs=approvalIDs
    }
}

public enum EngineeringApprovalEngine {
    public static func requiredRoles(for state: DrawingIssueState) -> Set<EngineeringApprovalRole> {
        switch state {
        case .preliminary: return [.designer]
        case .ifr: return [.designer, .checker, .controlsEngineer]
        case .ifc: return [.designer, .checker, .controlsEngineer, .electricalEngineer, .projectEngineer]
        case .asBuilt: return [.designer, .checker, .projectEngineer]
        case .superseded: return []
        }
    }
    public static func canIssue(state: DrawingIssueState, revision: String, approvals: [EngineeringApproval]) -> Bool {
        let relevant = approvals.filter { $0.revision == revision && $0.issueState == state }
        let accepted = Set(relevant.filter { $0.decision == .approved || $0.decision == .approvedWithComments }.map(\.role))
        let rejected = relevant.contains { $0.decision == .rejected }
        return !rejected && requiredRoles(for: state).isSubset(of: accepted)
    }
    public static func missingRoles(state: DrawingIssueState, revision: String, approvals: [EngineeringApproval]) -> [EngineeringApprovalRole] {
        let accepted = Set(approvals.filter { $0.revision == revision && $0.issueState == state && ($0.decision == .approved || $0.decision == .approvedWithComments) }.map(\.role))
        return requiredRoles(for: state).subtracting(accepted).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Field redlines and as-built generation

public enum RedlineMarkupKind: String, Codable, CaseIterable, Sendable {
    case cloud = "Revision cloud"
    case strikeout = "Strikeout"
    case addWire = "Add wire"
    case moveDevice = "Move device"
    case note = "Field note"
    case terminalChange = "Terminal change"
    case addressChange = "PLC address change"
}

public struct FieldRedlineMarkup: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var pageID: String
    public var revision: String
    public var kind: RedlineMarkupKind
    public var points: [ShopPoint]
    public var text: String
    public var author: String
    public var createdAt: Date
    public var resolvedByChangeID: String?
    public init(id: String, pageID: String, revision: String, kind: RedlineMarkupKind, points: [ShopPoint], text: String, author: String, createdAt: Date = Date(), resolvedByChangeID: String? = nil) {
        self.id=id; self.pageID=pageID; self.revision=revision; self.kind=kind; self.points=points; self.text=text; self.author=author; self.createdAt=createdAt; self.resolvedByChangeID=resolvedByChangeID
    }
}

public enum FieldChangeKind: String, Codable, CaseIterable, Sendable {
    case wireNumber, terminalNumber, devicePosition, plcAddress, wireEndpoint, noteOnly
}

public struct FieldChange: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: FieldChangeKind
    public var pageID: String?
    public var targetID: String
    public var secondaryID: String?
    public var oldValue: String
    public var newValue: String
    public var reason: String
    public var sourceRedlineID: String?
    public var approved: Bool
    public init(id: String, kind: FieldChangeKind, pageID: String? = nil, targetID: String, secondaryID: String? = nil, oldValue: String, newValue: String, reason: String, sourceRedlineID: String? = nil, approved: Bool = false) {
        self.id=id; self.kind=kind; self.pageID=pageID; self.targetID=targetID; self.secondaryID=secondaryID; self.oldValue=oldValue; self.newValue=newValue; self.reason=reason; self.sourceRedlineID=sourceRedlineID; self.approved=approved
    }
}

public struct AsBuiltGenerationResult: Codable, Equatable, Sendable {
    public var project: ElectricalCADProject
    public var appliedChangeIDs: [String]
    public var rejectedChangeIDs: [String]
    public var warnings: [String]
}

public enum AsBuiltGenerator {
    public static func generate(from project: ElectricalCADProject, fieldChanges: [FieldChange], revision: String) -> AsBuiltGenerationResult {
        var output = project
        var applied:[String]=[], rejected:[String]=[], warnings:[String]=[]
        for change in fieldChanges where change.approved {
            guard apply(change, to: &output) else { rejected.append(change.id); warnings.append("Could not apply field change \(change.id): \(change.reason)"); continue }
            applied.append(change.id)
        }
        output.revision = revision
        return .init(project: output, appliedChangeIDs: applied, rejectedChangeIDs: rejected, warnings: warnings)
    }

    @discardableResult private static func apply(_ change: FieldChange, to project: inout ElectricalCADProject) -> Bool {
        switch change.kind {
        case .wireNumber:
            guard let pageID=change.pageID, let pi=project.pages.firstIndex(where:{$0.id==pageID}), let wi=project.pages[pi].document.conductors.firstIndex(where:{$0.id==change.targetID}) else { return false }
            project.pages[pi].document.conductors[wi].wireNumber=change.newValue; return true
        case .terminalNumber:
            guard let pageID=change.pageID, let pi=project.pages.firstIndex(where:{$0.id==pageID}), let symbolID=change.secondaryID,
                  let si=project.pages[pi].document.symbols.firstIndex(where:{$0.id==symbolID}),
                  let ti=project.pages[pi].document.symbols[si].terminals.firstIndex(where:{$0.id==change.targetID}) else { return false }
            project.pages[pi].document.symbols[si].terminals[ti].terminalNumber=change.newValue; return true
        case .devicePosition:
            guard let pageID=change.pageID, let pi=project.pages.firstIndex(where:{$0.id==pageID}), let si=project.pages[pi].document.symbols.firstIndex(where:{$0.id==change.targetID}) else { return false }
            let parts=change.newValue.split(separator:",").compactMap{Double($0.trimmingCharacters(in:.whitespaces))}
            guard parts.count==2 else{return false}; project.pages[pi].document.symbols[si].position = .init(x:parts[0],y:parts[1]); return true
        case .plcAddress:
            guard let ai=project.plcAssignments.firstIndex(where:{$0.id==change.targetID}) else{return false}; project.plcAssignments[ai].address=change.newValue; return true
        case .wireEndpoint:
            guard let pageID=change.pageID, let pi=project.pages.firstIndex(where:{$0.id==pageID}), let wi=project.pages[pi].document.conductors.firstIndex(where:{$0.id==change.targetID}) else{return false}
            let parts=change.newValue.split(separator:":",maxSplits:1).map(String.init); guard parts.count==2 else{return false}
            project.pages[pi].document.conductors[wi].to = .init(symbolID:parts[0],terminalID:parts[1]); return true
        case .noteOnly: return true
        }
    }
}

// MARK: - Wire / terminal renumbering conflict resolution

public enum NumberingConflictKind: String, Codable, Sendable { case wireNumber, terminalNumber }
public struct NumberingConflict: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: NumberingConflictKind
    public var value: String
    public var references: [String]
    public var recommendedNextValue: String
}

public enum NumberingConflictResolver {
    public static func conflicts(in project: ElectricalCADProject) -> [NumberingConflict] {
        var output:[NumberingConflict]=[]
        var wires:[String:[String]] = [:]
        for page in project.pages { for wire in page.document.conductors where !wire.wireNumber.isEmpty { wires[wire.wireNumber,default:[]].append("\(page.sheetCode):\(wire.id)") } }
        let numericWireNumbers = wires.keys.compactMap(Int.init)
        var nextWire=(numericWireNumbers.max() ?? 1000)+1
        for (number, refs) in wires.filter({$0.value.count>1}).sorted(by:{$0.key<$1.key}) {
            output.append(.init(id:"WIRE-\(number)",kind:.wireNumber,value:number,references:refs,recommendedNextValue:String(nextWire))); nextWire += 1
        }
        for page in project.pages {
            for symbol in page.document.symbols {
                let grouped=Dictionary(grouping:symbol.terminals.filter{!$0.terminalNumber.isEmpty},by:{$0.terminalNumber})
                for (number, terminals) in grouped where terminals.count>1 {
                    let refs=terminals.map{"\(page.sheetCode):\(symbol.tag):\($0.id)"}
                    let numbers=symbol.terminals.compactMap{Int($0.terminalNumber)}
                    output.append(.init(id:"TERM-\(page.id)-\(symbol.id)-\(number)",kind:.terminalNumber,value:number,references:refs,recommendedNextValue:String((numbers.max() ?? 0)+1)))
                }
            }
        }
        return output.sorted{$0.id<$1.id}
    }

    public static func autoResolve(project: inout ElectricalCADProject) -> [String] {
        var log:[String]=[]
        var used=Set<String>()
        var next=(project.pages.flatMap{$0.document.conductors}.compactMap{Int($0.wireNumber)}.max() ?? 1000)+1
        for pi in project.pages.indices.sorted(by:{project.pages[$0].pageNumber < project.pages[$1].pageNumber}) {
            for wi in project.pages[pi].document.conductors.indices {
                let value=project.pages[pi].document.conductors[wi].wireNumber
                if value.isEmpty || used.contains(value) {
                    let replacement=String(next); next += 1
                    log.append("\(project.pages[pi].sheetCode): \(value.isEmpty ? "blank" : value) → \(replacement)")
                    project.pages[pi].document.conductors[wi].wireNumber=replacement; used.insert(replacement)
                } else { used.insert(value) }
            }
            for si in project.pages[pi].document.symbols.indices {
                var terminalUsed=Set<String>(); var terminalNext=(project.pages[pi].document.symbols[si].terminals.compactMap{Int($0.terminalNumber)}.max() ?? 0)+1
                for ti in project.pages[pi].document.symbols[si].terminals.indices {
                    let value=project.pages[pi].document.symbols[si].terminals[ti].terminalNumber
                    if !value.isEmpty && terminalUsed.contains(value) {
                        let replacement=String(terminalNext); terminalNext += 1
                        log.append("\(project.pages[pi].sheetCode):\(project.pages[pi].document.symbols[si].tag) terminal \(value) → \(replacement)")
                        project.pages[pi].document.symbols[si].terminals[ti].terminalNumber=replacement; terminalUsed.insert(replacement)
                    } else if !value.isEmpty { terminalUsed.insert(value) }
                }
            }
        }
        return log
    }
}

// MARK: - Cable tray routing and device-location drawings

public struct CableTraySegment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var fromNode: String
    public var toNode: String
    public var from: ShopPoint
    public var to: ShopPoint
    public var widthMM: Double
    public var depthMM: Double
    public var fillLimitPercent: Double
    public var existingFillPercent: Double
    public init(id:String,tag:String,fromNode:String,toNode:String,from:ShopPoint,to:ShopPoint,widthMM:Double,depthMM:Double,fillLimitPercent:Double=40,existingFillPercent:Double=0) {
        self.id=id; self.tag=tag; self.fromNode=fromNode; self.toNode=toNode; self.from=from; self.to=to; self.widthMM=widthMM; self.depthMM=depthMM; self.fillLimitPercent=fillLimitPercent; self.existingFillPercent=existingFillPercent
    }
    public var length: Double { from.distance(to: to) }
}

public struct CableTrayRoute: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var cableID: String
    public var segmentIDs: [String]
    public var points: [ShopPoint]
    public var length: Double
    public var predictedMaxFillPercent: Double
    public var passesFillLimit: Bool
}

public enum CableTrayRoutingEngine {
    public static func route(cable: CableDefinition, fromNode: String, toNode: String, segments:[CableTraySegment]) -> CableTrayRoute? {
        guard fromNode != toNode else{return .init(id:"TR-\(cable.id)",cableID:cable.id,segmentIDs:[],points:[],length:0,predictedMaxFillPercent:0,passesFillLimit:true)}
        var dist:[String:Double]=[fromNode:0], previous:[String:(String,String)]=[:], unvisited=Set(segments.flatMap{[$0.fromNode,$0.toNode]})
        while !unvisited.isEmpty {
            guard let node=unvisited.min(by:{(dist[$0] ?? .infinity) < (dist[$1] ?? .infinity)}), let base=dist[node], base.isFinite else{break}
            unvisited.remove(node); if node==toNode{break}
            for seg in segments where seg.fromNode==node || seg.toNode==node {
                let neighbor=seg.fromNode==node ? seg.toNode : seg.fromNode
                guard unvisited.contains(neighbor) else{continue}
                let fillPenalty = seg.existingFillPercent >= seg.fillLimitPercent ? 10.0 : 1.0 + max(0,seg.existingFillPercent/100)
                let candidate=base+seg.length*fillPenalty
                if candidate < (dist[neighbor] ?? .infinity) { dist[neighbor]=candidate; previous[neighbor]=(node,seg.id) }
            }
        }
        guard dist[toNode] != nil else{return nil}
        var node=toNode, ids:[String]=[]
        while node != fromNode { guard let p=previous[node] else{return nil}; ids.append(p.1); node=p.0 }
        ids.reverse()
        var pts:[ShopPoint]=[]; var cursor=fromNode; var length=0.0; var maxFill=0.0; var passes=true
        let addedFill = min(15.0, Double(max(1,cable.cores.count))*1.8)
        for id in ids { guard let s=segments.first(where:{$0.id==id}) else{continue}; let forward=s.fromNode==cursor; let a=forward ? s.from:s.to, b=forward ? s.to:s.from; if pts.isEmpty{pts.append(a)}; pts.append(b); cursor=forward ? s.toNode:s.fromNode; length += s.length; let fill=s.existingFillPercent+addedFill; maxFill=max(maxFill,fill); passes = passes && fill <= s.fillLimitPercent }
        return .init(id:"TR-\(cable.id)",cableID:cable.id,segmentIDs:ids,points:pts,length:length,predictedMaxFillPercent:maxFill,passesFillLimit:passes)
    }
}

public enum DeviceLocationType: String, Codable, CaseIterable, Sendable { case panel, sensor, motor, valve, instrument, junctionBox, hmi, drive }
public struct DeviceLocation: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var type: DeviceLocationType
    public var area: String
    public var x: Double
    public var y: Double
    public var elevationMM: Double
    public var mounting: String
    public var drawingReference: String
}
public struct DeviceLocationDrawing: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var drawingNumber: String
    public var title: String
    public var scaleDescription: String
    public var width: Double
    public var height: Double
    public var devices: [DeviceLocation]
}

// MARK: - Enclosure cutout / drilling layouts

public enum EnclosureOpeningShape: String, Codable, Sendable { case round, rectangle, slot }
public struct EnclosureOpening: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var deviceTag:String
    public var shape:EnclosureOpeningShape
    public var center:ShopPoint
    public var widthMM:Double
    public var heightMM:Double
    public var diameterMM:Double?
    public var note:String
}
public struct EnclosureDrillLayout: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var drawingNumber:String
    public var enclosureWidthMM:Double
    public var enclosureHeightMM:Double
    public var openings:[EnclosureOpening]
    public var warnings:[String]
}

public enum EnclosureLayoutEngine {
    public static func makeLayout(drawingNumber:String, enclosureWidthMM:Double, enclosureHeightMM:Double, placements:[PanelPlacement]) -> EnclosureDrillLayout {
        var openings:[EnclosureOpening]=[], warnings:[String]=[]
        for p in placements {
            let shape:EnclosureOpeningShape = [.vfd, .plcRack, .powerSupply].contains(p.part.kind) ? .rectangle : .round
            let w=max(6,Double(p.part.width)*12), h=max(6,Double(p.part.height)*12)
            let center=p.position
            openings.append(.init(id:"CUT-\(p.id)",deviceTag:p.part.tag,shape:shape,center:center,widthMM:w,heightMM:h,diameterMM:shape == .round ? max(w,h) : nil,note:shape == .rectangle ? "Panel cutout" : "Mounting/drill pattern"))
            if center.x-w/2 < 10 || center.y-h/2 < 10 || center.x+w/2 > enclosureWidthMM-10 || center.y+h/2 > enclosureHeightMM-10 { warnings.append("\(p.part.tag) cutout violates 10 mm edge margin") }
        }
        for i in openings.indices { for j in openings.indices where j>i { if abs(openings[i].center.x-openings[j].center.x) < (openings[i].widthMM+openings[j].widthMM)/2 && abs(openings[i].center.y-openings[j].center.y) < (openings[i].heightMM+openings[j].heightMM)/2 { warnings.append("Cutouts \(openings[i].deviceTag) and \(openings[j].deviceTag) overlap") } } }
        return .init(id:"DRILL-\(drawingNumber)",drawingNumber:drawingNumber,enclosureWidthMM:enclosureWidthMM,enclosureHeightMM:enclosureHeightMM,openings:openings,warnings:Array(Set(warnings)).sorted())
    }
}

// MARK: - Fabrication work orders, FAT / SAT, punch and NCR

public enum WorkItemStatus: String, Codable, CaseIterable, Sendable { case notStarted="Not started", inProgress="In progress", passed="Passed", failed="Failed", blocked="Blocked", waived="Waived" }
public struct FabricationTask: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var sequence:Int; public var title:String; public var drawingReference:String; public var estimatedMinutes:Int; public var status:WorkItemStatus; public var evidence:String; public var critical:Bool
}
public struct PanelFabricationWorkOrder: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var workOrderNumber:String; public var projectNumber:String; public var panelTag:String; public var releasedRevision:String; public var tasks:[FabricationTask]; public var startedAt:Date?; public var completedAt:Date?
    public var percentComplete:Double { guard !tasks.isEmpty else{return 100}; return Double(tasks.filter{$0.status == .passed || $0.status == .waived}.count)/Double(tasks.count)*100 }
    public var canReleaseToFAT:Bool { !tasks.isEmpty && tasks.allSatisfy{($0.status == .passed || $0.status == .waived) && (!$0.critical || $0.status == .passed)} }
}

public enum AcceptanceTestType: String, Codable, Sendable { case fat="FAT", sat="SAT" }
public struct AcceptanceTestItem: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var section:String; public var sequence:Int; public var requirement:String; public var expected:String; public var status:WorkItemStatus; public var evidence:String; public var critical:Bool; public var createsPunchOnFailure:Bool
}
public struct AcceptanceTestChecklist: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var type:AcceptanceTestType; public var projectNumber:String; public var revision:String; public var items:[AcceptanceTestItem]; public var witness:String; public var executedBy:String; public var executedAt:Date?
    public var scorePercent:Double { guard !items.isEmpty else{return 100}; return Double(items.filter{$0.status == .passed || $0.status == .waived}.count)/Double(items.count)*100 }
    public var passes:Bool { !items.isEmpty && items.allSatisfy{!$0.critical || $0.status == .passed} && items.allSatisfy{$0.status != .failed && $0.status != .blocked} }
}

public enum PunchSeverity: String, Codable, CaseIterable, Sendable { case a="A - blocks startup", b="B - blocks turnover", c="C - documentation/cosmetic" }
public enum PunchStatus: String, Codable, CaseIterable, Sendable { case open="Open", inProgress="In progress", readyForVerification="Ready for verification", closed="Closed" }
public struct CommissioningPunchItem: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var number:String; public var severity:PunchSeverity; public var source:String; public var description:String; public var owner:String; public var status:PunchStatus; public var correctiveAction:String; public var verification:String
}

public enum NCRSeverity: String, Codable, CaseIterable, Sendable { case minor, major, critical }
public enum NCRStatus: String, Codable, CaseIterable, Sendable { case open, dispositionPending, rework, useAsIs, rejected, closed }
public struct NonconformanceRecord: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var number:String; public var severity:NCRSeverity; public var requirementReference:String; public var description:String; public var detectedAtStage:String; public var status:NCRStatus; public var disposition:String; public var rootCause:String; public var correctiveAction:String; public var verification:String
}

public enum LifecycleQualityEngine {
    public static func punchItems(from checklist: AcceptanceTestChecklist, existingCount:Int=0) -> [CommissioningPunchItem] {
        checklist.items.filter{$0.status == .failed && $0.createsPunchOnFailure}.enumerated().map { offset,item in
            let severity:PunchSeverity=item.critical ? .a:.b
            return .init(id:"P-\(checklist.type.rawValue)-\(item.id)",number:String(format:"P-%03d",existingCount+offset+1),severity:severity,source:"\(checklist.type.rawValue) \(item.section)",description:item.requirement,owner:"Controls",status:.open,correctiveAction:"",verification:"")
        }
    }
    public static func ncr(number:String, from item:AcceptanceTestItem, stage:String) -> NonconformanceRecord {
        .init(id:"NCR-\(item.id)",number:number,severity:item.critical ? .major:.minor,requirementReference:item.requirement,description:"Acceptance criterion not met: \(item.expected)",detectedAtStage:stage,status:.open,disposition:"",rootCause:"",correctiveAction:"",verification:"")
    }
}

// MARK: - Instructor-controlled plant startup

public enum PlantStartupStage: Int, Codable, CaseIterable, Sendable, Identifiable {
    case engineering = 0, fabrication, fat, installation, sat, coldCommissioning, readyToEnergize, energized, hotCommissioning, production
    public var id: String { String(rawValue) }
    public var title:String {
        switch self { case .engineering:return "Engineering"; case .fabrication:return "Panel fabrication"; case .fat:return "FAT"; case .installation:return "Field installation"; case .sat:return "SAT"; case .coldCommissioning:return "Cold commissioning"; case .readyToEnergize:return "Ready to energize"; case .energized:return "Energized"; case .hotCommissioning:return "Hot commissioning"; case .production:return "Production" }
    }
}

public struct StartupGateResult: Codable, Equatable, Sendable { public var allowed:Bool; public var blockers:[String]; public var warnings:[String] }
public struct StartupEvent: Identifiable, Codable, Equatable, Sendable { public let id:String; public var stage:PlantStartupStage; public var timestamp:Date; public var actor:String; public var description:String; public var evidence:String }
public struct InstructorStartupScenario: Identifiable, Codable, Equatable, Sendable {
    public let id:String; public var title:String; public var description:String; public var hiddenFaults:[InstructorMiswire]; public var requiredProductionCycles:Int; public var targetPassingPercent:Double
}
public struct PlantStartupSession: Codable, Equatable, Sendable {
    public var stage:PlantStartupStage; public var scenario:InstructorStartupScenario; public var events:[StartupEvent]; public var productionCycles:Int; public var stableProductionCycles:Int; public var emergencyStopTestPassed:Bool; public var interlockProofPassed:Bool; public var baselineCaptured:Bool
    public init(stage: PlantStartupStage = .engineering,scenario:InstructorStartupScenario,events:[StartupEvent]=[],productionCycles:Int=0,stableProductionCycles:Int=0,emergencyStopTestPassed:Bool=false,interlockProofPassed:Bool=false,baselineCaptured:Bool=false) { self.stage=stage; self.scenario=scenario; self.events=events; self.productionCycles=productionCycles; self.stableProductionCycles=stableProductionCycles; self.emergencyStopTestPassed=emergencyStopTestPassed; self.interlockProofPassed=interlockProofPassed; self.baselineCaptured=baselineCaptured }
}

// MARK: - Complete lifecycle document

public struct ElectricalProjectLifecycle: Codable, Equatable, Sendable {
    public var designProject:ElectricalCADProject
    public var currentIssueState:DrawingIssueState
    public var issueHistory:[DrawingIssueRecord]
    public var approvals:[EngineeringApproval]
    public var redlines:[FieldRedlineMarkup]
    public var fieldChanges:[FieldChange]
    public var asBuiltProject:ElectricalCADProject?
    public var cableTraySegments:[CableTraySegment]
    public var cableTrayRoutes:[CableTrayRoute]
    public var deviceLocationDrawings:[DeviceLocationDrawing]
    public var drillLayouts:[EnclosureDrillLayout]
    public var fabricationOrders:[PanelFabricationWorkOrder]
    public var fat:AcceptanceTestChecklist
    public var sat:AcceptanceTestChecklist
    public var punchItems:[CommissioningPunchItem]
    public var ncrs:[NonconformanceRecord]
    public var startup:PlantStartupSession

    public init(designProject:ElectricalCADProject,currentIssueState: DrawingIssueState = .preliminary,issueHistory:[DrawingIssueRecord]=[],approvals:[EngineeringApproval]=[],redlines:[FieldRedlineMarkup]=[],fieldChanges:[FieldChange]=[],asBuiltProject:ElectricalCADProject?=nil,cableTraySegments:[CableTraySegment]=[],cableTrayRoutes:[CableTrayRoute]=[],deviceLocationDrawings:[DeviceLocationDrawing]=[],drillLayouts:[EnclosureDrillLayout]=[],fabricationOrders:[PanelFabricationWorkOrder]=[],fat:AcceptanceTestChecklist,sat:AcceptanceTestChecklist,punchItems:[CommissioningPunchItem]=[],ncrs:[NonconformanceRecord]=[],startup:PlantStartupSession) {
        self.designProject=designProject;self.currentIssueState=currentIssueState;self.issueHistory=issueHistory;self.approvals=approvals;self.redlines=redlines;self.fieldChanges=fieldChanges;self.asBuiltProject=asBuiltProject;self.cableTraySegments=cableTraySegments;self.cableTrayRoutes=cableTrayRoutes;self.deviceLocationDrawings=deviceLocationDrawings;self.drillLayouts=drillLayouts;self.fabricationOrders=fabricationOrders;self.fat=fat;self.sat=sat;self.punchItems=punchItems;self.ncrs=ncrs;self.startup=startup
    }

    public mutating func issue(_ state:DrawingIssueState, by actor:String, purpose:String) -> Bool {
        let transitionAllowed: Bool
        switch (currentIssueState, state) {
        case (.preliminary, .preliminary), (.preliminary, .ifr), (.ifr, .ifc), (.ifc, .asBuilt), (.asBuilt, .superseded): transitionAllowed = true
        default: transitionAllowed = false
        }
        guard transitionAllowed, EngineeringApprovalEngine.canIssue(state:state,revision:designProject.revision,approvals:approvals) else{return false}
        currentIssueState=state; issueHistory.append(.init(id:"ISSUE-\(designProject.revision)-\(state.rawValue)-\(issueHistory.count+1)",revision:designProject.revision,state:state,issuedBy:actor,purpose:purpose,approvalIDs:approvals.filter{$0.revision==designProject.revision && $0.issueState==state}.map(\.id))); return true
    }
    public mutating func generateAsBuilt(revision:String) -> AsBuiltGenerationResult {
        let result=AsBuiltGenerator.generate(from:designProject,fieldChanges:fieldChanges,revision:revision); asBuiltProject=result.project; return result
    }
    public func startupGate(to target:PlantStartupStage) -> StartupGateResult {
        var blockers:[String]=[], warnings:[String]=[]
        if target.rawValue >= PlantStartupStage.fabrication.rawValue && !issueHistory.contains(where:{$0.state == .ifc && $0.revision == designProject.revision}) { blockers.append("Current revision has not been issued IFC") }
        if target.rawValue >= PlantStartupStage.fat.rawValue && !fabricationOrders.contains(where:{$0.canReleaseToFAT}) { blockers.append("Panel fabrication work order is not complete") }
        if target.rawValue >= PlantStartupStage.installation.rawValue && !fat.passes { blockers.append("FAT has not passed") }
        if target.rawValue >= PlantStartupStage.coldCommissioning.rawValue && !sat.passes { blockers.append("SAT has not passed") }
        if target.rawValue >= PlantStartupStage.readyToEnergize.rawValue {
            if punchItems.contains(where:{$0.severity == .a && $0.status != .closed}) { blockers.append("Open A-severity punch items block energization") }
            if ncrs.contains(where:{$0.severity == .critical && $0.status != .closed}) { blockers.append("Open critical NCR blocks energization") }
            if !startup.emergencyStopTestPassed { blockers.append("Emergency-stop proof is incomplete") }
            if !startup.interlockProofPassed { blockers.append("Interlock proof is incomplete") }
        }
        if target.rawValue >= PlantStartupStage.production.rawValue {
            if startup.stableProductionCycles < startup.scenario.requiredProductionCycles { blockers.append("Required stable production cycles have not been completed") }
            if !startup.baselineCaptured { blockers.append("Healthy production baseline has not been captured") }
            if punchItems.contains(where:{$0.severity != .c && $0.status != .closed}) { blockers.append("Open A/B punch items block production turnover") }
            if ncrs.contains(where:{$0.status != .closed}) { warnings.append("Open non-critical NCRs remain for turnover") }
        }
        if target.rawValue > startup.stage.rawValue + 1 { blockers.append("Startup stages must be advanced in sequence") }
        return .init(allowed:blockers.isEmpty,blockers:blockers,warnings:warnings)
    }
    @discardableResult public mutating func advanceStartup(to target:PlantStartupStage, actor:String, evidence:String="") -> StartupGateResult {
        let gate=startupGate(to:target); guard gate.allowed else{return gate}; startup.stage=target; startup.events.append(.init(id:"EVT-\(startup.events.count+1)",stage:target,timestamp:Date(),actor:actor,description:"Advanced project to \(target.title)",evidence:evidence)); return gate
    }
}

// MARK: - Authored lifecycle training project

public enum ElectricalProjectLifecycleCatalog {
    public static let startupScenario = InstructorStartupScenario(id:"START-PKG-01",title:"Packaging Cell Project Turnover",description:"Take the packaging-cell electrical project from engineering release through panel fabrication, FAT, installation, SAT, cold commissioning, energization, hot commissioning, and stable production.",hiddenFaults:[ElectricalCADProjectCatalog.instructorFaultBank[0],ElectricalCADProjectCatalog.instructorFaultBank[1]],requiredProductionCycles:5,targetPassingPercent:85)

    public static var trainingLifecycle: ElectricalProjectLifecycle {
        let project=ElectricalCADProjectCatalog.trainingProject
        let approvalStates:[DrawingIssueState] = [.preliminary, .ifr, .ifc, .asBuilt]
        let approvals = approvalStates.flatMap { state in
            EngineeringApprovalEngine.requiredRoles(for:state).sorted{$0.rawValue<$1.rawValue}.enumerated().map { i,role in
                EngineeringApproval(id:"APP-\(state.rawValue)-\(i+1)",revision:project.revision,issueState:state,role:role,reviewer:"",decision:.pending)
            }
        }
        let fabTasks:[FabricationTask]=[
            .init(id:"FAB-1",sequence:1,title:"Verify released IFC drawing package",drawingReference:"E-101/E-201/E-301",estimatedMinutes:10,status:.notStarted,evidence:"",critical:true),
            .init(id:"FAB-2",sequence:2,title:"Machine enclosure and install DIN rail / wire duct",drawingReference:"Panel layout",estimatedMinutes:45,status:.notStarted,evidence:"",critical:true),
            .init(id:"FAB-3",sequence:3,title:"Install and label components",drawingReference:"BOM / panel layout",estimatedMinutes:60,status:.notStarted,evidence:"",critical:true),
            .init(id:"FAB-4",sequence:4,title:"Wire power and control circuits",drawingReference:"E-101",estimatedMinutes:90,status:.notStarted,evidence:"",critical:true),
            .init(id:"FAB-5",sequence:5,title:"Wire PLC I/O and field terminals",drawingReference:"E-201/E-301",estimatedMinutes:90,status:.notStarted,evidence:"",critical:true),
            .init(id:"FAB-6",sequence:6,title:"Point-to-point QA and torque verification",drawingReference:"Wire from/to report",estimatedMinutes:45,status:.notStarted,evidence:"",critical:true)
        ]
        let fab=PanelFabricationWorkOrder(id:"WO-PNL-001",workOrderNumber:"WO-PNL-001",projectNumber:project.projectNumber,panelTag:"CP-101",releasedRevision:project.revision,tasks:fabTasks)
        let fat=AcceptanceTestChecklist(id:"FAT-001",type:.fat,projectNumber:project.projectNumber,revision:project.revision,items:[
            .init(id:"FAT-1",section:"Documentation",sequence:1,requirement:"Approved IFC drawings match fabricated panel",expected:"No unexplained deviations",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"FAT-2",section:"Electrical",sequence:2,requirement:"Control power and protective devices verified",expected:"Correct voltage, polarity, fusing, grounding",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"FAT-3",section:"I/O",sequence:3,requirement:"100% I/O point checkout",expected:"Every field point maps to correct PLC tag/channel",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"FAT-4",section:"Functional",sequence:4,requirement:"Sequence and interlock simulation",expected:"Machine logic follows approved functional intent",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"FAT-5",section:"Documentation",sequence:5,requirement:"Backups and FAT evidence captured",expected:"PLC/HMI/VFD backups and signed results",status:.notStarted,evidence:"",critical:false,createsPunchOnFailure:true)
        ],witness:"",executedBy:"")
        let sat=AcceptanceTestChecklist(id:"SAT-001",type:.sat,projectNumber:project.projectNumber,revision:project.revision,items:[
            .init(id:"SAT-1",section:"Installation",sequence:1,requirement:"Field installation matches location and cable drawings",expected:"Tags, cable routes, terminations and grounding match",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"SAT-2",section:"Loop / I/O",sequence:2,requirement:"End-to-end field I/O checkout",expected:"Field stimulus reaches correct PLC/HMI indication",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"SAT-3",section:"Safety",sequence:3,requirement:"Safety devices and E-stop chain functionally proven",expected:"All protective actions and reset behavior pass",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"SAT-4",section:"Drives",sequence:4,requirement:"Motor rotation and VFD command/reference verified",expected:"Correct rotation, source, limits and feedback",status:.notStarted,evidence:"",critical:true,createsPunchOnFailure:true),
            .init(id:"SAT-5",section:"Network",sequence:5,requirement:"Industrial network diagnostics acceptable",expected:"Expected devices online with stable connections",status:.notStarted,evidence:"",critical:false,createsPunchOnFailure:true)
        ],witness:"",executedBy:"")
        let trays=[
            CableTraySegment(id:"TR1",tag:"CT-1A",fromNode:"PANEL",toNode:"JBOX",from:.init(x:80,y:100),to:.init(x:400,y:100),widthMM:150,depthMM:50,existingFillPercent:15),
            CableTraySegment(id:"TR2",tag:"CT-1B",fromNode:"JBOX",toNode:"FIELD",from:.init(x:400,y:100),to:.init(x:760,y:300),widthMM:150,depthMM:50,existingFillPercent:22),
            CableTraySegment(id:"TR3",tag:"CT-ALT",fromNode:"PANEL",toNode:"FIELD",from:.init(x:80,y:100),to:.init(x:760,y:300),widthMM:75,depthMM:40,existingFillPercent:38)
        ]
        let location=DeviceLocationDrawing(id:"DL-001",drawingNumber:"E-401",title:"Packaging Cell Device Locations",scaleDescription:"Training schematic / not to scale",width:900,height:560,devices:[
            .init(id:"DL-CP",tag:"CP-101",type:.panel,area:"Packaging Cell",x:100,y:120,elevationMM:1200,mounting:"Wall mounted",drawingReference:"E-401/A2"),
            .init(id:"DL-PE203",tag:"PE203",type:.sensor,area:"Infeed conveyor",x:650,y:260,elevationMM:850,mounting:"Conveyor bracket",drawingReference:"E-401/F4"),
            .init(id:"DL-M1",tag:"M1",type:.motor,area:"Main conveyor",x:740,y:400,elevationMM:250,mounting:"Machine frame",drawingReference:"E-401/G6")
        ])
        let drill=EnclosureLayoutEngine.makeLayout(drawingNumber:"E-501",enclosureWidthMM:800,enclosureHeightMM:600,placements:project.panelPlacements)
        return ElectricalProjectLifecycle(designProject:project,currentIssueState:.preliminary,approvals:approvals,cableTraySegments:trays,deviceLocationDrawings:[location],drillLayouts:[drill],fabricationOrders:[fab],fat:fat,sat:sat,startup:.init(scenario:startupScenario))
    }
}
