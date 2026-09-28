import Foundation

public enum DiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum DiagnosticCode: String, Codable, Sendable {
    case multipleWrites
    case mixedOutputSemantics
    case missingTag
    case invalidInstructionType
    case sharedStatefulStructure
    case oneShotStorageCollision
    case emptySeries
    case emptyParallel
}

public struct Diagnostic: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let code: DiagnosticCode
    public let severity: DiagnosticSeverity
    public let message: String
    public let tag: String?
    public let rungNumbers: [Int]

    public init(
        id: UUID = UUID(),
        code: DiagnosticCode = .multipleWrites,
        severity: DiagnosticSeverity,
        message: String,
        tag: String? = nil,
        rungNumbers: [Int] = []
    ) {
        self.id = id
        self.code = code
        self.severity = severity
        self.message = message
        self.tag = tag
        self.rungNumbers = rungNumbers
    }
}

public enum LadderAnalyzer {
    private enum WriterKind: String, Hashable {
        case ote, otl, otu, mov, add, sub, mul, div
    }

    private struct Writer: Hashable {
        let rung: Int
        let kind: WriterKind
    }

    public static func analyze(_ routine: LadderRoutine, tags: TagStore? = nil) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        var writers: [String: [Writer]] = [:]
        var statefulUses: [String: [(rung: Int, mnemonic: String)]] = [:]
        var oneShotStorageTags = Set<String>()

        for rung in routine.rungs {
            inspect(
                node: rung.logic,
                rung: rung.number,
                tags: tags,
                writers: &writers,
                statefulUses: &statefulUses,
                oneShotStorageTags: &oneShotStorageTags,
                diagnostics: &diagnostics
            )
        }

        for (tag, writes) in writers {
            let uniqueRungs = Array(Set(writes.map(\.rung))).sorted()
            if writes.count > 1 {
                diagnostics.append(Diagnostic(
                    code: .multipleWrites,
                    severity: .warning,
                    message: "\(tag) is written by multiple instructions. Scan order matters, and a later write can replace an earlier value during the same scan.",
                    tag: tag,
                    rungNumbers: uniqueRungs
                ))
            }

            let kinds = Set(writes.map(\.kind))
            if kinds.contains(.ote) && (kinds.contains(.otl) || kinds.contains(.otu)) {
                diagnostics.append(Diagnostic(
                    code: .mixedOutputSemantics,
                    severity: .warning,
                    message: "\(tag) mixes OTE with latch/unlatch semantics. This is legal to simulate but difficult to troubleshoot and can make the final state scan-order dependent.",
                    tag: tag,
                    rungNumbers: uniqueRungs
                ))
            }
        }

        for (tag, uses) in statefulUses where uses.count > 1 {
            let mnemonics = Set(uses.map(\.mnemonic))
            let allowedCounterPair = mnemonics.isSubset(of: ["CTU", "CTD"])
            let allResets = mnemonics == ["RES"]
            if !allowedCounterPair && !allResets {
                diagnostics.append(Diagnostic(
                    code: .sharedStatefulStructure,
                    severity: .warning,
                    message: "\(tag) is shared by multiple stateful instructions (\(mnemonics.sorted().joined(separator: ", "))). Shared TIMER/COUNTER structures can create unexpected state coupling.",
                    tag: tag,
                    rungNumbers: Array(Set(uses.map(\.rung))).sorted()
                ))
            }
        }

        for storage in oneShotStorageTags where writers[storage] != nil {
            diagnostics.append(Diagnostic(
                code: .oneShotStorageCollision,
                severity: .warning,
                message: "ONS storage tag \(storage) is also written elsewhere. A one-shot storage bit should normally be dedicated to the ONS instruction.",
                tag: storage,
                rungNumbers: Array(Set(writers[storage, default: []].map(\.rung))).sorted()
            ))
        }

