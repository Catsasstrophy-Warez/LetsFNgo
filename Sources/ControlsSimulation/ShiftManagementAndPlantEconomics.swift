import Foundation

public enum PlantSkill: String, Codable, CaseIterable, Sendable { case controls, electrical, mechanical, instrumentation, process, quality, operations }
public enum CrewRole: String, Codable, CaseIterable, Sendable { case `operator`, controlsTechnician, electrician, mechanic, instrumentationTechnician, processTechnician, qualityTechnician, supervisor }
public enum ShiftWorkOrderStatus: String, Codable, CaseIterable, Sendable { case backlog, planned, dispatched, waitingForParts, inProgress, complete, deferred }
public enum RecoveryDecisionKind: String, Codable, CaseIterable, Sendable { case overtime, expediteMaterial, expediteSpare, alternateRoute, resequenceOrders, deferPM, callVendor, reduceRate, qualityContainment }
public enum UtilityKind: String, Codable, CaseIterable, Sendable { case electricity, compressedAir, steam, chilledWater, processWater }
public enum CampaignEventKind: String, Codable, CaseIterable, Sendable { case productionMeeting, shiftHandoff, reliabilityFailure, technicianDispatch, repairComplete, recoveryDecision, customerRisk, safety, note }

public struct SkillRating: Codable, Equatable, Sendable {
    public var skill: PlantSkill
    public var level: Int
    public init(_ skill: PlantSkill, _ level: Int) { self.skill = skill; self.level = min(5, max(0, level)) }
}

public struct CrewMember: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: CrewRole
    public var skills: [SkillRating]
    public var baseResponseMinutes: Double
    public var hourlyRate: Double
    public var overtimeMultiplier: Double
    public var availableAt: Double
    public init(id: String = UUID().uuidString, name: String, role: CrewRole, skills: [SkillRating], baseResponseMinutes: Double = 8, hourlyRate: Double = 42, overtimeMultiplier: Double = 1.5, availableAt: Double = 0) {
        self.id=id; self.name=name; self.role=role; self.skills=skills; self.baseResponseMinutes=max(0,baseResponseMinutes); self.hourlyRate=max(0,hourlyRate); self.overtimeMultiplier=max(1,overtimeMultiplier); self.availableAt=availableAt
    }
    public func skill(_ skill: PlantSkill) -> Int { skills.first(where:{$0.skill == skill})?.level ?? 0 }
}

public struct PlantCrew: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var members: [CrewMember]
    public var shiftStart: Double
    public var shiftEnd: Double
    public init(id:String=UUID().uuidString,name:String,members:[CrewMember],shiftStart:Double,shiftEnd:Double){self.id=id;self.name=name;self.members=members;self.shiftStart=shiftStart;self.shiftEnd=shiftEnd}
    public func onDuty(at time:Double)->Bool { time >= shiftStart && time < shiftEnd }
}

public struct SparePart: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var partNumber:String
    public var description:String
    public var quantity:Int
    public var reorderPoint:Int
    public var unitCost:Double
    public var normalLeadHours:Double
    public var expediteLeadHours:Double
    public var expediteFee:Double
    public var machineFamilies:[PlayableMachineKind]
    public init(id:String=UUID().uuidString,partNumber:String,description:String,quantity:Int,reorderPoint:Int=1,unitCost:Double,normalLeadHours:Double=24,expediteLeadHours:Double=2,expediteFee:Double=250,machineFamilies:[PlayableMachineKind]=[]){self.id=id;self.partNumber=partNumber;self.description=description;self.quantity=max(0,quantity);self.reorderPoint=max(0,reorderPoint);self.unitCost=max(0,unitCost);self.normalLeadHours=max(0,normalLeadHours);self.expediteLeadHours=max(0,expediteLeadHours);self.expediteFee=max(0,expediteFee);self.machineFamilies=machineFamilies}
}

public struct InboundSupply: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var item:String
    public var quantity:Double
    public var arrivesAt:Double
    public var cost:Double
    public var isSpare:Bool
    public var received:Bool=false
}

public struct ReliabilityAsset: Identifiable, Codable, Equatable, Sendable {
    public var id:String { machine.rawValue }
    public var machine:PlayableMachineKind
    public var nominalMTBFHours:Double
    public var nominalMTTRHours:Double
    public var operatingHours:Double
    public var failureCount:Int
    public var repairHours:Double
    public var nextTrainingFailureAt:Double?
    public var requiredSkill:PlantSkill
    public var criticalSparePartNumber:String?
    public init(machine:PlayableMachineKind,nominalMTBFHours:Double=500,nominalMTTRHours:Double=1.5,operatingHours:Double=0,failureCount:Int=0,repairHours:Double=0,nextTrainingFailureAt:Double?=nil,requiredSkill:PlantSkill = .controls,criticalSparePartNumber:String?=nil){self.machine=machine;self.nominalMTBFHours=max(0.1,nominalMTBFHours);self.nominalMTTRHours=max(0.05,nominalMTTRHours);self.operatingHours=max(0,operatingHours);self.failureCount=max(0,failureCount);self.repairHours=max(0,repairHours);self.nextTrainingFailureAt=nextTrainingFailureAt;self.requiredSkill=requiredSkill;self.criticalSparePartNumber=criticalSparePartNumber}
    public var observedMTBFHours:Double { failureCount > 0 ? operatingHours/Double(failureCount) : operatingHours }
    public var observedMTTRHours:Double { failureCount > 0 ? repairHours/Double(failureCount) : 0 }
}

