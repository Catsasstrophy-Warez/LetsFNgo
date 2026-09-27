import Foundation

public enum CareerAssetDecision:String,Codable,CaseIterable,Sendable { case repair,rebuild,replace,`defer` }
public enum WorkforceRole:String,Codable,CaseIterable,Sendable { case mechanical,electrical,controls,reliability,instrumentation }
public enum ProgramMaturity:String,Codable,CaseIterable,Sendable { case reactive,basicPM,optimizedPM,predictive,prescriptive }
public enum RCAQuality:String,Codable,CaseIterable,Sendable { case none,weak,adequate,strong }

public struct CareerTechnician:Identifiable,Codable,Equatable,Sendable { public var id:String = UUID().uuidString; public var name:String;public var role:WorkforceRole;public var skill:Double;public var annualCost:Double;public var trainingHours:Double = 0;public var fatigue:Double = 0 }
public struct ObsolescenceRisk:Identifiable,Codable,Equatable,Sendable { public var id:String { machine.rawValue };public var machine:PlayableMachineKind;public var supportYearsRemaining:Double;public var partsScarcity:Double;public var cyberCompatibility:Double;public var score:Double }
public struct CapitalProject:Identifiable,Codable,Equatable,Sendable { public var id:String = UUID().uuidString;public var machine:PlayableMachineKind;public var decision:CareerAssetDecision;public var capex:Double;public var outageHours:Double;public var reliabilityGain:Double;public var approved:Bool = false }
public struct RCARecord:Identifiable,Codable,Equatable,Sendable { public var id:String = UUID().uuidString;public var year:Int;public var machine:PlayableMachineKind;public var quality:RCAQuality;public var rootCause:String;public var actions:[String];public var recurrenceRisk:Double;public var closed:Bool }
public struct DeferredConsequence:Identifiable,Codable,Equatable,Sendable { public var id:String = UUID().uuidString;public var createdYear:Int;public var maturityYear:Int;public var machine:PlayableMachineKind;public var origin:String;public var probability:Double;public var cost:Double;public var severity:Int;public var resolved:Bool = false }
public struct AnnualReliabilityBudget:Codable,Equatable,Sendable { public var year:Int;public var capex:Double;public var opex:Double;public var training:Double;public var capexSpent:Double = 0;public var opexSpent:Double = 0;public var trainingSpent:Double = 0; public var capexRemaining:Double { Swift.max(0, capex - capexSpent)} }
public struct CareerYearResult:Identifiable,Codable,Equatable,Sendable { public var id:Int { year };public var year:Int;public var availability:Double;public var failures:Int;public var maintenanceCost:Double;public var downtimeCost:Double;public var customerPenalty:Double;public var capexSpent:Double;public var workforce:Int;public var deferredRisks:Int;public var score:Double }
public struct ShutdownDefense:Codable,Equatable,Sendable { public var requestedHours:Double;public var approvedHours:Double;public var tasks:Int;public var riskAvoided:Double;public var productionCost:Double;public var argumentScore:Double;public var approved:Bool }

