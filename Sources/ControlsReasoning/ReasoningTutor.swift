import Foundation
import ControlsPLC

public enum WhyQuestion: String, Codable, Sendable {
    case whyTrue
    case whyFalse
}

public struct ReasoningEvidence: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let detail: String
    public let supportsResult: Bool

    public init(id: UUID = UUID(), label: String, detail: String, supportsResult: Bool) {
        self.id = id
        self.label = label
        self.detail = detail
        self.supportsResult = supportsResult
    }
}

public struct ReasoningAnswer: Equatable, Sendable {
    public let question: WhyQuestion
    public let nodePath: String
    public let headline: String
    public let explanation: String
    public let evidence: [ReasoningEvidence]
    public let upstreamBlockerPath: String?

    public init(question: WhyQuestion, nodePath: String, headline: String, explanation: String, evidence: [ReasoningEvidence], upstreamBlockerPath: String? = nil) {
        self.question = question
        self.nodePath = nodePath
        self.headline = headline
        self.explanation = explanation
        self.evidence = evidence
        self.upstreamBlockerPath = upstreamBlockerPath
    }
}

/// Converts deterministic execution evidence into technician-facing causal explanations.
/// It never guesses from the current tag table. Every answer comes from values captured at
/// the moment the instruction executed.
public enum PowerReasoner {
    public static func answer(question: WhyQuestion, nodePath: String, trace: RungTrace) -> ReasoningAnswer? {
        if let instruction = trace.instruction(at: nodePath) {
            return explainInstruction(question: question, instruction: instruction, trace: trace)
        }
        if let node = trace.power(at: nodePath) {
            return explainNode(question: question, node: node, trace: trace)
        }
        return nil
    }

    private static func explainInstruction(question: WhyQuestion, instruction: InstructionTrace, trace: RungTrace) -> ReasoningAnswer {
        let actual = instruction.outgoingCondition
        let askedState = question == .whyTrue
        let stateWord = actual ? "TRUE" : "FALSE"
        var evidence: [ReasoningEvidence] = []

        if !instruction.incomingCondition {
            let blocker = upstreamBlocker(before: instruction, in: trace)
            evidence.append(ReasoningEvidence(
                label: "Rung-condition-in",
                detail: "No power reached this instruction.",
                supportsResult: !actual
            ))
            return ReasoningAnswer(
                question: question,
                nodePath: instruction.nodePath ?? "",
                headline: "\(instruction.mnemonic) is \(stateWord) because power was already blocked upstream",
                explanation: askedState
                    ? "This instruction cannot become true until its upstream path carries power."
                    : "The instruction is false before its own operand can matter because rung-condition-in is false.",
                evidence: evidence,
                upstreamBlockerPath: blocker?.nodePath
            )
        }

        switch instruction.mnemonic {
        case "XIC":
            let observed = boolObservation(instruction)
            evidence.append(ReasoningEvidence(label: instruction.reference, detail: "The examined bit was \(observed == true ? "TRUE" : "FALSE").", supportsResult: observed == true))
            return directAnswer(question, instruction, actual, evidence, "XIC passes power only when its bit is true.")

        case "XIO":
            let observed = boolObservation(instruction)
            evidence.append(ReasoningEvidence(label: instruction.reference, detail: "The examined bit was \(observed == true ? "TRUE" : "FALSE").", supportsResult: observed == false))
            return directAnswer(question, instruction, actual, evidence, "XIO passes power only when its bit is false.")

        case "EQU", "NEQ", "LES", "LEQ", "GRT", "GEQ", "LIM":
            let result = instruction.observations.first(where: { $0.label == "comparison-result" })?.value.boolValue ?? actual
            for observation in instruction.observations where observation.label != "comparison-result" {
                evidence.append(ReasoningEvidence(label: observation.label, detail: TraceExplainer.display(observation.value), supportsResult: result))
            }
            evidence.append(ReasoningEvidence(label: "Comparison", detail: "The comparison evaluated \(result ? "TRUE" : "FALSE").", supportsResult: result))
            return directAnswer(question, instruction, actual, evidence, "The comparison result gates the incoming rung condition.")

        case "ONS":
            let storage = instruction.observations.first(where: { $0.label == "storage-before" })?.value.boolValue
            evidence.append(ReasoningEvidence(label: "Storage before execution", detail: storage == true ? "TRUE" : "FALSE", supportsResult: storage == false))
            return directAnswer(question, instruction, actual, evidence, "ONS passes power for one scan only when rung-condition-in is true and its storage bit was previously false.")

        case "OTE", "OTL", "OTU", "TON", "TOF", "RTO", "CTU", "CTD", "RES", "MOV", "ADD", "SUB", "MUL", "DIV", "JSR", "RET":
            evidence.append(ReasoningEvidence(label: "Rung-condition-in", detail: instruction.incomingCondition ? "TRUE" : "FALSE", supportsResult: instruction.incomingCondition))
            if !instruction.changes.isEmpty {
                for change in instruction.changes {
                    evidence.append(ReasoningEvidence(label: change.tag, detail: "\(TraceExplainer.display(change.oldValue)) → \(TraceExplainer.display(change.newValue))", supportsResult: true))
                }
            }
            return directAnswer(question, instruction, actual, evidence, "This instruction's rung-condition-out follows its incoming power; its internal or destination state may also change.")

        default:
            evidence.append(ReasoningEvidence(label: "Rung-condition-in", detail: instruction.incomingCondition ? "TRUE" : "FALSE", supportsResult: instruction.incomingCondition))
            return directAnswer(question, instruction, actual, evidence, "The captured execution trace determines this result.")
        }
    }

