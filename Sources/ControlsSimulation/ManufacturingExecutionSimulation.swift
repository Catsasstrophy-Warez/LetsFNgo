import Foundation

public enum ProductionOrderStatus: String, Codable, CaseIterable, Sendable { case planned, released, running, held, complete, cancelled }
public enum DispatchRule: String, Codable, CaseIterable, Sendable { case fifo, earliestDueDate, highestPriority, shortestProcessingTime, criticalRatio }
public enum DowntimeReasonCode: String, Codable, CaseIterable, Sendable { case controlsFault, mechanicalFault, materialShortage, qualityHold, changeover, blocked, starved, operatorDelay, plannedMaintenance, safetyStop, unknown }
public enum AndonSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case information, warning, lineStop, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)! }
}
public enum MaintenancePriority: String, Codable, CaseIterable, Sendable { case routine, urgent, emergency }
public enum OperatorActionKind: String, Codable, CaseIterable, Sendable { case login, startOrder, pauseOrder, resumeOrder, acknowledgeAndon, assignDowntimeCode, approveFirstPiece, requestMaintenance, materialIssue, qualityCheck, shiftHandoff }
public enum InventoryDisposition: String, Codable, CaseIterable, Sendable { case available, reserved, qualityHold, quarantine, consumed, finishedGoods }

public struct SKUDemand: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sku: String
    public var quantity: Int
    public var dueAt: Double
    public var customer: String
    public var priority: Int
    public init(id:String=UUID().uuidString,sku:String,quantity:Int,dueAt:Double,customer:String="Internal Demand",priority:Int=50){self.id=id;self.sku=sku;self.quantity=max(0,quantity);self.dueAt=dueAt;self.customer=customer;self.priority=priority}
}

public struct ProductionOrder: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var sku:String
    public var recipeID:String?
    public var quantity:Int
    public var completedQuantity:Int
    public var scrapQuantity:Int
    public var releasedAt:Double?
    public var startedAt:Double?
    public var completedAt:Double?
    public var dueAt:Double
    public var priority:Int
    public var status:ProductionOrderStatus
    public var taktTargetSeconds:Double
    public var assignedLine:String
    public init(id:String,sku:String,recipeID:String?=nil,quantity:Int,dueAt:Double,priority:Int=50,taktTargetSeconds:Double=1,assignedLine:String="Line 1",status:ProductionOrderStatus = .planned){self.id=id;self.sku=sku;self.recipeID=recipeID;self.quantity=max(1,quantity);self.completedQuantity=0;self.scrapQuantity=0;self.dueAt=dueAt;self.priority=priority;self.status=status;self.taktTargetSeconds=max(0.001,taktTargetSeconds);self.assignedLine=assignedLine}
    public var remaining:Int { max(0,quantity-completedQuantity) }
    public var attainment:Double { min(1,Double(completedQuantity)/Double(max(1,quantity))) }
}

public struct ShiftSchedule: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var name:String
    public var startAt:Double
    public var endAt:Double
    public var plannedBreaks:[ClosedRange<Double>]
    public var crew:String
    public init(id:String=UUID().uuidString,name:String,startAt:Double,endAt:Double,plannedBreaks:[ClosedRange<Double>]=[],crew:String="A Crew"){self.id=id;self.name=name;self.startAt=startAt;self.endAt=endAt;self.plannedBreaks=plannedBreaks;self.crew=crew}
    public func isScheduled(at time:Double)->Bool { time >= startAt && time < endAt && !plannedBreaks.contains(where:{$0.contains(time)}) }
    public var scheduledSeconds:Double { max(0,endAt-startAt-plannedBreaks.reduce(0){$0+max(0,$1.upperBound-$1.lowerBound)}) }
}

public struct InventoryLot: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var material:String
    public var lotID:String
    public var location:String
    public var onHand:Double
    public var reserved:Double
    public var unit:String
    public var unitCost:Double
    public var disposition:InventoryDisposition
    public init(id:String=UUID().uuidString,material:String,lotID:String,location:String="WH-A",onHand:Double,reserved:Double=0,unit:String="ea",unitCost:Double=0,disposition:InventoryDisposition = .available){self.id=id;self.material=material;self.lotID=lotID;self.location=location;self.onHand=max(0,onHand);self.reserved=max(0,reserved);self.unit=unit;self.unitCost=max(0,unitCost);self.disposition=disposition}
    public var available:Double { disposition == .available || disposition == .reserved ? max(0,onHand-reserved) : 0 }
}