public struct MaintenanceWorkOrder: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var machine:PlayableMachineKind
    public var title:String
    public var requiredSkill:PlantSkill
    public var requiredPartNumber:String?
    public var priority:MaintenancePriority
    public var status:ShiftWorkOrderStatus
    public var createdAt:Double
    public var dueAt:Double
    public var estimatedHours:Double
    public var assignedMemberID:String?
    public var dispatchedAt:Double?
    public var arrivalAt:Double?
    public var workStartedAt:Double?
    public var completedAt:Double?
    public var sourceMaintenanceCallID:String?
    public var preventive:Bool
    public var deferralRisk:Double
    public init(id:String=UUID().uuidString,machine:PlayableMachineKind,title:String,requiredSkill:PlantSkill,requiredPartNumber:String?=nil,priority:MaintenancePriority = .routine,status:ShiftWorkOrderStatus = .backlog,createdAt:Double=0,dueAt:Double,estimatedHours:Double=1,sourceMaintenanceCallID:String?=nil,preventive:Bool=false,deferralRisk:Double=0){self.id=id;self.machine=machine;self.title=title;self.requiredSkill=requiredSkill;self.requiredPartNumber=requiredPartNumber;self.priority=priority;self.status=status;self.createdAt=createdAt;self.dueAt=dueAt;self.estimatedHours=max(0.05,estimatedHours);self.sourceMaintenanceCallID=sourceMaintenanceCallID;self.preventive=preventive;self.deferralRisk=min(1,max(0,deferralRisk))}
}

public struct UtilityRate: Codable, Equatable, Sendable {
    public var kind:UtilityKind
    public var unit:String
    public var costPerUnit:Double
    public init(_ kind:UtilityKind,unit:String,costPerUnit:Double){self.kind=kind;self.unit=unit;self.costPerUnit=max(0,costPerUnit)}
}

public struct MachineUtilityProfile: Codable, Equatable, Sendable {
    public var machine:PlayableMachineKind
    public var idleElectricKW:Double
    public var runningElectricKW:Double
    public var compressedAirSCFM:Double
    public var steamPerHour:Double
    public var chilledWaterTonHoursPerHour:Double
    public var processWaterGallonsPerHour:Double
    public init(machine:PlayableMachineKind,idleElectricKW:Double,runningElectricKW:Double,compressedAirSCFM:Double=0,steamPerHour:Double=0,chilledWaterTonHoursPerHour:Double=0,processWaterGallonsPerHour:Double=0){self.machine=machine;self.idleElectricKW=max(0,idleElectricKW);self.runningElectricKW=max(0,runningElectricKW);self.compressedAirSCFM=max(0,compressedAirSCFM);self.steamPerHour=max(0,steamPerHour);self.chilledWaterTonHoursPerHour=max(0,chilledWaterTonHoursPerHour);self.processWaterGallonsPerHour=max(0,processWaterGallonsPerHour)}
}

public struct CustomerServiceAgreement: Identifiable, Codable, Equatable, Sendable {
    public var id:String { orderID }
    public var orderID:String
    public var latePenaltyPerMinute:Double
    public var shortUnitPenalty:Double
    public var priorityCustomerMultiplier:Double
    public init(orderID:String,latePenaltyPerMinute:Double=25,shortUnitPenalty:Double=15,priorityCustomerMultiplier:Double=1){self.orderID=orderID;self.latePenaltyPerMinute=max(0,latePenaltyPerMinute);self.shortUnitPenalty=max(0,shortUnitPenalty);self.priorityCustomerMultiplier=max(1,priorityCustomerMultiplier)}
}

public struct PlantEconomicsLedger: Codable, Equatable, Sendable {
    public var mesCost:Double=0
    public var directLabor:Double=0
    public var overtimeLabor:Double=0
    public var spareParts:Double=0
    public var expeditedFreight:Double=0
    public var electricity:Double=0
    public var compressedAir:Double=0
    public var steam:Double=0
    public var chilledWater:Double=0
    public var processWater:Double=0
    public var customerPenalties:Double=0
    public var lostProductionOpportunity:Double=0
    public var recoveredProductionValue:Double=0
    public var totalCost:Double { mesCost+directLabor+overtimeLabor+spareParts+expeditedFreight+electricity+compressedAir+steam+chilledWater+processWater+customerPenalties+lostProductionOpportunity }
    public var netEconomicImpact:Double { totalCost-recoveredProductionValue }
}

public struct RecoveryDecision: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var kind:RecoveryDecisionKind
    public var detail:String
    public var directCost:Double
    public var expectedRecoveryMinutes:Double
    public var actualRecoveryMinutes:Double?
}

public struct ProductionMeetingRecord: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var scheduleAttainment:Double
    public var lineOEE:Double
    public var openBacklog:Int
    public var activeAndons:Int
    public var economicImpact:Double
    public var risks:[String]
    public var actions:[String]
}

public struct ShiftHandoffRecord: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var fromCrew:String
    public var toCrew:String
    public var openWorkOrders:[String]
    public var openAndons:[String]
    public var scheduleRisks:[String]
    public var note:String
    public var fidelity:Double
}

public struct CampaignEvent: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var kind:CampaignEventKind
    public var message:String
    public var machine:PlayableMachineKind?
}

public struct PlantCampaignScore: Codable, Equatable, Sendable {
    public var schedule:Double
    public var economics:Double
    public var reliability:Double
    public var quality:Double
    public var response:Double
    public var communication:Double
    public var safety:Double
    public var overall:Double { max(0,min(100, schedule*0.25 + economics*0.20 + reliability*0.15 + quality*0.15 + response*0.10 + communication*0.10 + safety*0.05)) }
    public var grade:String { switch overall { case 90...: return "Expert"; case 80..<90: return "Strong"; case 70..<80: return "Competent"; case 60..<70: return "Developing"; default:return "Needs Recovery" } }
}

