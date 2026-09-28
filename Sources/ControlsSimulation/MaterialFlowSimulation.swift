import Foundation

public enum MaterialEntityKind: String, Codable, CaseIterable, Sendable {
    case carton, bottle, caseUnit, pallet, liquidBatch, parcel, moldedPart, pasteurizedUnit, batteryCell
    case bulkLot, carrier, conditionedStream, gasUtility, processBatch, genericUnit
}

public enum MaterialDisposition: String, Codable, CaseIterable, Sendable {
    case inProcess, good, rework, scrap, held
}

public struct MaterialResidenceSample: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var zoneID: String
    public var enteredAt: Double
    public var exitedAt: Double?
    public var temperatureC: Double?
    public var pressurePSI: Double?
    public init(zoneID: String, enteredAt: Double, exitedAt: Double? = nil, temperatureC: Double? = nil, pressurePSI: Double? = nil) {
        self.zoneID = zoneID; self.enteredAt = enteredAt; self.exitedAt = exitedAt; self.temperatureC = temperatureC; self.pressurePSI = pressurePSI
    }
}

public struct MaterialQualityRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var metric: String
    public var value: Double
    public var target: Double
    public var tolerance: Double
    public var unit: String
    public var passed: Bool
    public init(metric: String, value: Double, target: Double, tolerance: Double, unit: String) {
        self.metric=metric; self.value=value; self.target=target; self.tolerance=tolerance; self.unit=unit; self.passed=abs(value-target) <= tolerance
    }
}

public struct MaterialEntity: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var serial: String
    public var kind: MaterialEntityKind
    public var zoneID: String
    public var progressInZone: Double
    public var createdAt: Double
    public var disposition: MaterialDisposition
    public var attributes: [String: Double]
    public var labels: [String: String]
    public var residenceHistory: [MaterialResidenceSample]
    public var quality: [MaterialQualityRecord]
    public var route: [String]
    public init(id: String, serial: String, kind: MaterialEntityKind, zoneID: String, createdAt: Double, attributes: [String: Double] = [:], labels: [String: String] = [:], route: [String] = []) {
        self.id=id; self.serial=serial; self.kind=kind; self.zoneID=zoneID; self.progressInZone=0; self.createdAt=createdAt; self.disposition = .inProcess; self.attributes=attributes; self.labels=labels; self.residenceHistory=[.init(zoneID: zoneID, enteredAt: createdAt)]; self.quality=[]; self.route=route
    }
}

public struct MaterialFlowZone: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var capacity: Int
    public var nominalTransitSeconds: Double
    public var allowsAccumulation: Bool
    public var qualityGate: Bool
    public init(_ id:String,_ name:String,capacity:Int,transit:Double,accumulation:Bool=true,qualityGate:Bool=false){self.id=id;self.name=name;self.capacity=capacity;self.nominalTransitSeconds=transit;self.allowsAccumulation=accumulation;self.qualityGate=qualityGate}
}

public struct MachineMaterialFlowProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { machine.rawValue }
    public var machine: PlayableMachineKind
    public var entityKind: MaterialEntityKind
    public var zones: [MaterialFlowZone]
    public var nominalFeedInterval: Double
    public var maximumWIP: Int
    public var supportsRework: Bool
    public var description: String
}