public struct MaterialRequirement: Identifiable, Codable, Equatable, Sendable {
    public var id:String { material }
    public var material:String
    public var quantityPerUnit:Double
    public var unit:String
    public init(_ material:String,quantityPerUnit:Double,unit:String="ea"){self.material=material;self.quantityPerUnit=max(0,quantityPerUnit);self.unit=unit}
}

public struct MaterialReservation: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var orderID:String
    public var inventoryLotID:String
    public var material:String
    public var quantity:Double
    public var consumed:Double
    public init(orderID:String,inventoryLotID:String,material:String,quantity:Double,consumed:Double=0){self.orderID=orderID;self.inventoryLotID=inventoryLotID;self.material=material;self.quantity=quantity;self.consumed=consumed}
}

public struct FiniteCapacityScheduleItem: Identifiable, Codable, Equatable, Sendable {
    public var id:String { orderID }
    public var orderID:String
    public var sku:String
    public var plannedStart:Double
    public var plannedFinish:Double
    public var estimatedRunSeconds:Double
    public var setupSeconds:Double
    public var lateBySeconds:Double
}

public struct ElectronicBatchEvent: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var type:String
    public var detail:String
    public var entityIDs:[String]
    public var lotIDs:[String]
    public var user:String?
    public init(timestamp:Double,type:String,detail:String,entityIDs:[String]=[],lotIDs:[String]=[],user:String?=nil){self.timestamp=timestamp;self.type=type;self.detail=detail;self.entityIDs=entityIDs;self.lotIDs=lotIDs;self.user=user}
}

public struct ElectronicBatchRecord: Identifiable, Codable, Equatable, Sendable {
    public var id:String { orderID }
    public var orderID:String
    public var sku:String
    public var recipeID:String?
    public var inputLots:[String]
    public var outputEntityIDs:[String]
    public var events:[ElectronicBatchEvent]
    public var releasedBy:String?
    public var complete:Bool
    public init(orderID:String,sku:String,recipeID:String?=nil,inputLots:[String]=[],outputEntityIDs:[String]=[],events:[ElectronicBatchEvent]=[],releasedBy:String?=nil,complete:Bool=false){self.orderID=orderID;self.sku=sku;self.recipeID=recipeID;self.inputLots=inputLots;self.outputEntityIDs=outputEntityIDs;self.events=events;self.releasedBy=releasedBy;self.complete=complete}
}

public struct OperatorAction: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var operatorName:String
    public var kind:OperatorActionKind
    public var detail:String
    public var orderID:String?
    public init(timestamp:Double,operatorName:String,kind:OperatorActionKind,detail:String,orderID:String?=nil){self.timestamp=timestamp;self.operatorName=operatorName;self.kind=kind;self.detail=detail;self.orderID=orderID}
}

public struct DowntimeEvent: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var machine:PlayableMachineKind?
    public var startedAt:Double
    public var endedAt:Double?
    public var reason:DowntimeReasonCode
    public var detail:String
    public var acknowledged:Bool
    public var costPerMinute:Double
    public init(machine:PlayableMachineKind?=nil,startedAt:Double,reason:DowntimeReasonCode,detail:String,costPerMinute:Double=75,acknowledged:Bool=false){self.machine=machine;self.startedAt=startedAt;self.reason=reason;self.detail=detail;self.costPerMinute=costPerMinute;self.acknowledged=acknowledged}
    public func duration(at time:Double)->Double { max(0,(endedAt ?? time)-startedAt) }
}

public struct AndonEvent: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var machine:PlayableMachineKind?
    public var raisedAt:Double
    public var severity:AndonSeverity
    public var message:String
    public var acknowledgedAt:Double?
    public var escalatedAt:Double?
    public var clearedAt:Double?
    public init(machine:PlayableMachineKind?=nil,raisedAt:Double,severity:AndonSeverity,message:String){self.machine=machine;self.raisedAt=raisedAt;self.severity=severity;self.message=message}
    public var active:Bool { clearedAt == nil }
}

public struct MaintenanceCall: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var machine:PlayableMachineKind?
    public var requestedAt:Double
    public var priority:MaintenancePriority
    public var problem:String
    public var assignedTo:String?
    public var arrivedAt:Double?
    public var completedAt:Double?
    public var workOrder:String
    public init(machine:PlayableMachineKind?=nil,requestedAt:Double,priority:MaintenancePriority,problem:String,assignedTo:String?=nil,workOrder:String=""){self.machine=machine;self.requestedAt=requestedAt;self.priority=priority;self.problem=problem;self.assignedTo=assignedTo;self.workOrder=workOrder.isEmpty ? "MWO-\(Int(requestedAt))" : workOrder}
}