public struct PlantShiftManagementSnapshot: Sendable {
    public var elapsedSeconds:Double
    public var mes:ManufacturingExecutionSnapshot
    public var currentCrew:String
    public var maintenanceBacklog:[MaintenanceWorkOrder]
    public var spares:[SparePart]
    public var inbound:[InboundSupply]
    public var economics:PlantEconomicsLedger
    public var meetings:[ProductionMeetingRecord]
    public var handoffs:[ShiftHandoffRecord]
    public var decisions:[RecoveryDecision]
    public var events:[CampaignEvent]
    public var score:PlantCampaignScore
}

public struct PlantShiftManagementRuntime: Sendable {
    public var mes:ManufacturingExecutionRuntime
    public var crews:[PlantCrew]=[]
    public var spareCrib:[SparePart]=[]
    public var inbound:[InboundSupply]=[]
    public var reliability:[PlayableMachineKind:ReliabilityAsset]=[:]
    public var maintenanceBacklog:[MaintenanceWorkOrder]=[]
    public var utilityRates:[UtilityKind:UtilityRate]=[:]
    public var utilityProfiles:[PlayableMachineKind:MachineUtilityProfile]=[:]
    public var agreements:[String:CustomerServiceAgreement]=[:]
    public var economics=PlantEconomicsLedger()
    public var meetings:[ProductionMeetingRecord]=[]
    public var handoffs:[ShiftHandoffRecord]=[]
    public var decisions:[RecoveryDecision]=[]
    public var events:[CampaignEvent]=[]
    public var campaignDurationSeconds:Double=86_400
    public var unitContributionMargin:Double=12
    public var automaticDispatch:Bool=true
    public var overtimeAuthorizedUntil:Double?
    private var mirroredMaintenanceCalls:Set<String>=[]
    private var lastPenaltyByOrder:[String:Double]=[:]
    private var lastMesCost:Double=0
    private var lastGoodUnits:Int=0
    private var lastCrewName:String?
    private var completedRepairStart:[String:Double]=[:]

    public init(mes:ManufacturingExecutionRuntime) {
        self.mes=mes
        seedDefaults()
    }

    public mutating func seedDefaults() {
        if utilityRates.isEmpty {
            utilityRates[.electricity] = .init(.electricity,unit:"kWh",costPerUnit:0.11)
            utilityRates[.compressedAir] = .init(.compressedAir,unit:"kSCF",costPerUnit:0.28)
            utilityRates[.steam] = .init(.steam,unit:"klb",costPerUnit:11)
            utilityRates[.chilledWater] = .init(.chilledWater,unit:"ton-h",costPerUnit:0.18)
            utilityRates[.processWater] = .init(.processWater,unit:"kgal",costPerUnit:4.5)
        }
        if utilityProfiles.isEmpty { for m in mes.line.project.nodes.map(\.machine) { utilityProfiles[m]=Self.utilityProfile(m) } }
        if reliability.isEmpty { for (i,m) in mes.line.project.nodes.map(\.machine).enumerated() { reliability[m]=Self.reliabilityProfile(m,index:i) } }
    }

    public mutating func addCrew(_ crew:PlantCrew){crews.append(crew);crews.sort{$0.shiftStart<$1.shiftStart}}
    public mutating func addSpare(_ part:SparePart){spareCrib.append(part)}
    public mutating func addPM(_ wo:MaintenanceWorkOrder){maintenanceBacklog.append(wo)}
    public mutating func setAgreement(_ agreement:CustomerServiceAgreement){agreements[agreement.orderID]=agreement}

    @discardableResult public mutating func cycle(elapsedMilliseconds:Int32=1000)throws->PlantShiftManagementSnapshot {
        let before=mes.elapsedSeconds
        let mesSnapshot=try mes.cycle(elapsedMilliseconds:elapsedMilliseconds)
        let dt=max(0,mes.elapsedSeconds-before)
        receiveInbound(); mirrorMaintenanceCalls(); updateReliability(dt:dt); updateWorkOrders(); updateUtilities(dt:dt,mesSnapshot:mesSnapshot); updateLabor(dt:dt); updatePenalties(); updateEconomicRollup(); checkShiftHandoff(); checkMeetingCadence();
        if automaticDispatch { autoDispatchBestWorkOrder() }
        return snapshot(from:mesSnapshot)
    }

    @discardableResult public mutating func run(seconds:Double,stepMilliseconds:Int32=10_000)throws->PlantShiftManagementSnapshot {
        let end=min(campaignDurationSeconds,mes.elapsedSeconds+max(0,seconds));var snap:PlantShiftManagementSnapshot?
        while mes.elapsedSeconds < end { let remaining=end-mes.elapsedSeconds;let step=Int32(min(Double(stepMilliseconds),remaining*1000));snap=try cycle(elapsedMilliseconds:max(1,step)) }
        if let snap { return snap }; let ms = try mes.cycle(elapsedMilliseconds:1); return snapshot(from: ms)
    }

    @discardableResult public mutating func run24Hours(stepMilliseconds:Int32=10_000)throws->PlantShiftManagementSnapshot { try run(seconds:max(0,campaignDurationSeconds-mes.elapsedSeconds),stepMilliseconds:stepMilliseconds) }

    public func currentCrew(at time:Double?=nil)->PlantCrew? { let t=time ?? mes.elapsedSeconds;return crews.first(where:{$0.onDuty(at:t)}) ?? crews.last(where:{$0.shiftStart <= t}) }