public enum MachineMaterialFlowLibrary {
    public static let all = PlayableMachineKind.allCases.map(profile)
    public static func profile(_ machine: PlayableMachineKind) -> MachineMaterialFlowProfile {
        func z(_ id:String,_ name:String,_ cap:Int,_ sec:Double,_ acc:Bool=true,_ q:Bool=false)->MaterialFlowZone{.init(id,name,capacity:cap,transit:sec,accumulation:acc,qualityGate:q)}
        switch machine {
        case .packagingCell: return .init(machine:machine,entityKind:.carton,zones:[z("INFEED","Infeed conveyor",6,1.2),z("INDEX","Index station",1,0.8,false),z("SEAL","Seal station",1,2.0,false,true),z("OUTFEED","Outfeed conveyor",8,1.0)],nominalFeedInterval:1.0,maximumWIP:16,supportsRework:true,description:"Multiple cartons accumulate, index, seal, verify, and discharge independently.")
        case .bottlingLine: return .init(machine:machine,entityKind:.bottle,zones:[z("INFEED","Bottle infeed",12,0.6),z("STARWHEEL","Starwheel pockets",8,0.8,false),z("FILLER","Filler carousel",12,2.4,false,true),z("CAPPER","Capper",6,1.0,false,true),z("INSPECT","Vision inspection",4,0.5,false,true),z("OUTFEED","Bottle outfeed",16,0.7)],nominalFeedInterval:0.35,maximumWIP:48,supportsRework:false,description:"Bottles occupy indexed pockets and retain fill/cap/inspection genealogy.")
        case .roboticPalletizer: return .init(machine:machine,entityKind:.caseUnit,zones:[z("CASE_QUEUE","Case queue",18,0.8),z("PICK","Robot pick",1,1.0,false),z("PLACE","Pallet placement",1,1.3,false),z("PALLET","Active pallet",48,0.2,true,true),z("EXIT","Completed pallet",2,2.0)],nominalFeedInterval:0.7,maximumWIP:52,supportsRework:true,description:"Cases build a row/column/layer pattern on a persistent pallet entity.")
        case .batchMixingTank, .bioreactor, .cipSkid: return .init(machine:machine,entityKind:.liquidBatch,zones:[z("RECIPE","Recipe staging",2,2),z("VESSEL","Process vessel",1,30,false,true),z("HOLD","Quality hold",2,5,true,true),z("TRANSFER","Transfer out",2,5)],nominalFeedInterval:42,maximumWIP:5,supportsRework:true,description:"Batches retain ingredient composition, recipe, process exposure and genealogy.")
        case .parcelSortation: return .init(machine:machine,entityKind:.parcel,zones:[z("INDUCT","Induction",8,0.7),z("SCAN","Barcode scan",2,0.4,false),z("SORTER","Sorter carrier",20,1.4,false),z("DIVERT","Destination divert",4,0.5,false,true),z("CHUTE","Destination chute",10,0.8)],nominalFeedInterval:0.45,maximumWIP:44,supportsRework:true,description:"Each parcel carries destination, scan confidence and actual divert route.")
        case .injectionMoldingCell: return .init(machine:machine,entityKind:.moldedPart,zones:[z("MOLD","Mold cavities",4,18,false,true),z("EJECT","Eject",4,1.0,false),z("COOL","Post-mold cooling",8,5),z("GAUGE","Dimensional gauge",2,1,false,true),z("BIN","Good/reject bin",20,0.2)],nominalFeedInterval:18,maximumWIP:28,supportsRework:false,description:"Individual cavity parts retain cavity number, dimensions, shot history and disposition.")
        case .htstPasteurizer: return .init(machine:machine,entityKind:.pasteurizedUnit,zones:[z("BALANCE","Balance tank",12,1),z("REGEN","Regeneration section",12,2),z("HEAT","Heating section",10,2,false),z("HOLD_TUBE","Holding tube",16,15,false,true),z("DIVERT","Flow diversion",6,1,false,true),z("COOL","Cooling section",12,3)],nominalFeedInterval:0.8,maximumWIP:58,supportsRework:true,description:"Every unit retains temperature-time residence history through the legal hold path.")
        case .batteryFormationLine: return .init(machine:machine,entityKind:.batteryCell,zones:[z("LOAD","Cell load",12,1),z("CONTACT","Formation contacts",8,1,false),z("CHARGE","Charge stage",8,12,false,true),z("REST","Rest",8,5),z("DISCHARGE","Discharge/test",8,10,false,true),z("GRADE","Grade and unload",8,1,false,true)],nominalFeedInterval:1.5,maximumWIP:44,supportsRework:true,description:"Each battery serial retains current/voltage/temperature curve summaries and grade.")
        case .asrsCrane: return .init(machine:machine,entityKind:.pallet,zones:[z("INBOUND","Inbound pallet",4,2),z("PICKUP","Crane pickup",1,2,false),z("TRAVEL","Crane travel",1,4,false),z("STORAGE","Storage slot",20,0.5,true,true)],nominalFeedInterval:5,maximumWIP:24,supportsRework:true,description:"Pallet identities retain assigned storage slot and motion history.")
        case .pressureSkid,.pumpStation,.wastewaterLiftStation,.reverseOsmosisPlant,.chilledWaterPlant,.dataCenterCooling: return .init(machine:machine,entityKind:.conditionedStream,zones:[z("SOURCE","Source/header",8,2),z("PROCESS","Pump/process path",6,5,false,true),z("DELIVERY","Delivery header",8,2)],nominalFeedInterval:2,maximumWIP:22,supportsRework:false,description:"Finite stream parcels retain pressure/flow exposure so hydraulic disturbances affect delivered quality.")
        case .industrialOven,.refrigerationRack,.airHandlingUnit,.cleanroomPressureSystem,.automotivePaintBooth,.boilerSteamPlant: return .init(machine:machine,entityKind:.genericUnit,zones:[z("INLET","Process inlet",8,2),z("CONDITION","Conditioning zone",8,8,false,true),z("HOLD","Residence/soak",8,6,false,true),z("OUTLET","Process outlet",8,2)],nominalFeedInterval:2.5,maximumWIP:28,supportsRework:true,description:"Individual process units retain thermal/environmental exposure and quality state.")
        case .servoConveyor,.cncCoolantCell: return .init(machine:machine,entityKind:.carrier,zones:[z("QUEUE","Input queue",8,1),z("ACTIVE","Active station",1,3,false,true),z("EXIT","Exit buffer",8,1)],nominalFeedInterval:1.2,maximumWIP:17,supportsRework:true,description:"Carriers retain station position, process exposure and timing history.")
        case .compressedAirPlant: return .init(machine:machine,entityKind:.gasUtility,zones:[z("INTAKE","Intake",8,2),z("COMPRESS","Compression",6,4,false,true),z("RECEIVER","Receiver",10,4),z("HEADER","Plant header",10,2)],nominalFeedInterval:1.5,maximumWIP:30,supportsRework:false,description:"Finite air parcels expose pressure generation, receiver accumulation and header starvation.")
        case .crusherConveyor,.grainElevator: return .init(machine:machine,entityKind:.bulkLot,zones:[z("FEED","Feed hopper",12,2),z("PROCESS","Crusher/elevator",5,5,false,true),z("TRANSFER","Transfer conveyor",10,3),z("DISCHARGE","Discharge",10,2)],nominalFeedInterval:1.4,maximumWIP:32,supportsRework:true,description:"Bulk lots accumulate and expose blockage, starvation and throughput loss.")
        }
    }
}

