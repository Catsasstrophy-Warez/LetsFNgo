import Foundation

public enum PlantArea: String, Codable, CaseIterable, Sendable {
    case controlRoom, packaging, process, utilities, warehouse, maintenanceShop, electricalRoom, qualityLab
}

public enum CommunicationChannel: String, Codable, CaseIterable, Sendable { case radio, phone, faceToFace, digitalAndon, shiftLog }
public enum InformationConfidence: String, Codable, CaseIterable, Sendable { case rumor, low, medium, high, verified }
public enum DecisionIncidentDomain: String, Codable, CaseIterable, Sendable { case controls, electrical, mechanical, instrumentation, process, quality, utility, logistics, customer }
public enum IncidentSeverity: String, Codable, CaseIterable, Sendable { case advisory, degraded, lineStop, critical }
public enum RepairStrategy: String, Codable, CaseIterable, Sendable { case temporary, permanent }
public enum PermitKind: String, Codable, CaseIterable, Sendable { case none, loto, electricalSafeWork, lineBreak, confinedSpace, hotWork }
public enum VendorRequestStatus: String, Codable, CaseIterable, Sendable { case requested, queued, connected, complete, unavailable }
public enum DecisionActionKind: String, Codable, CaseIterable, Sendable {
    case acknowledgeCall, askOperatorToCheck, inspectHistorian, dispatchTechnician, reserveTool, requestPermit, startLOTO,
         requestVendor, temporaryRepair, permanentRepair, reprioritizeCustomer, curtailUtilityLoad, authorizeBypass,
         stopLine, continueRunning, escalateManagement, recordHandoff
}
public enum ConsequenceKind: String, Codable, CaseIterable, Sendable { case downtime, productionLoss, scrap, labor, freight, utility, customerPenalty, safetyExposure, recurrence, avoidedLoss }

public struct PlantAreaLocation: Codable, Equatable, Sendable {
    public var area: PlantArea
    public var x: Double
    public var y: Double
    public init(_ area: PlantArea, x: Double, y: Double) { self.area = area; self.x = x; self.y = y }
}

public struct TechnicianGameState: Identifiable, Codable, Equatable, Sendable {
    public var id: String { memberID }
    public var memberID: String
    public var name: String
    public var area: PlantArea
    public var destination: PlantArea?
    public var travelingUntil: Double?
    public var assignedIncidentID: String?
    public var carriedToolIDs: [String]
    public var pendingToolID: String?
    public init(memberID: String, name: String, area: PlantArea = .maintenanceShop, destination: PlantArea? = nil, travelingUntil: Double? = nil, assignedIncidentID: String? = nil, carriedToolIDs: [String] = [], pendingToolID: String? = nil) {
        self.memberID=memberID;self.name=name;self.area=area;self.destination=destination;self.travelingUntil=travelingUntil;self.assignedIncidentID=assignedIncidentID;self.carriedToolIDs=carriedToolIDs;self.pendingToolID=pendingToolID
    }
}

public struct PlantTool: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var area: PlantArea
    public var requiredSkill: PlantSkill?
    public var quantity: Int
    public var reservedByMemberID: String?
    public var calibrationDue: Bool
    public init(id:String,name:String,area:PlantArea,requiredSkill:PlantSkill?=nil,quantity:Int=1,reservedByMemberID:String?=nil,calibrationDue:Bool=false){self.id=id;self.name=name;self.area=area;self.requiredSkill=requiredSkill;self.quantity=max(0,quantity);self.reservedByMemberID=reservedByMemberID;self.calibrationDue=calibrationDue}
}

public struct PermitRequirement: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var incidentID:String
    public var kind:PermitKind
    public var preparationMinutes:Double
    public var issuedAt:Double?
    public var lotoAppliedAt:Double?
    public var verifiedZeroEnergyAt:Double?
    public var clearedAt:Double?
    public var bypassed:Bool
    public init(id:String=UUID().uuidString,incidentID:String,kind:PermitKind,preparationMinutes:Double,issuedAt:Double?=nil,lotoAppliedAt:Double?=nil,verifiedZeroEnergyAt:Double?=nil,clearedAt:Double?=nil,bypassed:Bool=false){self.id=id;self.incidentID=incidentID;self.kind=kind;self.preparationMinutes=max(0,preparationMinutes);self.issuedAt=issuedAt;self.lotoAppliedAt=lotoAppliedAt;self.verifiedZeroEnergyAt=verifiedZeroEnergyAt;self.clearedAt=clearedAt;self.bypassed=bypassed}
    public var readyForWork:Bool { kind == .none || (issuedAt != nil && (kind != .loto || verifiedZeroEnergyAt != nil)) }
}

public struct VendorSupportRequest: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var incidentID:String
    public var vendor:String
    public var requestedAt:Double
    public var eta:Double
    public var status:VendorRequestStatus
    public var hourlyCost:Double
    public var connectionFee:Double
    public var guidance:String?
}

public struct OperatorCommunication: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var incidentID:String
    public var timestamp:Double
    public var channel:CommunicationChannel
    public var from:String
    public var message:String
    public var confidence:InformationConfidence
    public var misleading:Bool
    public var acknowledged:Bool=false
}