    private static func explainNode(question: WhyQuestion, node: PowerNodeTrace, trace: RungTrace) -> ReasoningAnswer {
        let state = node.outgoingCondition ? "TRUE" : "FALSE"
        switch node.kind {
        case .parallel:
            let branches = trace.powerNodes.filter { $0.path.hasPrefix(node.path + ".branch") }
            let passing = branches.filter(\.outgoingCondition)
            let evidence = branches.map { branch in
                ReasoningEvidence(
                    label: "Branch \((branch.branchIndex ?? 0) + 1)",
                    detail: branch.outgoingCondition ? "carried power" : "was blocked",
                    supportsResult: branch.outgoingCondition
                )
            }
            return ReasoningAnswer(
                question: question,
                nodePath: node.path,
                headline: "Parallel network is \(state)",
                explanation: node.outgoingCondition
                    ? "At least one parallel branch carried power to the merge point."
                    : "Every parallel branch was blocked, so no power reached the merge point.",
                evidence: evidence.isEmpty ? passing.map { _ in ReasoningEvidence(label: "Branch", detail: "carried power", supportsResult: true) } : evidence
            )
        case .series:
            let blocker = trace.instructions.first { instruction in
                guard let path = instruction.nodePath else { return false }
                return path.hasPrefix(node.path + ".") && instruction.incomingCondition && !instruction.outgoingCondition
            }
            return ReasoningAnswer(
                question: question,
                nodePath: node.path,
                headline: "Series network is \(state)",
                explanation: node.outgoingCondition ? "Every required series element passed power." : "At least one series element blocked power.",
                evidence: blocker.map { [ReasoningEvidence(label: "First blocker", detail: "\($0.mnemonic) \($0.reference)", supportsResult: false)] } ?? [],
                upstreamBlockerPath: blocker?.nodePath
            )
        case .instruction:
            return ReasoningAnswer(question: question, nodePath: node.path, headline: "Instruction is \(state)", explanation: "Open the instruction trace for operand-level evidence.", evidence: [])
        }
    }

    private static func directAnswer(_ question: WhyQuestion, _ instruction: InstructionTrace, _ actual: Bool, _ evidence: [ReasoningEvidence], _ rule: String) -> ReasoningAnswer {
        let target = question == .whyTrue ? "true" : "false"
        let actualText = actual ? "TRUE" : "FALSE"
        return ReasoningAnswer(
            question: question,
            nodePath: instruction.nodePath ?? "",
            headline: "\(instruction.mnemonic) \(instruction.reference) evaluated \(actualText)",
            explanation: actual == (question == .whyTrue)
                ? "This is why it is \(target): \(rule)"
                : "It is not \(target) in this execution. \(rule)",
            evidence: evidence
        )
    }

    private static func boolObservation(_ instruction: InstructionTrace) -> Bool? {
        instruction.observations.first?.value.boolValue
    }

    private static func upstreamBlocker(before instruction: InstructionTrace, in trace: RungTrace) -> InstructionTrace? {
        guard let index = trace.instructions.firstIndex(where: { $0.nodePath == instruction.nodePath }) else { return nil }
        guard index > 0 else { return nil }
        return trace.instructions[..<index].last { $0.incomingCondition && !$0.outgoingCondition }
    }
}

public struct TrendSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let scanNumber: UInt64
    public let stepIndex: Int
    public let controllerMilliseconds: Int64
    public let value: TagValue

    public init(id: UUID = UUID(), target: String, scanNumber: UInt64, stepIndex: Int, controllerMilliseconds: Int64, value: TagValue) {
        self.id = id
        self.target = target
        self.scanNumber = scanNumber
        self.stepIndex = stepIndex
        self.controllerMilliseconds = controllerMilliseconds
        self.value = value
    }
}

public enum StructuredTagExpander {
    public static func members(name: String, value: TagValue) -> [(name: String, value: TagValue)] {
        switch value {
        case let .timer(timer):
            return [
                ("\(name).PRE", .dint(timer.PRE)), ("\(name).ACC", .dint(timer.ACC)),
                ("\(name).EN", .bool(timer.EN)), ("\(name).TT", .bool(timer.TT)), ("\(name).DN", .bool(timer.DN))
            ]
        case let .counter(counter):
            return [
                ("\(name).PRE", .dint(counter.PRE)), ("\(name).ACC", .dint(counter.ACC)),
                ("\(name).CU", .bool(counter.CU)), ("\(name).CD", .bool(counter.CD)),
                ("\(name).DN", .bool(counter.DN)), ("\(name).OV", .bool(counter.OV)), ("\(name).UN", .bool(counter.UN))
            ]
        default:
            return []
        }
    }
}