public struct MaterialFlowSnapshot: Codable, Equatable, Sendable {
    public var profile: MachineMaterialFlowProfile
    public var elapsedSeconds: Double
    public var entities: [MaterialEntity]
    public var completed: [MaterialEntity]
    public var scrapped: [MaterialEntity]
    public var rework: [MaterialEntity]
    public var starvation: Bool
    public var blockage: Bool
    public var zoneCounts: [String:Int]
    public var throughputPerMinute: Double
    public var oldestWIPSeconds: Double
}


public struct MaterialCompletionStamp: Codable, Equatable, Sendable {
    public var time: Double
    public var entityID: String
    public init(time: Double, entityID: String) { self.time = time; self.entityID = entityID }
}

public struct MachineMaterialFlowRuntime: Codable, Equatable, Sendable {
    public var profile: MachineMaterialFlowProfile
    public var elapsedSeconds: Double = 0
    public var nextSerial: Int = 1
    public var feedAccumulator: Double = 0
    public var entities: [MaterialEntity] = []
    public var completed: [MaterialEntity] = []
    public var scrapped: [MaterialEntity] = []
    public var rework: [MaterialEntity] = []
    public var externalFeedEnabled: Bool = true
    public var downstreamCapacityAvailable: Bool = true
    public var events: [MachineCycleEvent] = []
    private var completionsInWindow: [MaterialCompletionStamp] = []

    public init(machine:PlayableMachineKind){profile=MachineMaterialFlowLibrary.profile(machine)}

