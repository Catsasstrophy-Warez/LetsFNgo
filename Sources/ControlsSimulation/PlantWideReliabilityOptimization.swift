import Foundation

public enum ReliabilityCampaignPolicy:String,Codable,CaseIterable,Sendable { case riskBased,availabilityFirst,costFirst,runToFailure }
public enum FleetAssetState:String,Codable,CaseIterable,Sendable { case healthy,degrading,advisory,alarm,failed,maintenance,standby }

public struct FMEAProfile:Codable,Equatable,Sendable {
    public var severity:Int; public var occurrence:Int; public var detection:Int
    public var rpn:Int { severity*occurrence*detection }
    public var criticality:Double { Double(rpn)/1000 }
    public init(severity:Int,occurrence:Int,detection:Int){self.severity=min(10,max(1,severity));self.occurrence=min(10,max(1,occurrence));self.detection=min(10,max(1,detection))}
}

public struct BayesianRULBelief:Codable,Equatable,Sendable {
    public var meanDays:Double; public var variance:Double; public var observations:Int
    public init(meanDays:Double=90,variance:Double=900,observations:Int=0){self.meanDays=max(0,meanDays);self.variance=max(0.01,variance);self.observations=observations}
    public mutating func update(measuredDays:Double,measurementVariance:Double){
        let mv=max(0.01,measurementVariance), gain=variance/(variance+mv)
        meanDays=max(0,meanDays+gain*(measuredDays-meanDays)); variance=max(0.01,(1-gain)*variance); observations += 1
    }
    public var lower95:Double { max(0,meanDays-1.96*sqrt(variance)) }
    public var upper95:Double { meanDays+1.96*sqrt(variance) }
}

public struct FleetReliabilityAsset:Identifiable,Codable,Equatable,Sendable {
    public var id:String { machine.rawValue }
    public var machine:PlayableMachineKind; public var fault:PredictiveFaultFamily; public var state:FleetAssetState
    public var health:Double; public var degradationPerDay:Double; public var weibullShape:Double; public var weibullScaleDays:Double
    public var belief:BayesianRULBelief; public var fmea:FMEAProfile; public var redundantWith:PlayableMachineKind?
    public var requiredSkill:PlantSkill; public var sparePartNumber:String; public var repairHours:Double; public var lifecycleAgeYears:Double
    public var acquisitionCost:Double; public var accumulatedMaintenanceCost:Double; public var accumulatedDowntimeCost:Double
    public init(machine:PlayableMachineKind,index:Int){
        self.machine=machine; fault=PredictiveFaultFamily.allCases[index % PredictiveFaultFamily.allCases.count]; state = .healthy
        health=0.08+Double(index%4)*0.015; degradationPerDay=0.0025+Double(index%7)*0.00045
        weibullShape=1.5+Double(index%5)*0.25; weibullScaleDays=220+Double(index%8)*28
        belief = .init(meanDays:180,variance:1600); fmea = .init(severity:6+index%5,occurrence:3+index%6,detection:2+index%7)
        redundantWith=nil; requiredSkill=index%3==0 ? .electrical : index%3==1 ? .mechanical : .controls
        sparePartNumber="REL-"+String(format:"%03d",index+1); repairHours=1+Double(index%5)*0.5; lifecycleAgeYears=Double(index%9)*0.7
        acquisitionCost=35_000+Double(index%8)*18_000; accumulatedMaintenanceCost=0; accumulatedDowntimeCost=0
    }
}

public struct MonteCarloRULResult:Codable,Equatable,Sendable {
    public var trials:Int; public var meanDays:Double; public var p10Days:Double; public var p50Days:Double; public var p90Days:Double; public var failureWithin30Days:Double
}

