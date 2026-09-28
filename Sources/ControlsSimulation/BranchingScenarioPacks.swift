import Foundation

public enum BranchingScenarioPackID: String, Codable, CaseIterable, Sendable {
    case nightShiftFromHell, customerLaunchDay, postShutdownStartup, utilityCrisis, weekendSkeletonCrew
}

public enum BranchOperation: Codable, Equatable, Sendable {
    case advanceMinutes(Double)
    case directCost(Double, String)
    case inspectHistorian
    case askOperator(String)
    case stopLine
    case requestVendor(delayMinutes: Double, cost: Double)
    case authorizeOvertime(Double)
    case dispatchRule(DispatchRule)
    case customerPriority(Int)
    case scheduleBranchIncident(String, delayMinutes: Double)
    case suppressBranchIncident(String)
    case diagnosis(Double)
    case risk(Double)
    case trust(Double)
    case qualityRisk(Double)
    case recurrenceRisk(Double)
    case addTag(String)
}

public struct BranchChoice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var rationale: String
    public var immediateFeedback: String
    public var operations: [BranchOperation]
    public init(id:String,title:String,rationale:String,immediateFeedback:String,operations:[BranchOperation]) { self.id=id;self.title=title;self.rationale=rationale;self.immediateFeedback=immediateFeedback;self.operations=operations }
}

public struct BranchDecisionGate: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var sequence:Int
    public var title:String
    public var situation:String
    public var hiddenTeachingPoint:String
    public var choices:[BranchChoice]
    public init(id:String,sequence:Int,title:String,situation:String,hiddenTeachingPoint:String,choices:[BranchChoice]) { self.id=id;self.sequence=sequence;self.title=title;self.situation=situation;self.hiddenTeachingPoint=hiddenTeachingPoint;self.choices=choices }
}

public struct BranchIncidentTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id:String
    public var title:String
    public var domain:DecisionIncidentDomain
    public var severity:IncidentSeverity
    public var machineOffset:Int
    public var area:PlantArea
    public var skill:PlantSkill
    public var tools:[String]
    public var permitKind:PermitKind
    public var permanentMinutes:Double
    public var temporaryMinutes:Double
    public var recurrenceMinutes:Double?
    public var lossPerMinute:Double
    public var safetyCritical:Bool
    public var rootCause:String
    public var openingFact:String
    public var falseLead:String
}

public struct BranchingScenarioPack: Identifiable, Codable, Equatable, Sendable {
    public var id:BranchingScenarioPackID
    public var title:String
    public var subtitle:String
    public var briefing:String
    public var learningObjectives:[String]
    public var gates:[BranchDecisionGate]
    public var branchIncidents:[BranchIncidentTemplate]
    public var startingBudgetPressure:Double
}

public struct BranchChoiceRecord: Identifiable, Codable, Equatable, Sendable {
    public var id:String=UUID().uuidString
    public var timestamp:Double
    public var gateID:String
    public var choiceID:String
    public var choiceTitle:String
    public var feedback:String
    public var tagsAfter:[String]
}

public struct BranchingCampaignScore: Codable, Equatable, Sendable {
    public var plantScore:Double
    public var decisionScore:Double
    public var earlyDecisionQuality:Double
    public var branchControl:Double
    public var trust:Double
    public var qualityProtection:Double
    public var riskPenalty:Double
    public var overall:Double { max(0,min(100,plantScore*0.30+decisionScore*0.25+earlyDecisionQuality*0.20+branchControl*0.10+trust*0.075+qualityProtection*0.075-riskPenalty*0.15)) }
}

public struct BranchingCampaignEnding: Codable, Equatable, Sendable {
    public var title:String
    public var summary:String
    public var decisiveMoments:[String]
    public var score:BranchingCampaignScore
}

public struct BranchingScenarioRuntime: Sendable {
    public var pack:BranchingScenarioPack
    public var game:SupervisorTechnicianDecisionGameRuntime
    public var records:[BranchChoiceRecord]=[]
    public var tags:Set<String>=[]
    public var suppressedIncidentIDs:Set<String>=[]
    public var scheduledIncidentIDs:Set<String>=[]
    public var riskPressure:Double=0
    public var trust:Double=70
    public var qualityRisk:Double=0
    public var recurrenceRisk:Double=0
    public var earlyDecisionPoints:Double=0
    public var decisionCount:Int { records.count }
    public var currentGate:BranchDecisionGate? { pack.gates.sorted{$0.sequence<$1.sequence}.first{ gate in !records.contains(where:{$0.gateID==gate.id}) } }
    public var complete:Bool { currentGate == nil }

    public init(pack:BranchingScenarioPack, project:LineBuilderProject)throws {
        self.pack=pack
        self.game=try SupervisorTechnicianDecisionGameTemplates.twentyFourHourDecisionCampaign(project:project)
        self.riskPressure=pack.startingBudgetPressure
        // Scenario packs own the opening incident cadence; keep baseline incidents but shift them later to avoid identical openings.
        for i in game.incidents.indices { game.incidents[i].scheduledAt += 7_200 }
    }

