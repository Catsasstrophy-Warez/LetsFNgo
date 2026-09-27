import Foundation
import ControlsPLC

public enum OnlineEditState: String, Codable, Equatable, Sendable {
    case offline
    case pending
    case testing
}

public enum OnlineEditSafety: String, Codable, Equatable, Sendable {
    case safe
    case caution
    case blocked
}

public struct OnlineEditFinding: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var safety: OnlineEditSafety
    public var message: String
    public init(id: String, safety: OnlineEditSafety, message: String) { self.id=id; self.safety=safety; self.message=message }
}

public struct OnlineEditAssessment: Codable, Equatable, Sendable {
    public var findings: [OnlineEditFinding]
    public var canTest: Bool { !findings.contains { $0.safety == .blocked } }
    public var summary: String {
        if findings.contains(where: { $0.safety == .blocked }) { return "Edit blocked until the operating risk is removed." }
        if findings.contains(where: { $0.safety == .caution }) { return "Edit can be tested, but operating consequences should be reviewed first." }
        return "Edit is suitable for controlled testing in this training model."
    }
}

public enum OnlineProgrammingLabError: Error, Equatable, Sendable {
    case noPendingEdit
    case notTesting
    case editAlreadyPending
    case unsafeEdit(String)
    case compileFailed(String)
}

public struct TagAutocompleteSuggestion: Identifiable, Codable, Equatable, Sendable {
    public var id: String { value }
    public var value: String
    public var detail: String
}

public enum WorkbenchTagAutocomplete {
    public static func suggestions(for prefix: String, in workbench: LadderConstructionWorkbench) -> [TagAutocompleteSuggestion] {
        let needle = prefix.lowercased()
        var values: [TagAutocompleteSuggestion] = []
        for tag in workbench.tags {
            func add(_ value: String, _ detail: String) {
                if needle.isEmpty || value.lowercased().contains(needle) { values.append(.init(value:value, detail:detail)) }
            }
            add(tag.name, "\(tag.dataType.rawValue.uppercased()) • \(tag.role.rawValue)")
            switch tag.dataType {
            case .timer:
                for member in ["PRE","ACC","EN","TT","DN"] { add("\(tag.name).\(member)", "TIMER member") }
            case .counter:
                for member in ["PRE","ACC","CU","CD","DN","OV","UN"] { add("\(tag.name).\(member)", "COUNTER member") }
            default: break
            }
        }
        return values.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
    }
}

public struct OnlineProgrammingLab: Sendable {
    public private(set) var assembled: LadderConstructionWorkbench
    public private(set) var pending: LadderConstructionWorkbench?
    public private(set) var state: OnlineEditState = .offline
    public private(set) var controllerMode: ControllerMode = .program
    public var equipmentOperating: Bool = false
    public private(set) var lastAssessment: OnlineEditAssessment?
    public private(set) var lastRun: WorkbenchRunResult?

    public init(workbench: LadderConstructionWorkbench) { self.assembled = workbench }

    public mutating func setControllerMode(_ mode: ControllerMode) { controllerMode = mode }
    public mutating func setEquipmentOperating(_ active: Bool) { equipmentOperating = active }

    public mutating func beginEdit() throws {
        guard state == .offline else { throw OnlineProgrammingLabError.editAlreadyPending }
        pending = assembled
        state = .pending
        lastAssessment = nil
    }

    public mutating func mutatePending(_ body: (inout LadderConstructionWorkbench) throws -> Void) throws {
        guard var edit = pending else { throw OnlineProgrammingLabError.noPendingEdit }
        try body(&edit)
        pending = edit
        lastAssessment = assessPending()
    }

    public func assessPending() -> OnlineEditAssessment {
        guard let pending else { return .init(findings:[.init(id:"none", safety:.blocked, message:"No pending edit exists.")]) }
        var findings: [OnlineEditFinding] = []
        let compile = pending.compile()
        for issue in compile.issues where issue.severity == .failure {
            findings.append(.init(id:"compile-\(issue.id)", safety:.blocked, message:issue.message))
        }
        let delta = Self.delta(from: assembled, to: pending)
        if controllerMode == .program {
            findings.append(.init(id:"program-mode", safety:.safe, message:"Controller is in PROGRAM mode; structural edits do not affect executing equipment."))
        } else if equipmentOperating {
            if delta.outputWriteChanged || delta.latchChanged {
                findings.append(.init(id:"output-risk", safety:.blocked, message:"RUN-mode edit changes output/latch behavior while equipment is operating. Stop or isolate the equipment before testing this edit."))
            } else if delta.logicChanged {
                findings.append(.init(id:"logic-risk", safety:.caution, message:"Logic is executing in RUN mode. Review permissives and downstream consequences before testing."))
            }
        } else if controllerMode == .run && delta.logicChanged {
            findings.append(.init(id:"run-idle", safety:.caution, message:"Controller is in RUN mode, but equipment is reported idle. Test edits deliberately and verify outputs before returning equipment to service."))
        }
        if findings.isEmpty { findings.append(.init(id:"clean", safety:.safe, message:"No blocking issue detected.")) }
        return .init(findings:findings)
    }

    public mutating func testEdits(inputValues: [String: TagValue] = [:], scans: Int = 1, elapsedMilliseconds: Int32 = 10) throws -> WorkbenchRunResult {
        guard let edit = pending else { throw OnlineProgrammingLabError.noPendingEdit }
        let assessment = assessPending(); lastAssessment = assessment
        guard assessment.canTest else { throw OnlineProgrammingLabError.unsafeEdit(assessment.summary) }
        let run = try WorkbenchRunner.run(workbench: edit, scans:scans, elapsedMilliseconds:elapsedMilliseconds, inputValues:inputValues)
        state = .testing
        lastRun = run
        return run
    }

    public mutating func assembleEdits() throws {
        guard state == .testing, let edit = pending else { throw OnlineProgrammingLabError.notTesting }
        assembled = edit
        pending = nil
        state = .offline
        lastAssessment = nil
    }

    public mutating func cancelEdits() {
        pending = nil
        state = .offline
        lastAssessment = nil
        lastRun = nil
    }

    public func activeWorkbench() -> LadderConstructionWorkbench { pending ?? assembled }

    public func rungPower(rungNumber: Int) -> RungTrace? {
        guard let lastRun else { return nil }
        for scan in lastRun.traces {
            for program in scan.programs {
                for routine in program.routineTraces {
                    if let rung = routine.rungs.first(where: { $0.rungNumber == rungNumber }) { return rung }
                }
            }
        }
        return nil
    }

    private struct EditDelta { var logicChanged=false; var outputWriteChanged=false; var latchChanged=false }
    private static func delta(from old: LadderConstructionWorkbench, to new: LadderConstructionWorkbench) -> EditDelta {
        var d = EditDelta()
        d.logicChanged = old.rungs != new.rungs || old.tags != new.tags
        let oldInstructions = old.rungs.flatMap { $0.elements.flatMap(\.instructions) }
        let newInstructions = new.rungs.flatMap { $0.elements.flatMap(\.instructions) }
        if oldInstructions != newInstructions {
            d.outputWriteChanged = newInstructions.contains { !$0.writeTagNames.isEmpty }
            d.latchChanged = newInstructions.contains { if case .otl = $0 { true } else if case .otu = $0 { true } else { false } }
        }
        return d
    }
}
