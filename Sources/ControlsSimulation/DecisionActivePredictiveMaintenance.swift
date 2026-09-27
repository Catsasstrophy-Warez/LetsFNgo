import Foundation

// MARK: - Decision-active predictive maintenance

public enum MaintenanceStrategy: String, Codable, CaseIterable, Sendable {
    case conditionBased
    case preventive
    case reactive
}

public enum PredictiveMaintenanceAction: String, Codable, CaseIterable, Sendable {
    case continueMonitoring
    case inspect
    case planMaintenance
    case interveneNow
    case deferred
}

public struct RULConfidenceInterval: Codable, Equatable, Sendable {
    public var lowerDays: Double
    public var pointDays: Double
    public var upperDays: Double
    public var confidence: Double
}

public struct RemainingUsefulLifeForecast: Codable, Equatable, Sendable {
    public var machine: PlayableMachineKind
    public var fault: PredictiveFaultFamily
    public var generatedAtDay: Double
    public var failureThreshold: Double
    public var healthIndex: Double
    public var slopePerDay: Double
    public var interval95: RULConfidenceInterval
    public var probabilityWithin7Days: Double
    public var probabilityWithin30Days: Double
    public var probabilityWithin90Days: Double
    public var evidenceQuality: Double
}

public enum RemainingUsefulLifeForecaster {
    public static func forecast(
        machine: PlayableMachineKind,
        fault: PredictiveFaultFamily,
        records: [ConditionHistorianRecord],
        failureThreshold: Double = 0.80
    ) -> RemainingUsefulLifeForecast {
        let sorted = records.sorted { $0.simulatedDay < $1.simulatedDay }
        let usable = sorted.filter { $0.simulatedDay >= 1 }
        let now = usable.last?.simulatedDay ?? sorted.last?.simulatedDay ?? 0
        let points = usable.map { ConditionTrendPoint(simulatedDay: $0.simulatedDay, value: healthIndex($0.features, fault: fault)) }
        let fit = DegradationAnalyzer.fit(points, threshold: failureThreshold)
        let current = points.last?.value ?? 0
        let projectedDay = fit.projectedThresholdDay ?? (fit.slopePerDay > 1e-9 ? now + max(0, failureThreshold-current)/fit.slopePerDay : now + 3650)
        let point = max(0, projectedDay-now)
        let residuals = points.map { $0.value - (fit.intercept + fit.slopePerDay*$0.simulatedDay) }
        let residualSD = residuals.count > 1 ? sqrt(residuals.reduce(0) { $0+$1*$1 } / Double(residuals.count-1)) : max(0.02, current*0.05)
        let slope = max(1e-6, abs(fit.slopePerDay))
        let daySigma = min(365, max(0.5, residualSD/slope))
        let lower = max(0, point - 1.96*daySigma)
        let upper = point + 1.96*daySigma
        let evidence = min(1, max(0.05, fit.rSquared * min(1, Double(points.count)/24)))
        return .init(
            machine: machine,
            fault: fault,
            generatedAtDay: now,
            failureThreshold: failureThreshold,
            healthIndex: current,
            slopePerDay: fit.slopePerDay,
            interval95: .init(lowerDays: lower, pointDays: point, upperDays: upper, confidence: 0.95),
            probabilityWithin7Days: normalCDF(7, mean: point, sigma: daySigma),
            probabilityWithin30Days: normalCDF(30, mean: point, sigma: daySigma),
            probabilityWithin90Days: normalCDF(90, mean: point, sigma: daySigma),
            evidenceQuality: evidence
        )
    }

    public static func healthIndex(_ f: ConditionFeatureVector, fault: PredictiveFaultFamily) -> Double {
        switch fault {
        case .bearingWear: return f.bearingEnvelopeEnergy + max(0, f.temperatureC-42)/80
        case .brokenRotorBar: return f.brokenBarSidebandRatio*2 + max(0,f.currentRMS-11.5)/25
        case .eccentricity: return f.eccentricitySidebandRatio*2 + max(0,f.currentRMS-11.5)/30
        case .supplyUnbalance: return f.negativeSequencePercent/8 + max(0,f.temperatureC-42)/100
        case .harmonicContamination: return f.currentTHDPercent/25 + f.voltageTHDPercent/20 + max(0,0.9-f.powerFactor)
        case .insulationAging: return max(0,f.temperatureC-42)/45 + max(0,f.crestFactor-1.45)/1.5 + f.currentTHDPercent/80
        case .looseConnection: return max(0,277-f.voltageRMS)/30 + max(0,f.temperatureC-42)/45 + f.voltageTHDPercent/35
        }
    }