public struct ProductionCostLedger: Codable, Equatable, Sendable {
    public var scrapCost:Double=0
    public var downtimeCost:Double=0
    public var materialCost:Double=0
    public var maintenanceCost:Double=0
    public var goodUnits:Int=0
    public var scrapUnits:Int=0
    public var totalCost:Double { scrapCost+downtimeCost+materialCost+maintenanceCost }
    public var costPerGoodUnit:Double { goodUnits > 0 ? totalCost/Double(goodUnits) : totalCost }
}


public enum ShiftDisturbanceDomain: String, Codable, CaseIterable, Sendable { case outputPath, inputPath, qualityHold }

public struct ScheduledShiftDisturbance: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var triggerAt:Double
    public var machine:PlayableMachineKind
    public var domain:ShiftDisturbanceDomain
    public var outputFault:OutputPathFaultKind?
    public var inputFault:MachineFieldFaultKind?
    public var target:String?
    public var magnitude:Double
    public var message:String
    public var applied:Bool
    public init(id:String=UUID().uuidString,triggerAt:Double,machine:PlayableMachineKind,outputFault:OutputPathFaultKind,target:String?=nil,magnitude:Double=0,message:String){self.id=id;self.triggerAt=triggerAt;self.machine=machine;self.domain = .outputPath;self.outputFault=outputFault;self.inputFault=nil;self.target=target;self.magnitude=magnitude;self.message=message;self.applied=false}
    public init(id:String=UUID().uuidString,triggerAt:Double,machine:PlayableMachineKind,inputFault:MachineFieldFaultKind,target:String?=nil,magnitude:Double=0,message:String){self.id=id;self.triggerAt=triggerAt;self.machine=machine;self.domain = .inputPath;self.outputFault=nil;self.inputFault=inputFault;self.target=target;self.magnitude=magnitude;self.message=message;self.applied=false}
    public init(id:String=UUID().uuidString,triggerAt:Double,machine:PlayableMachineKind,qualityHoldMessage:String){self.id=id;self.triggerAt=triggerAt;self.machine=machine;self.domain = .qualityHold;self.outputFault=nil;self.inputFault=nil;self.target=nil;self.magnitude=0;self.message=qualityHoldMessage;self.applied=false}
}

public struct ManufacturingExecutionSnapshot: Sendable {
    public var elapsedSeconds:Double
    public var shiftName:String?
    public var activeOrder:ProductionOrder?
    public var orders:[ProductionOrder]
    public var schedule:[FiniteCapacityScheduleItem]
    public var inventory:[InventoryLot]
    public var line:ProductionIntelligenceSnapshot
    public var openDowntime:[DowntimeEvent]
    public var activeAndons:[AndonEvent]
    public var maintenanceCalls:[MaintenanceCall]
    public var costs:ProductionCostLedger
    public var scheduleAttainment:Double
    public var taktActualSeconds:Double?
}

public enum ManufacturingExecutionError: Error, Equatable, Sendable { case unknownOrder(String), insufficientMaterial(String), noShiftSchedule, invalidQuantity }

public struct ManufacturingExecutionRuntime: Sendable {
    public var line:ProductionIntelligenceRuntime
    public var orders:[ProductionOrder]=[]
    public var demand:[SKUDemand]=[]
    public var shifts:[ShiftSchedule]=[]
    public var inventory:[InventoryLot]=[]
    public var requirementsBySKU:[String:[MaterialRequirement]]=[:]
    public var reservations:[MaterialReservation]=[]
    public var schedule:[FiniteCapacityScheduleItem]=[]
    public var batchRecords:[String:ElectronicBatchRecord]=[:]
    public var operatorActions:[OperatorAction]=[]
    public var downtime:[DowntimeEvent]=[]
    public var andons:[AndonEvent]=[]
    public var maintenanceCalls:[MaintenanceCall]=[]
    public var disturbances:[ScheduledShiftDisturbance]=[]
    public var costs=ProductionCostLedger()
    public var dispatchRule:DispatchRule = .earliestDueDate
    public var elapsedSeconds:Double=0
    public var currentOperator:String="Learner"
    public var downtimeEscalationSeconds:Double=60
    public var automaticMaintenanceEscalationSeconds:Double=180
    private var creditedFinishedIDs:Set<String>=[]
    private var creditedRejectIDs:Set<String>=[]
    private var activeDowntimeByMachine:[PlayableMachineKind:String]=[:]
    private var manualDowntimeMachines:Set<PlayableMachineKind>=[]
    private var lastGoodCompletionAt:Double?
    private var lastCompletedSKU:String?