        return diagnostics.sorted {
            if $0.severity != $1.severity { return severityRank($0.severity) > severityRank($1.severity) }
            if ($0.tag ?? "") != ($1.tag ?? "") { return ($0.tag ?? "") < ($1.tag ?? "") }
            return $0.code.rawValue < $1.code.rawValue
        }
    }

    private static func severityRank(_ severity: DiagnosticSeverity) -> Int {
        switch severity { case .info: 0; case .warning: 1; case .error: 2 }
    }

    private static func inspect(
        node: LogicNode,
        rung: Int,
        tags: TagStore?,
        writers: inout [String: [Writer]],
        statefulUses: inout [String: [(rung: Int, mnemonic: String)]],
        oneShotStorageTags: inout Set<String>,
        diagnostics: inout [Diagnostic]
    ) {
        switch node {
        case let .instruction(instruction):
            inspectInstruction(
                instruction,
                rung: rung,
                tags: tags,
                writers: &writers,
                statefulUses: &statefulUses,
                oneShotStorageTags: &oneShotStorageTags,
                diagnostics: &diagnostics
            )

        case let .series(nodes):
            if nodes.isEmpty {
                diagnostics.append(Diagnostic(code: .emptySeries, severity: .info, message: "Rung \(rung) contains an empty series node.", rungNumbers: [rung]))
            }
            for child in nodes {
                inspect(node: child, rung: rung, tags: tags, writers: &writers, statefulUses: &statefulUses, oneShotStorageTags: &oneShotStorageTags, diagnostics: &diagnostics)
            }

        case let .parallel(nodes):
            if nodes.isEmpty {
                diagnostics.append(Diagnostic(code: .emptyParallel, severity: .error, message: "Rung \(rung) contains an empty parallel branch and cannot execute.", rungNumbers: [rung]))
            }
            for child in nodes {
                inspect(node: child, rung: rung, tags: tags, writers: &writers, statefulUses: &statefulUses, oneShotStorageTags: &oneShotStorageTags, diagnostics: &diagnostics)
            }
        }
    }

    private static func inspectInstruction(
        _ instruction: Instruction,
        rung: Int,
        tags: TagStore?,
        writers: inout [String: [Writer]],
        statefulUses: inout [String: [(rung: Int, mnemonic: String)]],
        oneShotStorageTags: inout Set<String>,
        diagnostics: inout [Diagnostic]
    ) {
        func require(_ tag: String, _ expected: TagDataType) {
            guard let tags else { return }
            guard tags.contains(tag) else {
                diagnostics.append(Diagnostic(code: .missingTag, severity: .error, message: "\(instruction.mnemonic) references missing tag \(tag).", tag: tag, rungNumbers: [rung]))
                return
            }
            if let actual = try? tags.dataType(for: tag), actual != expected {
                diagnostics.append(Diagnostic(code: .invalidInstructionType, severity: .error, message: "\(instruction.mnemonic) requires \(tag) to be \(expected.rawValue.uppercased()), but it is \(actual.rawValue.uppercased()).", tag: tag, rungNumbers: [rung]))
            }
        }

        func requireNumeric(_ operand: NumericOperand) {
            guard case let .tag(name) = operand, let tags else { return }
            guard tags.contains(name) else {
                diagnostics.append(Diagnostic(code: .missingTag, severity: .error, message: "\(instruction.mnemonic) references missing numeric tag \(name).", tag: name, rungNumbers: [rung]))
                return
            }
            if let type = try? tags.dataType(for: name), type != .dint && type != .real {
                diagnostics.append(Diagnostic(code: .invalidInstructionType, severity: .error, message: "\(instruction.mnemonic) requires numeric operand \(name), but it is \(type.rawValue.uppercased()).", tag: name, rungNumbers: [rung]))
            }
        }

        switch instruction {
        case let .xic(tag), let .xio(tag): require(tag, .bool)
        case let .ote(tag): require(tag, .bool); writers[tag, default: []].append(Writer(rung: rung, kind: .ote))
        case let .otl(tag): require(tag, .bool); writers[tag, default: []].append(Writer(rung: rung, kind: .otl))
        case let .otu(tag): require(tag, .bool); writers[tag, default: []].append(Writer(rung: rung, kind: .otu))
        case let .ons(storageTag): require(storageTag, .bool); oneShotStorageTags.insert(storageTag)

        case let .ton(tag), let .tof(tag), let .rto(tag):
            require(tag, .timer); statefulUses[tag, default: []].append((rung, instruction.mnemonic))
        case let .ctu(tag), let .ctd(tag):
            require(tag, .counter); statefulUses[tag, default: []].append((rung, instruction.mnemonic))
        case let .res(tag):
            if let tags, tags.contains(tag), let type = try? tags.dataType(for: tag), type != .timer && type != .counter {
                diagnostics.append(Diagnostic(code: .invalidInstructionType, severity: .error, message: "RES requires TIMER or COUNTER tag \(tag).", tag: tag, rungNumbers: [rung]))
            } else if let tags, !tags.contains(tag) {
                diagnostics.append(Diagnostic(code: .missingTag, severity: .error, message: "RES references missing tag \(tag).", tag: tag, rungNumbers: [rung]))
            }

        case let .equ(a, b), let .neq(a, b), let .les(a, b), let .leq(a, b), let .grt(a, b), let .geq(a, b):
            requireNumeric(a); requireNumeric(b)
        case let .lim(low, test, high):
            requireNumeric(low); requireNumeric(test); requireNumeric(high)

        case let .mov(source, destination):
            requireNumeric(source); requireNumeric(.tag(destination)); writers[destination, default: []].append(Writer(rung: rung, kind: .mov))
        case let .add(a, b, destination):
            requireNumeric(a); requireNumeric(b); requireNumeric(.tag(destination)); writers[destination, default: []].append(Writer(rung: rung, kind: .add))
        case let .sub(a, b, destination):
            requireNumeric(a); requireNumeric(b); requireNumeric(.tag(destination)); writers[destination, default: []].append(Writer(rung: rung, kind: .sub))
        case let .mul(a, b, destination):
            requireNumeric(a); requireNumeric(b); requireNumeric(.tag(destination)); writers[destination, default: []].append(Writer(rung: rung, kind: .mul))
        case let .div(a, b, destination):
            requireNumeric(a); requireNumeric(b); requireNumeric(.tag(destination)); writers[destination, default: []].append(Writer(rung: rung, kind: .div))
        case .jsr, .ret:
            break
        }
    }
}