    @discardableResult public mutating func dispatch(workOrderID:String,memberID:String)->Bool {
        guard let wi=maintenanceBacklog.firstIndex(where:{$0.id==workOrderID}), var crew=currentCrew(), let mi=crew.members.firstIndex(where:{$0.id==memberID}) else{return false}
        guard [.backlog,.planned,.waitingForParts].contains(maintenanceBacklog[wi].status) else{return false}
        if let part=maintenanceBacklog[wi].requiredPartNumber, !consumeSpare(partNumber:part,quantity:1,charge:true) { maintenanceBacklog[wi].status = .waitingForParts;return false }
        let member=crew.members[mi], skill=max(0,member.skill(maintenanceBacklog[wi].requiredSkill))
        let priorityFactor:Double = maintenanceBacklog[wi].priority == .emergency ? 0.55 : maintenanceBacklog[wi].priority == .urgent ? 0.75 : 1
        let skillFactor=max(0.45,1.35-Double(skill)*0.15)
        let response=member.baseResponseMinutes*priorityFactor*skillFactor*60
        maintenanceBacklog[wi].status = .dispatched;maintenanceBacklog[wi].assignedMemberID=member.id;maintenanceBacklog[wi].dispatchedAt=mes.elapsedSeconds;maintenanceBacklog[wi].arrivalAt=max(mes.elapsedSeconds,member.availableAt)+response
        crew.members[mi].availableAt=(maintenanceBacklog[wi].arrivalAt ?? mes.elapsedSeconds)+maintenanceBacklog[wi].estimatedHours*3600*skillFactor
        if let ci=crews.firstIndex(where:{$0.id==crew.id}){crews[ci]=crew}
        events.append(.init(timestamp:mes.elapsedSeconds,kind:.technicianDispatch,message:"Dispatched \(member.name) to \(maintenanceBacklog[wi].title); estimated response \(Int(response/60)) min.",machine:maintenanceBacklog[wi].machine))
        return true
    }

    @discardableResult public mutating func expediteSpare(partNumber:String,quantity:Int=1)->InboundSupply? {
        guard let p=spareCrib.first(where:{$0.partNumber==partNumber}) else{return nil};let cost=Double(max(1,quantity))*p.unitCost+p.expediteFee;let shipment=InboundSupply(item:partNumber,quantity:Double(max(1,quantity)),arrivesAt:mes.elapsedSeconds+p.expediteLeadHours*3600,cost:cost,isSpare:true);inbound.append(shipment);economics.expeditedFreight += p.expediteFee;decisions.append(.init(timestamp:mes.elapsedSeconds,kind:.expediteSpare,detail:"Expedited \(quantity)x \(partNumber), ETA \(p.expediteLeadHours) h",directCost:cost,expectedRecoveryMinutes:p.expediteLeadHours*60));return shipment
    }

    @discardableResult public mutating func expediteMaterial(material:String,quantity:Double,leadHours:Double=2,unitCost:Double=1.5,freight:Double=350)->InboundSupply {
        let shipment=InboundSupply(item:material,quantity:max(0,quantity),arrivesAt:mes.elapsedSeconds+max(0,leadHours)*3600,cost:max(0,quantity)*unitCost+freight,isSpare:false);inbound.append(shipment);economics.expeditedFreight += freight;decisions.append(.init(timestamp:mes.elapsedSeconds,kind:.expediteMaterial,detail:"Expedited \(String(format:"%.0f",quantity)) \(material), ETA \(leadHours) h",directCost:shipment.cost,expectedRecoveryMinutes:leadHours*60));return shipment
    }

    public mutating func authorizeOvertime(hours:Double,crewName:String="Recovery Crew") {
        let h=max(0,hours);guard h>0 else{return};let start=mes.shifts.map(\.endAt).max() ?? mes.elapsedSeconds;let end=start+h*3600;campaignDurationSeconds=max(campaignDurationSeconds,end);mes.addShift(.init(name:"Overtime",startAt:start,endAt:end,crew:crewName));overtimeAuthorizedUntil=end;decisions.append(.init(timestamp:mes.elapsedSeconds,kind:.overtime,detail:"Authorized \(String(format:"%.1f",h)) h overtime through t=\(Int(end))s",directCost:0,expectedRecoveryMinutes:h*60))
    }

    @discardableResult public mutating func activateAlternateRoute(around machine:PlayableMachineKind,capacity:Int=6)->LineBuilderConnection? {
        guard let node=mes.line.project.nodes.first(where:{$0.machine==machine}),let incoming=mes.line.project.connections.first(where:{$0.toNodeID==node.id}),let outgoing=mes.line.project.connections.first(where:{$0.fromNodeID==node.id}) else{return nil}
        if let existing=mes.line.project.connections.first(where:{$0.fromNodeID==incoming.fromNodeID && $0.toNodeID==outgoing.toNodeID}){return existing}
        let c=LineBuilderConnection(fromNodeID:incoming.fromNodeID,toNodeID:outgoing.toNodeID,capacity:capacity,discipline:.fifo,priority:10);mes.line.project.connections.append(c);mes.line.buffers[c.id]=IntelligentLineBuffer(connection:c)
        if let u=mes.line.project.nodes.first(where:{$0.id==c.fromNodeID}),let d=mes.line.project.nodes.first(where:{$0.id==c.toNodeID}) { mes.line.handshakes[c.id]=LineHandshake(id:c.id,upstream:u.machine,downstream:d.machine) }
        decisions.append(.init(timestamp:mes.elapsedSeconds,kind:.alternateRoute,detail:"Activated bypass around \(machine.rawValue)",directCost:150,expectedRecoveryMinutes:15));economics.maintenanceCostEquivalent(150)
        return c
    }

