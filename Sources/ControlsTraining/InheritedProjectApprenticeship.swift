import Foundation
import ControlsPLC

public enum InheritedIssueRole: String, Codable, CaseIterable, Sendable {
    case primaryRootCause
    case secondaryDefect
    case harmlessCodeSmell
    case staleOrMisleadingSymptom
}

public struct InheritedProjectIssue: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var role: InheritedIssueRole
    public var title: String
    public var evidence: String
    public var shouldRepair: Bool
}

public struct InheritedProjectAssignment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var machineContext: String
    public var briefing: String
    public var rungCount: Int
    public var issues: [InheritedProjectIssue]
    public var successCriteria: [String]

    public var primaryIssue: InheritedProjectIssue? { issues.first { $0.role == .primaryRootCause } }
}

public struct InheritedProjectAssessment: Codable, Equatable, Sendable {
    public var assignmentID: String
    public var identifiedIssueIDs: Set<String>
    public var repairedIssueIDs: Set<String>
    public var verificationPerformed: Bool

    public var correctlyPrioritized: Bool { true }
}

public enum InheritedProjectCatalog {
    public static let all: [InheritedProjectAssignment] = [
        .init(id:"packaging-shift-handoff", title:"The Friday-night packaging edit", machineContext:"Packaging Cell", briefing:"You inherit a 10-rung transfer program after an overnight edit. Operators report intermittent stalls. Not every ugly rung is related.", rungCount:10, issues:[
            .init(id:"root-pe-bypass", role:.primaryRootCause, title:"Transfer permissive bypass", evidence:"A parallel branch can bypass PE_Clear during transfer enable.", shouldRepair:true),
            .init(id:"secondary-reset", role:.secondaryDefect, title:"Fault reset permissive incomplete", evidence:"Reset can clear one latched fault before its field condition is healthy.", shouldRepair:true),
            .init(id:"smell-comment", role:.harmlessCodeSmell, title:"Misleading rung comment", evidence:"Comment says PE201 although logic uses PE203.", shouldRepair:false),
            .init(id:"stale-hmi", role:.staleOrMisleadingSymptom, title:"Stale HMI status", evidence:"HMI display updates slowly and lags the real transfer command.", shouldRepair:false)
        ], successCriteria:["Identify the transfer permissive bypass first","Do not treat the stale HMI symptom as root cause","Verify repeated transfer cycles after repair"]),
        .init(id:"pressure-skid-tune-trap", title:"Someone already tuned around it", machineContext:"Pressure Control Skid", briefing:"A 9-rung pressure-control support routine contains a real actuator issue plus a questionable tuning workaround and noisy trend evidence.", rungCount:9, issues:[
            .init(id:"root-valve-proof", role:.primaryRootCause, title:"Valve-position proof ignored", evidence:"Run permissive never evaluates ValvePositionValid before enabling regulation.", shouldRepair:true),
            .init(id:"secondary-alarm", role:.secondaryDefect, title:"Pressure alarm lacks reset hysteresis", evidence:"Alarm can chatter around HighLimit.", shouldRepair:true),
            .init(id:"smell-temp-tag", role:.harmlessCodeSmell, title:"Unused commissioning tag", evidence:"Old tuning test tag remains in the database but is not referenced.", shouldRepair:false),
            .init(id:"stale-historian", role:.staleOrMisleadingSymptom, title:"Historian suggests a one-second pressure spike", evidence:"Collection interval is too slow to establish scan-level sequence.", shouldRepair:false)
        ], successCriteria:["Prioritize valve proof over retuning","Explain historian evidence limitation","Verify pressure response and alarm behavior"]),
        .init(id:"pump-station-rain-event", title:"Storm-day lift/pump mystery", machineContext:"Pump / Lift Station", briefing:"A 12-rung pump alternation project shows short cycling during high inflow. One defect matters now; another is real but unrelated to the current symptom.", rungCount:12, issues:[
            .init(id:"root-stop-delay", role:.primaryRootCause, title:"Pump stop condition drops too early", evidence:"Stop threshold is evaluated without the intended minimum-run latch.", shouldRepair:true),
            .init(id:"secondary-alt", role:.secondaryDefect, title:"Alternation counter reset path weak", evidence:"Lead-pump alternation can reset after a power-cycle edge case.", shouldRepair:true),
            .init(id:"smell-nop", role:.harmlessCodeSmell, title:"Redundant XIC in status rung", evidence:"Duplicate healthy permissive does not change rung truth.", shouldRepair:false),
            .init(id:"stale-flow", role:.staleOrMisleadingSymptom, title:"Flow totalizer lags", evidence:"SCADA total is delayed and is not evidence of instantaneous backflow.", shouldRepair:false)
        ], successCriteria:["Fix minimum-run behavior first","Do not chase delayed totalizer as initiating evidence","Verify starts/hour and drawdown"]),
        .init(id:"ahu-commissioning-leftovers", title:"AHU commissioning leftovers", machineContext:"Commercial AHU", briefing:"An 11-rung AHU sequence contains a genuine enable-path bug, a real alarm-quality issue, and several commissioning leftovers.", rungCount:11, issues:[
            .init(id:"root-fan-proof", role:.primaryRootCause, title:"Cooling enabled without fan proof", evidence:"Cooling-valve enable uses FanCmd instead of FanProof.", shouldRepair:true),
            .init(id:"secondary-static-alarm", role:.secondaryDefect, title:"Static-pressure alarm resets at trip point", evidence:"No hysteresis exists between trip and clear.", shouldRepair:true),
            .init(id:"smell-force-note", role:.harmlessCodeSmell, title:"Old force-warning comment", evidence:"Comment references a force that is no longer active.", shouldRepair:false),
            .init(id:"stale-trend", role:.staleOrMisleadingSymptom, title:"Five-minute SAT trend looks flat", evidence:"Trend resolution hides short cycling and cannot prove the enable sequence.", shouldRepair:false)
        ], successCriteria:["Restore physical fan-proof interlock","Separate alarm cleanup from initiating problem","Verify sequence using live status, not slow trend only"]),
        .init(id:"asrs-docking-handoff", title:"Crane docking handoff", machineContext:"AS/RS Crane", briefing:"A 15-rung docking routine has been edited by several technicians. The reported symptom is location overshoot, but the project contains multiple unrelated imperfections.", rungCount:15, issues:[
            .init(id:"root-position-source", role:.primaryRootCause, title:"Docking uses biased position feedback", evidence:"Final docking permissive uses CranePositionFB without independent location validation.", shouldRepair:true),
            .init(id:"secondary-timeout", role:.secondaryDefect, title:"Dock timeout does not reset on aborted move", evidence:"Timeout accumulator can carry into the next commanded move.", shouldRepair:true),
            .init(id:"smell-order", role:.harmlessCodeSmell, title:"Status rungs are out of numeric order", evidence:"Unusual organization is harder to read but does not change execution semantics.", shouldRepair:false),
            .init(id:"stale-hmi-pos", role:.staleOrMisleadingSymptom, title:"HMI position display rounded to whole units", evidence:"Display makes small bias invisible but does not create it.", shouldRepair:false)
        ], successCriteria:["Identify feedback integrity as the root cause","Do not rewrite harmless rung ordering","Verify independent physical docking after correction"])
    ]

