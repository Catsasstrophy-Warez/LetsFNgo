import Foundation
import ControlsPLC

public enum GeneratedArchitectureIssueRole: String, Codable, CaseIterable, Sendable {
    case primaryRootCause
    case secondaryDefect
    case harmlessImperfection
    case staleEvidence
}

public enum GeneratedArchitectureBoundary: String, Codable, CaseIterable, Sendable {
    case taskScheduling
    case routineCallPath
    case tagScope
    case remoteIO
    case explicitMessaging
    case hmiMapping
    case historianCollection
}

public struct GeneratedArchitectureIssue: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var role: GeneratedArchitectureIssueRole
    public var boundary: GeneratedArchitectureBoundary
    public var title: String
    public var evidence: String
    public var shouldRepair: Bool
}

public struct GeneratedRemoteIOModule: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var chassis: String
    public var slot: Int
    public var kind: String
    public var rpiMilliseconds: Int
    public var mappedTags: [String]
}

public struct GeneratedMessagePath: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var sourceController: String
    public var destinationController: String
    public var direction: String
    public var sourceTag: String
    public var destinationTag: String
    public var triggerRoutine: String
}

public struct GeneratedHMIMapping: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var commandTag: String?
    public var statusTag: String
    public var pollMilliseconds: Int
}

public struct GeneratedHistorianPoint: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var tag: String
    public var scanMilliseconds: Int
    public var purpose: String
}

public struct GeneratedControllerArchitecture: Sendable {
    public let seed: UInt64
    public let title: String
    public let controllerProject: ControllerProject
    public let remoteModules: [GeneratedRemoteIOModule]
    public let messages: [GeneratedMessagePath]
    public let hmiMappings: [GeneratedHMIMapping]
    public let historianPoints: [GeneratedHistorianPoint]
    public let issues: [GeneratedArchitectureIssue]
    public let briefing: String

    public var taskCount: Int { controllerProject.tasks.count }
    public var programCount: Int { controllerProject.tasks.flatMap(\.programs).count }
    public var routineCount: Int { controllerProject.tasks.flatMap(\.programs).flatMap(\.routines).count }
    public var primaryIssue: GeneratedArchitectureIssue? { issues.first { $0.role == .primaryRootCause } }
}