    public init(project:LineBuilderProject) throws { self.line=try ProductionIntelligenceRuntime(project:project) }
    public init(line:ProductionIntelligenceRuntime){self.line=line}

    public mutating func seedTrainingWarehouse() {
        let materials=Set(orders.flatMap{requirementsBySKU[$0.sku] ?? []}.map(\.material))
        for (i,m) in materials.sorted().enumerated() where !inventory.contains(where:{$0.material==m}) { inventory.append(.init(material:m,lotID:"LOT-\(m.prefix(8).uppercased())-\(i+1)",onHand:10_000,unitCost:1.25+Double(i)*0.2)) }
    }

    public mutating func addOrder(_ order:ProductionOrder){orders.append(order);rebuildSchedule()}
    public mutating func registerBOM(sku:String,requirements:[MaterialRequirement]){requirementsBySKU[sku]=requirements}
    public mutating func addInventory(_ lot:InventoryLot){inventory.append(lot)}
    public mutating func addShift(_ shift:ShiftSchedule){shifts.append(shift);shifts.sort{$0.startAt<$1.startAt};rebuildSchedule()}
    public mutating func addDemand(_ item:SKUDemand){demand.append(item)}

    public mutating func releaseOrder(_ id:String,by operatorName:String?=nil)throws {
        guard let i=orders.firstIndex(where:{$0.id==id}) else { throw ManufacturingExecutionError.unknownOrder(id) }
        guard orders[i].quantity > 0 else { throw ManufacturingExecutionError.invalidQuantity }
        guard orders[i].status == .planned else { return }
        let needed=requirementsBySKU[orders[i].sku] ?? []
        var proposed:[MaterialReservation]=[]
        for req in needed {
            var remaining=req.quantityPerUnit*Double(orders[i].quantity)
            let candidates=inventory.indices.filter{inventory[$0].material==req.material && inventory[$0].available>0}.sorted{inventory[$0].lotID<inventory[$1].lotID}
            for idx in candidates where remaining > 0 { let q=min(remaining,inventory[idx].available);proposed.append(.init(orderID:id,inventoryLotID:inventory[idx].id,material:req.material,quantity:q));remaining -= q }
            if remaining > 0.0001 { throw ManufacturingExecutionError.insufficientMaterial(req.material) }
        }
        for r in proposed { if let idx=inventory.firstIndex(where:{$0.id==r.inventoryLotID}){inventory[idx].reserved += r.quantity;inventory[idx].disposition = .reserved} }
        reservations.append(contentsOf:proposed);orders[i].status = .released;orders[i].releasedAt=elapsedSeconds
        let lots=proposed.compactMap{r in inventory.first(where:{$0.id==r.inventoryLotID})?.lotID}
        batchRecords[id] = .init(orderID:id,sku:orders[i].sku,recipeID:orders[i].recipeID,inputLots:lots,events:[.init(timestamp:elapsedSeconds,type:"OrderReleased",detail:"Material reserved and order released",lotIDs:lots,user:operatorName ?? currentOperator)],releasedBy:operatorName ?? currentOperator)
        operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:operatorName ?? currentOperator,kind:.startOrder,detail:"Released \(id)",orderID:id));rebuildSchedule()
    }

    public mutating func pauseOrder(_ id:String){guard let i=orders.firstIndex(where:{$0.id==id}),orders[i].status == .running else{return};orders[i].status = .held;operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:currentOperator,kind:.pauseOrder,detail:"Paused order",orderID:id))}
    public mutating func resumeOrder(_ id:String){guard let i=orders.firstIndex(where:{$0.id==id}),orders[i].status == .held else{return};orders[i].status = .released;operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:currentOperator,kind:.resumeOrder,detail:"Resumed order",orderID:id))}

    public mutating func cycle(elapsedMilliseconds:Int32=100)throws->ManufacturingExecutionSnapshot {
        let dt=Double(elapsedMilliseconds)/1000;elapsedSeconds += dt
        let scheduled=currentShift()?.isScheduled(at:elapsedSeconds) ?? shifts.isEmpty
        dispatchIfNeeded(scheduled:scheduled)
        applyScheduledDisturbances()
        gateSourceMachines(allow:scheduled && activeOrderIndex() != nil)
        let lineSnapshot=try line.cycle(elapsedMilliseconds:elapsedMilliseconds)
        creditFinishedGoods();creditRejects();updateAutomaticDowntime(lineSnapshot,dt:dt,scheduled:scheduled);updateAndonEscalation();finishOrderIfNeeded();rebuildSchedule()
        let active=activeOrderIndex().map{orders[$0]}
        let planned=orders.filter{$0.status != .cancelled}.reduce(0){$0+$1.quantity},done: Int=orders.reduce(0){$0+$1.completedQuantity}
        let attainment=planned > 0 ? Double(done)/Double(planned) : 0
        return .init(elapsedSeconds:elapsedSeconds,shiftName:currentShift()?.name,activeOrder:active,orders:orders,schedule:schedule,inventory:inventory,line:lineSnapshot,openDowntime:downtime.filter{$0.endedAt==nil},activeAndons:andons.filter(\.active),maintenanceCalls:maintenanceCalls,costs:costs,scheduleAttainment:attainment,taktActualSeconds:actualTakt())
    }

    public mutating func run(seconds:Double,stepMilliseconds:Int32=100)throws->ManufacturingExecutionSnapshot { var result:ManufacturingExecutionSnapshot?;let n=max(1,Int(seconds*1000/Double(stepMilliseconds)));for _ in 0..<n{result=try cycle(elapsedMilliseconds:stepMilliseconds)};return result! }

    public mutating func assignDowntimeReason(eventID:String,reason:DowntimeReasonCode,by:String?=nil){guard let i=downtime.firstIndex(where:{$0.id==eventID})else{return};downtime[i].reason=reason;downtime[i].acknowledged=true;operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:by ?? currentOperator,kind:.assignDowntimeCode,detail:"\(reason.rawValue): \(downtime[i].detail)"))}
    public mutating func acknowledgeAndon(_ id:String,by:String?=nil){guard let i=andons.firstIndex(where:{$0.id==id})else{return};andons[i].acknowledgedAt=elapsedSeconds;operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:by ?? currentOperator,kind:.acknowledgeAndon,detail:andons[i].message))}
    @discardableResult public mutating func requestMaintenance(machine:PlayableMachineKind?,priority:MaintenancePriority,problem:String)->MaintenanceCall { let call=MaintenanceCall(machine:machine,requestedAt:elapsedSeconds,priority:priority,problem:problem);maintenanceCalls.append(call);operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:currentOperator,kind:.requestMaintenance,detail:problem));return call }
    public mutating func completeMaintenance(_ id:String,cost:Double=0){guard let i=maintenanceCalls.firstIndex(where:{$0.id==id})else{return};maintenanceCalls[i].completedAt=elapsedSeconds;costs.maintenanceCost += max(0,cost)}
    @discardableResult public mutating func reportDowntime(machine:PlayableMachineKind,reason:DowntimeReasonCode,detail:String)->DowntimeEvent { manualDowntimeMachines.insert(machine);startDowntime(machine:machine,reason:reason,detail:detail);return downtime.first(where:{$0.id == activeDowntimeByMachine[machine]})! }
    public mutating func clearDowntime(machine:PlayableMachineKind){manualDowntimeMachines.remove(machine);endDowntime(machine:machine)}
    public mutating func approveFirstPieceForLine(){for node in line.project.nodes{line.approveFirstPiece(nodeID:node.id)};operatorActions.append(.init(timestamp:elapsedSeconds,operatorName:currentOperator,kind:.approveFirstPiece,detail:"Approved first piece for active line changeover",orderID:activeOrderIndex().map{orders[$0].id}))}
    public mutating func scheduleDisturbance(_ disturbance:ScheduledShiftDisturbance){disturbances.append(disturbance);disturbances.sort{$0.triggerAt<$1.triggerAt}}

    public mutating func rebuildSchedule(){
        var cursor=max(elapsedSeconds,currentShift()?.startAt ?? elapsedSeconds),lastSKU:String?
        let candidates=orders.filter{[.planned,.released,.running,.held].contains($0.status)}.sorted(by:dispatchComparator)
        schedule=candidates.map{order in let setup=lastSKU == nil || lastSKU == order.sku ? 0 : 300;let bottleneck=max(0.05,line.project.nodes.map{MachineMaterialFlowLibrary.profile($0.machine).nominalFeedInterval}.max() ?? 1);let run=Double(order.remaining)*bottleneck;let start=cursor+Double(setup);let finish=start+run;cursor=finish;lastSKU=order.sku;return .init(orderID:order.id,sku:order.sku,plannedStart:start,plannedFinish:finish,estimatedRunSeconds:run,setupSeconds:Double(setup),lateBySeconds:max(0,finish-order.dueAt))}
    }

    public func taktTarget(for demand:SKUDemand,shift:ShiftSchedule)->Double { shift.scheduledSeconds/Double(max(1,demand.quantity)) }

    private mutating func applyScheduledDisturbances(){
        for i in disturbances.indices where !disturbances[i].applied && disturbances[i].triggerAt <= elapsedSeconds {
            guard let node=line.project.nodes.first(where:{$0.machine==disturbances[i].machine}),var machine=line.machines[node.id] else{disturbances[i].applied=true;continue}
            switch disturbances[i].domain {
            case .outputPath:
                if let kind=disturbances[i].outputFault { let target=disturbances[i].target ?? ClosedLoopPlantRuntime.outputPaths(for:machine.executable).first?.commandTag ?? machine.executable.sourceProject.drives.first?.tag ?? "";if !target.isEmpty{machine.injectOutputFault(.init(target:target,kind:kind,magnitude:disturbances[i].magnitude))} }
            case .inputPath:
                if let kind=disturbances[i].inputFault { let target=disturbances[i].target ?? machine.executable.bindings.first(where:{$0.direction == .input})?.ioTag ?? "";if !target.isEmpty{machine.injectInputFault(.init(target:target,kind:kind,magnitude:disturbances[i].magnitude))} }
            case .qualityHold:
                if let entity=line.genealogy.values.first(where:{$0.events.contains(where:{$0.machine==disturbances[i].machine})}) { _ = line.placeHold(entityIDs:[entity.id],reason:disturbances[i].message) }
            }
            line.machines[node.id]=machine;disturbances[i].applied=true
            if let oi=activeOrderIndex(){batchRecords[orders[oi].id]?.events.append(.init(timestamp:elapsedSeconds,type:"ProductionException",detail:disturbances[i].message))}
        }
    }

    private mutating func dispatchIfNeeded(scheduled:Bool){guard scheduled else{return};if activeOrderIndex() != nil{return};let candidates=orders.indices.filter{orders[$0].status == .released};guard let idx=candidates.sorted(by:{dispatchComparator(orders[$0],orders[$1])}).first else{return};orders[idx].status = .running;if orders[idx].startedAt == nil{orders[idx].startedAt=elapsedSeconds};if let previous=lastCompletedSKU,previous != orders[idx].sku { for node in line.project.nodes { line.beginChangeover(nodeID:node.id,toSKU:orders[idx].sku,targetSeconds:300) };batchRecords[orders[idx].id]?.events.append(.init(timestamp:elapsedSeconds,type:"ChangeoverStarted",detail:"SKU \(previous) → \(orders[idx].sku)",user:currentOperator)) };if let recipe=orders[idx].recipeID { for node in line.project.nodes{line.setRecipe(recipe,on:node.id)} };batchRecords[orders[idx].id]?.events.append(.init(timestamp:elapsedSeconds,type:"OrderStarted",detail:"Dispatched by \(dispatchRule.rawValue)",user:currentOperator))}
    private func activeOrderIndex()->Int?{orders.firstIndex(where:{$0.status == .running})}
    private func currentShift()->ShiftSchedule?{shifts.first(where:{$0.isScheduled(at:elapsedSeconds)}) ?? (shifts.isEmpty ? nil : shifts.first(where:{$0.startAt <= elapsedSeconds && elapsedSeconds < $0.endAt}))}
    private func dispatchComparator(_ a:ProductionOrder,_ b:ProductionOrder)->Bool { switch dispatchRule { case .fifo:return (a.releasedAt ?? .greatestFiniteMagnitude) < (b.releasedAt ?? .greatestFiniteMagnitude);case .earliestDueDate:return a.dueAt < b.dueAt;case .highestPriority:return a.priority > b.priority;case .shortestProcessingTime:return a.remaining < b.remaining;case .criticalRatio:let ar=max(0,a.dueAt-elapsedSeconds)/Double(max(1,a.remaining)),br=max(0,b.dueAt-elapsedSeconds)/Double(max(1,b.remaining));return ar<br } }
    private mutating func gateSourceMachines(allow:Bool){let receiving=Set(line.project.connections.map(\.toNodeID));for node in line.project.nodes where !receiving.contains(node.id){line.machines[node.id]?.materialFlow.externalFeedEnabled=allow}}

    private mutating func creditFinishedGoods(){guard let oi=activeOrderIndex() else{return};let terminal=Set(line.project.nodes.map(\.id)).subtracting(Set(line.project.connections.map(\.fromNodeID)))
        for nodeID in terminal { guard var machine=line.machines[nodeID] else{continue};for idx in machine.materialFlow.completed.indices { let id=machine.materialFlow.completed[idx].id;guard orders[oi].completedQuantity < orders[oi].quantity else{break};guard creditedFinishedIDs.insert(id).inserted else{continue};machine.materialFlow.completed[idx].labels["productionOrder"]=orders[oi].id;machine.materialFlow.completed[idx].labels["sku"]=orders[oi].sku;orders[oi].completedQuantity += 1;costs.goodUnits += 1;lastGoodCompletionAt=elapsedSeconds;batchRecords[orders[oi].id]?.outputEntityIDs.append(id);batchRecords[orders[oi].id]?.events.append(.init(timestamp:elapsedSeconds,type:"FinishedGood",detail:"Completed \(id)",entityIDs:[id]));let fgLot="FG-\(orders[oi].id)";if let fi=inventory.firstIndex(where:{$0.lotID==fgLot}){inventory[fi].onHand += 1}else{inventory.append(.init(material:orders[oi].sku,lotID:fgLot,location:"FG",onHand:1,unit:"ea",unitCost:0,disposition:.finishedGoods))};consumeReservation(orderIndex:oi,units:1)};line.machines[nodeID]=machine }
    }
    private mutating func creditRejects(){guard let oi=activeOrderIndex() else{return};for reject in line.rejects where creditedRejectIDs.insert(reject.id).inserted { orders[oi].scrapQuantity += 1;costs.scrapUnits += 1;let unitMaterialCost=requirementsBySKU[orders[oi].sku]?.reduce(0){sum,req in sum+req.quantityPerUnit*(inventory.first(where:{$0.material==req.material})?.unitCost ?? 0)} ?? 5;costs.scrapCost += unitMaterialCost;batchRecords[orders[oi].id]?.events.append(.init(timestamp:elapsedSeconds,type:"Reject",detail:reject.reason,entityIDs:[reject.entityID])) }}
    private mutating func consumeReservation(orderIndex:Int,units:Int){let reqs=requirementsBySKU[orders[orderIndex].sku] ?? [];for req in reqs { var needed=req.quantityPerUnit*Double(units);for ri in reservations.indices where reservations[ri].orderID==orders[orderIndex].id && reservations[ri].material==req.material && needed>0 { let available=reservations[ri].quantity-reservations[ri].consumed;let q=min(needed,available);reservations[ri].consumed += q;needed -= q;if let ii=inventory.firstIndex(where:{$0.id==reservations[ri].inventoryLotID}){inventory[ii].onHand=max(0,inventory[ii].onHand-q);inventory[ii].reserved=max(0,inventory[ii].reserved-q);costs.materialCost += q*inventory[ii].unitCost;if inventory[ii].reserved == 0 && inventory[ii].onHand > 0{inventory[ii].disposition = .available}} } } }

    private mutating func updateAutomaticDowntime(_ snapshot:ProductionIntelligenceSnapshot,dt:Double,scheduled:Bool){guard scheduled else{return};var affected=Set<PlayableMachineKind>()
        for node in line.project.nodes { if let cycle = line.machines[node.id]?.latestCycle, cycle.jammed || cycle.collisionInterlock { affected.insert(node.machine);startDowntime(machine:node.machine,reason:cycle.collisionInterlock ? .safetyStop:.mechanicalFault,detail:cycle.collisionInterlock ? "Collision/interlock active":"Machine cycle jammed") } }
        for h in snapshot.handshakes.values { if h.upstreamState == .blocked { affected.insert(h.upstream);startDowntime(machine:h.upstream,reason:.blocked,detail:h.reason ?? "Downstream blocked") };if h.downstreamState == .starved { affected.insert(h.downstream);startDowntime(machine:h.downstream,reason:.starved,detail:h.reason ?? "Upstream starved") } }
        for node in line.project.nodes { if let c=line.changeovers[node.id],c.phase != .complete { affected.insert(node.machine);startDowntime(machine:node.machine,reason:.changeover,detail:"SKU changeover: \(c.phase.rawValue)") } }
        for machine in Array(activeDowntimeByMachine.keys) where !affected.contains(machine) && !manualDowntimeMachines.contains(machine){endDowntime(machine:machine)}
        for i in downtime.indices where downtime[i].endedAt == nil { costs.downtimeCost += downtime[i].costPerMinute*dt/60 }
    }
    private mutating func startDowntime(machine:PlayableMachineKind,reason:DowntimeReasonCode,detail:String){guard activeDowntimeByMachine[machine] == nil else{return};let e=DowntimeEvent(machine:machine,startedAt:elapsedSeconds,reason:reason,detail:detail);downtime.append(e);activeDowntimeByMachine[machine]=e.id;andons.append(.init(machine:machine,raisedAt:elapsedSeconds,severity:reason == .safetyStop ? .critical:.lineStop,message:"\(machine.rawValue): \(detail)"))}
    private mutating func endDowntime(machine:PlayableMachineKind){guard let id=activeDowntimeByMachine.removeValue(forKey:machine),let i=downtime.firstIndex(where:{$0.id==id})else{return};downtime[i].endedAt=elapsedSeconds;for j in andons.indices where andons[j].machine==machine && andons[j].clearedAt==nil{andons[j].clearedAt=elapsedSeconds}}
    private mutating func updateAndonEscalation(){for i in andons.indices where andons[i].active { let age=elapsedSeconds-andons[i].raisedAt;if age>=downtimeEscalationSeconds && andons[i].escalatedAt==nil{andons[i].escalatedAt=elapsedSeconds;if andons[i].severity < .critical{andons[i].severity = .critical}};if age>=automaticMaintenanceEscalationSeconds && !maintenanceCalls.contains(where:{$0.machine==andons[i].machine && $0.completedAt==nil}){_ = requestMaintenance(machine:andons[i].machine,priority:.emergency,problem:andons[i].message)} }}
    private mutating func finishOrderIfNeeded(){guard let i=activeOrderIndex(),orders[i].completedQuantity>=orders[i].quantity else{return};orders[i].status = .complete;orders[i].completedAt=elapsedSeconds;lastCompletedSKU=orders[i].sku;batchRecords[orders[i].id]?.complete=true;batchRecords[orders[i].id]?.events.append(.init(timestamp:elapsedSeconds,type:"OrderComplete",detail:"Produced \(orders[i].completedQuantity) good, \(orders[i].scrapQuantity) scrap",user:currentOperator));releaseUnusedReservations(orderID:orders[i].id)}
    private mutating func releaseUnusedReservations(orderID:String){for ri in reservations.indices where reservations[ri].orderID==orderID { let remaining=max(0,reservations[ri].quantity-reservations[ri].consumed);if let ii=inventory.firstIndex(where:{$0.id==reservations[ri].inventoryLotID}){inventory[ii].reserved=max(0,inventory[ii].reserved-remaining);if inventory[ii].reserved==0 && inventory[ii].onHand>0{inventory[ii].disposition = .available}};reservations[ri].quantity=reservations[ri].consumed}}
    private func actualTakt()->Double?{guard costs.goodUnits>1,let first=orders.compactMap(\.startedAt).min(),elapsedSeconds>first else{return nil};return (elapsedSeconds-first)/Double(costs.goodUnits)}
}

