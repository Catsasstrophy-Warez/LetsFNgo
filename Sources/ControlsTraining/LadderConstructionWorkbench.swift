import Foundation
import ControlsPLC

public enum WorkbenchError: Error, Equatable, Sendable {
    case duplicateTag(String)
    case missingTag(String)
    case invalidTagName(String)
    case emptyRung(Int)
    case invalidRungIndex(Int)
    case invalidElementIndex(Int)
    case unsupportedInstruction(String)
}

public struct WorkbenchTagDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var dataType: TagDataType
    public var role: TagRole
    public var initialValue: TagValue
    public var description: String

    public init(id: UUID = UUID(), name: String, dataType: TagDataType, role: TagRole = .internalValue, initialValue: TagValue? = nil, description: String = "") {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.role = role
        self.initialValue = initialValue ?? Self.defaultValue(for: dataType)
        self.description = description
    }

    private static func defaultValue(for type: TagDataType) -> TagValue {
        switch type {
        case .bool: .bool(false)
        case .dint: .dint(0)
        case .real: .real(0)
        case .timer: .timer(.init())
        case .counter: .counter(.init())
        }
    }

    public func makeTag() -> PLCTag { .init(name: name, value: initialValue, description: description, role: role) }
}

public indirect enum WorkbenchLogic: Codable, Equatable, Sendable {
    case instruction(Instruction)
    case series([WorkbenchLogic])
    case parallel([WorkbenchLogic])

    public func compile() -> LogicNode {
        switch self {
        case let .instruction(i): .instruction(i)
        case let .series(nodes): .series(nodes.map { $0.compile() })
        case let .parallel(nodes): .parallel(nodes.map { $0.compile() })
        }
    }

    public var instructions: [Instruction] {
        switch self {
        case let .instruction(i): [i]
        case let .series(nodes), let .parallel(nodes): nodes.flatMap(\.instructions)
        }
    }
}

public struct WorkbenchRung: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var number: Int
    public var comment: String
    public var elements: [WorkbenchLogic]

    public init(id: UUID = UUID(), number: Int, comment: String = "", elements: [WorkbenchLogic] = []) {
        self.id = id; self.number = number; self.comment = comment; self.elements = elements
    }

    public func compile() throws -> Rung {
        guard !elements.isEmpty else { throw WorkbenchError.emptyRung(number) }
        let logic: LogicNode = elements.count == 1 ? elements[0].compile() : .series(elements.map { $0.compile() })
        return .init(number: number, comment: comment, logic: logic)
    }
}

public enum WorkbenchPaletteItem: String, CaseIterable, Codable, Sendable {
    case xic, xio, ote, otl, otu, ons
    case ton, tof, rto, ctu, ctd, res
    case equ, neq, les, leq, grt, geq, lim
    case mov, add, sub, mul, div

    public var mnemonic: String { rawValue.uppercased() }
}

public struct WorkbenchValidationIssue: Identifiable, Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case pass, warning, failure }
    public let id: String
    public var severity: Severity
    public var message: String

    public init(id: String, severity: Severity, message: String) { self.id=id; self.severity=severity; self.message=message }
}

public struct WorkbenchCompileReport: Equatable, Sendable {
    public var project: ControllerProject?
    public var issues: [WorkbenchValidationIssue]
    public var succeeded: Bool { project != nil && !issues.contains { $0.severity == .failure } }
}

public struct LadderConstructionWorkbench: Codable, Equatable, Sendable {
    public var projectName: String
    public private(set) var tags: [WorkbenchTagDefinition]
    public private(set) var rungs: [WorkbenchRung]

    public init(projectName: String = "LearnerProject", tags: [WorkbenchTagDefinition] = [], rungs: [WorkbenchRung] = []) {
        self.projectName = projectName; self.tags = tags; self.rungs = rungs
    }

    public mutating func addTag(_ definition: WorkbenchTagDefinition) throws {
        let trimmed = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed.first?.isNumber != true && !trimmed.contains(" ") else { throw WorkbenchError.invalidTagName(definition.name) }
        guard !tags.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { throw WorkbenchError.duplicateTag(trimmed) }
        var copy = definition; copy.name = trimmed; tags.append(copy)
    }

    @discardableResult public mutating func addRung(comment: String = "") -> Int {
        let number = (rungs.map(\.number).max() ?? -10) + 10
        rungs.append(.init(number: number, comment: comment)); return rungs.count - 1
    }

    public mutating func append(_ logic: WorkbenchLogic, toRung index: Int) throws {
        guard rungs.indices.contains(index) else { throw WorkbenchError.invalidRungIndex(index) }
        rungs[index].elements.append(logic)
    }

    public mutating func insert(_ logic: WorkbenchLogic, at elementIndex: Int, inRung rungIndex: Int) throws {
        guard rungs.indices.contains(rungIndex) else { throw WorkbenchError.invalidRungIndex(rungIndex) }
        guard elementIndex >= 0 && elementIndex <= rungs[rungIndex].elements.count else { throw WorkbenchError.invalidElementIndex(elementIndex) }
        rungs[rungIndex].elements.insert(logic, at: elementIndex)
    }

    public mutating func removeElement(at elementIndex: Int, inRung rungIndex: Int) throws {
        guard rungs.indices.contains(rungIndex) else { throw WorkbenchError.invalidRungIndex(rungIndex) }
        guard rungs[rungIndex].elements.indices.contains(elementIndex) else { throw WorkbenchError.invalidElementIndex(elementIndex) }
        rungs[rungIndex].elements.remove(at: elementIndex)
    }

    public mutating func updateRungComment(at rungIndex: Int, to comment: String) throws {
        guard rungs.indices.contains(rungIndex) else { throw WorkbenchError.invalidRungIndex(rungIndex) }
        rungs[rungIndex].comment = comment
    }