public struct HiddenPlantTruth: Codable, Equatable, Sendable {
    public var rootCause:String
    public var actualMachine:PlayableMachineKind?
    public var actualArea:PlantArea
    public var requiredSkill:PlantSkill
    public var requiredToolIDs:[String]
    public var permitKind:PermitKind
    public var permanentRepairMinutes:Double
    public var temporaryRepairMinutes:Double
    public var temporaryRecurrenceAfterMinutes:Double?
    public var lossPerMinute:Double
    public var safetyCritical:Bool
    public init(rootCause:String,actualMachine:PlayableMachineKind?,actualArea:PlantArea,requiredSkill:PlantSkill,requiredToolIDs:[String]=[],permitKind:PermitKind = .none,permanentRepairMinutes:Double=45,temporaryRepairMinutes:Double=15,temporaryRecurrenceAfterMinutes:Double?=120,lossPerMinute:Double=250,safetyCritical:Bool=false){self.rootCause=rootCause;self.actualMachine=actualMachine;self.actualArea=actualArea;self.requiredSkill=requiredSkill;self.requiredToolIDs=requiredToolIDs;self.permitKind=permitKind;self.permanentRepairMinutes=max(1,permanentRepairMinutes);self.temporaryRepairMinutes=max(1,temporaryRepairMinutes);self.temporaryRecurrenceAfterMinutes=temporaryRecurrenceAfterMinutes;self.lossPerMinute=max(0,lossPerMinute);self.safetyCritical=safetyCritical}
}

public struct DecisionIncident: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var title:String
    public var domain:DecisionIncidentDomain
    public var severity:IncidentSeverity
    public var scheduledAt:Double
    public var revealedAt:Double?
    public var resolvedAt:Double?
    public var truth:HiddenPlantTruth
    public var knownFacts:[String]
    public var falseLeads:[String]
    public var communications:[OperatorCommunication]
    public var assignedMemberID:String?
    public var diagnosisConfidence:Double
    public var strategy:RepairStrategy?
    public var temporaryRepairExpiresAt:Double?
    public var recurrenceCount:Int
    public var managementEscalated:Bool
    public var stoppedLine:Bool
    public init(id:String=UUID().uuidString,title:String,domain:DecisionIncidentDomain,severity:IncidentSeverity,scheduledAt:Double,truth:HiddenPlantTruth,knownFacts:[String]=[],falseLeads:[String]=[],communications:[OperatorCommunication]=[],assignedMemberID:String?=nil,diagnosisConfidence:Double=0,strategy:RepairStrategy?=nil,temporaryRepairExpiresAt:Double?=nil,recurrenceCount:Int=0,managementEscalated:Bool=false,stoppedLine:Bool=false){self.id=id;self.title=title;self.domain=domain;self.severity=severity;self.scheduledAt=scheduledAt;self.truth=truth;self.knownFacts=knownFacts;self.falseLeads=falseLeads;self.communications=communications;self.assignedMemberID=assignedMemberID;self.diagnosisConfidence=diagnosisConfidence;self.strategy=strategy;self.temporaryRepairExpiresAt=temporaryRepairExpiresAt;self.recurrenceCount=recurrenceCount;self.managementEscalated=managementEscalated;self.stoppedLine=stoppedLine}
    public var active:Bool { revealedAt != nil && resolvedAt == nil }
}

public struct CustomerPriorityChange: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var triggerAt:Double
    public var orderID:String
    public var newPriority:Int
    public var newDueAt:Double?
    public var reason:String
    public var applied:Bool=false
}

public struct UtilityDisturbance: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var triggerAt:Double
    public var endAt:Double
    public var utility:UtilityKind
    public var capacityFraction:Double
    public var message:String
    public var affectedMachines:[PlayableMachineKind]
    public var applied:Bool=false
    public var cleared:Bool=false
}

public struct DecisionConsequence: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var incidentID:String?
    public var action:DecisionActionKind?
    public var kind:ConsequenceKind
    public var minutes:Double
    public var dollars:Double
    public var detail:String
    public var preventable:Bool
}

public struct ReplayMoment: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var category:String
    public var decision:String
    public var actualConsequence:String
    public var downtimeMinutes:Double
    public var dollarImpact:Double
    public var counterfactual:String
    public var preventableMinutes:Double
    public var preventableDollars:Double
}

public struct DecisionGameScore: Codable, Equatable, Sendable {
    public var basePlantScore:Double
    public var diagnosis:Double
    public var resourceManagement:Double
    public var safetyDiscipline:Double
    public var communication:Double
    public var economicJudgment:Double
    public var overall:Double { max(0,min(100,basePlantScore*0.35+diagnosis*0.20+resourceManagement*0.15+safetyDiscipline*0.10+communication*0.10+economicJudgment*0.10)) }
}

public struct DecisionGameSnapshot: Sendable {
    public var plant:PlantShiftManagementSnapshot
    public var visibleIncidents:[DecisionIncident]
    public var communications:[OperatorCommunication]
    public var technicians:[TechnicianGameState]
    public var tools:[PlantTool]
    public var vendors:[VendorSupportRequest]
    public var consequences:[DecisionConsequence]
    public var customerChanges:[CustomerPriorityChange]
    public var utilityDisturbances:[UtilityDisturbance]
    public var score:DecisionGameScore
}