    public mutating func resequenceOrders(using rule:DispatchRule){mes.dispatchRule=rule;mes.rebuildSchedule();decisions.append(.init(timestamp:mes.elapsedSeconds,kind:.resequenceOrders,detail:"Changed dispatch rule to \(rule.rawValue)",directCost:0,expectedRecoveryMinutes:20))}
    public mutating func deferPM(_ id:String){guard let i=maintenanceBacklog.firstIndex(where:{$0.id==id}),maintenanceBacklog[i].preventive else{return};maintenanceBacklog[i].status = .deferred;maintenanceBacklog[i].deferralRisk=min(1,maintenanceBacklog[i].deferralRisk+0.25);decisions.append(.init(timestamp:mes.elapsedSeconds,kind:.deferPM,detail:"Deferred PM \(id): \(maintenanceBacklog[i].title)",directCost:0,expectedRecoveryMinutes:maintenanceBacklog[i].estimatedHours*60))}

    public mutating func recordProductionMeeting(actions:[String],risks:[String]=[]) {
        let s=currentMESQuickSnapshot();meetings.append(.init(timestamp:mes.elapsedSeconds,scheduleAttainment:s.0,lineOEE:s.1,openBacklog:maintenanceBacklog.filter{![$0.status == .complete].contains(true)}.count,activeAndons:mes.andons.filter(\.active).count,economicImpact:economics.netEconomicImpact,risks:risks,actions:actions));events.append(.init(timestamp:mes.elapsedSeconds,kind:.productionMeeting,message:"Production meeting recorded with \(actions.count) actions."))
    }

    public mutating func recordHandoff(toCrew:String,note:String,fidelity:Double=1) {
        let from=lastCrewName ?? currentCrew()?.name ?? "Unknown";let risks=mes.schedule.filter{$0.lateBySeconds>0}.map{"\($0.orderID) late \(Int($0.lateBySeconds/60)) min"};let rec=ShiftHandoffRecord(timestamp:mes.elapsedSeconds,fromCrew:from,toCrew:toCrew,openWorkOrders:maintenanceBacklog.filter{$0.status != .complete}.map(\.id),openAndons:mes.andons.filter(\.active).map(\.message),scheduleRisks:risks,note:note,fidelity:min(1,max(0,fidelity)));handoffs.append(rec);mes.operatorActions.append(.init(timestamp:mes.elapsedSeconds,operatorName:from,kind:.shiftHandoff,detail:"Handoff to \(toCrew): \(note)"));events.append(.init(timestamp:mes.elapsedSeconds,kind:.shiftHandoff,message:"\(from) → \(toCrew), fidelity \(Int(rec.fidelity*100))%."));lastCrewName=toCrew
    }

    public func score()->PlantCampaignScore {
        let planned=max(1,mes.orders.reduce(0){$0+$1.quantity});let good=mes.orders.reduce(0){$0+$1.completedQuantity};let schedule=min(100,100*Double(good)/Double(planned))
        let budget=max(5000,Double(planned)*8);let economicsScore=max(0,100-100*economics.netEconomicImpact/budget)
        let overdue=maintenanceBacklog.filter{$0.status != .complete && $0.dueAt < mes.elapsedSeconds}.count;let reliabilityScore=max(0,100-Double(overdue)*8-Double(maintenanceBacklog.filter{$0.status == .deferred}.count)*6)
        let total=max(1,mes.costs.goodUnits+mes.costs.scrapUnits);let quality=100*Double(mes.costs.goodUnits)/Double(total)
        let completed=maintenanceBacklog.filter{$0.status == .complete};let avgResponse=completed.compactMap{wo->Double? in guard let d=wo.dispatchedAt,let a=wo.arrivalAt else{return nil};return (a-d)/60}.average ?? 0;let response=max(0,100-avgResponse*2)
        let expectedHandoffs=max(1,crews.count-1);let comm=min(100,100*Double(handoffs.count)/Double(expectedHandoffs))*(handoffs.map(\.fidelity).average ?? 1)
        let safety: Double = mes.downtime.contains(where:{$0.reason == .safetyStop && $0.duration(at:mes.elapsedSeconds)>600}) ? 70 : 100
        return .init(schedule:schedule,economics:economicsScore,reliability:reliabilityScore,quality:quality,response:response,communication:comm,safety:safety)
    }

    private mutating func mirrorMaintenanceCalls(){
        for call in mes.maintenanceCalls where !mirroredMaintenanceCalls.contains(call.id) {
            guard let machine=call.machine else{mirroredMaintenanceCalls.insert(call.id);continue};let asset=reliability[machine] ?? Self.reliabilityProfile(machine,index:0);maintenanceBacklog.append(.init(machine:machine,title:call.problem,requiredSkill:asset.requiredSkill,requiredPartNumber:asset.criticalSparePartNumber,priority:call.priority,status:.backlog,createdAt:call.requestedAt,dueAt:call.requestedAt+(call.priority == .emergency ? 900 : 3600),estimatedHours:asset.nominalMTTRHours,sourceMaintenanceCallID:call.id));mirroredMaintenanceCalls.insert(call.id)
        }
    }

    private mutating func updateWorkOrders(){
        for i in maintenanceBacklog.indices {
            guard maintenanceBacklog[i].status == .dispatched || maintenanceBacklog[i].status == .inProgress else{continue}
            if maintenanceBacklog[i].status == .dispatched,let arrival=maintenanceBacklog[i].arrivalAt,arrival <= mes.elapsedSeconds { maintenanceBacklog[i].status = .inProgress;maintenanceBacklog[i].workStartedAt=arrival;completedRepairStart[maintenanceBacklog[i].id]=arrival }
            if maintenanceBacklog[i].status == .inProgress,let start=maintenanceBacklog[i].workStartedAt {
                let member=member(id:maintenanceBacklog[i].assignedMemberID);let skill=member?.skill(maintenanceBacklog[i].requiredSkill) ?? 1;let factor=max(0.45,1.35-Double(skill)*0.15);let finish=start+maintenanceBacklog[i].estimatedHours*3600*factor
                if finish <= mes.elapsedSeconds { completeWorkOrder(at:i,finish:finish) }
            }
        }
    }