    private static func normalCDF(_ x: Double, mean: Double, sigma: Double) -> Double {
        let z = (x-mean)/max(1e-9,sigma)
        return 0.5 * (1 + erfApprox(z/sqrt(2)))
    }

    private static func erfApprox(_ x: Double) -> Double {
        // Abramowitz and Stegun 7.1.26; adequate for training probability estimates.
        let sign = x < 0 ? -1.0 : 1.0
        let ax = abs(x)
        let t = 1/(1+0.3275911*ax)
        let y = 1 - (((((1.061405429*t - 1.453152027)*t) + 1.421413741)*t - 0.284496736)*t + 0.254829592)*t*exp(-ax*ax)
        return sign*y
    }
}

public struct MaintenanceDecisionEconomics: Codable, Equatable, Sendable {
    public var plannedInterventionCost: Double
    public var inspectionCost: Double
    public var falsePositiveCost: Double
    public var falseNegativeFailureCost: Double
    public var plannedDowntimeHours: Double
    public var unplannedDowntimeHours: Double
    public var lostMarginPerHour: Double
    public init(plannedInterventionCost:Double=850,inspectionCost:Double=180,falsePositiveCost:Double=500,falseNegativeFailureCost:Double=8_500,plannedDowntimeHours:Double=1.0,unplannedDowntimeHours:Double=4.0,lostMarginPerHour:Double=1_200) {
        self.plannedInterventionCost=plannedInterventionCost; self.inspectionCost=inspectionCost; self.falsePositiveCost=falsePositiveCost; self.falseNegativeFailureCost=falseNegativeFailureCost; self.plannedDowntimeHours=plannedDowntimeHours; self.unplannedDowntimeHours=unplannedDowntimeHours; self.lostMarginPerHour=lostMarginPerHour
    }
}

public struct MaintenanceRecommendation: Codable, Equatable, Sendable {
    public var machine: PlayableMachineKind
    public var action: PredictiveMaintenanceAction
    public var confidence: Double
    public var failureProbabilityBeforeHorizon: Double
    public var expectedCostAct: Double
    public var expectedCostDefer: Double
    public var falsePositiveExposure: Double
    public var falseNegativeExposure: Double
    public var rationale: [String]
}

public enum PredictiveMaintenanceRecommender {
    public static func recommend(forecast: RemainingUsefulLifeForecast, horizonDays:Double=30, economics:MaintenanceDecisionEconomics = .init()) -> MaintenanceRecommendation {
        let p = probability(forecast, horizonDays: horizonDays)
        let planned = economics.plannedInterventionCost + economics.plannedDowntimeHours*economics.lostMarginPerHour
        let fp = (1-p)*economics.falsePositiveCost
        let act = planned + fp
        let failureConsequence = economics.falseNegativeFailureCost + economics.unplannedDowntimeHours*economics.lostMarginPerHour
        let fn = p*failureConsequence
        let monitoring = max(40, economics.inspectionCost*0.2)
        let deferCost = fn + monitoring
        let action:PredictiveMaintenanceAction
        if p >= 0.75 || forecast.interval95.lowerDays <= 3 { action = .interveneNow }
        else if act < deferCost && p >= 0.25 { action = .planMaintenance }
        else if p >= 0.10 { action = .inspect }
        else { action = .continueMonitoring }
        var rationale=[String]()
        rationale.append(String(format:"%.0f%% probability of threshold crossing within %.0f days",p*100,horizonDays))
        rationale.append(String(format:"RUL %.1f days (95%% %.1f–%.1f)",forecast.interval95.pointDays,forecast.interval95.lowerDays,forecast.interval95.upperDays))
        rationale.append(String(format:"Act-now expected cost $%.0f versus defer $%.0f",act,deferCost))
        if economics.falseNegativeFailureCost > economics.falsePositiveCost*5 { rationale.append("False-negative consequence dominates unnecessary-maintenance consequence") }
        return .init(machine:forecast.machine,action:action,confidence:forecast.evidenceQuality,failureProbabilityBeforeHorizon:p,expectedCostAct:act,expectedCostDefer:deferCost,falsePositiveExposure:fp,falseNegativeExposure:fn,rationale:rationale)
    }