    public mutating func replaceInstruction(inRung rungIndex: Int, elementIndex: Int, with instruction: Instruction) throws {
        guard rungs.indices.contains(rungIndex) else { throw WorkbenchError.invalidRungIndex(rungIndex) }
        guard rungs[rungIndex].elements.indices.contains(elementIndex) else { throw WorkbenchError.invalidElementIndex(elementIndex) }
        rungs[rungIndex].elements[elementIndex] = .instruction(instruction)
    }

    public mutating func moveElement(inRung rungIndex: Int, from source: Int, to destination: Int) throws {
        guard rungs.indices.contains(rungIndex) else { throw WorkbenchError.invalidRungIndex(rungIndex) }
        guard rungs[rungIndex].elements.indices.contains(source), destination >= 0, destination < rungs[rungIndex].elements.count else { throw WorkbenchError.invalidElementIndex(source) }
        let element = rungs[rungIndex].elements.remove(at: source)
        rungs[rungIndex].elements.insert(element, at: destination)
    }

    /// Replaces a consecutive range on a rung with a parallel branch. Each supplied branch is a sequence.
    public mutating func makeParallelBranch(inRung rungIndex: Int, replacing range: Range<Int>, branches: [[WorkbenchLogic]]) throws {
        guard rungs.indices.contains(rungIndex) else { throw WorkbenchError.invalidRungIndex(rungIndex) }
        guard range.lowerBound >= 0, range.upperBound <= rungs[rungIndex].elements.count, !range.isEmpty, branches.count >= 2 else { throw WorkbenchError.invalidElementIndex(range.lowerBound) }
        let branchNodes = branches.map { branch -> WorkbenchLogic in branch.count == 1 ? branch[0] : .series(branch) }
        rungs[rungIndex].elements.replaceSubrange(range, with: [.parallel(branchNodes)])
    }

    public func compile() -> WorkbenchCompileReport {
        var issues: [WorkbenchValidationIssue] = []
        let names = Set(tags.map(\.name))
        for rung in rungs {
            if rung.elements.isEmpty { issues.append(.init(id:"empty-\(rung.number)", severity:.failure, message:"Rung \(rung.number) is empty.")) }
            for instruction in rung.elements.flatMap(\.instructions) {
                for name in Set(instruction.readTagNames + instruction.writeTagNames) where !names.contains(name) && !isStructuredMember(name, rootNames:names) {
                    issues.append(.init(id:"missing-\(rung.number)-\(name)", severity:.failure, message:"Rung \(rung.number) references missing tag \(name)."))
                }
            }
        }
        if issues.contains(where: { $0.severity == .failure }) { return .init(project:nil, issues:issues) }
        do {
            let tagStore = try TagStore(tags: tags.map { $0.makeTag() })
            let compiledRungs = try rungs.sorted { $0.number < $1.number }.map { try $0.compile() }
            let routine = LadderRoutine(name:"MainRoutine", rungs:compiledRungs)
            let program = ControllerProgram(name:"LearnerProgram", routines:[routine])
            let task = ControllerTask(name:"MainTask", programs:[program])
            issues.append(.init(id:"compile", severity:.pass, message:"Project compiled into executable ladder AST."))
            return .init(project:.init(name:projectName, controllerTags:tagStore, tasks:[task]), issues:issues)
        } catch {
            issues.append(.init(id:"compile-error", severity:.failure, message:"Compile failed: \(error)"))
            return .init(project:nil, issues:issues)
        }
    }

    private func isStructuredMember(_ name: String, rootNames: Set<String>) -> Bool {
        guard let root = name.split(separator:".").first.map(String.init) else { return false }
        return rootNames.contains(root)
    }
}

public struct WorkbenchRunResult: Sendable {
    public var runtime: ControllerRuntime
    public var traces: [ControllerScanTrace]
}

public enum WorkbenchRunner {
    public static func run(workbench: LadderConstructionWorkbench, scans: Int = 1, elapsedMilliseconds: Int32 = 10, inputValues: [String: TagValue] = [:]) throws -> WorkbenchRunResult {
        let report = workbench.compile()
        guard let project = report.project else { throw WorkbenchError.unsupportedInstruction(report.issues.map(\.message).joined(separator:"; ")) }
        var runtime = ControllerRuntime(project: project)
        for (tag, value) in inputValues { try runtime.setControllerTagValue(tag, to:value) }
        try runtime.setMode(.run)
        var traces:[ControllerScanTrace] = []
        for _ in 0..<max(0, scans) { traces.append(try runtime.scan(elapsedMilliseconds:elapsedMilliseconds)) }
        return .init(runtime:runtime, traces:traces)
    }
}

public enum WorkbenchLessonFactory {
    public static func starter(for lessonID: String) throws -> LadderConstructionWorkbench {
        guard let reference = try StepByStepReferenceProjectFactory.project(for: lessonID) else { return .init(projectName:"Learner-\(lessonID)") }
        let tags = reference.controllerTags.allTags.map { WorkbenchTagDefinition(name:$0.name, dataType:$0.dataType, role:$0.role, initialValue:$0.value, description:$0.description) }
        return .init(projectName:"Learner-\(lessonID)", tags:tags, rungs:[])
    }

    public static func validate(_ workbench: LadderConstructionWorkbench, lesson: StepByStepLesson) -> StepByStepValidationReport {
        let compiled = workbench.compile()
        guard let project = compiled.project else {
            return .init(lessonID:lesson.id, findings:compiled.issues.map { .init($0.id, severity:.failure, title:"Workbench compile issue", detail:$0.message) })
        }
        return StepByStepProjectValidator.validate(project:project, lesson:lesson)
    }
}