public struct ReliabilityManagerCareerRuntime:Sendable {
    public var fleet:ReliabilityManagerCampaignRuntime;public var careerYear:Int = 1;public var maxYears:Int = 8;public var budget:AnnualReliabilityBudget
    public var workforce:[CareerTechnician];public var programMaturity:ProgramMaturity = .basicPM;public var capitalProjects:[CapitalProject] = [];public var rcas:[RCARecord] = [];public var deferred:[DeferredConsequence] = [];public var history:[CareerYearResult] = [];public var reputation:Double = 60;public var safetyCulture:Double = 65;public var executiveTrust:Double = 55;public var rng:ReliabilityRNG
    public init(plant:PlantShiftManagementRuntime,seed:UInt64 = 2026) { fleet = .init(plant:plant,policy:.riskBased,seed:seed); rng = .init(seed:seed ^ 0xCAFE); budget = .init(year:1,capex:650_000,opex:420_000,training:55_000); workforce = [.init(name:"M. Rivera",role:.mechanical,skill:0.72,annualCost:82_000),.init(name:"J. Chen",role:.electrical,skill:0.78,annualCost:88_000),.init(name:"A. Brooks",role:.controls,skill:0.74,annualCost:96_000),.init(name:"S. Patel",role:.reliability,skill:0.68,annualCost:102_000)] }
    public func obsolescenceRisks() -> [ObsolescenceRisk] {
        var result:[ObsolescenceRisk] = []
        for a in fleet.assets.values {
            let age = a.lifecycleAgeYears + Double(careerYear - 1)
            let support = Swift.max(0.0, 12.0 - age)
            let scarcity = Swift.min(1.0, age / 14.0)
            let compat = Swift.max(0.15, 1.0 - age / 18.0)
            let unsupported = Swift.max(0.0, 1.0 - support / 10.0)
            let score = Swift.min(100.0, 100.0 * (0.42 * scarcity + 0.33 * (1.0 - compat) + 0.25 * unsupported))
            result.append(.init(machine:a.machine,supportYearsRemaining:support,partsScarcity:scarcity,cyberCompatibility:compat,score:score))
        }
        return result.sorted { $0.score > $1.score }
    }
    public mutating func hire(role:WorkforceRole) ->Bool { let salary: [WorkforceRole: Double] = [.mechanical:82_000,.electrical:88_000,.controls:98_000,.reliability:105_000,.instrumentation:92_000]; let cost = salary[role]!;guard budget.opex - budget.opexSpent >= cost else { return false }; budget.opexSpent += cost; workforce.append(.init(name:"Hire Y\(careerYear)-\(workforce.count + 1)",role:role,skill:0.58,annualCost:cost));return true }
    public mutating func train(technicianID:String,hours:Double) ->Bool { guard let i = workforce.firstIndex(where: { $0.id == technicianID }) else { return false }; let cost = hours * 180;guard budget.training - budget.trainingSpent >= cost else { return false }; budget.trainingSpent += cost; workforce[i].trainingHours += hours; workforce[i].skill = Swift.min(0.98,workforce[i].skill + hours / 500);return true }
    public mutating func setProgram(_ maturity:ProgramMaturity) {programMaturity = maturity;fleet.policy = maturity == .reactive ? .runToFailure : (maturity == .prescriptive ? .availabilityFirst : .riskBased) }
    public func propose(machine:PlayableMachineKind,decision:CareerAssetDecision) ->CapitalProject { let a = fleet.assets[machine]!;let mult = decision == .repair ? 0.05 : (decision == .rebuild ? 0.28 : (decision == .replace ? 1.0 : 0)); let capex = a.acquisitionCost * mult; let gain = decision == .replace ? 0.9 : (decision == .rebuild ? 0.62 : (decision == .repair ? 0.25 : 0)); return .init(machine:machine,decision:decision,capex:capex,outageHours:decision == .replace ? 36 : (decision == .rebuild ? 20 : 6),reliabilityGain:gain) }
    public mutating func approve(_ project:CapitalProject) ->Bool { guard project.decision != .defer, budget.capexRemaining >= project.capex else { if project.decision == .defer { createDeferred(machine:project.machine,origin:"Deferred capital renewal",years:3,cost:fleet.assets[project.machine]!.acquisitionCost * 0.65,severity:8)}; return false };budget.capexSpent += project.capex; var p = project;p.approved = true;capitalProjects.append(p); if var a = fleet.assets[p.machine] {a.health = Swift.max(0.03, a.health * (1 - p.reliabilityGain)); if p.decision == .replace {a.lifecycleAgeYears = 0;a.weibullScaleDays *= 1.35} else if p.decision == .rebuild {a.lifecycleAgeYears = Swift.max(0, a.lifecycleAgeYears - 3);a.weibullScaleDays *= 1.18};fleet.assets[p.machine] = a }; return true }
    public mutating func performRCA(machine:PlayableMachineKind,quality:RCAQuality) {let risk = quality == .strong ? 0.08 : (quality == .adequate ? 0.22 : (quality == .weak ? 0.55 : 0.82)); let actions = quality == .strong ? ["Eliminate physical cause","Update PM/PdM task","Update spare strategy","Train affected craft"] : ["Restore equipment","Monitor recurrence"]; rcas.append(.init(year:careerYear,machine:machine,quality:quality,rootCause:"Campaign-derived failure mechanism",actions:actions,recurrenceRisk:risk,closed:quality != .none)); if quality == .weak || quality == .none { createDeferred(machine:machine,origin:"Incomplete RCA corrective action",years:3,cost:45_000 + Double(fleet.assets[machine]!.fmea.rpn) * 80,severity:7)} }
    public mutating func defendShutdown(requestedHours:Double) ->ShutdownDefense {let plan = fleet.planTurnaround(startDay:fleet.day + 14,durationHours:requestedHours);let evidence = Swift.min(100, plan.expectedAvoidedCost / 2500 + Double(plan.tasks.count) * 4 + executiveTrust * 0.25); let approved = evidence >= 45; let approvedHours = approved ? requestedHours : Swift.max(4, requestedHours * 0.5); executiveTrust = Swift.min(100, Swift.max(0,executiveTrust + (approved ? 2 : -2))); return .init(requestedHours:requestedHours,approvedHours:approvedHours,tasks:plan.tasks.count,riskAvoided:plan.expectedAvoidedCost,productionCost:plan.productionOpportunityCost,argumentScore:evidence,approved:approved) }
    public mutating func negotiateSpareStrategy(investment:Double) ->Bool {guard budget.opex - budget.opexSpent >= investment else { return false }; budget.opexSpent += investment; let count = Swift.max(1,Int(investment / 2500));for x in fleet.optimizeSpares().prefix(count) {if let i = fleet.plant.spareCrib.firstIndex(where: { $0.partNumber == x.partNumber }) {fleet.plant.spareCrib[i].quantity = Swift.max(fleet.plant.spareCrib[i].quantity,x.recommendedStock)} else { fleet.plant.addSpare(.init(partNumber:x.partNumber,description:"Career reliability strategic spare",quantity:x.recommendedStock,reorderPoint:x.reorderPoint,unitCost:900,normalLeadHours:72,expediteLeadHours:8,expediteFee:450,machineFamilies:[])) } }; return true }
    mutating func createDeferred(machine:PlayableMachineKind,origin:String,years:Int,cost:Double,severity:Int) {deferred.append(.init(createdYear:careerYear,maturityYear:careerYear + years,machine:machine,origin:origin,probability:Swift.min(0.95,0.35 + Double(severity) * 0.055),cost:cost,severity:severity))}
    mutating func matureDeferredRisks() {for i in deferred.indices where !deferred[i].resolved && deferred[i].maturityYear <= careerYear { if rng.nextDouble() < deferred[i].probability { let m = deferred[i].machine; if var a = fleet.assets[m] {a.health = Swift.min(1.25, a.health + 0.35 + Double(deferred[i].severity) * 0.035);a.accumulatedDowntimeCost += deferred[i].cost; fleet.assets[m] = a }; reputation = Swift.max(0,reputation - Double(deferred[i].severity) * 0.7);executiveTrust = Swift.max(0,executiveTrust - 3)}; deferred[i].resolved = true } }
    public mutating func finishYear() throws -> CareerYearResult {
        matureDeferredRisks()
        let factor:Double
        switch programMaturity { case .reactive: factor=1.18; case .basicPM: factor=1.0; case .optimizedPM: factor=0.88; case .predictive: factor=0.76; case .prescriptive: factor=0.66 }
        for m in PlayableMachineKind.allCases { fleet.assets[m]!.degradationPerDay *= factor }
        for _ in 0..<365 {
            fleet.day += 1
            fleet.degradeFleet()
            if programMaturity != .reactive { try fleet.executeDailyReliabilityPlan() }
        }
        let snap = fleet.snapshot()
        let skill = workforce.map { $0.skill }.reduce(0,+) / Double(Swift.max(1,workforce.count))
        let openRisks = deferred.filter { !$0.resolved }.count
        let score = Swift.max(0, Swift.min(100, snap.score + skill * 12 + reputation * 0.12 + executiveTrust * 0.08 - Double(openRisks)))
        let result = CareerYearResult(year:careerYear,availability:snap.fleetAvailability,failures:snap.failedAssets,maintenanceCost:snap.maintenanceCost,downtimeCost:snap.downtimeCost,customerPenalty:snap.customerPenalty,capexSpent:budget.capexSpent,workforce:workforce.count,deferredRisks:openRisks,score:score)
        history.append(result)
        careerYear += 1
        if careerYear <= maxYears {
            let trustFactor = 0.8 + executiveTrust / 250
            budget = .init(year:careerYear,capex:(600_000 + Double(careerYear)*45_000)*trustFactor,opex:(430_000 + Double(careerYear)*18_000)*trustFactor,training:55_000 + Double(careerYear)*4_000)
        }
        for m in PlayableMachineKind.allCases { fleet.assets[m]!.lifecycleAgeYears += 1 }
        return result
    }
}