    @discardableResult public mutating func choose(_ choiceID:String)throws->DecisionGameSnapshot {
        guard let gate=currentGate,let choice=gate.choices.first(where:{$0.id==choiceID}) else { return try game.cycle(elapsedMilliseconds:1) }
        let incidentID=game.visibleIncidents.first(where:{$0.active})?.id ?? game.incidents.first(where:{$0.active})?.id
        for op in choice.operations { try apply(op, incidentID:incidentID) }
        records.append(.init(timestamp:game.plant.mes.elapsedSeconds,gateID:gate.id,choiceID:choice.id,choiceTitle:choice.title,feedback:choice.immediateFeedback,tagsAfter:Array(tags).sorted()))
        let quality = choice.id.contains("best") || choice.id.contains("verify") || choice.id.contains("safe") || choice.id.contains("evidence") ? 10.0 : (choice.id.contains("bad") || choice.id.contains("rush") || choice.id.contains("bypass") ? -6.0 : 4.0)
        if gate.sequence <= 10 { earlyDecisionPoints += quality }
        applyBranchEscalation(after:gate)
        return try game.cycle(elapsedMilliseconds:1)
    }

    @discardableResult public mutating func run(seconds:Double,stepMilliseconds:Int32=10_000)throws->DecisionGameSnapshot { try game.run(seconds:seconds,stepMilliseconds:stepMilliseconds) }
    @discardableResult public mutating func finish24Hours(stepMilliseconds:Int32=60_000)throws->DecisionGameSnapshot { try game.run24Hours(stepMilliseconds:stepMilliseconds) }

    public func score()->BranchingCampaignScore {
        let d=game.score(); let early=max(0,min(100,50+earlyDecisionPoints)); let control=max(0,min(100,100-riskPressure*24-recurrenceRisk*20)); let q=max(0,min(100,100-qualityRisk*25))
        return .init(plantScore:d.basePlantScore,decisionScore:d.overall,earlyDecisionQuality:early,branchControl:control,trust:max(0,min(100,trust)),qualityProtection:q,riskPenalty:max(0,riskPressure*10))
    }

    public func ending()->BranchingCampaignEnding {
        let s=score(); let title:String; let summary:String
        if s.overall >= 90 { title="Controlled the Chaos"; summary="You protected people, evidence, quality, and customer commitments while keeping the plant economically disciplined." }
        else if s.overall >= 78 { title="Recovered the Shift"; summary="The plant recovered, but several early decisions created avoidable downtime, cost, or risk." }
        else if s.overall >= 62 { title="Production Survived"; summary="Orders moved, but resource contention and reactive decisions left meaningful losses and unresolved exposure." }
        else if s.overall >= 45 { title="Escalation Took Control"; summary="Management, maintenance, and customer pressure overtook the shift because early uncertainty was not controlled quickly enough." }
        else { title="Cascade Failure"; summary="Compounding technical and supervisory choices converted recoverable faults into a plant-wide production and economic event." }
        let decisive=records.prefix(10).map{"Gate \($0.gateID): \($0.choiceTitle) — \($0.feedback)"}
        return .init(title:title,summary:summary,decisiveMoments:Array(decisive),score:s)
    }

    private mutating func apply(_ op:BranchOperation,incidentID:String?)throws {
        switch op {
        case .advanceMinutes(let m): _=try game.run(seconds:max(0,m)*60,stepMilliseconds:10_000)
        case .directCost(let d,let note): game.plant.economics.spareParts += max(0,d); game.replay.append(.init(timestamp:game.plant.mes.elapsedSeconds,category:"Branch decision",decision:note,actualConsequence:"Direct cost \(Int(d))",downtimeMinutes:0,dollarImpact:d,counterfactual:"A different branch may trade cost for time/risk.",preventableMinutes:0,preventableDollars:0))
        case .inspectHistorian: if let id=incidentID { game.inspectHistorian(incidentID:id) }
        case .askOperator(let check): if let id=incidentID { game.askOperatorToCheck(incidentID:id,check:check) }
        case .stopLine: if let id=incidentID { game.stopLine(for:id) }
        case .requestVendor(let delay,let cost): if let id=incidentID { _=game.requestVendor(incidentID:id,delayMinutes:delay,cost:cost) }
        case .authorizeOvertime(let hours): game.plant.authorizeOvertime(hours:hours)
        case .dispatchRule(let r): game.plant.resequenceOrders(using:r)
        case .customerPriority(let p): if let id=game.plant.mes.orders.first?.id { game.reprioritize(orderID:id,priority:p) }
        case .scheduleBranchIncident(let id,let delay): scheduleIncident(id,delayMinutes:delay)
        case .suppressBranchIncident(let id): suppressedIncidentIDs.insert(id)
        case .diagnosis(let v): if let id=incidentID,let i=game.incidents.firstIndex(where:{$0.id==id}) { game.incidents[i].diagnosisConfidence=max(0,min(1,game.incidents[i].diagnosisConfidence+v)) }
        case .risk(let v): riskPressure=max(0,riskPressure+v)
        case .trust(let v): trust=max(0,min(100,trust+v))
        case .qualityRisk(let v): qualityRisk=max(0,qualityRisk+v)
        case .recurrenceRisk(let v): recurrenceRisk=max(0,recurrenceRisk+v)
        case .addTag(let t): tags.insert(t)
        }
    }