    @discardableResult public mutating func step(plant: ClosedLoopPlantSnapshot, cycle: AuthoredMachineCycleSnapshot, deltaTime: Double) -> MaterialFlowSnapshot {
        let dt=max(0.001,deltaTime); elapsedSeconds += dt; feedAccumulator += dt
        if externalFeedEnabled { feedIfPossible(cycle: cycle) }
        moveEntities(plant:plant,cycle:cycle,dt:dt)
        applyMachineSpecificState(plant:plant,cycle:cycle,dt:dt)
        completionsInWindow.removeAll{$0.time < elapsedSeconds-60}
        if completed.count > 60 { completed.removeFirst(completed.count-60) }
        if scrapped.count > 60 { scrapped.removeFirst(scrapped.count-60) }
        if rework.count > 60 { rework.removeFirst(rework.count-60) }
        let counts=Dictionary(grouping:entities,by:{$0.zoneID}).mapValues(\.count)
        let firstCap=profile.zones.first?.capacity ?? 1
        let starvation=(counts[profile.zones.first?.id ?? ""] ?? 0)==0 && entities.count < max(1,firstCap/2)
        let last=profile.zones.last; let blockage = !downstreamCapacityAvailable || (last.map{(counts[$0.id] ?? 0) >= $0.capacity} ?? false)
        let oldest=entities.map{elapsedSeconds-$0.createdAt}.max() ?? 0
        return .init(profile:profile,elapsedSeconds:elapsedSeconds,entities:entities,completed:completed,scrapped:scrapped,rework:rework,starvation:starvation,blockage:blockage,zoneCounts:counts,throughputPerMinute:Double(completionsInWindow.count),oldestWIPSeconds:oldest)
    }

    public mutating func enqueue(_ entity: MaterialEntity) -> Bool {
        guard let first=profile.zones.first, entities.filter({$0.zoneID==first.id}).count < first.capacity, entities.count < profile.maximumWIP else{return false}
        var e=entity; e.zoneID=first.id;e.progressInZone=0;e.residenceHistory.append(.init(zoneID:first.id,enteredAt:elapsedSeconds));entities.append(e);return true
    }

    public mutating func takeCompleted(limit:Int=1)->[MaterialEntity] {
        let n=min(limit,completed.count); guard n>0 else{return []}; let out=Array(completed.prefix(n));completed.removeFirst(n);return out
    }

    private mutating func feedIfPossible(cycle: AuthoredMachineCycleSnapshot) {
        guard feedAccumulator >= profile.nominalFeedInterval, let first=profile.zones.first else{return}
        let zoneCount=entities.filter{$0.zoneID==first.id}.count
        guard zoneCount < first.capacity, entities.count < profile.maximumWIP else{return}
        feedAccumulator=0
        let serial=nextSerial;nextSerial += 1
        entities.append(makeEntity(serial:serial,zone:first.id,cycle:cycle))
    }

    private func makeEntity(serial:Int,zone:String,cycle:AuthoredMachineCycleSnapshot)->MaterialEntity {
        let prefix=String(profile.machine.rawValue.prefix(4)).uppercased()
        var attrs:[String:Double]=[:], labels:[String:String]=[:]
        switch profile.machine {
        case .bottlingLine: attrs["fillerPocket"]=Double((serial-1)%12+1); attrs["fillPercent"]=0; labels["capLot"]="CAP-\((serial-1)/100+1)"
        case .roboticPalletizer: attrs["row"]=Double((serial-1)%4+1);attrs["column"]=Double(((serial-1)/4)%3+1);attrs["layer"]=Double(((serial-1)/12)%4+1);labels["pattern"]="4x3 interlocked"
        case .batchMixingTank,.bioreactor,.cipSkid: attrs["waterPct"]=65;attrs["ingredientAPct"]=20;attrs["ingredientBPct"]=15;labels["recipe"]="RCP-\((serial-1)%3+1)"
        case .parcelSortation: let dests=["A","B","C","D","E","F"];labels["destination"]=dests[(serial-1)%dests.count];attrs["scanConfidence"]=98
        case .injectionMoldingCell: attrs["cavity"]=Double((serial-1)%4+1);attrs["lengthMM"]=50;attrs["widthMM"]=24.0;attrs["massG"]=18.5
        case .htstPasteurizer: attrs["peakTempC"]=25;attrs["holdSecondsAboveTarget"]=0;labels["legalPath"]="pending"
        case .batteryFormationLine: attrs["capacityAh"]=0;attrs["peakTempC"]=25;attrs["voltageV"]=3.2;attrs["currentA"]=0;labels["grade"]="UNTESTED"
        case .asrsCrane: labels["storageSlot"]="R\((serial-1)%5+1)-C\(((serial-1)/5)%4+1)"
        default: break
        }
        return .init(id:"\(profile.machine.rawValue)-\(serial)",serial:"\(prefix)-\(String(format:"%05d",serial))",kind:profile.entityKind,zoneID:zone,createdAt:elapsedSeconds,attributes:attrs,labels:labels,route:profile.zones.map(\.id))
    }