    private static func probability(_ f:RemainingUsefulLifeForecast,horizonDays:Double)->Double {
        if horizonDays <= 7 { return f.probabilityWithin7Days }
        if horizonDays <= 30 { return f.probabilityWithin30Days }
        if horizonDays <= 90 { return f.probabilityWithin90Days }
        let base=f.probabilityWithin90Days
        return min(0.999,base+(1-base)*(1-exp(-(horizonDays-90)/90)))
    }
}

// MARK: - Production-demand-aware scheduling

public struct MaintenanceDemandWindow: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var startAtSeconds:Double
    public var endAtSeconds:Double
    public var demandIntensity:Double
    public var customerPenaltyRisk:Double
    public var description:String
    public init(id:String=UUID().uuidString,startAtSeconds:Double,endAtSeconds:Double,demandIntensity:Double,customerPenaltyRisk:Double,description:String){self.id=id;self.startAtSeconds=startAtSeconds;self.endAtSeconds=endAtSeconds;self.demandIntensity=max(0,demandIntensity);self.customerPenaltyRisk=max(0,customerPenaltyRisk);self.description=description}
}

public struct MaintenanceWindowScore: Identifiable, Codable, Equatable, Sendable {
    public var id:String { "\(Int(startAtSeconds))-\(Int(endAtSeconds))" }
    public var startAtSeconds:Double
    public var endAtSeconds:Double
    public var productionLossCost:Double
    public var customerRiskCost:Double
    public var laborCost:Double
    public var failureBeforeWindowCost:Double
    public var totalExpectedCost:Double
    public var feasible:Bool
    public var explanation:String
}

public struct MaintenanceScheduleRecommendation: Codable, Equatable, Sendable {
    public var machine:PlayableMachineKind
    public var selected:MaintenanceWindowScore?
    public var alternatives:[MaintenanceWindowScore]
}

public enum ProductionAwareMaintenanceScheduler {
    public static func demandWindows(from plant:PlantShiftManagementRuntime,horizonHours:Double=24)->[MaintenanceDemandWindow] {
        let now=plant.mes.elapsedSeconds, end=now+horizonHours*3600
        let activeOrders=plant.mes.orders.filter{$0.status != .complete && $0.dueAt >= now && $0.dueAt <= end}
        if activeOrders.isEmpty { return [.init(startAtSeconds:now,endAtSeconds:end,demandIntensity:0.25,customerPenaltyRisk:0,description:"No due production orders in horizon")] }
        return activeOrders.map { order in
            let remaining=Double(max(0,order.quantity-order.completedQuantity))
            let duration=max(1800,order.dueAt-now)
            let intensity=min(1.5,remaining/max(1,duration/60))
            let agreement=plant.agreements[order.id]
            let penalty=(agreement?.latePenaltyPerMinute ?? 20)*(agreement?.priorityCustomerMultiplier ?? 1)
            return .init(startAtSeconds:max(now,order.startedAt ?? now),endAtSeconds:order.dueAt,demandIntensity:intensity,customerPenaltyRisk:penalty,description:"\(order.id) \(order.sku), priority \(order.priority)")
        }
    }

    public static func schedule(machine:PlayableMachineKind,forecast:RemainingUsefulLifeForecast,plant:PlantShiftManagementRuntime,durationHours:Double=1,sparePartNumber:String?=nil,horizonHours:Double=24)->MaintenanceScheduleRecommendation {
        let now=plant.mes.elapsedSeconds, horizon=max(1,horizonHours)*3600
        let windows=demandWindows(from:plant,horizonHours:horizonHours)
        let candidateStarts=Array(stride(from:now,through:now+horizon,by:3600))
        let hasSpare:Bool = sparePartNumber == nil || plant.spareCrib.contains(where:{$0.partNumber==sparePartNumber && $0.quantity>0})
        let crewAvailable = !plant.crews.isEmpty
        let scores=candidateStarts.map { start -> MaintenanceWindowScore in
            let end=start+durationHours*3600
            var loss=0.0, customer=0.0
            for w in windows where rangesOverlap(start,end,w.startAtSeconds,w.endAtSeconds) {
                let overlap=max(0,min(end,w.endAtSeconds)-max(start,w.startAtSeconds))/3600
                loss += overlap*1200*w.demandIntensity
                customer += overlap*60*w.customerPenaltyRisk*min(1,w.demandIntensity)
            }
            let hour=Int(start/3600)%24
            let labor=durationHours*55*((hour>=22 || hour<6) ? 1.5:1)
            let daysUntil=max(0,(start-now)/86400)
            let pBefore = approximateFailureProbability(forecast,days:daysUntil)
            let failureCost=pBefore*12_000
            let feasible=hasSpare && crewAvailable
            let total=loss+customer+labor+failureCost+(feasible ? 0:5_000)
            return .init(startAtSeconds:start,endAtSeconds:end,productionLossCost:loss,customerRiskCost:customer,laborCost:labor,failureBeforeWindowCost:failureCost,totalExpectedCost:total,feasible:feasible,explanation:feasible ? "Balances production/customer risk against failure risk":"Blocked by required resource availability")
        }.sorted{$0.totalExpectedCost<$1.totalExpectedCost}
        return .init(machine:machine,selected:scores.first(where:{$0.feasible}),alternatives:Array(scores.prefix(8)))
    }