    private mutating func scheduleIncident(_ templateID:String,delayMinutes:Double) {
        guard !suppressedIncidentIDs.contains(templateID),!scheduledIncidentIDs.contains(templateID),let t=pack.branchIncidents.first(where:{$0.id==templateID}) else{return}
        let machines=game.plant.mes.line.project.nodes.map(\.machine); let m=machines.isEmpty ? nil : machines[min(max(0,t.machineOffset),machines.count-1)]
        let incident=DecisionIncident(id:"\(pack.id.rawValue).\(t.id)",title:t.title,domain:t.domain,severity:t.severity,scheduledAt:game.plant.mes.elapsedSeconds+max(0,delayMinutes)*60,truth:.init(rootCause:t.rootCause,actualMachine:m,actualArea:t.area,requiredSkill:t.skill,requiredToolIDs:t.tools,permitKind:t.permitKind,permanentRepairMinutes:t.permanentMinutes,temporaryRepairMinutes:t.temporaryMinutes,temporaryRecurrenceAfterMinutes:t.recurrenceMinutes,lossPerMinute:t.lossPerMinute,safetyCritical:t.safetyCritical),knownFacts:[t.openingFact],falseLeads:[t.falseLead])
        game.addIncident(incident); scheduledIncidentIDs.insert(templateID)
    }

    private mutating func applyBranchEscalation(after gate:BranchDecisionGate) {
        // Poor early control causes authored secondary incidents; disciplined evidence can suppress them.
        if riskPressure >= 1.6, gate.sequence <= 6, let t=pack.branchIncidents.first(where:{!scheduledIncidentIDs.contains($0.id) && !suppressedIncidentIDs.contains($0.id)}) { scheduleIncident(t.id,delayMinutes:20+Double(gate.sequence)*4) }
        if qualityRisk >= 1.2 { tags.insert("qualityContainmentRequired") }
        if recurrenceRisk >= 1.2 { tags.insert("temporaryRepairDebt") }
        if trust < 45 { tags.insert("managementTrustLow") }
    }
}

public enum BranchingScenarioPackCatalog {
    public static let all:[BranchingScenarioPack] = [.nightShiftFromHell,.customerLaunchDay,.postShutdownStartup,.utilityCrisis,.weekendSkeletonCrew]
    public static func pack(_ id:BranchingScenarioPackID)->BranchingScenarioPack { all.first{$0.id==id}! }
}

private extension BranchChoice {
    static func c(_ id:String,_ title:String,_ rationale:String,_ feedback:String,_ ops:[BranchOperation])->Self { .init(id:id,title:title,rationale:rationale,immediateFeedback:feedback,operations:ops) }
}
private extension BranchDecisionGate {
    static func g(_ n:Int,_ key:String,_ title:String,_ situation:String,_ teaching:String,_ choices:[BranchChoice])->Self { .init(id:"G\(n)-\(key)",sequence:n,title:title,situation:situation,hiddenTeachingPoint:teaching,choices:choices) }
}
private extension BranchIncidentTemplate {
    static func i(_ id:String,_ title:String,_ domain:DecisionIncidentDomain,_ severity:IncidentSeverity,_ offset:Int,_ area:PlantArea,_ skill:PlantSkill,_ tools:[String],_ permitKind:PermitKind,_ root:String,_ fact:String,_ falseLead:String,_ loss:Double,_ safe:Bool=false)->Self { .init(id:id,title:title,domain:domain,severity:severity,machineOffset:offset,area:area,skill:skill,tools:tools,permitKind:permitKind,permanentMinutes:55,temporaryMinutes:18,recurrenceMinutes:90,lossPerMinute:loss,safetyCritical:safe,rootCause:root,openingFact:fact,falseLead:falseLead) }
}