public enum GeneratedControllerArchitectureGenerator {
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z=state; z=(z^(z>>30)) &* 0xBF58476D1CE4E5B9; z=(z^(z>>27)) &* 0x94D049BB133111EB; return z^(z>>31) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count-1))] }
    }

    public static func generate(seed: UInt64) throws -> GeneratedControllerArchitecture {
        var rng = RNG(state: seed == 0 ? 1 : seed)
        let primaryBoundary = rng.pick(GeneratedArchitectureBoundary.allCases)
        let programCount = rng.int(2...4)
        let periodicMs = primaryBoundary == .taskScheduling ? 100 : [5, 10, 20, 50][rng.int(0...3)]
        let remoteRPI = primaryBoundary == .remoteIO ? 200 : [10, 20, 50, 100][rng.int(0...3)]

        let controllerTags = try TagStore(tags: [
            PLCTag(name:"Plant_Enable", value:.bool(true)),
            PLCTag(name:"Remote_Permissive", value:.bool(true), role:.input),
            PLCTag(name:"Line_RunCmd", value:.bool(false), role:.output),
            PLCTag(name:"Line_RunningFB", value:.bool(false), role:.input),
            PLCTag(name:"ProcessPV", value:.real(42.0), role:.input),
            PLCTag(name:"Remote_Status", value:.bool(true)),
            PLCTag(name:"HMI_StartCmd", value:.bool(false)),
            PLCTag(name:"AlarmSummary", value:.bool(false))
        ])

        func makeProgram(index: Int) throws -> ControllerProgram {
            let prefix = index == 0 ? "Machine" : (index == 1 ? "Process" : "Support\(index)")
            let tags = try TagStore(tags:[
                PLCTag(name:"\(prefix)_Enable", value:.bool(true)),
                PLCTag(name:"\(prefix)_Healthy", value:.bool(true))
            ])
            let logicRoutine = LadderRoutine(name:"\(prefix)_Logic", rungs:[
                Rung(number:100, comment:"Inherited functional routine", logic:.series([
                    .instruction(.xic(tag:"\(prefix)_Enable")),
                    .instruction(.ote(tag:"\(prefix)_Healthy"))
                ])),
                Rung(number:110, comment:"Return to caller", logic:.instruction(.ret))
            ])
            let mainLogic: LogicNode
            if index == 0 && primaryBoundary == .routineCallPath {
                mainLogic = .series([.instruction(.xic(tag:"Plant_Enable")), .instruction(.ote(tag:"Line_RunCmd"))])
            } else {
                mainLogic = .series([.instruction(.xic(tag:"Plant_Enable")), .instruction(.jsr(routine:"\(prefix)_Logic"))])
            }
            let main = LadderRoutine(name:"MainRoutine", rungs:[
                Rung(number:0, comment:index == 0 && primaryBoundary == .routineCallPath ? "Inherited call path: functional routine not invoked" : "Call functional logic", logic:mainLogic)
            ])
            return ControllerProgram(name:"\(prefix)Program", mainRoutineName:"MainRoutine", routines:[main, logicRoutine], tags:tags)
        }

        var programs:[ControllerProgram] = []
        for i in 0..<programCount { programs.append(try makeProgram(index:i)) }

        // Keep one continuous task plus one faster periodic diagnostics/task boundary.
        let split = max(1, programs.count - 1)
        let continuousPrograms = Array(programs.prefix(split))
        let periodicPrograms = Array(programs.suffix(programs.count - split))
        let continuous = ControllerTask(name:"MainContinuous", kind:.continuous, programs:continuousPrograms)
        let periodic = ControllerTask(name:"FastPeriodic", kind:.periodic(periodMilliseconds:Int32(periodicMs), priority:5), programs: periodicPrograms.isEmpty ? [try makeProgram(index:99)] : periodicPrograms)
        let project = ControllerProject(name:"GeneratedArchitecture_\(seed)", controllerTags:controllerTags, tasks:[continuous, periodic])

        let remoteModules = [
            GeneratedRemoteIOModule(id:"remote-di", chassis:"RemoteRack_A", slot:1, kind:"16-point Digital Input", rpiMilliseconds:remoteRPI, mappedTags:["Remote_Permissive"]),
            GeneratedRemoteIOModule(id:"remote-ai", chassis:"RemoteRack_A", slot:2, kind:"4-channel Analog Input", rpiMilliseconds:remoteRPI * 2, mappedTags:["ProcessPV"])
        ]
        let messages = [GeneratedMessagePath(id:"msg-status", sourceController:"UtilityPLC", destinationController:"GeneratedPLC", direction:"CIP Data Table Read", sourceTag:"Utility_Status", destinationTag:"Remote_Status", triggerRoutine: primaryBoundary == .explicitMessaging ? "SlowMaintenancePoll" : "SupportComms")]
        let hmi = [
            GeneratedHMIMapping(id:"hmi-line", displayName:"Line Control", commandTag:"HMI_StartCmd", statusTag:"Line_RunningFB", pollMilliseconds: primaryBoundary == .hmiMapping ? 2_000 : 250),
            GeneratedHMIMapping(id:"hmi-alarm", displayName:"Alarm Banner", commandTag:nil, statusTag:"AlarmSummary", pollMilliseconds:500)
        ]
        let historian = [
            GeneratedHistorianPoint(id:"hist-pv", tag:"ProcessPV", scanMilliseconds: primaryBoundary == .historianCollection ? 10_000 : 1_000, purpose:"Long-duration process trend"),
            GeneratedHistorianPoint(id:"hist-run", tag:"Line_RunningFB", scanMilliseconds:5000, purpose:"Production state history")
        ]

        let templates: [GeneratedArchitectureBoundary:(String,String)] = [
            .taskScheduling:("Wrong task-rate assumption","Logic is correct locally, but the relevant program executes in a task whose period cannot meet the event timing."),
            .routineCallPath:("Routine not reached on the active path","The expected logic exists, but the MainRoutine/JSR path does not execute it under the failing condition."),
            .tagScope:("Correct-looking tag in the wrong scope","A program-scoped value shadows the intended controller-scoped data contract."),
            .remoteIO:("Remote I/O visibility gap","The physical event can occur between remote I/O updates and task execution."),
            .explicitMessaging:("Stale explicit-message data","The MSG transaction is healthy as a transaction, but its trigger/update cadence leaves the destination stale during the symptom."),
            .hmiMapping:("HMI command/status contract defect","The display presents a command or stale status as if it were physical confirmation."),
            .historianCollection:("Historian resolution hides ordering","The historian point interval cannot establish the scan-level sequence implied by the operator complaint.")
        ]
        let primaryText = templates[primaryBoundary]!
        var issues = [GeneratedArchitectureIssue(id:"root-\(primaryBoundary.rawValue)", role:.primaryRootCause, boundary:primaryBoundary, title:primaryText.0, evidence:primaryText.1, shouldRepair:true)]
        let secondaryBoundary = rng.pick(GeneratedArchitectureBoundary.allCases.filter { $0 != primaryBoundary })
        let secondaryText = templates[secondaryBoundary]!
        issues.append(.init(id:"secondary-\(secondaryBoundary.rawValue)", role:.secondaryDefect, boundary:secondaryBoundary, title:secondaryText.0, evidence:"A real secondary weakness exists here, but it does not explain the primary symptom.", shouldRepair:true))
        issues.append(.init(id:"smell-naming", role:.harmlessImperfection, boundary:.tagScope, title:"Inconsistent inherited tag naming", evidence:"Naming is untidy but execution and data ownership are unaffected.", shouldRepair:false))
        issues.append(.init(id:"stale-hmi", role:.staleEvidence, boundary:.hmiMapping, title:"Stale operator display clue", evidence:"The operator screen updates slower than the controller evidence and may lag the event.", shouldRepair:false))

        return .init(seed:seed, title:"Generated whole-controller handoff \(seed)", controllerProject:project, remoteModules:remoteModules, messages:messages, hmiMappings:hmi, historianPoints:historian, issues:issues, briefing:"You inherited an unfamiliar multi-task, multi-program ControlLogix-style project. The root cause may cross task, routine, scope, I/O, communications, HMI, or historian boundaries. Trace execution and evidence before editing.")
    }
}

public enum GeneratedControllerArchitectureAssessor {
    public static func assess(_ architecture: GeneratedControllerArchitecture, identifiedIssueIDs:Set<String>, repairedIssueIDs:Set<String>, verificationPerformed:Bool) -> (score:Double, feedback:[String]) {
        var score = 0.0
        var feedback:[String] = []
        if let root = architecture.primaryIssue, identifiedIssueIDs.contains(root.id) { score += 40; feedback.append("Primary architectural root cause identified.") }
        else { feedback.append("Primary architectural root cause was not identified.") }
        let required = Set(architecture.issues.filter(\.shouldRepair).map(\.id))
        let correct = required.intersection(repairedIssueIDs).count
        score += Double(correct) * 15.0
        let unnecessary = repairedIssueIDs.subtracting(required).count
        score -= Double(unnecessary) * 12.0
        if unnecessary > 0 { feedback.append("Unnecessary edits were made to cosmetic/stale evidence items.") }
        if verificationPerformed { score += 20; feedback.append("Cross-boundary repair was verified after the change.") }
        else { feedback.append("No end-to-end verification was recorded.") }
        return (max(0,min(100,score)),feedback)
    }
}