    private static func rangesOverlap(_ a0:Double,_ a1:Double,_ b0:Double,_ b1:Double)->Bool { a0 < b1 && b0 < a1 }
    private static func approximateFailureProbability(_ f:RemainingUsefulLifeForecast,days:Double)->Double {
        if days<=0{return 0}; if days<=7{return f.probabilityWithin7Days*days/7}; if days<=30{return f.probabilityWithin7Days+(f.probabilityWithin30Days-f.probabilityWithin7Days)*(days-7)/23}; if days<=90{return f.probabilityWithin30Days+(f.probabilityWithin90Days-f.probabilityWithin30Days)*(days-30)/60}; return min(1,f.probabilityWithin90Days+(1-f.probabilityWithin90Days)*(days-90)/180)
    }
}

// MARK: - Closed-loop decision campaign

public struct PredictiveMaintenanceDecisionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var simulatedDay:Double
    public var strategy:MaintenanceStrategy
    public var action:PredictiveMaintenanceAction
    public var rationale:String
    public var expectedCost:Double
}

public struct DecisionActivePredictiveSnapshot: Sendable {
    public var machine:PlayableMachineKind
    public var fault:PredictiveFaultFamily
    public var strategy:MaintenanceStrategy
    public var simulatedDay:Double
    public var degradationSeverity:Double
    public var rul:RemainingUsefulLifeForecast
    public var recommendation:MaintenanceRecommendation
    public var schedule:MaintenanceScheduleRecommendation
    public var decisions:[PredictiveMaintenanceDecisionRecord]
    public var missedAdvisories:Int
    public var failures:Int
    public var maintenanceInterventions:Int
    public var falsePositiveInterventions:Int
    public var plantEconomics:PlantEconomicsLedger
    public var mesCosts:ProductionCostLedger
    public var lineAvailabilityPercent:Double
    public var scheduleAttainmentPercent:Double
    public var customerPenaltyCost:Double
    public var openWorkOrders:Int
    public var spareInventory:[SparePart]
}

public struct DecisionActivePredictiveMaintenanceRuntime: Sendable {
    public var plant:PlantShiftManagementRuntime
    public var condition=ConditionMonitoringRuntime()
    public var machine:PlayableMachineKind
    public var fault:PredictiveFaultFamily
    public var strategy:MaintenanceStrategy
    public var simulatedDay:Double=0
    public var degradationSeverity:Double=0
    public var degradationPerDay:Double=0.004
    public var failureSeverity:Double=0.92
    public var decisions:[PredictiveMaintenanceDecisionRecord]=[]
    public var missedAdvisories:Int=0
    public var failures:Int=0
    public var maintenanceInterventions:Int=0
    public var falsePositiveInterventions:Int=0
    public var lastMaintenanceDay:Double=0
    public var preventiveIntervalDays:Double=90
    public var automaticRecommendations:Bool=true
    public var falseNegativeCost:Double=8_500
    private var failed=false
    private var lastRecommendationAction:PredictiveMaintenanceAction = .continueMonitoring

    public init(plant:PlantShiftManagementRuntime,machine:PlayableMachineKind,fault:PredictiveFaultFamily,strategy:MaintenanceStrategy = .conditionBased) {
        self.plant=plant; self.machine=machine; self.fault=fault; self.strategy=strategy
        // Establish a healthy, state-conditioned baseline.
        for i in 0..<24 {
            let f=PredictiveConditionCampaign.features(machine:machine,severity:0,fault:fault,noise:Double(i%5-2)*0.002)
            _=condition.ingest(machine:machine,state:.normalProduction,simulatedDay:Double(i)/24,rpm:1760,features:f,learnHealthy:true)
        }
    }