    public static func assignment(_ id: String) -> InheritedProjectAssignment? { all.first { $0.id == id } }

    /// Creates a deliberately imperfect 5–15 rung project. The issue metadata is the grading ground truth;
    /// the ladder remains executable so learners can inspect and run it in the normal workbench.
    public static func makeWorkbench(for assignmentID: String) throws -> LadderConstructionWorkbench? {
        guard let assignment = assignment(assignmentID) else { return nil }
        return try makeWorkbench(for: assignment)
    }

    public static func makeWorkbench(for assignment: InheritedProjectAssignment) throws -> LadderConstructionWorkbench {
        var wb = LadderConstructionWorkbench(projectName:"Inherited_\(assignment.id)")
        for tag in [
            WorkbenchTagDefinition(name:"AutoMode", dataType:.bool, role:.input),
            WorkbenchTagDefinition(name:"PermissiveOK", dataType:.bool, role:.input, initialValue:.bool(true)),
            WorkbenchTagDefinition(name:"Sensor_OK", dataType:.bool, role:.input, initialValue:.bool(true)),
            WorkbenchTagDefinition(name:"StartCmd", dataType:.bool, role:.input),
            WorkbenchTagDefinition(name:"RunCmd", dataType:.bool, role:.output),
            WorkbenchTagDefinition(name:"Fault", dataType:.bool),
            WorkbenchTagDefinition(name:"Reset", dataType:.bool, role:.input),
            WorkbenchTagDefinition(name:"Step", dataType:.dint),
            WorkbenchTagDefinition(name:"Delay", dataType:.timer),
            WorkbenchTagDefinition(name:"Count", dataType:.counter)
        ] { try wb.addTag(tag) }

        // Rung 0 intentionally contains a bypass topology that is suspicious in every inherited project.
        let r0=wb.addRung(comment:"Inherited run permissive: inspect branch priority")
        try wb.append(.instruction(.xic(tag:"AutoMode")), toRung:r0)
        try wb.append(.parallel([.instruction(.xic(tag:"PermissiveOK")), .instruction(.xic(tag:"StartCmd"))]), toRung:r0)
        try wb.append(.instruction(.ote(tag:"RunCmd")), toRung:r0)
        let r1=wb.addRung(comment:"Latch generic fault")
        try wb.append(.instruction(.xio(tag:"Sensor_OK")), toRung:r1); try wb.append(.instruction(.otl(tag:"Fault")), toRung:r1)
        let r2=wb.addRung(comment:"Reset inherited fault")
        try wb.append(.instruction(.xic(tag:"Reset")), toRung:r2); try wb.append(.instruction(.otu(tag:"Fault")), toRung:r2)
        let r3=wb.addRung(comment:"Delay while running")
        try wb.append(.instruction(.xic(tag:"RunCmd")), toRung:r3); try wb.append(.instruction(.ton(timer:"Delay")), toRung:r3)
        let r4=wb.addRung(comment:"Advance state after delay")
        try wb.append(.instruction(.xic(tag:"Delay.DN")), toRung:r4); try wb.append(.instruction(.mov(source:.dint(20), destination:"Step")), toRung:r4)
        let r5=wb.addRung(comment:"Count completed cycles")
        try wb.append(.instruction(.xic(tag:"Delay.DN")), toRung:r5); try wb.append(.instruction(.ctu(counter:"Count")), toRung:r5)
        for i in 6..<assignment.rungCount {
            let r=wb.addRung(comment:i % 2 == 0 ? "Inherited status rung \(i)" : "Legacy diagnostic rung \(i)")
            if i % 3 == 0 { try wb.append(.instruction(.xic(tag:"RunCmd")), toRung:r); try wb.append(.instruction(.ote(tag:"Sensor_OK")), toRung:r) }
            else { try wb.append(.instruction(.xic(tag:"PermissiveOK")), toRung:r); try wb.append(.instruction(.ote(tag:"RunCmd")), toRung:r) }
        }
        return wb
    }