private extension BranchingScenarioPack {
    static var nightShiftFromHell:Self { .init(id:.nightShiftFromHell,title:"Night Shift From Hell",subtitle:"Three failures. Two specialists. One bad handoff.",briefing:"You inherit a running plant at 23:00 with weak handoff notes, one high-priority order, and a maintenance crew already stretched thin. The first symptoms look unrelated.",learningObjectives:["Control uncertainty before dispatching scarce specialists","Separate correlated symptoms from independent faults","Balance temporary recovery against recurrence debt","Protect safety when production pressure rises"],gates:[
        .g(1,"handoff","Trust the handoff?","Prior shift says the conveyor VFD is failing, but no diagnostic capture was saved.","Handoffs are evidence, not truth.",[.c("best-evidence","Verify historian before dispatch","Use existing evidence first.","You preserve the controls specialist while testing the VFD theory.",[.inspectHistorian,.diagnosis(0.25),.risk(-0.25),.addTag("evidenceFirst")]),.c("rush-vfd","Send controls tech to VFD immediately","Fast response to a weak hypothesis.","The specialist is committed before the failure mode is confirmed.",[.advanceMinutes(8),.risk(0.45),.trust(-4),.scheduleBranchIncident("airLeak",delayMinutes:32)]),.c("bad-ignore","Keep running until it stops again","Protect output now.","Intermittent evidence is lost and the next stop is more disruptive.",[.advanceMinutes(22),.risk(0.75),.recurrenceRisk(0.4)])]),
        .g(2,"firstcall","Second operator call","Utilities reports low air pressure while Packaging reports random cylinder timeouts.","Correlated symptoms may share a utility cause.",[.c("best-correlate","Correlate plant air and sequence trends","Test one cause against both symptoms.","The common utility signature becomes visible.",[.askOperator("physical pressure feedback"),.diagnosis(0.2),.suppressBranchIncident("falseVFD"),.risk(-0.25)]),.c("split-team","Split scarce technicians","Parallel work may reduce elapsed time.","Coverage improves, but no specialist is available for a new critical call.",[.advanceMinutes(10),.risk(0.2),.scheduleBranchIncident("bearing",delayMinutes:25)]),.c("rush-reset","Reset faults and continue","Recover without understanding.","The line runs, but recurrence probability rises sharply.",[.recurrenceRisk(0.8),.risk(0.5),.advanceMinutes(5)])]),
        .g(3,"tool","Tool conflict","The only loop calibrator is in Quality; the DMM is with another technician.","Tool logistics are part of MTTR.",[.c("best-stage","Stage tools before the next stop","Spend travel time proactively.","The next field response avoids a retrieval delay.",[.advanceMinutes(6),.risk(-0.2),.addTag("toolsStaged")]),.c("wait-tools","Wait until a fault is confirmed","Avoid unnecessary motion.","You save six minutes now but expose the next incident to longer MTTR.",[.risk(0.25)]),.c("rush-borrow","Borrow unverified contractor meter","Fast but uncertain measurement quality.","A questionable measurement adds diagnostic ambiguity.",[.diagnosis(-0.1),.trust(-3),.qualityRisk(0.25)])]),
        .g(4,"repair","Temporary or permanent?","A loose terminal is confirmed. Permanent repair requires LOTO and 35–50 minutes.","Fast recovery creates recurrence debt.",[.c("best-safe","Take permanent repair window","Accept downtime now.","The recurring electrical fault is removed from the rest of the shift.",[.advanceMinutes(42),.risk(-0.45),.recurrenceRisk(-0.8),.suppressBranchIncident("falseVFD")]),.c("temp-jumper","Temporary repair to make the order","Restore output quickly.","Production recovers, but the shift inherits recurrence exposure.",[.advanceMinutes(14),.recurrenceRisk(0.9),.scheduleBranchIncident("recurrence",delayMinutes:95)]),.c("bad-hotwork","Tighten energized without permit","Avoid downtime.","You create a major safety-discipline penalty and management exposure.",[.risk(1.2),.trust(-18),.directCost(2500,"Safety exposure investigation")])]),
        .g(5,"bearing","Simultaneous mechanical call","A motor shows vibration while controls work is still active.","The same specialist cannot be everywhere.",[.c("best-triage","Use vibration evidence and rank failure risk","Triage by consequence and evidence.","The bearing event is planned before seizure.",[.diagnosis(0.15),.risk(-0.3),.suppressBranchIncident("seizure")]),.c("rush-defer","Defer mechanical until order completes","Protect schedule.","Bearing damage continues accumulating.",[.risk(0.7),.scheduleBranchIncident("seizure",delayMinutes:45)]),.c("neutral-oem","Call mechanical vendor","Buy expertise at the cost of delay and money.","Vendor support improves diagnosis but arrives later.",[.requestVendor(delayMinutes:35,cost:700),.directCost(700,"Mechanical vendor escalation")])]),
        .g(6,"customer","Customer priority call","A line-down customer requests the next pallet two hours earlier.","Priority changes can destabilize an already constrained system.",[.c("best-plan","Recalculate critical-ratio dispatch","Change schedule using current capacity.","The recovery plan reflects real constraints.",[.dispatchRule(.criticalRatio),.customerPriority(100),.risk(-0.1)]),.c("rush-promise","Promise it without capacity check","Protect relationship immediately.","The commitment is now more aggressive than demonstrated capacity.",[.customerPriority(100),.trust(3),.risk(0.5)]),.c("bad-refuse","Refuse all reprioritization","Protect internal efficiency.","Customer escalation rises despite stable dispatch.",[.trust(-10),.directCost(1800,"Customer service escalation exposure")])]),
        .g(7,"fatigue","Crew fatigue","The night crew has been in response mode for hours.","Human performance is a production variable.",[.c("best-overtime","Bring a targeted recovery technician","Add capacity before the next failure.","Overtime costs money but lowers resource contention.",[.authorizeOvertime(4),.directCost(520,"Targeted overtime coverage"),.risk(-0.35)]),.c("neutral-hold","Stay with current staffing","Avoid overtime.","Costs stay lower but specialist contention remains.",[.risk(0.15)]),.c("bad-allot","Put everyone on overtime","Maximize coverage.","Labor cost rises faster than useful capacity.",[.authorizeOvertime(8),.directCost(1600,"Broad overtime authorization")])]),
        .g(8,"recurrence","Symptom returns","The earlier intermittent stop returns during a product transition.","Temporary fixes need explicit debt management.",[.c("best-stop","Stop and permanently eliminate recurrence","Use accumulated evidence.","You convert repeated stops into one controlled outage.",[.risk(-0.4),.recurrenceRisk(-0.8),.advanceMinutes(38)]),.c("rush-reset2","Reset one more time","Preserve the current run.","Recurrence debt remains and the next interruption is less predictable.",[.recurrenceRisk(0.6),.risk(0.45)]),.c("neutral-vendor","Wait for OEM guidance","Defer commitment.","Diagnosis improves, but production waits for external support.",[.requestVendor(delayMinutes:25,cost:500),.advanceMinutes(25)])]),
        .g(9,"handoff2","Prepare day-shift handoff","Several issues are closed; one temporary repair may remain.","Communication quality affects next-shift MTTR.",[.c("best-handoff","Record verified facts, open risk, and exact temporary work","High-fidelity transfer.","Day shift inherits evidence rather than rumors.",[.trust(8),.risk(-0.25),.addTag("highFidelityHandoff")]),.c("neutral-short","Write a short status note","Basic continuity.","Important diagnostic context is omitted.",[.trust(1)]),.c("bad-clean","Report everything normal","Hide unfinished risk.","The next team loses the evidence chain.",[.trust(-15),.risk(0.7)])]),
        .g(10,"finish","Last-hour decision","Output is behind target but the line is stable.","Recovery should not recreate risk at shift end.",[.c("best-recover","Run constrained recovery plan","Use verified stable capacity.","You recover schedule without reopening controlled risks.",[.dispatchRule(.criticalRatio),.risk(-0.3)]),.c("rush-max","Run maximum speed","Chase output.","Short-term throughput improves but process and recurrence risk increase.",[.risk(0.7),.qualityRisk(0.5)]),.c("neutral-hold","Hold current rate","Protect stability.","You finish safely but accept more schedule loss.",[.risk(-0.1),.directCost(900,"Accepted customer lateness exposure")])])],branchIncidents:[
            .i("airLeak","Plant air header decays",.utility,.degraded,0,.utilities,.mechanical,["PRESS-01"],.none,"Pneumatic header leak plus cycling compressor","Multiple cylinders slow together.","Packaging operator blames sticky solenoids.",260),
            .i("falseVFD","Conveyor trips again",.controls,.lineStop,0,.packaging,.controls,["DMM-01","LAPTOP-01"],.loto,"Loose field terminal, not VFD failure","Input power collapses before the stop.","VFD fault history looks suspicious but is consequential.",340),
            .i("bearing","Utility motor vibration rises",.mechanical,.degraded,1,.utilities,.mechanical,["VIB-01","IR-01"],.loto,"Bearing outer-race damage","Vibration repeats at a mechanical frequency.","Operator suggests raising overload setting.",420,true),
            .i("seizure","Motor bearing seizes",.mechanical,.critical,1,.utilities,.mechanical,["VIB-01","IR-01"],.loto,"Deferred bearing degradation reached seizure","Motor current spikes and speed collapses.","Controls is blamed because the starter dropped out.",700,true),
            .i("recurrence","Temporary electrical repair fails",.electrical,.lineStop,0,.packaging,.electrical,["DMM-01"],.loto,"Temporary terminal repair loosened under vibration","Same I/O point drops out again.","Operator says the PLC program changed itself.",410)
        ],startingBudgetPressure:0.45) }