    @discardableResult public mutating func advanceCompressed(days:Double,plantSecondsPerDay:Double=300,autoAct:Bool=true)throws->DecisionActivePredictiveSnapshot {
        let steps=max(1,Int(ceil(days)))
        let dt=days/Double(steps)
        for _ in 0..<steps {
            simulatedDay += dt
            if !failed { degradationSeverity=min(1.2,degradationSeverity+degradationPerDay*dt) }
            let f=PredictiveConditionCampaign.features(machine:machine,severity:min(1,degradationSeverity),fault:fault,noise:sin(simulatedDay*1.7)*0.005)
            let state:ConditionOperatingState = degradationSeverity>0.65 ? .degradedProduction:.normalProduction
            let rec=condition.ingest(machine:machine,state:state,simulatedDay:simulatedDay,rpm:1760-min(90,degradationSeverity*70),features:f)
            let forecast=currentRUL()
            let economics=MaintenanceDecisionEconomics(falseNegativeFailureCost:falseNegativeCost)
            let recommendation=PredictiveMaintenanceRecommender.recommend(forecast:forecast,economics:economics)
            lastRecommendationAction=recommendation.action
            if rec.severity != .information && rec.severity != .advisory && recommendation.action != .continueMonitoring && !autoAct { missedAdvisories += 1 }
            if autoAct && automaticRecommendations { try applyStrategy(recommendation:recommendation) }
            if !failed && degradationSeverity >= failureSeverity { triggerFailure() }
            if plantSecondsPerDay > 0 && plant.mes.elapsedSeconds < plant.campaignDurationSeconds { _=try plant.run(seconds:min(plantSecondsPerDay,plant.campaignDurationSeconds-plant.mes.elapsedSeconds),stepMilliseconds:10_000) }
        }
        return snapshot()
    }

    public mutating func explicitlyDeferCurrentRecommendation() {
        missedAdvisories += 1
        decisions.append(.init(simulatedDay:simulatedDay,strategy:strategy,action:.deferred,rationale:"Learner deferred predictive recommendation",expectedCost:falseNegativeCost))
        degradationSeverity=min(1.2,degradationSeverity+0.015)
    }

    public mutating func performMaintenance(reason:String="Predictive intervention") {
        if plant.maintenanceBacklog.contains(where: { $0.machine == machine && $0.title.hasPrefix("Predictive") && $0.status != .complete }) { return }
        let early = degradationSeverity < 0.25
        let asset=plant.reliability[machine]
        let part=asset?.criticalSparePartNumber
        let skill=asset?.requiredSkill ?? requiredSkill(for:fault)
        let title = reason.hasPrefix("Predictive") ? reason : "Predictive: \(reason)"
        let wo=MaintenanceWorkOrder(machine:machine,title:title,requiredSkill:skill,requiredPartNumber:part,priority:.urgent,status:.planned,createdAt:plant.mes.elapsedSeconds,dueAt:plant.mes.elapsedSeconds+1800,estimatedHours:max(0.5,asset?.nominalMTTRHours ?? 1),preventive:true,deferralRisk:0)
        plant.addPM(wo)
        var dispatched=false
        if let crew=plant.currentCrew(),let member=crew.members.max(by:{$0.skill(skill)<$1.skill(skill)}) { dispatched=plant.dispatch(workOrderID:wo.id,memberID:member.id) }
        if !dispatched {
            if let part, !plant.inbound.contains(where:{$0.isSpare && $0.item == part && !$0.received}) { _=plant.expediteSpare(partNumber:part) }
            decisions.append(.init(simulatedDay:simulatedDay,strategy:strategy,action:.planMaintenance,rationale:"Maintenance queued but resource constrained: \(title)",expectedCost:plant.economics.netEconomicImpact))
            return
        }
        if early { falsePositiveInterventions += 1 }
        maintenanceInterventions += 1
        degradationSeverity=max(0.02,degradationSeverity*0.08); failed=false; lastMaintenanceDay=simulatedDay
        decisions.append(.init(simulatedDay:simulatedDay,strategy:strategy,action:.interveneNow,rationale:title,expectedCost:plant.economics.netEconomicImpact))
    }