    private mutating func completeWorkOrder(at i:Int,finish:Double){
        let wo=maintenanceBacklog[i];maintenanceBacklog[i].status = .complete;maintenanceBacklog[i].completedAt=finish
                if let node=mes.line.project.nodes.first(where:{$0.machine==wo.machine}),var machine=mes.line.machines[node.id] { machine.clearFaults();mes.line.machines[node.id]=machine }
        mes.clearDowntime(machine:wo.machine)
        if let callID=wo.sourceMaintenanceCallID { mes.completeMaintenance(callID,cost:0) }
        if var asset=reliability[wo.machine] { if let start=completedRepairStart[wo.id]{asset.repairHours += max(0,finish-start)/3600};reliability[wo.machine]=asset }
        events.append(.init(timestamp:finish,kind:.repairComplete,message:"Completed \(wo.title); faults cleared and machine returned to service.",machine:wo.machine))
    }

    private mutating func updateReliability(dt:Double){
        let h=dt/3600
        for machine in reliability.keys {
            guard var a=reliability[machine] else{continue};let inDowntime=mes.downtime.contains(where:{$0.machine==machine && $0.endedAt == nil});if !inDowntime{a.operatingHours += h}
            if let failAt=a.nextTrainingFailureAt,a.operatingHours >= failAt,!inDowntime { triggerReliabilityFailure(&a) }
            if let pm=maintenanceBacklog.first(where:{$0.machine==machine && $0.preventive && $0.status == .deferred}),pm.deferralRisk > 0.3,a.nextTrainingFailureAt == nil { a.nextTrainingFailureAt=a.operatingHours+max(0.25,a.nominalMTBFHours*(1-pm.deferralRisk)*0.02) }
            reliability[machine]=a
        }
    }

    private mutating func triggerReliabilityFailure(_ asset:inout ReliabilityAsset){
        asset.failureCount += 1;asset.nextTrainingFailureAt=nil;_ = mes.reportDowntime(machine:asset.machine,reason: asset.requiredSkill == .mechanical ? .mechanicalFault : .controlsFault,detail:"Reliability event on \(asset.machine.rawValue)")
        if let node=mes.line.project.nodes.first(where:{$0.machine==asset.machine}),var machine=mes.line.machines[node.id] { if asset.requiredSkill == .mechanical { let target=ClosedLoopPlantRuntime.outputPaths(for:machine.executable).first?.commandTag ?? "";if !target.isEmpty{machine.injectOutputFault(.init(target:target,kind:.actuatorStuck))} } else { let target=machine.executable.bindings.first(where:{$0.direction == .input})?.ioTag ?? "";if !target.isEmpty{machine.injectInputFault(.init(target:target,kind:.openWire))} };mes.line.machines[node.id]=machine }
        events.append(.init(timestamp:mes.elapsedSeconds,kind:.reliabilityFailure,message:"\(asset.machine.rawValue) failed; maintenance response required.",machine:asset.machine))
    }

    private mutating func autoDispatchBestWorkOrder(){
        guard let crew=currentCrew() else{return};let candidates=maintenanceBacklog.filter{$0.status == .backlog || ($0.status == .planned && $0.dueAt <= mes.elapsedSeconds+1800)}.sorted{priorityRank($0.priority)>priorityRank($1.priority)}
        guard let wo=candidates.first else{return};let available=crew.members.filter{$0.availableAt <= mes.elapsedSeconds}.sorted{ lhs,rhs in lhs.skill(wo.requiredSkill) > rhs.skill(wo.requiredSkill) }
        if let best=available.first { _=dispatch(workOrderID:wo.id,memberID:best.id) }
    }

    private mutating func receiveInbound(){
        for i in inbound.indices where !inbound[i].received && inbound[i].arrivesAt <= mes.elapsedSeconds { let shipment=inbound[i];if shipment.isSpare { if let p=spareCrib.firstIndex(where:{$0.partNumber==shipment.item}){spareCrib[p].quantity += Int(shipment.quantity)} } else { mes.addInventory(.init(material:shipment.item,lotID:"EXP-\(Int(shipment.arrivesAt))",onHand:shipment.quantity,unitCost: shipment.quantity>0 ? max(0,(shipment.cost-350)/shipment.quantity):0)) };inbound[i].received=true }
    }

    private mutating func updateUtilities(dt:Double,mesSnapshot:ManufacturingExecutionSnapshot){
        let h=dt/3600;for node in mes.line.project.nodes { guard let p=utilityProfiles[node.machine] else{continue};let down=mesSnapshot.openDowntime.contains(where:{$0.machine==node.machine});let kw=down ? p.idleElectricKW : p.runningElectricKW;economics.electricity += kw*h*(utilityRates[.electricity]?.costPerUnit ?? 0);economics.compressedAir += p.compressedAirSCFM*60*h/1000*(utilityRates[.compressedAir]?.costPerUnit ?? 0);economics.steam += p.steamPerHour*h*(utilityRates[.steam]?.costPerUnit ?? 0);economics.chilledWater += p.chilledWaterTonHoursPerHour*h*(utilityRates[.chilledWater]?.costPerUnit ?? 0);economics.processWater += p.processWaterGallonsPerHour*h/1000*(utilityRates[.processWater]?.costPerUnit ?? 0) }
    }