    static var customerLaunchDay:Self { makePack(id:.customerLaunchDay,title:"Customer Launch Day",subtitle:"First production. Zero schedule margin. Quality under scrutiny.",briefing:"A strategic customer is launching a new SKU today. Corporate leadership is onsite. The first good shipment must leave on time, but the process has never run a full-rate commercial day.",focus:"quality",incidents:[.i("recipe","Wrong recipe revision loaded",.quality,.lineStop,1,.process,.controls,["LAPTOP-01"],.none,"MES recipe revision and PLC parameter set are mismatched","First-piece dimensions trend toward the control limit.","Operator says raw material feels different.",520),.i("sensor","Inspection sensor drifts",.instrumentation,.degraded,2,.qualityLab,.instrumentation,["LOOP-01"],.lineBreak,"Inspection transmitter warmup drift","Reject rate rises slowly after warmup.","Quality suspects the new supplier lot.",430),.i("rush","Launch-rate jam",.process,.lineStop,0,.packaging,.mechanical,["DMM-01"],.none,"Accumulation zone is tuned for legacy line speed","Backpressure rises only at launch speed.","Controls code is blamed for missed photoeyes.",480)]) }
    static var postShutdownStartup:Self { makePack(id:.postShutdownStartup,title:"Post-Shutdown Startup",subtitle:"Everything was touched. Nothing is proven yet.",briefing:"The plant is returning from a major shutdown. Wiring, valves, instruments, drives, and safety devices were serviced. Production wants immediate startup, but latent installation errors remain.",focus:"startup",incidents:[.i("phase","Motor phase rotation reversed",.electrical,.critical,0,.electricalRoom,.electrical,["DMM-01"],.loto,"Motor leads were landed with reversed phase rotation","Pump develops abnormal current with low flow.","Mechanical crew thinks the rebuilt pump is bad.",600,true),.i("impulse","Transmitter impulse line swapped",.instrumentation,.lineStop,1,.process,.instrumentation,["PRESS-01"],.lineBreak,"High/low impulse lines were reversed during shutdown","DP signal responds in the wrong direction.","PLC scaling is blamed because value is negative.",450),.i("safety","Guard channel not restored",.electrical,.critical,2,.packaging,.electrical,["DMM-01"],.loto,"Safety channel jumper was removed and field wiring restored incorrectly","Safety reset will not complete.","Operator asks to bypass the guard for startup.",700,true)]) }
    static var utilityCrisis:Self { makePack(id:.utilityCrisis,title:"Utility Crisis",subtitle:"The plant is healthy. The utilities are not.",briefing:"A severe storm and utility curtailment reduce electrical and compressed-air capacity. The learner must decide what to shed, what to protect, and when to restart interconnected systems.",focus:"utility",incidents:[.i("air","Compressed-air header collapse",.utility,.critical,0,.utilities,.mechanical,["PRESS-01"],.none,"Compressor capacity lost after feeder trip","Air header falls across multiple areas.","Production thinks dozens of valves failed at once.",650,true),.i("brownout","Voltage sag trips drives",.electrical,.lineStop,1,.electricalRoom,.electrical,["DMM-01","LAPTOP-01"],.electricalSafeWork,"Incoming voltage sag exceeds ride-through settings","Multiple drives log undervoltage within milliseconds.","Network switch is blamed for simultaneous communication losses.",590),.i("chiller","Chilled-water capacity shortage",.utility,.degraded,2,.utilities,.mechanical,["IR-01"],.none,"Cooling tower fan unavailable during peak wet-bulb load","Loop temperature climbs as process demand increases.","Operator suggests raising chiller setpoint to stop alarms.",420)]) }
    static var weekendSkeletonCrew:Self { makePack(id:.weekendSkeletonCrew,title:"Weekend Skeleton Crew",subtitle:"Few people. Long vendor delays. Every dispatch matters.",briefing:"The weekend production plan looks easy until several low-frequency failures appear. Only a small cross-trained crew is onsite, the parts crib is limited, and OEM response is slow.",focus:"resources",incidents:[.i("servo","Servo feedback cable intermittency",.controls,.lineStop,0,.packaging,.controls,["LAPTOP-01","DMM-01"],.loto,"Encoder connector has fretting corrosion","Position error spikes only during high acceleration.","Operator says the servo motor is worn out.",480),.i("seal","Pump seal leak",.mechanical,.degraded,1,.process,.mechanical,["IR-01"],.lineBreak,"Mechanical seal face damaged","Leak rate rises with discharge pressure.","Instrumentation tech thinks the flow meter is leaking.",390),.i("spare","Remote I/O adapter failure",.controls,.critical,2,.electricalRoom,.controls,["LAPTOP-01","DMM-01"],.loto,"Remote I/O adapter power supply fails thermally","Entire remote rack drops after warmup.","Prior shift blamed Ethernet packet loss.",620,true)]) }