    public func currentRUL()->RemainingUsefulLifeForecast { RemainingUsefulLifeForecaster.forecast(machine:machine,fault:fault,records:condition.records(machine:machine)) }

    public func currentSchedule()->MaintenanceScheduleRecommendation {
        let part=plant.reliability[machine]?.criticalSparePartNumber
        return ProductionAwareMaintenanceScheduler.schedule(machine:machine,forecast:currentRUL(),plant:plant,durationHours:max(0.5,plant.reliability[machine]?.nominalMTTRHours ?? 1),sparePartNumber:part)
    }

    private mutating func applyStrategy(recommendation:MaintenanceRecommendation)throws {
        switch strategy {
        case .conditionBased:
            if recommendation.action == .interveneNow || recommendation.action == .planMaintenance {
                let schedule=currentSchedule()
                if let selected=schedule.selected, selected.startAtSeconds <= plant.mes.elapsedSeconds+3600 { performMaintenance(reason:"Condition-based maintenance: \(recommendation.rationale.first ?? "risk threshold")") }
                else if recommendation.action == .interveneNow { performMaintenance(reason:"Condition-based urgent intervention") }
            }
        case .preventive:
            if simulatedDay-lastMaintenanceDay >= preventiveIntervalDays { performMaintenance(reason:"Fixed-interval preventive maintenance") }
        case .reactive:
            break
        }
    }

    private mutating func triggerFailure() {
        failed=true; failures += 1
        let reason:DowntimeReasonCode = requiredSkill(for:fault) == .mechanical ? .mechanicalFault:.controlsFault
        _=plant.mes.reportDowntime(machine:machine,reason:reason,detail:"Predictive degradation ignored until functional failure: \(fault.rawValue)")
        if let node=plant.mes.line.project.nodes.first(where:{$0.machine==machine}),var runtime=plant.mes.line.machines[node.id] {
            let target=ClosedLoopPlantRuntime.outputPaths(for:runtime.executable).first?.commandTag ?? ""
            if !target.isEmpty { runtime.injectOutputFault(.init(target:target,kind: outputFault(for:fault),magnitude:max(1,degradationSeverity))) }
            plant.mes.line.machines[node.id]=runtime
        }
        let call=plant.mes.requestMaintenance(machine:machine,priority:.emergency,problem:"Condition-monitoring failure: \(fault.rawValue)")
        _=call
        plant.economics.lostProductionOpportunity += 4*1200
        decisions.append(.init(simulatedDay:simulatedDay,strategy:strategy,action:.deferred,rationale:"Failure occurred after predictive deterioration was not removed",expectedCost:falseNegativeCost))
    }

    private func requiredSkill(for fault:PredictiveFaultFamily)->PlantSkill {
        switch fault { case .bearingWear,.brokenRotorBar,.eccentricity:return .mechanical; case .supplyUnbalance,.harmonicContamination,.insulationAging,.looseConnection:return .electrical }
    }
    private func outputFault(for fault:PredictiveFaultFamily)->OutputPathFaultKind {
        switch fault { case .bearingWear,.brokenRotorBar,.eccentricity:return .motorOverload; case .looseConnection:return .brokenFieldWire; default:return .driveFault }
    }

    private func snapshot()->DecisionActivePredictiveSnapshot {
        let r=currentRUL(); let economics=MaintenanceDecisionEconomics(falseNegativeFailureCost:falseNegativeCost); let rec=PredictiveMaintenanceRecommender.recommend(forecast:r,economics:economics)
        let baseAvailability=(plant.mes.line.machineOEE[machine]?.availability ?? 1)*100
        let elapsed=max(1,plant.mes.elapsedSeconds)
        let downtimeSeconds=plant.mes.downtime.filter{$0.machine == machine}.reduce(0){$0+$1.duration(at:plant.mes.elapsedSeconds)}
        let downtimeAvailability=max(0,100*(1-downtimeSeconds/elapsed))
        let availability=min(baseAvailability,downtimeAvailability)
        let planned=max(1,plant.mes.orders.reduce(0){$0+$1.quantity})
        let completed=plant.mes.orders.reduce(0){$0+$1.completedQuantity}
        let attainment=100*Double(completed)/Double(planned)
        return .init(machine:machine,fault:fault,strategy:strategy,simulatedDay:simulatedDay,degradationSeverity:degradationSeverity,rul:r,recommendation:rec,schedule:currentSchedule(),decisions:decisions,missedAdvisories:missedAdvisories,failures:failures,maintenanceInterventions:maintenanceInterventions,falsePositiveInterventions:falsePositiveInterventions,plantEconomics:plant.economics,mesCosts:plant.mes.costs,lineAvailabilityPercent:availability,scheduleAttainmentPercent:attainment,customerPenaltyCost:plant.economics.customerPenalties,openWorkOrders:plant.maintenanceBacklog.filter{$0.status != .complete}.count,spareInventory:plant.spareCrib)
    }
}