    private mutating func moveEntities(plant:ClosedLoopPlantSnapshot,cycle:AuthoredMachineCycleSnapshot,dt:Double) {
        guard !profile.zones.isEmpty else{return}
        let speedFactor=max(0,min(1.25,(cycle.dynamics.motorSpeedPercent + cycle.phaseCompliance)/200))
        var i=entities.count-1
        while i>=0 && !entities.isEmpty {
            guard i < entities.count else { i-=1; continue }
            let zoneID=entities[i].zoneID; guard let zi=profile.zones.firstIndex(where:{$0.id==zoneID}) else{i-=1;continue}
            let zone=profile.zones[zi]
            let processFactor = cycle.jammed || cycle.collisionInterlock ? 0 : max(0.02,speedFactor)
            entities[i].progressInZone += dt/max(0.1,zone.nominalTransitSeconds)*100*processFactor
            if entities[i].progressInZone >= 100 {
                if zi == profile.zones.count-1 {
                    if downstreamCapacityAvailable { complete(index:i,cycle:cycle,plant:plant) }
                } else {
                    let next=profile.zones[zi+1]
                    let nextCount=entities.filter{$0.zoneID==next.id}.count
                    if nextCount < next.capacity {
                        if let h=entities[i].residenceHistory.indices.last { entities[i].residenceHistory[h].exitedAt=elapsedSeconds;entities[i].residenceHistory[h].temperatureC=cycle.dynamics.temperatureC;entities[i].residenceHistory[h].pressurePSI=cycle.dynamics.pumpHeadPSI }
                        entities[i].zoneID=next.id;entities[i].progressInZone=0;entities[i].residenceHistory.append(.init(zoneID:next.id,enteredAt:elapsedSeconds))
                    } else { entities[i].progressInZone=100 }
                }
            }
            i-=1
        }
    }

    private mutating func complete(index:Int,cycle:AuthoredMachineCycleSnapshot,plant:ClosedLoopPlantSnapshot) {
        var e=entities.remove(at:index)
        if let h=e.residenceHistory.indices.last { e.residenceHistory[h].exitedAt=elapsedSeconds;e.residenceHistory[h].temperatureC=cycle.dynamics.temperatureC;e.residenceHistory[h].pressurePSI=cycle.dynamics.pumpHeadPSI }
        let score=max(0,min(100,cycle.phaseCompliance - (cycle.jammed ? 45:0) - (cycle.collisionInterlock ? 55:0)))
        e.quality.append(.init(metric:"process compliance",value:score,target:95,tolerance:10,unit:"%"))
        if score>=85 {e.disposition = .good;completed.append(e);completionsInWindow.append(.init(time: elapsedSeconds, entityID: e.id))}
        else if score>=65 && profile.supportsRework {e.disposition = .rework;rework.append(e)}
        else {e.disposition = .scrap;scrapped.append(e)}
    }