public enum ManufacturingExecutionTemplates {
    public static func trainingRuntime(project:LineBuilderProject = ProductionLineTemplates.beverageLine)throws->ManufacturingExecutionRuntime { var r=try ManufacturingExecutionRuntime(project:project);r.addShift(.init(name:"Day Shift",startAt:0,endAt:28_800,plannedBreaks:[7200...8100,14_400...16_200,21_600...22_500],crew:"A Crew"));r.registerBOM(sku:"SKU-A",requirements:[.init("Base Material",quantityPerUnit:1),.init("Packaging",quantityPerUnit:1)]);r.registerBOM(sku:"SKU-B",requirements:[.init("Base Material",quantityPerUnit:1.1),.init("Packaging",quantityPerUnit:1)]);r.addInventory(.init(material:"Base Material",lotID:"RM-BASE-260902",onHand:5000,unitCost:0.85));r.addInventory(.init(material:"Packaging",lotID:"PKG-260902",onHand:5000,unitCost:0.22));r.addOrder(.init(id:"PO-1001",sku:"SKU-A",quantity:120,dueAt:10_800,priority:70,taktTargetSeconds:60));r.addOrder(.init(id:"PO-1002",sku:"SKU-B",quantity:80,dueAt:21_600,priority:50,taktTargetSeconds:75));r.addDemand(.init(sku:"SKU-A",quantity:120,dueAt:10_800,customer:"Customer A",priority:70));r.addDemand(.init(sku:"SKU-B",quantity:80,dueAt:21_600,customer:"Customer B",priority:50));if let first=project.nodes.first?.machine{r.scheduleDisturbance(.init(triggerAt:1800,machine:first,outputFault:.brokenFieldWire,message:"Intermittent production stop develops during the shift"))};if let second=project.nodes.dropFirst().first?.machine{r.scheduleDisturbance(.init(triggerAt:5400,machine:second,inputFault:.analogDrift,magnitude:8,message:"Process measurement begins drifting"))};return r }
}