    private mutating func updateLabor(dt:Double){
        guard let crew=currentCrew() else{return};let h=dt/3600;for member in crew.members { let base=member.hourlyRate*h;if overtimeAuthorizedUntil != nil && mes.elapsedSeconds > 86_400 { economics.overtimeLabor += base*member.overtimeMultiplier } else { economics.directLabor += base } }
    }

    private mutating func updatePenalties(){
        for o in mes.orders { let a=agreements[o.id] ?? .init(orderID:o.id);let late=max(0,mes.elapsedSeconds-o.dueAt);let short=max(0,o.quantity-o.completedQuantity);let penalty = late > 0 && o.status != .complete ? (late/60*a.latePenaltyPerMinute + Double(short)*a.shortUnitPenalty)*a.priorityCustomerMultiplier : 0;let previous=lastPenaltyByOrder[o.id] ?? 0;if penalty>previous{economics.customerPenalties += penalty-previous;lastPenaltyByOrder[o.id]=penalty;if penalty-previous > 100{events.append(.init(timestamp:mes.elapsedSeconds,kind:.customerRisk,message:"Customer penalty exposure increasing on \(o.id): $\(Int(penalty))."))}} }
    }

    private mutating func updateEconomicRollup(){
        economics.mesCost=mes.costs.totalCost;let newGood=max(0,mes.costs.goodUnits-lastGoodUnits);economics.recoveredProductionValue += Double(newGood)*unitContributionMargin;lastGoodUnits=mes.costs.goodUnits
        let lateUnits=mes.orders.reduce(0){$0 + (($1.dueAt < mes.elapsedSeconds && $1.status != .complete) ? $1.remaining : 0)};economics.lostProductionOpportunity=Double(lateUnits)*unitContributionMargin
        lastMesCost=mes.costs.totalCost
    }

    private mutating func checkShiftHandoff(){
        let name=currentCrew()?.name;defer{if lastCrewName == nil{lastCrewName=name}}
        if let name,lastCrewName != nil,name != lastCrewName,!handoffs.contains(where:{$0.toCrew==name && abs($0.timestamp-mes.elapsedSeconds)<900}) { recordHandoff(toCrew:name,note:"Automatic handoff prompt: review active Andons, backlog, schedule risk, quality holds, and temporary repairs.",fidelity:0.8) }
    }

    private mutating func checkMeetingCadence(){
        let hour=mes.elapsedSeconds/3600;let slots=[0.5,4.0,8.0,12.0,16.0,20.0,23.5];let dueCount=slots.filter{hour >= $0}.count;while meetings.count < dueCount { let risks=mes.schedule.filter{$0.lateBySeconds>0}.prefix(3).map{"\($0.orderID) forecast late"};recordProductionMeeting(actions:["Review bottleneck","Confirm critical spares","Protect next customer due order"],risks:Array(risks)) }
    }

    private func snapshot(from mesSnapshot:ManufacturingExecutionSnapshot)->PlantShiftManagementSnapshot { .init(elapsedSeconds:mes.elapsedSeconds,mes:mesSnapshot,currentCrew:currentCrew()?.name ?? "Unstaffed",maintenanceBacklog:maintenanceBacklog,spares:spareCrib,inbound:inbound,economics:economics,meetings:meetings,handoffs:handoffs,decisions:decisions,events:events,score:score()) }
    private func currentMESQuickSnapshot()->(Double,Double){let planned=max(1,mes.orders.reduce(0){$0+$1.quantity});return (Double(mes.orders.reduce(0){$0+$1.completedQuantity})/Double(planned),mes.line.machineOEE.values.map(\.oee).average ?? 0)}
    private func member(id:String?)->CrewMember? { guard let id else{return nil};return crews.flatMap(\.members).first(where:{$0.id==id}) }
    private mutating func consumeSpare(partNumber:String,quantity:Int,charge:Bool)->Bool { guard let i=spareCrib.firstIndex(where:{$0.partNumber==partNumber}),spareCrib[i].quantity>=quantity else{return false};spareCrib[i].quantity -= quantity;if charge{economics.spareParts += Double(quantity)*spareCrib[i].unitCost};return true }
    private func priorityRank(_ p:MaintenancePriority)->Int { p == .emergency ? 3 : p == .urgent ? 2 : 1 }

    private static func reliabilityProfile(_ m:PlayableMachineKind,index:Int)->ReliabilityAsset { let skill:PlantSkill = [PlayableMachineKind.servoConveyor,.asrsCrane,.roboticPalletizer].contains(m) ? .controls : ([.pumpStation,.crusherConveyor,.grainElevator,.compressedAirPlant].contains(m) ? .mechanical : .electrical);let spare = skill == .controls ? "IO-POINT" : skill == .mechanical ? "BEARING-6205" : "CONTACTOR-32A";return .init(machine:m,nominalMTBFHours:Double(350+(index%7)*75),nominalMTTRHours:Double(1+(index%4))/2+0.5,nextTrainingFailureAt:index < 3 ? Double(3+index*3) : nil,requiredSkill:skill,criticalSparePartNumber:spare) }
    private static func utilityProfile(_ m:PlayableMachineKind)->MachineUtilityProfile { switch m { case .industrialOven,.boilerSteamPlant:return .init(machine:m,idleElectricKW:12,runningElectricKW:95,compressedAirSCFM:8,steamPerHour:m == .boilerSteamPlant ? 4:0);case .refrigerationRack,.dataCenterCooling,.chilledWaterPlant:return .init(machine:m,idleElectricKW:18,runningElectricKW:160,chilledWaterTonHoursPerHour:45);case .pressureSkid,.pumpStation,.reverseOsmosisPlant,.wastewaterLiftStation:return .init(machine:m,idleElectricKW:5,runningElectricKW:60,compressedAirSCFM:4,processWaterGallonsPerHour:800);case .packagingCell,.bottlingLine,.roboticPalletizer,.parcelSortation:return .init(machine:m,idleElectricKW:3,runningElectricKW:28,compressedAirSCFM:45);default:return .init(machine:m,idleElectricKW:4,runningElectricKW:35,compressedAirSCFM:10) } }
}