public enum ReliabilityMonteCarlo {
    public static func forecast(asset:FleetReliabilityAsset,trials:Int=1000,seed:UInt64=1)->MonteCarloRULResult {
        var rng=ReliabilityRNG(seed:seed); var values=[Double](); values.reserveCapacity(max(10,trials))
        for _ in 0..<max(10,trials) {
            let u=max(1e-9,min(1-1e-9,rng.nextDouble()))
            let life=asset.weibullScaleDays*pow(-log(1-u),1/asset.weibullShape)
            let ageEquivalent=asset.health*asset.weibullScaleDays
            values.append(max(0,life-ageEquivalent))
        }
        values.sort(); func q(_ p:Double)->Double { values[min(values.count-1,max(0,Int(Double(values.count-1)*p)))] }
        return .init(trials:values.count,meanDays:values.reduce(0,+)/Double(values.count),p10Days:q(0.1),p50Days:q(0.5),p90Days:q(0.9),failureWithin30Days:Double(values.filter{$0<=30}.count)/Double(values.count))
    }
}

public struct FleetMaintenancePriority:Identifiable,Codable,Equatable,Sendable {
    public var id:String { machine.rawValue }; public var machine:PlayableMachineKind; public var score:Double; public var riskCost:Double; public var rationale:[String]
}

public struct TurnaroundTask:Identifiable,Codable,Equatable,Sendable { public var id:String=UUID().uuidString; public var machine:PlayableMachineKind; public var durationHours:Double; public var bundled:Bool; public var opportunity:Bool; public var expectedAvoidedCost:Double }
public struct TurnaroundPlan:Codable,Equatable,Sendable { public var startDay:Double; public var durationHours:Double; public var tasks:[TurnaroundTask]; public var laborHours:Double; public var expectedAvoidedCost:Double; public var productionOpportunityCost:Double }

public struct SpareOptimization:Identifiable,Codable,Equatable,Sendable { public var id:String { partNumber }; public var partNumber:String; public var recommendedStock:Int; public var reorderPoint:Int; public var annualHoldingCost:Double; public var expectedStockoutCost:Double }

public struct AssetLifecycleCost:Identifiable,Codable,Equatable,Sendable { public var id:String { machine.rawValue }; public var machine:PlayableMachineKind; public var years:Double; public var acquisition:Double; public var maintenance:Double; public var downtime:Double; public var energyAndOperations:Double; public var replacementResidual:Double; public var total:Double }

public struct ReliabilityManagerSnapshot:Sendable {
    public var day:Double; public var fleetAvailability:Double; public var failedAssets:Int; public var advisoryAssets:Int; public var backlog:Int
    public var maintenanceCost:Double; public var downtimeCost:Double; public var customerPenalty:Double; public var score:Double; public var topPriorities:[FleetMaintenancePriority]
}