    public static func assess(assignment: InheritedProjectAssignment, identified: Set<String>, repaired: Set<String>, verificationPerformed: Bool) -> (score: Double, feedback: [String]) {
        var score=0.0; var feedback:[String]=[]
        if let root=assignment.primaryIssue, identified.contains(root.id) { score += 40; feedback.append("Primary root cause correctly prioritized.") }
        else { feedback.append("Primary root cause was not identified first.") }
        let repairable=Set(assignment.issues.filter(\.shouldRepair).map(\.id))
        let correctRepairs=repaired.intersection(repairable).count
        score += Double(correctRepairs) * 15
        let unnecessary=repaired.subtracting(repairable).count
        score -= Double(unnecessary) * 10
        if unnecessary > 0 { feedback.append("Unnecessary repairs were made to non-causal or stale evidence items.") }
        if verificationPerformed { score += 15; feedback.append("Repair was verified against machine behavior.") }
        else { feedback.append("No verification run was recorded.") }
        return (max(0,min(100,score)),feedback)
    }
}


public struct GeneratedInheritedProject: Sendable {
    public let seed: UInt64
    public let machineID: HeroMachineID
    public let assignment: InheritedProjectAssignment
    public let recommendedMeasurements: [String]
    public init(seed: UInt64, machineID: HeroMachineID, assignment: InheritedProjectAssignment, recommendedMeasurements: [String]) {
        self.seed=seed; self.machineID=machineID; self.assignment=assignment; self.recommendedMeasurements=recommendedMeasurements
    }
}