private extension Array where Element == Double { var average:Double? { isEmpty ? nil : reduce(0,+)/Double(count) } }
private extension PlantEconomicsLedger { mutating func maintenanceCostEquivalent(_ amount:Double){ spareParts += max(0,amount) } }

public enum PlantShiftManagementTemplates {
    public static func twentyFourHourCampaign(project:LineBuilderProject = ProductionLineTemplates.beverageLine)throws->PlantShiftManagementRuntime {
        var mes=try ManufacturingExecutionTemplates.trainingRuntime(project:project)
        mes.shifts=[]
        mes.addShift(.init(name:"Day Shift",startAt:0,endAt:28_800,plannedBreaks:[7200...8100,14_400...16_200,21_600...22_500],crew:"A Crew"))
        mes.addShift(.init(name:"Evening Shift",startAt:28_800,endAt:57_600,plannedBreaks:[36_000...36_900,43_200...45_000,50_400...51_300],crew:"B Crew"))
        mes.addShift(.init(name:"Night Shift",startAt:57_600,endAt:86_400,plannedBreaks:[64_800...65_700,72_000...73_800,79_200...80_100],crew:"C Crew"))
        if !mes.orders.contains(where:{$0.id=="PO-1003"}) { mes.addOrder(.init(id:"PO-1003",sku:"SKU-A",quantity:150,dueAt:54_000,priority:85,taktTargetSeconds:55));mes.addOrder(.init(id:"PO-1004",sku:"SKU-B",quantity:110,dueAt:82_800,priority:90,taktTargetSeconds:60)) }
        var r=PlantShiftManagementRuntime(mes:mes)
        r.addCrew(.init(name:"A Crew",members:[.init(name:"Maya",role:.controlsTechnician,skills:[.init(.controls,5),.init(.electrical,4),.init(.instrumentation,3)],baseResponseMinutes:5,hourlyRate:48),.init(name:"Luis",role:.mechanic,skills:[.init(.mechanical,5),.init(.operations,2)],baseResponseMinutes:7,hourlyRate:44),.init(name:"Rae",role:.operator,skills:[.init(.operations,5),.init(.quality,3)],baseResponseMinutes:2,hourlyRate:31)],shiftStart:0,shiftEnd:28_800))
        r.addCrew(.init(name:"B Crew",members:[.init(name:"Dev",role:.electrician,skills:[.init(.electrical,5),.init(.controls,3)],baseResponseMinutes:8,hourlyRate:45),.init(name:"Kim",role:.mechanic,skills:[.init(.mechanical,4),.init(.process,3)],baseResponseMinutes:9,hourlyRate:42),.init(name:"Jo",role:.operator,skills:[.init(.operations,5),.init(.quality,2)],baseResponseMinutes:2,hourlyRate:30)],shiftStart:28_800,shiftEnd:57_600))
        r.addCrew(.init(name:"C Crew",members:[.init(name:"Ari",role:.controlsTechnician,skills:[.init(.controls,4),.init(.instrumentation,4),.init(.electrical,3)],baseResponseMinutes:10,hourlyRate:46),.init(name:"Sam",role:.mechanic,skills:[.init(.mechanical,3),.init(.operations,3)],baseResponseMinutes:11,hourlyRate:40),.init(name:"Noor",role:.operator,skills:[.init(.operations,4),.init(.quality,4)],baseResponseMinutes:2,hourlyRate:30)],shiftStart:57_600,shiftEnd:86_400))
        r.addSpare(.init(partNumber:"IO-POINT",description:"Remote I/O replacement point/module",quantity:1,reorderPoint:1,unitCost:780,normalLeadHours:18,expediteLeadHours:2,expediteFee:420,machineFamilies:project.nodes.map(\.machine)))
        r.addSpare(.init(partNumber:"BEARING-6205",description:"Critical motor/pump bearing kit",quantity:2,reorderPoint:1,unitCost:95,normalLeadHours:8,expediteLeadHours:1.5,expediteFee:180,machineFamilies:project.nodes.map(\.machine)))
        r.addSpare(.init(partNumber:"CONTACTOR-32A",description:"32 A IEC contactor",quantity:1,reorderPoint:1,unitCost:145,normalLeadHours:12,expediteLeadHours:2,expediteFee:240,machineFamilies:project.nodes.map(\.machine)))
        for (i,m) in project.nodes.map(\.machine).enumerated() { r.addPM(.init(machine:m,title:"PM-\(i+1) inspect drives, terminals, guards, lubrication",requiredSkill:i%2==0 ? .electrical:.mechanical,priority:.routine,status:.planned,createdAt:0,dueAt:Double(18_000+i*5400),estimatedHours:0.75,preventive:true,deferralRisk:0.1)) }
        for o in r.mes.orders { r.setAgreement(.init(orderID:o.id,latePenaltyPerMinute:o.priority>=80 ? 40:22,shortUnitPenalty:o.priority>=80 ? 25:12,priorityCustomerMultiplier:o.priority>=90 ? 1.5:1)) }
        for order in r.mes.orders where order.status == .planned { try? r.mes.releaseOrder(order.id, by: "Production Control") }
        return r
    }
}