// MARK: - Strategy comparison / long-horizon economics

public struct MaintenanceStrategyOutcome: Identifiable, Codable, Equatable, Sendable {
    public var id:String { strategy.rawValue }
    public var strategy:MaintenanceStrategy
    public var failures:Int
    public var interventions:Int
    public var falsePositives:Int
    public var missedAdvisories:Int
    public var maintenanceCost:Double
    public var downtimeCost:Double
    public var spareCost:Double
    public var customerPenalty:Double
    public var lostProduction:Double
    public var totalEconomicImpact:Double
    public var availabilityPercent:Double
}

public struct MaintenanceStrategyComparison: Codable, Equatable, Sendable {
    public var machine:PlayableMachineKind
    public var fault:PredictiveFaultFamily
    public var horizonDays:Double
    public var outcomes:[MaintenanceStrategyOutcome]
    public var bestStrategy:MaintenanceStrategy
}

public enum PredictiveMaintenanceStrategyComparator {
    public static func compare(machine:PlayableMachineKind,fault:PredictiveFaultFamily,horizonDays:Double=365,project:LineBuilderProject=ProductionLineTemplates.beverageLine)throws->MaintenanceStrategyComparison {
        var outcomes=[MaintenanceStrategyOutcome]()
        for strategy in MaintenanceStrategy.allCases {
            let actualProject:LineBuilderProject
            if project.nodes.contains(where:{$0.machine == machine}) { actualProject=project }
            else { var p=LineBuilderProject(name:"Predictive maintenance — \(machine.rawValue)"); _=p.addMachine(machine,x:120,y:120); actualProject=p }
            var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:actualProject)
            // Disable unrelated seeded reliability failures so the comparison isolates strategy effects.
            for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
            for i in plant.spareCrib.indices { plant.spareCrib[i].quantity=max(plant.spareCrib[i].quantity,100) }
            var runtime=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:machine,fault:fault,strategy:strategy)
            runtime.degradationPerDay = 1/max(45,horizonDays*0.55)
            runtime.preventiveIntervalDays = max(30,horizonDays/4)
            let step=max(1,horizonDays/120)
            var remaining=horizonDays
            while remaining>0 { let d=min(step,remaining); _=try runtime.advanceCompressed(days:d,plantSecondsPerDay:0,autoAct:true); remaining-=d }
            // Aggregate long-horizon cost terms that do not require simulating every production second.
            let plannedCost=Double(runtime.maintenanceInterventions)*850
            let failureDowntime=Double(runtime.failures)*4*1200
            let falsePositive=Double(runtime.falsePositiveInterventions)*500
            let customer=Double(runtime.failures)*1400
            let spare=Double(runtime.maintenanceInterventions)*180
            let lost=Double(runtime.failures)*4800
            let total=plannedCost+failureDowntime+falsePositive+customer+spare+lost
            let downtimeHours=Double(runtime.failures)*4+Double(runtime.maintenanceInterventions)
            let availability=max(0,100*(1-downtimeHours/(horizonDays*24)))
            outcomes.append(.init(strategy:strategy,failures:runtime.failures,interventions:runtime.maintenanceInterventions,falsePositives:runtime.falsePositiveInterventions,missedAdvisories:runtime.missedAdvisories,maintenanceCost:plannedCost,downtimeCost:failureDowntime,spareCost:spare,customerPenalty:customer,lostProduction:lost,totalEconomicImpact:total,availabilityPercent:availability))
        }
        let best=outcomes.min(by:{$0.totalEconomicImpact<$1.totalEconomicImpact})?.strategy ?? .conditionBased
        return .init(machine:machine,fault:fault,horizonDays:horizonDays,outcomes:outcomes,bestStrategy:best)
    }
}