public enum SeededInheritedProjectGenerator {
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z=state; z=(z^(z>>30)) &* 0xBF58476D1CE4E5B9; z=(z^(z>>27)) &* 0x94D049BB133111EB; return z^(z>>31) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }
    public static func generate(seed: UInt64, machineID: HeroMachineID? = nil) -> GeneratedInheritedProject {
        var rng=RNG(state:seed == 0 ? 1:seed)
        let machines=HeroMachineID.allCases
        let machine=machineID ?? machines[rng.int(0...(machines.count-1))]
        let title=HeroMachineCatalog.machine(machine)?.title ?? machine.rawValue
        let rungCount=rng.int(10...25)
        let rootTemplates=[
            ("root-permissive","Primary permissive bypass","A permissive branch can energize RunCmd without proving the physical prerequisite."),
            ("root-feedback","Command/feedback integrity failure","The sequence advances from command state without validating physical feedback."),
            ("root-timing","Timing window defect","A timer/state transition can complete before the real process event is confirmed."),
            ("root-scaling","Measurement interpretation defect","A process decision is made from a biased or incorrectly scaled measurement.")]
        let secondaryTemplates=[
            ("secondary-reset","Reset path weakness","A fault or timer state can survive an abnormal restart."),
            ("secondary-alarm","Alarm hysteresis missing","Alarm trip and reset thresholds are identical."),
            ("secondary-counter","Counter lifecycle weakness","A counter can retain state across a scenario boundary.")]
        let smells=[
            ("smell-comment","Obsolete rung comment","The comment is misleading but execution is unaffected."),
            ("smell-order","Odd rung numbering","Organization is untidy but execution semantics are unchanged."),
            ("smell-unused","Unused commissioning tag","A leftover tag is not referenced by executing logic.")]
        let stale=[
            ("stale-hmi","Stale HMI indication","The HMI refresh is slow enough to lag the controller state."),
            ("stale-historian","Low-resolution historian clue","Historian collection is too slow to establish scan-level causality."),
            ("stale-alarm","Old alarm banner","An acknowledged historical alarm remains visible after the initiating event has cleared.")]
        let rt=rootTemplates[rng.int(0...(rootTemplates.count-1))], st=secondaryTemplates[rng.int(0...(secondaryTemplates.count-1))], sm=smells[rng.int(0...(smells.count-1))], sl=stale[rng.int(0...(stale.count-1))]
        var issues=[
            InheritedProjectIssue(id:rt.0,role:.primaryRootCause,title:rt.1,evidence:rt.2,shouldRepair:true),
            .init(id:st.0,role:.secondaryDefect,title:st.1,evidence:st.2,shouldRepair:true),
            .init(id:sm.0,role:.harmlessCodeSmell,title:sm.1,evidence:sm.2,shouldRepair:false),
            .init(id:sl.0,role:.staleOrMisleadingSymptom,title:sl.1,evidence:sl.2,shouldRepair:false)
        ]
        // 0–3 extra believable imperfections; most are intentionally non-causal.
        for i in 0..<rng.int(0...3) {
            issues.append(.init(id:"extra-\(i)",role:i == 0 && rungCount > 18 ? .secondaryDefect:.harmlessCodeSmell,title:i == 0 ? "Inherited maintenance edge case":"Legacy readability issue \(i+1)",evidence:i == 0 ? "A secondary edge condition exists but does not explain the primary symptom.":"The code is inelegant but not causal.",shouldRepair:i == 0 && rungCount > 18))
        }
        let assignment=InheritedProjectAssignment(id:"generated-\(seed)-\(machine.rawValue)",title:"Unknown inherited project – \(title)",machineContext:title,briefing:"You inherited a \(rungCount)-rung project with one primary root cause, unrelated imperfections, and stale evidence. Diagnose in priority order; do not rewrite everything that looks unusual.",rungCount:rungCount,issues:issues,successCriteria:["Identify the primary root cause before editing","Separate secondary defects from stale or cosmetic evidence","Minimize unnecessary edits","Run a verification after repair"])
        let measurements=["Trace the first failed physical permissive","Compare command and feedback at the symptom boundary","Check the fastest evidence source before trusting HMI/historian state"]
        return .init(seed:seed,machineID:machine,assignment:assignment,recommendedMeasurements:measurements)
    }
}