    private mutating func applyMachineSpecificState(plant:ClosedLoopPlantSnapshot,cycle:AuthoredMachineCycleSnapshot,dt:Double) {
        for idx in entities.indices {
            switch profile.machine {
            case .bottlingLine:
                if entities[idx].zoneID=="FILLER" { entities[idx].attributes["fillPercent"] = min(100,(entities[idx].attributes["fillPercent"] ?? 0)+dt*45*max(0,cycle.dynamics.valvePositionPercent/100)) }
            case .roboticPalletizer:
                if entities[idx].zoneID=="PALLET" { entities[idx].labels["placement"]="L\(Int(entities[idx].attributes["layer"] ?? 1))-R\(Int(entities[idx].attributes["row"] ?? 1))-C\(Int(entities[idx].attributes["column"] ?? 1))" }
            case .batchMixingTank,.bioreactor,.cipSkid:
                if entities[idx].zoneID=="VESSEL" { entities[idx].attributes["mixednessPct"] = min(100,(entities[idx].attributes["mixednessPct"] ?? 0)+dt*max(0.5,cycle.dynamics.motorSpeedPercent/8));entities[idx].attributes["temperatureC"]=cycle.dynamics.temperatureC }
            case .parcelSortation:
                if entities[idx].zoneID=="DIVERT" { let desired=entities[idx].labels["destination"] ?? "A";let error=cycle.phaseCompliance<75;entities[idx].labels["actualDestination"]=error ? "MISROUTE":desired }
            case .injectionMoldingCell:
                if entities[idx].zoneID=="MOLD" { let thermalError=max(0,75-cycle.dynamics.temperatureC);entities[idx].attributes["lengthMM"]=50+thermalError*0.015;entities[idx].attributes["massG"]=18.5-max(0,70-cycle.phaseCompliance)*0.03 }
            case .htstPasteurizer:
                if entities[idx].zoneID=="HOLD_TUBE" { let t=cycle.dynamics.temperatureC;entities[idx].attributes["peakTempC"]=max(entities[idx].attributes["peakTempC"] ?? 0,t);if t>=72 {entities[idx].attributes["holdSecondsAboveTarget",default:0]+=dt};entities[idx].labels["legalPath"]=(entities[idx].attributes["holdSecondsAboveTarget"] ?? 0)>=15 ? "forward":"divert" }
            case .batteryFormationLine:
                let zone=entities[idx].zoneID
                if zone=="CHARGE" || zone=="DISCHARGE" { let pct=max(0,cycle.dynamics.pidResponsePercent);entities[idx].attributes["currentA"]=pct*0.05;entities[idx].attributes["voltageV"]=3.2+pct*0.012;entities[idx].attributes["peakTempC"]=max(entities[idx].attributes["peakTempC"] ?? 25,cycle.dynamics.temperatureC);entities[idx].attributes["capacityAh",default:0]+=dt*(entities[idx].attributes["currentA"] ?? 0)/3600 }
                if zone=="GRADE" { let cap=entities[idx].attributes["capacityAh"] ?? 0;entities[idx].labels["grade"]=cap>0.01 ? "A":"HOLD" }
            default: break
            }
        }
    }
}

public struct LineBuffer: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var upstream: PlayableMachineKind
    public var downstream: PlayableMachineKind
    public var capacity: Int
    public var entities: [MaterialEntity]
    public init(id:String,upstream:PlayableMachineKind,downstream:PlayableMachineKind,capacity:Int,entities:[MaterialEntity]=[]){self.id=id;self.upstream=upstream;self.downstream=downstream;self.capacity=capacity;self.entities=entities}
}

public struct ProductionLineSnapshot: Codable, Equatable, Sendable {
    public var machineSnapshots: [PlayableMachineKind: MaterialFlowSnapshot]
    public var buffers: [LineBuffer]
    public var starvedMachines: [PlayableMachineKind]
    public var blockedMachines: [PlayableMachineKind]
    public var totalWIP: Int
}

public struct ProductionLineRuntime: Codable, Equatable, Sendable {
    public var machineOrder: [PlayableMachineKind]
    public var materialFlows: [PlayableMachineKind:MachineMaterialFlowRuntime]
    public var buffers: [LineBuffer]
    public init(machines:[PlayableMachineKind],bufferCapacity:Int=8){
        self.machineOrder=machines;self.materialFlows=Dictionary(uniqueKeysWithValues:machines.map{($0,MachineMaterialFlowRuntime(machine:$0))});self.buffers=[]
        if machines.count>1 { for i in 0..<(machines.count-1){buffers.append(.init(id:"B\(i+1)",upstream:machines[i],downstream:machines[i+1],capacity:bufferCapacity))} }
    }

    public mutating func transferCompleted() {
        for i in buffers.indices {
            let up=buffers[i].upstream, down=buffers[i].downstream
            guard var upstream=materialFlows[up], var downstream=materialFlows[down] else{continue}
            let room=max(0,buffers[i].capacity-buffers[i].entities.count)
            if room>0 { buffers[i].entities.append(contentsOf:upstream.takeCompleted(limit:room)) }
            while !buffers[i].entities.isEmpty {
                var e=buffers[i].entities[0]
                e.labels["sourceMachine"]=up.rawValue
                if downstream.enqueue(e) { buffers[i].entities.removeFirst() } else { break }
            }
            upstream.downstreamCapacityAvailable=buffers[i].entities.count < buffers[i].capacity
            downstream.externalFeedEnabled = i==0 ? false : downstream.externalFeedEnabled
            materialFlows[up]=upstream;materialFlows[down]=downstream
        }
    }