public struct SupervisorTechnicianDecisionGameRuntime: Sendable {
    public var plant:PlantShiftManagementRuntime
    public var incidents:[DecisionIncident]=[]
    public var technicianStates:[String:TechnicianGameState]=[:]
    public var tools:[PlantTool]=[]
    public var permits:[String:PermitRequirement]=[:]
    public var vendorRequests:[VendorSupportRequest]=[]
    public var customerPriorityChanges:[CustomerPriorityChange]=[]
    public var utilityDisturbances:[UtilityDisturbance]=[]
    public var consequences:[DecisionConsequence]=[]
    public var replay:[ReplayMoment]=[]
    public var hiddenInformationEnabled:Bool=true
    public var managementEscalationMinutes:Double=35
    public var travelMinutesPerMapUnit:Double=2.5
    public var automaticPlantDispatchWasEnabled:Bool
    public var areaMap:[PlantArea:PlantAreaLocation]=[:]
    private var lastPlantEconomicImpact:Double=0
    private var lastPlantDowntimeMinutes:Double=0

    public init(plant:PlantShiftManagementRuntime) {
        self.plant=plant
        self.automaticPlantDispatchWasEnabled=plant.automaticDispatch
        self.plant.automaticDispatch=false
        seedAreaMap(); seedTechnicians(); seedTools()
    }

    public mutating func seedAreaMap(){
        areaMap = [
            .controlRoom:.init(.controlRoom,x:0,y:0), .packaging:.init(.packaging,x:3,y:1), .process:.init(.process,x:7,y:2),
            .utilities:.init(.utilities,x:10,y:4), .warehouse:.init(.warehouse,x:1,y:6), .maintenanceShop:.init(.maintenanceShop,x:5,y:6),
            .electricalRoom:.init(.electricalRoom,x:8,y:6), .qualityLab:.init(.qualityLab,x:4,y:3)
        ]
    }

    public mutating func seedTechnicians(){
        for c in plant.crews { for m in c.members where m.role != .operator { technicianStates[m.id] = TechnicianGameState(memberID:m.id,name:m.name,area:.maintenanceShop) } }
    }

    public mutating func seedTools(){
        if !tools.isEmpty{return}
        tools=[
            .init(id:"DMM-01",name:"CAT-rated digital multimeter",area:.maintenanceShop,requiredSkill:.electrical),
            .init(id:"LAPTOP-01",name:"Controls programming laptop",area:.controlRoom,requiredSkill:.controls),
            .init(id:"LOOP-01",name:"4–20 mA loop calibrator",area:.instrumentationAreaFallback,requiredSkill:.instrumentation),
            .init(id:"MEGGER-01",name:"Insulation resistance tester",area:.electricalRoom,requiredSkill:.electrical),
            .init(id:"VIB-01",name:"Vibration analyzer",area:.maintenanceShop,requiredSkill:.mechanical),
            .init(id:"IR-01",name:"Infrared camera",area:.electricalRoom),
            .init(id:"PRESS-01",name:"Pressure calibrator",area:.qualityLab,requiredSkill:.instrumentation)
        ]
    }

    public mutating func addIncident(_ incident:DecisionIncident){ incidents.append(incident);incidents.sort{$0.scheduledAt<$1.scheduledAt};if permits[incident.id] == nil { permits[incident.id]=PermitRequirement(incidentID:incident.id,kind:incident.truth.permitKind,preparationMinutes:permitPrepMinutes(incident.truth.permitKind)) } }
    public mutating func addCustomerPriorityChange(_ change:CustomerPriorityChange){customerPriorityChanges.append(change);customerPriorityChanges.sort{$0.triggerAt<$1.triggerAt}}
    public mutating func addUtilityDisturbance(_ disturbance:UtilityDisturbance){utilityDisturbances.append(disturbance);utilityDisturbances.sort{$0.triggerAt<$1.triggerAt}}

    @discardableResult public mutating func cycle(elapsedMilliseconds:Int32=1000)throws->DecisionGameSnapshot {
        revealDueIncidents(); applyPriorityChanges(); applyUtilityDisturbances(); updateTravel(); updateVendorRequests(); updateTemporaryRepairs(); updateEscalations()
        let plantSnap=try plant.cycle(elapsedMilliseconds:elapsedMilliseconds)
        revealDueIncidents(); applyPriorityChanges(); applyUtilityDisturbances(); updateTravel(); updateVendorRequests(); updateTemporaryRepairs(); updateEscalations(); captureEconomicDelta(plantSnap)
        return snapshot(plantSnap)
    }

    @discardableResult public mutating func run(seconds:Double,stepMilliseconds:Int32=10_000)throws->DecisionGameSnapshot {
        let end=min(plant.campaignDurationSeconds,plant.mes.elapsedSeconds+max(0,seconds));var snap:DecisionGameSnapshot?
        while plant.mes.elapsedSeconds < end { let remaining=end-plant.mes.elapsedSeconds;let step=Int32(min(Double(stepMilliseconds),remaining*1000));snap=try cycle(elapsedMilliseconds:max(1,step)) }
        if let snap{return snap};return try cycle(elapsedMilliseconds:1)
    }

    @discardableResult public mutating func run24Hours(stepMilliseconds:Int32=10_000)throws->DecisionGameSnapshot { try run(seconds:max(0,plant.campaignDurationSeconds-plant.mes.elapsedSeconds),stepMilliseconds:stepMilliseconds) }