public struct ReliabilityManagerCampaignRuntime:Sendable {
    public var plant:PlantShiftManagementRuntime; public var assets:[PlayableMachineKind:FleetReliabilityAsset]=[:]; public var policy:ReliabilityCampaignPolicy
    public var day:Double=0; public var rng:ReliabilityRNG; public var missedAdvisories:Int=0; public var opportunityMaintenanceCount:Int=0; public var bundledJobs:Int=0
    public init(plant:PlantShiftManagementRuntime,policy:ReliabilityCampaignPolicy = .riskBased,seed:UInt64=42){
        self.plant=plant; self.policy=policy; self.rng = .init(seed:seed)
        for (i,m) in PlayableMachineKind.allCases.enumerated(){ assets[m]=FleetReliabilityAsset(machine:m,index:i) }
        // Pair representative duty/standby equipment to teach redundancy decisions.
        let pairs:[(PlayableMachineKind,PlayableMachineKind)]=[(.pumpStation,.chilledWaterPlant),(.compressedAirPlant,.airHandlingUnit),(.wastewaterLiftStation,.reverseOsmosisPlant)]
        for (a,b) in pairs { assets[a]?.redundantWith=b; assets[b]?.redundantWith=a }
    }
    public mutating func advance(days:Double,autoOptimize:Bool=true)throws->ReliabilityManagerSnapshot {
        let whole=max(1,Int(ceil(max(0,days))))
        for _ in 0..<whole { day += 1; degradeFleet(); if autoOptimize { try executeDailyReliabilityPlan() }; try plant.run(seconds:min(300,plant.campaignDurationSeconds-plant.mes.elapsedSeconds),stepMilliseconds:10_000) }
        return snapshot()
    }
    mutating func degradeFleet(){
        for m in PlayableMachineKind.allCases {
            guard var a=assets[m], a.state != .maintenance else { continue }
            let stochastic=0.65+0.7*rng.nextDouble(); a.health=min(1.5,a.health+a.degradationPerDay*stochastic)
            let mc=ReliabilityMonteCarlo.forecast(asset:a,trials:250,seed:rng.next())
            a.belief.update(measuredDays:mc.p50Days,measurementVariance:max(4,pow((mc.p90Days-mc.p10Days)/2.56,2)))
            if a.health>=1 { a.state = .failed; a.accumulatedDowntimeCost += 6000+Double(a.fmea.rpn)*8 }
            else if a.health>=0.78 { if a.state != .alarm { missedAdvisories += 1 }; a.state = .alarm }
            else if a.health>=0.55 { a.state = .advisory }
            else if a.health>=0.25 { a.state = .degrading }
            assets[m]=a
        }
    }
    public func priorities()->[FleetMaintenancePriority] {
        assets.values.map { a in
            let mc=ReliabilityMonteCarlo.forecast(asset:a,trials:400,seed:UInt64(abs(a.machine.rawValue.hashValue))+7)
            let redundancyFactor = a.redundantWith.flatMap{assets[$0]}?.state == .healthy ? 0.72 : 1.0
            let risk=mc.failureWithin30Days*(5000+Double(a.fmea.rpn)*22)*redundancyFactor
            let score=min(100,100*(0.35*a.health+0.35*mc.failureWithin30Days+0.30*a.fmea.criticality)*redundancyFactor)
            return .init(machine:a.machine,score:score,riskCost:risk,rationale:["RPN \(a.fmea.rpn)",String(format:"30-day failure risk %.0f%%",mc.failureWithin30Days*100),a.redundantWith == nil ? "No modeled redundancy" : "Redundant asset available for switching"])
        }.sorted{$0.score>$1.score}
    }
    public mutating func executeDailyReliabilityPlan()throws {
        let candidates=priorities().prefix(policy == .availabilityFirst ? 3 : 2)
        for p in candidates where p.score >= (policy == .runToFailure ? 101 : policy == .costFirst ? 72 : 58) { _=scheduleMaintenance(p.machine,opportunity:false) }
    }
    @discardableResult public mutating func scheduleMaintenance(_ machine:PlayableMachineKind,opportunity:Bool)->Bool {
        guard var a=assets[machine], a.state != .maintenance else{return false}
        let hasSpare=plant.spareCrib.contains{$0.partNumber==a.sparePartNumber && $0.quantity>0}
        if !hasSpare {
            if !plant.spareCrib.contains(where:{$0.partNumber==a.sparePartNumber}) { plant.addSpare(.init(partNumber:a.sparePartNumber,description:"Reliability critical spare for \(machine.rawValue)",quantity:0,reorderPoint:1,unitCost:900,normalLeadHours:48,expediteLeadHours:4,expediteFee:300,machineFamilies:[machine])) }
            _=plant.expediteSpare(partNumber:a.sparePartNumber); return false
        }
        let wo=MaintenanceWorkOrder(machine:machine,title:opportunity ? "Opportunity maintenance — \(machine.rawValue)" : "Reliability intervention — \(machine.rawValue)",requiredSkill:a.requiredSkill,requiredPartNumber:a.sparePartNumber,priority:a.state == .failed ? .emergency : .routine,status:.planned,createdAt:plant.mes.elapsedSeconds,dueAt:plant.mes.elapsedSeconds+86400,estimatedHours:a.repairHours,preventive:true)
        plant.addPM(wo); a.state = .maintenance; a.accumulatedMaintenanceCost += 700+a.repairHours*160; a.health=max(0.05,a.health*0.15); assets[machine]=a; if opportunity { opportunityMaintenanceCount += 1 }; return true
    }
    public mutating func switchToRedundantAsset(for machine:PlayableMachineKind)->Bool {
        guard var primary=assets[machine],let backupKind=primary.redundantWith,var backup=assets[backupKind],backup.state != .failed else{return false}
        primary.state = .standby; backup.state=backup.health<0.25 ? .healthy : .degrading; assets[machine]=primary;assets[backupKind]=backup;return true
    }
    public func planTurnaround(startDay:Double,durationHours:Double=12)->TurnaroundPlan {
        let ranked=priorities().filter{$0.score>35}; var tasks=[TurnaroundTask](); var used=0.0
        for p in ranked { guard let a=assets[p.machine], used+a.repairHours<=durationHours else{continue}; tasks.append(.init(machine:p.machine,durationHours:a.repairHours,bundled:true,opportunity:a.state != .alarm && a.state != .failed,expectedAvoidedCost:p.riskCost));used += a.repairHours }
        return .init(startDay:startDay,durationHours:durationHours,tasks:tasks,laborHours:used,expectedAvoidedCost:tasks.reduce(0){$0+$1.expectedAvoidedCost},productionOpportunityCost:durationHours*1800)
    }
    public func optimizeSpares()->[SpareOptimization] {
        assets.values.map { a in let annual=365/max(1,a.weibullScaleDays);let stock=max(1,Int(ceil(annual*a.repairHours/24+Double(a.fmea.severity)/10)));return .init(partNumber:a.sparePartNumber,recommendedStock:stock,reorderPoint:max(1,stock-1),annualHoldingCost:Double(stock)*900*0.22,expectedStockoutCost:annual*Double(a.fmea.rpn)*35) }.sorted{$0.expectedStockoutCost>$1.expectedStockoutCost}
    }
    public func lifecycleCosts(years:Double=5)->[AssetLifecycleCost] {
        assets.values.map { a in let maint=a.accumulatedMaintenanceCost+years/a.weibullScaleDays*365*(500+Double(a.fmea.rpn));let down=a.accumulatedDowntimeCost+years*Double(a.fmea.rpn)*180;let ops=years*a.acquisitionCost*0.08;let residual=max(0,a.acquisitionCost*(0.5-0.06*years));return .init(machine:a.machine,years:years,acquisition:a.acquisitionCost,maintenance:maint,downtime:down,energyAndOperations:ops,replacementResidual:residual,total:a.acquisitionCost+maint+down+ops-residual) }.sorted{$0.total>$1.total}
    }
    public func snapshot()->ReliabilityManagerSnapshot {
        let vals=Array(assets.values),failed=vals.filter{$0.state == .failed}.count,adv=vals.filter{$0.state == .advisory || $0.state == .alarm}.count
        let availability=1-Double(failed)/Double(max(1,vals.count));let maint=vals.reduce(0){$0+$1.accumulatedMaintenanceCost};let down=vals.reduce(0){$0+$1.accumulatedDowntimeCost};let penalty=plant.economics.customerPenalties
        let score=max(0,100*availability-Double(missedAdvisories)*0.25-(maint+down+penalty)/100_000)
        return .init(day:day,fleetAvailability:availability,failedAssets:failed,advisoryAssets:adv,backlog:plant.maintenanceBacklog.filter{$0.status != .complete}.count,maintenanceCost:maint,downtimeCost:down,customerPenalty:penalty,score:score,topPriorities:Array(priorities().prefix(8)))
    }
}

public struct ReliabilityRNG:Sendable { public var state:UInt64; public init(seed:UInt64){state=seed == 0 ? 0x9E3779B97F4A7C15:seed}; public mutating func next()->UInt64{state &+= 0x9E3779B97F4A7C15;var z=state;z=(z^(z>>30))&*0xBF58476D1CE4E5B9;z=(z^(z>>27))&*0x94D049BB133111EB;return z^(z>>31)};public mutating func nextDouble()->Double{Double(next()>>11)/Double(1<<53)} }