    public func snapshot(_ latest:[PlayableMachineKind:MaterialFlowSnapshot])->ProductionLineSnapshot {
        let starved=latest.filter{$0.value.starvation}.map(\.key);let blocked=latest.filter{$0.value.blockage}.map(\.key)
        return .init(machineSnapshots:latest,buffers:buffers,starvedMachines:starved,blockedMachines:blocked,totalWIP:latest.values.reduce(0){$0+$1.entities.count}+buffers.reduce(0){$0+$1.entities.count})
    }
}

public struct IntegratedProductionLineSnapshot: Sendable {
    public var machineSnapshots: [PlayableMachineKind: FullyClosedLoopSnapshot]
    public var materialSnapshots: [PlayableMachineKind: MaterialFlowSnapshot]
    public var buffers: [LineBuffer]
    public var starvedMachines: [PlayableMachineKind]
    public var blockedMachines: [PlayableMachineKind]
    public var totalWIP: Int
}

public struct IntegratedProductionLineRuntime: Sendable {
    public var machineOrder: [PlayableMachineKind]
    public var machines: [PlayableMachineKind: FullyClosedLoopMachineRuntime]
    public var buffers: [LineBuffer]

    public init(machines machineOrder:[PlayableMachineKind], bufferCapacity:Int=8) throws {
        self.machineOrder=machineOrder
        self.machines=try Dictionary(uniqueKeysWithValues: machineOrder.map { ($0, try FullyClosedLoopMachineRuntime(machine:$0)) })
        self.buffers=[]
        if machineOrder.count>1 {
            for i in 0..<(machineOrder.count-1) { buffers.append(.init(id:"ILB\(i+1)",upstream:machineOrder[i],downstream:machineOrder[i+1],capacity:bufferCapacity)) }
            for i in 1..<machineOrder.count { self.machines[machineOrder[i]]?.materialFlow.externalFeedEnabled=false }
        }
    }

    @discardableResult public mutating func cycle(elapsedMilliseconds:Int32=100) throws -> IntegratedProductionLineSnapshot {
        var closed:[PlayableMachineKind:FullyClosedLoopSnapshot]=[:]
        for machine in machineOrder {
            guard var r=machines[machine] else{continue}
            closed[machine]=try r.cycle(elapsedMilliseconds:elapsedMilliseconds)
            machines[machine]=r
        }
        transferBetweenMachines()
        let material=Dictionary(uniqueKeysWithValues:machineOrder.compactMap { m -> (PlayableMachineKind,MaterialFlowSnapshot)? in
            guard let s=machines[m]?.latestMaterialFlow else{return nil};return (m,s)
        })
        let starved=material.filter{$0.value.starvation}.map(\.key)
        let blocked=material.filter{$0.value.blockage}.map(\.key)
        let total=material.values.reduce(0){$0+$1.entities.count}+buffers.reduce(0){$0+$1.entities.count}
        return .init(machineSnapshots:closed,materialSnapshots:material,buffers:buffers,starvedMachines:starved,blockedMachines:blocked,totalWIP:total)
    }

    public mutating func injectOutputFault(machine:PlayableMachineKind,_ fault:OutputPathFault){machines[machine]?.injectOutputFault(fault)}
    public mutating func injectInputFault(machine:PlayableMachineKind,_ fault:MachineFieldFault){machines[machine]?.injectInputFault(fault)}

    private mutating func transferBetweenMachines() {
        for i in buffers.indices {
            let up=buffers[i].upstream,down=buffers[i].downstream
            guard var u=machines[up], var d=machines[down] else{continue}
            let room=max(0,buffers[i].capacity-buffers[i].entities.count)
            if room>0 { buffers[i].entities.append(contentsOf:u.materialFlow.takeCompleted(limit:room)) }
            while !buffers[i].entities.isEmpty {
                var e=buffers[i].entities[0];e.labels["upstreamMachine"]=up.rawValue
                if d.materialFlow.enqueue(e) {buffers[i].entities.removeFirst()} else{break}
            }
            u.materialFlow.downstreamCapacityAvailable=buffers[i].entities.count < buffers[i].capacity
            d.materialFlow.externalFeedEnabled=false
            machines[up]=u;machines[down]=d
        }
    }
}