    public var visibleIncidents:[DecisionIncident] { incidents.filter{$0.revealedAt != nil}.map{ incident in
        guard hiddenInformationEnabled,incident.resolvedAt == nil else{return incident};var copy=incident;copy.truth.rootCause = copy.diagnosisConfidence >= 0.95 ? copy.truth.rootCause : "Hidden until verified";return copy
    }}
    public var communications:[OperatorCommunication] { incidents.flatMap(\.communications).sorted{$0.timestamp<$1.timestamp} }

    @discardableResult public mutating func acknowledgeCommunication(_ id:String)->Bool {
        for i in incidents.indices { if let j=incidents[i].communications.firstIndex(where:{$0.id==id}) { incidents[i].communications[j].acknowledged=true;replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Communication",decision:"Acknowledged operator report",actualConsequence:"Report entered into active evidence",downtimeMinutes:0,dollarImpact:0,counterfactual:"Ignoring calls delays recognition and escalation.",preventableMinutes:0,preventableDollars:0));return true } };return false
    }

    public mutating func askOperatorToCheck(incidentID:String,check:String){
        guard let i=incidents.firstIndex(where:{$0.id==incidentID && $0.active})else{return};let truth=incidents[i].truth
        let result:String
        if check.lowercased().contains("feedback") { result="Operator reports command/feedback mismatch remains at the machine.";incidents[i].diagnosisConfidence=min(1,incidents[i].diagnosisConfidence+0.18) }
        else if check.lowercased().contains("local") || check.lowercased().contains("physical") { result="Local observation narrows the problem to \(truth.actualArea.rawValue).";incidents[i].diagnosisConfidence=min(1,incidents[i].diagnosisConfidence+0.14) }
        else { result="Operator check is inconclusive; symptoms persist.";incidents[i].diagnosisConfidence=min(1,incidents[i].diagnosisConfidence+0.05) }
        incidents[i].communications.append(.init(incidentID:incidentID,timestamp:plant.mes.elapsedSeconds,channel:.radio,from:"Operator",message:result,confidence:.medium,misleading:false))
    }

    public mutating func inspectHistorian(incidentID:String){guard let i=incidents.firstIndex(where:{$0.id==incidentID && $0.active})else{return};incidents[i].diagnosisConfidence=min(1,incidents[i].diagnosisConfidence+0.28);incidents[i].knownFacts.append("Historian/Flight Recorder sequence reviewed at t=\(Int(plant.mes.elapsedSeconds))s.");replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Diagnosis",decision:"Reviewed historian evidence",actualConsequence:"Diagnosis confidence increased without consuming a field specialist",downtimeMinutes:0,dollarImpact:0,counterfactual:"Parts swapping without evidence can extend MTTR.",preventableMinutes:5,preventableDollars:incidents[i].truth.lossPerMinute*5))}

    @discardableResult public mutating func reserveTool(toolID:String,memberID:String)->Bool {
        guard let ti=tools.firstIndex(where:{$0.id==toolID}),tools[ti].quantity>0,(tools[ti].reservedByMemberID==nil || tools[ti].reservedByMemberID==memberID),var s=technicianStates[memberID],s.travelingUntil == nil else{return false}
        tools[ti].reservedByMemberID=memberID
        if s.carriedToolIDs.contains(toolID){return true}
        if s.area == tools[ti].area { s.carriedToolIDs.append(toolID);technicianStates[memberID]=s;return true }
        let travel=travelMinutes(from:s.area,to:tools[ti].area)*60;s.destination=tools[ti].area;s.travelingUntil=plant.mes.elapsedSeconds+travel;s.pendingToolID=toolID;technicianStates[memberID]=s
        replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Tool",decision:"Sent \(s.name) to retrieve \(tools[ti].name)",actualConsequence:"Tool location adds \(Int(travel/60)) min travel",downtimeMinutes:travel/60,dollarImpact:0,counterfactual:"Pre-staging calibrated tools near critical assets removes retrieval travel.",preventableMinutes:travel/60,preventableDollars:0))
        return true
    }

    @discardableResult public mutating func dispatch(memberID:String,to incidentID:String)->Bool {
        guard let ii=incidents.firstIndex(where:{$0.id==incidentID && $0.active}),var tech=technicianStates[memberID],let member=crewMember(memberID),member.availableAt <= plant.mes.elapsedSeconds else{return false}
        if technicianStates.values.contains(where:{$0.memberID==memberID && $0.assignedIncidentID != nil && $0.assignedIncidentID != incidentID}) { return false }
        let target=incidents[ii].truth.actualArea;let travel=travelMinutes(from:tech.area,to:target)*60;tech.destination=target;tech.travelingUntil=plant.mes.elapsedSeconds+travel;tech.assignedIncidentID=incidentID;technicianStates[memberID]=tech;incidents[ii].assignedMemberID=memberID
        replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Dispatch",decision:"Dispatched \(member.name) to \(target.rawValue)",actualConsequence:"Travel consumes \(Int(travel/60)) min before hands-on diagnosis",downtimeMinutes:travel/60,dollarImpact:incidents[ii].truth.lossPerMinute*travel/60,counterfactual:"Dispatching the nearest qualified specialist may reduce response time.",preventableMinutes:max(0,travel/60-3),preventableDollars:max(0,travel/60-3)*incidents[ii].truth.lossPerMinute))
        return true
    }

    @discardableResult public mutating func requestPermit(incidentID:String)->Bool { guard var p=permits[incidentID],p.issuedAt==nil else{return false};p.issuedAt=plant.mes.elapsedSeconds+p.preparationMinutes*60;permits[incidentID]=p;return true }
    @discardableResult public mutating func applyLOTO(incidentID:String)->Bool { guard var p=permits[incidentID],p.kind == .loto,let issued=p.issuedAt,issued <= plant.mes.elapsedSeconds else{return false};p.lotoAppliedAt=plant.mes.elapsedSeconds;p.verifiedZeroEnergyAt=plant.mes.elapsedSeconds+5*60;permits[incidentID]=p;return true }

    @discardableResult public mutating func requestVendor(incidentID:String,vendor:String="OEM Remote Support",delayMinutes:Double=45,cost:Double=650)->VendorSupportRequest? { guard incidents.contains(where:{$0.id==incidentID && $0.active})else{return nil};let request=VendorSupportRequest(incidentID:incidentID,vendor:vendor,requestedAt:plant.mes.elapsedSeconds,eta:plant.mes.elapsedSeconds+max(1,delayMinutes)*60,status:.queued,hourlyCost:275,connectionFee:cost,guidance:nil);vendorRequests.append(request);plant.economics.spareParts += max(0,cost);return request }

    @discardableResult public mutating func performRepair(incidentID:String,strategy:RepairStrategy)->Bool {
        guard let ii=incidents.firstIndex(where:{$0.id==incidentID && $0.active}),let memberID=incidents[ii].assignedMemberID,var tech=technicianStates[memberID],tech.travelingUntil == nil,let member=crewMember(memberID) else{return false}
        let truth=incidents[ii].truth
        if truth.permitKind != .none { guard let p=permits[incidentID],p.readyForWork else { return false } }
        let requiredTools=Set(truth.requiredToolIDs);let hasTools=requiredTools.isSubset(of:Set(tech.carriedToolIDs));guard hasTools else{return false}
        let skill=member.skill(truth.requiredSkill);guard skill>0 else{return false}
        let baseMinutes = strategy == .temporary ? truth.temporaryRepairMinutes : truth.permanentRepairMinutes
        let skillFactor=max(0.55,1.35-Double(skill)*0.14);let evidenceFactor=max(0.65,1.25-incidents[ii].diagnosisConfidence*0.45);let repairMinutes=baseMinutes*skillFactor*evidenceFactor
        let completeAt=plant.mes.elapsedSeconds+repairMinutes*60
        tech.travelingUntil=completeAt;tech.destination=tech.area;technicianStates[memberID]=tech
        incidents[ii].strategy=strategy
        if strategy == .temporary,let recur=truth.temporaryRecurrenceAfterMinutes { incidents[ii].temporaryRepairExpiresAt=completeAt+recur*60 }
        else { incidents[ii].temporaryRepairExpiresAt=nil }
        let directLabor=member.hourlyRate*(repairMinutes/60);plant.economics.directLabor += directLabor
        consequences.append(.init(timestamp:plant.mes.elapsedSeconds,incidentID:incidentID,action:strategy == .temporary ? .temporaryRepair:.permanentRepair,kind:.labor,minutes:repairMinutes,dollars:directLabor,detail:"\(strategy.rawValue.capitalized) repair by \(member.name)",preventable:false))
        replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Repair",decision:"Selected \(strategy.rawValue) repair",actualConsequence:"Expected hands-on work \(Int(repairMinutes)) min",downtimeMinutes:repairMinutes,dollarImpact:directLabor+truth.lossPerMinute*repairMinutes,counterfactual:strategy == .temporary ? "Permanent repair costs more time now but avoids recurrence exposure.":"Temporary repair could restore output sooner but creates recurrence risk.",preventableMinutes:strategy == .temporary ? 0:max(0,repairMinutes-truth.temporaryRepairMinutes),preventableDollars:0))
        return true
    }

    public mutating func stopLine(for incidentID:String){guard let i=incidents.firstIndex(where:{$0.id==incidentID && $0.active})else{return};incidents[i].stoppedLine=true;if let m=incidents[i].truth.actualMachine{_ = plant.mes.reportDowntime(machine:m,reason:.safetyStop,detail:"Supervisor stop for \(incidents[i].title)")};replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Safety",decision:"Stopped line",actualConsequence:"Production stopped to control exposure",downtimeMinutes:0,dollarImpact:0,counterfactual:incidents[i].truth.safetyCritical ? "Continuing could increase safety and damage exposure.":"A controlled diagnostic run might have preserved some production.",preventableMinutes:0,preventableDollars:0))}

    public mutating func reprioritize(orderID:String,priority:Int,dueAt:Double?=nil){guard let i=plant.mes.orders.firstIndex(where:{$0.id==orderID})else{return};plant.mes.orders[i].priority=max(0,min(100,priority));if let dueAt{plant.mes.orders[i].dueAt=dueAt};plant.mes.rebuildSchedule();plant.resequenceOrders(using:.highestPriority);replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Customer",decision:"Reprioritized \(orderID)",actualConsequence:"Dispatch sequence and lateness exposure recalculated",downtimeMinutes:0,dollarImpact:0,counterfactual:"Keeping the old sequence may protect efficiency but miss the new customer commitment.",preventableMinutes:0,preventableDollars:0))}

    public func endOfDayReplay()->[ReplayMoment] {
        let economicMoments=consequences.map { c in ReplayMoment(timestamp:c.timestamp,category:"Economic Ledger",decision:c.action?.rawValue ?? "Plant interval",actualConsequence:c.detail,downtimeMinutes:c.minutes,dollarImpact:c.dollars,counterfactual:c.preventable ? "This loss was tagged as preventable by an earlier/better decision.":"This interval is retained as unavoidable/baseline plant impact.",preventableMinutes:c.preventable ? c.minutes:0,preventableDollars:c.preventable ? c.dollars:0) }
        return (replay+economicMoments).sorted{$0.timestamp<$1.timestamp}
    }

    public func score()->DecisionGameScore {
        let base=plant.score().overall
        let active=incidents.filter{$0.revealedAt != nil};let resolved=active.filter{$0.resolvedAt != nil}
        let diagnosis=active.isEmpty ? 100 : 100*active.map{$0.diagnosisConfidence}.reduce(0,+)/Double(active.count)
        let resource=active.isEmpty ? 100 : 100*Double(resolved.count)/Double(active.count)
        let bypasses=permits.values.filter{$0.bypassed}.count;let safety=max(0,100-Double(bypasses)*25-Double(active.filter{$0.truth.safetyCritical && !$0.stoppedLine && $0.resolvedAt == nil}.count)*10)
        let comms=communications;let communication=comms.isEmpty ? 100 : 100*Double(comms.filter{$0.acknowledged}.count)/Double(comms.count)
        let preventable=replay.reduce(0){$0+$1.preventableDollars};let actual=max(1,plant.economics.totalCost);let econ=max(0,100-min(100,preventable/actual*100))
        return .init(basePlantScore:base,diagnosis:diagnosis,resourceManagement:resource,safetyDiscipline:safety,communication:communication,economicJudgment:econ)
    }

    private mutating func revealDueIncidents(){
        for i in incidents.indices where incidents[i].revealedAt == nil && incidents[i].scheduledAt <= plant.mes.elapsedSeconds {
            incidents[i].revealedAt=plant.mes.elapsedSeconds
            if incidents[i].communications.isEmpty { let msg=incidentOpeningMessage(incidents[i]);let isHandoff=msg.2 && (msg.0.lowercased().contains("shift") || msg.0.lowercased().contains("handoff"));incidents[i].communications.append(.init(incidentID:incidents[i].id,timestamp:plant.mes.elapsedSeconds,channel:isHandoff ? .shiftLog:.radio,from:isHandoff ? "Prior Shift Handoff":"Area Operator",message:msg.0,confidence:msg.1,misleading:msg.2)) }
            if let m=incidents[i].truth.actualMachine { _ = plant.mes.reportDowntime(machine:m,reason:downtimeReason(incidents[i]),detail:"Unresolved field incident: \(incidents[i].title)") }
            plant.events.append(.init(timestamp:plant.mes.elapsedSeconds,kind:.reliabilityFailure,message:"Operator reported \(incidents[i].title). Root cause hidden until evidence is developed.",machine:incidents[i].truth.actualMachine))
        }
    }

    private mutating func updateTravel(){
        for id in technicianStates.keys { guard var s=technicianStates[id],let until=s.travelingUntil,until <= plant.mes.elapsedSeconds else{continue};if let dest=s.destination{s.area=dest};s.destination=nil;s.travelingUntil=nil;if let toolID=s.pendingToolID,!s.carriedToolIDs.contains(toolID){s.carriedToolIDs.append(toolID)};s.pendingToolID=nil;technicianStates[id]=s
            if let incidentID=s.assignedIncidentID,let ii=incidents.firstIndex(where:{$0.id==incidentID && $0.active}) { incidents[ii].diagnosisConfidence=min(1,incidents[ii].diagnosisConfidence+0.20);incidents[ii].knownFacts.append("\(s.name) arrived in \(s.area.rawValue) and confirmed field symptoms.") }
        }
        // Complete repairs when technician timer ends and repair strategy is set.
        for i in incidents.indices where incidents[i].active && incidents[i].strategy != nil {
            guard let mid=incidents[i].assignedMemberID,let s=technicianStates[mid],s.travelingUntil == nil else{continue}
            if incidents[i].knownFacts.contains(where:{$0.hasPrefix("Repair completed")}){continue}
            incidents[i].knownFacts.append("Repair completed at t=\(Int(plant.mes.elapsedSeconds))s.");incidents[i].resolvedAt=plant.mes.elapsedSeconds
            if let m=incidents[i].truth.actualMachine { plant.mes.clearDowntime(machine:m);clearMachineFaults(machine:m) }
            replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Resolution",decision:"Returned equipment to service",actualConsequence:"\(incidents[i].title) cleared",downtimeMinutes:max(0,(plant.mes.elapsedSeconds-(incidents[i].revealedAt ?? plant.mes.elapsedSeconds))/60),dollarImpact:0,counterfactual:"Earlier evidence, travel, permits, tools, or specialist availability could alter this timestamp.",preventableMinutes:0,preventableDollars:0))
            var tech=s;tech.assignedIncidentID=nil;technicianStates[mid]=tech
        }
    }

    private mutating func updateTemporaryRepairs(){
        for i in incidents.indices where incidents[i].resolvedAt != nil && incidents[i].strategy == .temporary {
            guard let expires=incidents[i].temporaryRepairExpiresAt,expires <= plant.mes.elapsedSeconds else{continue}
            incidents[i].resolvedAt=nil;incidents[i].revealedAt=plant.mes.elapsedSeconds;incidents[i].recurrenceCount += 1;incidents[i].temporaryRepairExpiresAt=nil;incidents[i].strategy=nil;incidents[i].diagnosisConfidence=max(incidents[i].diagnosisConfidence,0.8);incidents[i].assignedMemberID=nil
            if let m=incidents[i].truth.actualMachine{_ = plant.mes.reportDowntime(machine:m,reason:downtimeReason(incidents[i]),detail:"Temporary repair recurrence: \(incidents[i].title)")}
            incidents[i].communications.append(.init(incidentID:incidents[i].id,timestamp:plant.mes.elapsedSeconds,channel:.phone,from:"Operator",message:"The same symptom is back after the temporary repair.",confidence:.high,misleading:false))
            consequences.append(.init(timestamp:plant.mes.elapsedSeconds,incidentID:incidents[i].id,action:.temporaryRepair,kind:.recurrence,minutes:0,dollars:0,detail:"Temporary repair recurred",preventable:true))
        }
    }

    private mutating func updateVendorRequests(){for i in vendorRequests.indices where vendorRequests[i].status == .queued && vendorRequests[i].eta <= plant.mes.elapsedSeconds {vendorRequests[i].status = .connected;vendorRequests[i].guidance="OEM recommends checking command/feedback path, network diagnostics, and device-specific fault history before replacement.";if let ii=incidents.firstIndex(where:{$0.id==vendorRequests[i].incidentID}){incidents[ii].diagnosisConfidence=min(1,incidents[ii].diagnosisConfidence+0.25)}}}

    private mutating func applyPriorityChanges(){for i in customerPriorityChanges.indices where !customerPriorityChanges[i].applied && customerPriorityChanges[i].triggerAt <= plant.mes.elapsedSeconds {let c=customerPriorityChanges[i];reprioritize(orderID:c.orderID,priority:c.newPriority,dueAt:c.newDueAt);customerPriorityChanges[i].applied=true;plant.events.append(.init(timestamp:plant.mes.elapsedSeconds,kind:.customerRisk,message:"Customer priority changed: \(c.orderID) — \(c.reason)."))}}

    private mutating func applyUtilityDisturbances(){
        for i in utilityDisturbances.indices {
            if !utilityDisturbances[i].applied && utilityDisturbances[i].triggerAt <= plant.mes.elapsedSeconds { utilityDisturbances[i].applied=true;for m in utilityDisturbances[i].affectedMachines {_ = plant.mes.reportDowntime(machine:m,reason:.unknown,detail:utilityDisturbances[i].message)};plant.events.append(.init(timestamp:plant.mes.elapsedSeconds,kind:.safety,message:"Utility disturbance: \(utilityDisturbances[i].message)")) }
            if utilityDisturbances[i].applied && !utilityDisturbances[i].cleared && utilityDisturbances[i].endAt <= plant.mes.elapsedSeconds {utilityDisturbances[i].cleared=true;for m in utilityDisturbances[i].affectedMachines where !incidents.contains(where:{$0.active && $0.truth.actualMachine==m}){plant.mes.clearDowntime(machine:m)}}
        }
    }

    private mutating func updateEscalations(){for i in incidents.indices where incidents[i].active && !incidents[i].managementEscalated {let age=(plant.mes.elapsedSeconds-(incidents[i].revealedAt ?? plant.mes.elapsedSeconds))/60;if age >= managementEscalationMinutes {incidents[i].managementEscalated=true;plant.events.append(.init(timestamp:plant.mes.elapsedSeconds,kind:.customerRisk,message:"Management escalation: \(incidents[i].title) open \(Int(age)) min.",machine:incidents[i].truth.actualMachine));replay.append(.init(timestamp:plant.mes.elapsedSeconds,category:"Escalation",decision:"Incident exceeded escalation threshold",actualConsequence:"Management attention and customer-risk scrutiny increased",downtimeMinutes:0,dollarImpact:0,counterfactual:"Earlier qualified response could prevent escalation.",preventableMinutes:max(0,age-managementEscalationMinutes),preventableDollars:max(0,age-managementEscalationMinutes)*incidents[i].truth.lossPerMinute))}}}

    private mutating func captureEconomicDelta(_ snap:PlantShiftManagementSnapshot){let impact=snap.economics.netEconomicImpact;let delta=max(0,impact-lastPlantEconomicImpact);lastPlantEconomicImpact=impact;let downtime=plant.mes.downtime.reduce(0){$0+(($1.endedAt ?? snap.elapsedSeconds)-$1.startedAt)/60};let dmin=max(0,downtime-lastPlantDowntimeMinutes);lastPlantDowntimeMinutes=downtime;if delta>0 || dmin>0 {consequences.append(.init(timestamp:snap.elapsedSeconds,incidentID:nil,action:nil,kind:.downtime,minutes:dmin,dollars:delta,detail:"Plant economic/downtime delta during decision interval",preventable:false))}}

    private func snapshot(_ plantSnap:PlantShiftManagementSnapshot)->DecisionGameSnapshot {.init(plant:plantSnap,visibleIncidents:visibleIncidents,communications:communications,technicians:Array(technicianStates.values).sorted{$0.name<$1.name},tools:tools,vendors:vendorRequests,consequences:consequences,customerChanges:customerPriorityChanges,utilityDisturbances:utilityDisturbances,score:score())}

    private func travelMinutes(from:PlantArea,to:PlantArea)->Double {guard let a=areaMap[from],let b=areaMap[to]else{return 8};let d=hypot(a.x-b.x,a.y-b.y);return max(1,d*travelMinutesPerMapUnit)}
    private func permitPrepMinutes(_ kind:PermitKind)->Double {switch kind{case .none:return 0;case .loto:return 8;case .electricalSafeWork:return 12;case .lineBreak:return 15;case .confinedSpace:return 25;case .hotWork:return 20}}
    private func crewMember(_ id:String)->CrewMember? {plant.crews.flatMap(\.members).first(where:{$0.id==id})}
    private func incidentOpeningMessage(_ incident:DecisionIncident)->(String,InformationConfidence,Bool) {if let falseLead=incident.falseLeads.first{return (falseLead,.low,true)};if let fact=incident.knownFacts.first{return (fact,.medium,false)};return ("\(incident.title): machine stopped; cause unknown.",.low,false)}
    private func downtimeReason(_ incident:DecisionIncident)->DowntimeReasonCode {switch incident.domain{case .controls:return .controlsFault;case .electrical:return .controlsFault;case .mechanical:return .mechanicalFault;case .process:return .unknown;case .quality:return .qualityHold;case .utility:return .unknown;default:return .unknown}}
    private mutating func clearMachineFaults(machine:PlayableMachineKind){guard let node=plant.mes.line.project.nodes.first(where:{$0.machine==machine}),var runtime=plant.mes.line.machines[node.id] else{return};runtime.clearFaults();plant.mes.line.machines[node.id]=runtime}
}

private extension PlantArea { static var instrumentationAreaFallback:PlantArea { .qualityLab } }

public enum SupervisorTechnicianDecisionGameTemplates {
    public static func twentyFourHourDecisionCampaign(project:LineBuilderProject = ProductionLineTemplates.beverageLine)throws->SupervisorTechnicianDecisionGameRuntime {
        var base=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:project);base.automaticDispatch=false
        var g=SupervisorTechnicianDecisionGameRuntime(plant:base)
        let machines=project.nodes.map(\.machine);let m0=machines.first;let m1=machines.dropFirst().first ?? m0;let m2=machines.dropFirst(2).first ?? m1
        g.addIncident(.init(title:"Intermittent stop with conflicting operator reports",domain:.controls,severity:.lineStop,scheduledAt:1_650,truth:.init(rootCause:"Loose 24 VDC field terminal causing intermittent input collapse",actualMachine:m0,actualArea:.packaging,requiredSkill:.controls,requiredToolIDs:["DMM-01","LAPTOP-01"],permitKind:.loto,permanentRepairMinutes:38,temporaryRepairMinutes:12,temporaryRecurrenceAfterMinutes:95,lossPerMinute:310),knownFacts:["The PLC sequence stopped twice in ten minutes."],falseLeads:["Operator says the VFD is probably bad because the conveyor stopped."]))
        g.addIncident(.init(title:"Flow indication drifts during production",domain:.instrumentation,severity:.degraded,scheduledAt:5_250,truth:.init(rootCause:"4–20 mA transmitter zero drift after warmup",actualMachine:m1,actualArea:.process,requiredSkill:.instrumentation,requiredToolIDs:["LOOP-01","PRESS-01"],permitKind:.lineBreak,permanentRepairMinutes:52,temporaryRepairMinutes:18,temporaryRecurrenceAfterMinutes:180,lossPerMinute:190),knownFacts:["Quality reports increasing process variation."],falseLeads:["Night shift wrote that the control valve was sticky, but no stroke test was recorded."]))
        g.addIncident(.init(title:"Motor current rises with repeating vibration",domain:.mechanical,severity:.lineStop,scheduledAt:11_400,truth:.init(rootCause:"Bearing degradation progressing toward seizure",actualMachine:m2,actualArea:.utilities,requiredSkill:.mechanical,requiredToolIDs:["VIB-01","IR-01"],permitKind:.loto,permanentRepairMinutes:78,temporaryRepairMinutes:25,temporaryRecurrenceAfterMinutes:70,lossPerMinute:420,safetyCritical:true),knownFacts:["Motor current is elevated and vibration increased during the last hour."],falseLeads:["Operator thinks product is too heavy and wants to increase overload setting."]))
        if let order=base.mes.orders.last { g.addCustomerPriorityChange(.init(triggerAt:31_500,orderID:order.id,newPriority:100,newDueAt:max(32_400,order.dueAt-7_200),reason:"Customer line-down risk moved this order ahead of normal sequence.")) }
        g.addUtilityDisturbance(.init(triggerAt:49_500,endAt:52_200,utility:.compressedAir,capacityFraction:0.55,message:"Thunderstorm causes compressor feeder trip; plant air header falls below normal pressure.",affectedMachines:Array(machines.prefix(2))))
        return g
    }
}