    static func makePack(id:BranchingScenarioPackID,title:String,subtitle:String,briefing:String,focus:String,incidents:[BranchIncidentTemplate])->Self {
        let scripts:[String:[(String,String,String,String,String,String)]] = [
            "quality":[
                ("First-piece release","The first launch samples are barely inside specification, but shipment timing is already at risk.","Hold for verified capability","Ship first pieces under heightened inspection","Release immediately to protect launch time","First-piece approval is a quality gate, not a calendar event."),
                ("Recipe revision conflict","MES shows revision C while the controller download record shows revision B.","Stop and reconcile recipe genealogy","Run one controlled comparison batch","Assume PLC is correct and continue","Recipe provenance must be proven before volume production."),
                ("Supplier lot question","Quality sees a process shift just after a raw-material lot change.","Correlate lot, process, and sensor history","Quarantine only suspect WIP","Blame supplier and purge all material","Correlation prevents both under-containment and needless scrap."),
                ("Inspection drift","Reject rate rises slowly as the vision/instrument station warms up.","Verify the measurement system","Widen sampling temporarily","Widen acceptance limits","Never solve a measurement problem by moving the spec."),
                ("Launch-rate pressure","Corporate asks for nameplate speed before the line has demonstrated stable accumulation control.","Ramp speed with capability checks","Increase in two controlled steps","Go straight to maximum rate","Rate increases expose latent line-control interactions."),
                ("Customer ETA call","The customer asks for an exact truck-ready time while the process is still unstable.","Commit from constrained forecast","Give a conservative time buffer","Promise the requested time","A credible promise beats an optimistic one that drives bad decisions."),
                ("Rework temptation","A pallet of borderline launch product could be reworked and still make the truck.","Segregate and disposition by genealogy","Rework only fully traceable units","Blend borderline product into good stock","Genealogy must survive recovery decisions."),
                ("Second failure","A filler/packaging stop appears while Quality is still investigating the launch deviation.","Protect quality containment and triage separately","Split team and accept slower closure","Collapse both symptoms into one assumed cause","Simultaneous incidents require independent evidence chains."),
                ("Management walkdown","Leadership asks why the launch is behind and whether controls is the bottleneck.","Present evidence, capacity, and risks","Give status without root-cause detail","Name a department before proof","Management escalation should improve decisions, not distort diagnosis."),
                ("Ship-or-hold decision","The truck cutoff is approaching with some product verified and some still under investigation.","Ship only released genealogy","Delay entire shipment","Release all to protect OTIF","Customer service cannot override product disposition." )],
            "startup":[
                ("Energization readiness","Production asks to energize before every shutdown redline is closed.","Verify energization package","Energize noncritical islands only","Energize the entire line","Startup discipline prevents latent installation errors becoming damage."),
                ("Wrong rotation symptom","A pump draws current but develops poor flow after motor work.","Prove rotation locally","Change PLC output logic","Increase VFD speed","Electrical/mechanical direction must be checked at the physical asset."),
                ("Safety reset blocked","A guard channel will not reset and schedule pressure is rising.","Troubleshoot the safety circuit","Inspect wiring while keeping safety active","Bypass the channel for startup","Safety faults are not production interlocks to be defeated."),
                ("Instrument sign error","A differential transmitter moves opposite expected direction during loop check.","Trace impulse lines and raw signal","Invert scaling in PLC temporarily","Assume process piping is wrong","Startup should repair physical truth, not encode compensating software mistakes."),
                ("Punch-list conflict","Several B-list punch items remain while Production wants wet commissioning.","Reclassify by startup risk","Proceed with documented restrictions","Close punch items administratively","Punch severity must reflect actual energization/process risk."),
                ("First motor solo run","A rebuilt motor shows mild vibration but stays below trip limits.","Capture baseline and inspect","Accept as normal after overhaul","Raise protection threshold","Startup baselines are future troubleshooting evidence."),
                ("Network node missing","One remote I/O rack intermittently disappears after shutdown switch work.","Inspect topology/diagnostics first","Power-cycle until stable","Replace controller","Commissioning faults often cluster around touched infrastructure."),
                ("Operator pressure","Operations asks to skip cold checks because the product window is closing.","Keep commissioning gates intact","Compress checks using parallel teams","Skip directly to hot commissioning","Sequence discipline is cheaper than startup damage."),
                ("Startup handoff","Night commissioning must hand a partially proven line to day shift.","Document proven/unproven boundaries","List only open alarms","Say line is production-ready","A startup handoff must distinguish tested from assumed."),
                ("Production release","The line has run three cycles; one latent anomaly remains unexplained.","Hold release until anomaly is bounded","Release at reduced rate with monitoring","Declare full production","Production release is an engineering decision with explicit residual risk." )],
            "utility":[
                ("Storm warning","Utility provider warns of an incoming demand curtailment and unstable weather.","Pre-plan load shedding","Wait for the first trip","Run everything while power is available","Preemptive load strategy prevents uncontrolled cascades."),
                ("Air header falling","Compressed-air pressure decays across multiple production areas.","Prioritize critical pneumatic users","Raise compressor setpoint","Keep every line running","Utility scarcity requires load prioritization, not setpoint chasing."),
                ("Drive undervoltage wave","Several drives trip within milliseconds of each other.","Correlate common bus event","Troubleshoot the nearest drive","Replace the network switch","Near-simultaneous faults usually point upstream."),
                ("Cooling capacity","Chilled-water return temperature rises as outside conditions worsen.","Shed noncritical thermal loads","Lower chilled-water setpoint","Ignore until process alarms","Utility capacity must be allocated by process consequence."),
                ("Restart order","Power stabilizes but multiple systems are ready to restart simultaneously.","Sequence utility and process restart","Restart highest-output line first","Let operators restart independently","Restart sequencing prevents inrush and dependency failures."),
                ("Customer pressure","A critical order is due while the plant is on utility curtailment.","Reforecast against constrained capacity","Promise recovery after storm","Override load shedding","Customer urgency cannot create utility capacity."),
                ("Generator decision","Backup generation can support only part of the facility.","Reserve generator for critical controls/process","Spread power evenly","Use it only for production motors","Resilience depends on protecting enabling infrastructure."),
                ("Second utility loss","Plant air recovers as cooling capacity falls.","Rebalance by bottleneck consequence","Keep original shed list","Restore everything then react","Utility crises are dynamic allocation problems."),
                ("Management escalation","Leadership asks which line should be sacrificed to protect the plant.","Use economic + safety + customer ranking","Protect the loudest customer","Rotate outages equally","Curtailment should be intentional and explainable."),
                ("Weather clears","Capacity returns near shift end, with a large backlog waiting.","Ramp loads in staged recovery","Restart at maximum rate","Delay all restarts until next shift","Recovery can trigger a second cascade if dependencies are ignored." )],
            "resources":[
                ("Thin staffing","Only one strong controls technician and one mechanical generalist are onsite.","Map skills to likely risks","Assign both to production floor","Wait until a failure occurs","Scarce-resource planning starts before the call."),
                ("Servo intermittent","A servo position error occurs only at high acceleration.","Capture drive/encoder evidence","Replace servo motor","Lower acceleration and continue indefinitely","Intermittent motion faults demand evidence before expensive replacement."),
                ("Tool availability","The programming laptop is across the plant and the DMM is checked out.","Stage the critical kit","Send tech without tools","Borrow unknown tools","Tool logistics can dominate weekend MTTR."),
                ("Pump leak","A process pump develops a seal leak while the controls tech is occupied.","Contain leak and triage mechanical risk","Wait for controls tech","Keep running to avoid downtime","Cross-discipline triage matters with skeleton crews."),
                ("OEM queue","Vendor support estimates a 90-minute callback.","Request support early while diagnosing locally","Wait until local options are exhausted","Replace hardware before callback","Vendor latency should run in parallel with local evidence gathering."),
                ("No spare adapter","A remote I/O adapter is suspected but the crib has no identical spare.","Verify failure then expedite correct part","Swap from another running line","Order several possible parts","Parts strategy affects both present and future availability."),
                ("Temporary repair","A safe temporary repair could restore production before the part arrives.","Use temporary repair with expiry/control plan","Refuse all temporary work","Make an undocumented workaround","Temporary repairs must become visible technical debt."),
                ("Competing call","A second line fails while your controls specialist is committed.","Triage by consequence and skill fit","Pull specialist immediately","Have operator experiment with logic","Simultaneous failures require explicit dispatch arbitration."),
                ("Weekend handoff","Monday staff will inherit unresolved temporary work and vendor actions.","Create high-fidelity technical handoff","Leave a short shift note","Assume Monday will rediscover it","Weekend recovery is incomplete until knowledge is transferred."),
                ("Sunday recovery","Orders are behind but the plant is stable and the next crew arrives soon.","Use constrained overtime/recovery","Run maximum rate until crew change","Stop early and leave backlog","Recovery decisions should account for fatigue, risk, and next-shift capacity." )]
        ]
        let selected=scripts[focus] ?? scripts["resources"]!
        let gates:[BranchDecisionGate] = selected.enumerated().map { idx,item in
            let n=idx+1
            return .g(n,"\(focus)\(n)",item.0,item.1,item.5,[
                .c("best-verify-\(n)",item.2,"Evidence-first controlled response.","You reduce uncertainty before committing scarce capacity.",[.inspectHistorian,.diagnosis(0.15),.risk(-0.2), n==2 ? .suppressBranchIncident(incidents.last?.id ?? ""):.addTag("verified\(n)")]),
                .c("neutral-balance-\(n)",item.3,"Balanced production/recovery path.","You preserve some output while accepting bounded uncertainty.",[.advanceMinutes(4),.risk(0.12),.trust(1)]),
                .c("rush-bypass-\(n)",item.4,"Immediate-output path.","Short-term recovery increases hidden technical, quality, or resource debt.",[.advanceMinutes(2),.risk(0.42),.qualityRisk(n % 2 == 0 ? 0.25:0.05),.recurrenceRisk(0.18), n==3 ? .scheduleBranchIncident(incidents.first?.id ?? "",delayMinutes:20):.addTag("rushed\(n)")])
            ])
        }
        return .init(id:id,title:title,subtitle:subtitle,briefing:briefing,learningObjectives:["Make evidence-driven decisions under time pressure","Manage finite specialists/tools/vendor support","Understand schedule-quality-safety-economic tradeoffs","Use handoffs and replay to identify avoidable losses"],gates:gates,branchIncidents:incidents,startingBudgetPressure:0.35)
    }
}
