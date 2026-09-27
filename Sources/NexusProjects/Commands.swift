import NexusCore
import NexusModel
import NexusPermissions

/// Stable identity of a command. `Command.id` stays a plain string for the
/// UI; this type names every command the executor (`NexusActions`) handles.
public struct CommandID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Universal grammar.
    public static let ask = CommandID(rawValue: "ask")
    public static let create = CommandID(rawValue: "create")
    public static let search = CommandID(rawValue: "search")
    public static let run = CommandID(rawValue: "run")
    public static let open = CommandID(rawValue: "open")
    public static let analyze = CommandID(rawValue: "analyze")
    public static let link = CommandID(rawValue: "link")
    public static let compare = CommandID(rawValue: "compare")
    public static let group = CommandID(rawValue: "group")
    public static let export = CommandID(rawValue: "export")
    public static let runAnalysis = CommandID(rawValue: "runAnalysis")

    // Engineering selections.
    public static let trace = CommandID(rawValue: "trace")
    public static let measure = CommandID(rawValue: "measure")
    public static let recordMeasurement = CommandID(rawValue: "recordMeasurement")
    public static let simulate = CommandID(rawValue: "simulate")
    public static let investigate = CommandID(rawValue: "investigate")

    // Investigations, hypotheses, repair tasks and readings.
    public static let proposeHypothesis = CommandID(rawValue: "proposeHypothesis")
    public static let confirmHypothesis = CommandID(rawValue: "confirmHypothesis")
    public static let rejectHypothesis = CommandID(rawValue: "rejectHypothesis")
    public static let markFirstDivergence = CommandID(rawValue: "markFirstDivergence")
    public static let createRepairTask = CommandID(rawValue: "createRepairTask")
    public static let verifyRepair = CommandID(rawValue: "verifyRepair")
    public static let closeInvestigation = CommandID(rawValue: "closeInvestigation")
    public static let generateReport = CommandID(rawValue: "generateReport")
    public static let generateTrainingScenario = CommandID(rawValue: "generateTrainingScenario")

    // Documents.
    public static let extractClaim = CommandID(rawValue: "extractClaim")

    /// Every command any built-in provider offers.
    public static let all: [CommandID] = [
        .ask, .create, .search, .run, .open, .analyze, .link, .compare, .group, .export, .runAnalysis,
        .trace, .measure, .recordMeasurement, .simulate, .investigate,
        .proposeHypothesis, .confirmHypothesis, .rejectHypothesis, .markFirstDivergence, .createRepairTask, .verifyRepair,
        .closeInvestigation, .generateReport, .generateTrainingScenario,
        .extractClaim,
    ]
}

public struct Command: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var permission: PermissionLevel

    public init(id: String, title: String, permission: PermissionLevel) {
        self.id = id
        self.title = title
        self.permission = permission
    }

    public init(_ id: CommandID, title: String, permission: PermissionLevel) {
        self.init(id: id.rawValue, title: title, permission: permission)
    }

    public var commandID: CommandID { CommandID(rawValue: id) }
}

/// Contributes commands for a selection. Domain modules register their own
/// providers, so selecting a test point offers Measure without the core
/// knowing anything about measurement.
public protocol CommandProvider: Sendable {
    func commands(for selection: [ObjectRecord]) -> [Command]
}

/// The universal grammar: what any selection can do, by selection size.
public struct UniversalCommands: CommandProvider {
    public init() {}

    public func commands(for selection: [ObjectRecord]) -> [Command] {
        switch selection.count {
        case 0:
            [
                Command(.ask, title: "Ask", permission: .analyze),
                Command(.create, title: "Create", permission: .createDraft),
                Command(.search, title: "Search", permission: .observe),
                Command(.run, title: "Run", permission: .modifyInternalState),
            ]
        case 1:
            [
                Command(.open, title: "Open", permission: .observe),
                Command(.ask, title: "Ask", permission: .analyze),
                Command(.analyze, title: "Analyze", permission: .analyze),
                Command(.link, title: "Link", permission: .modifyInternalState),
            ]
        default:
            [
                Command(.compare, title: "Compare", permission: .analyze),
                Command(.group, title: "Group", permission: .modifyInternalState),
                Command(.export, title: "Export", permission: .createDraft),
                Command(.runAnalysis, title: "Run Analysis", permission: .analyze),
            ]
        }
    }
}

/// Engineering selections expose Trace / Measure / Simulate / Investigate.
/// Lives here until NexusEngineering exists; it will move there.
public struct EngineeringCommands: CommandProvider {
    static let physical: Set<ObjectType> = [.equipment, .component, .sensor, .signal, .testPoint]

    public init() {}

    public func commands(for selection: [ObjectRecord]) -> [Command] {
        guard !selection.isEmpty, selection.allSatisfy({ Self.physical.contains($0.type) }) else { return [] }
        var commands = [
            Command(.trace, title: "Trace", permission: .analyze),
            Command(.simulate, title: "Simulate", permission: .modifyInternalState),
            Command(.investigate, title: "Start Investigation", permission: .createDraft),
        ]
        if selection.contains(where: { $0.type == .testPoint }) {
            commands.insert(Command(.measure, title: "Measure", permission: .createDraft), at: 1)
        }
        // Manual entry of one reading at one test point.
        if selection.count == 1, selection[0].type == .testPoint {
            commands.insert(Command(.recordMeasurement, title: "Record Measurement", permission: .createDraft), at: 2)
        }
        return commands
    }
}

/// Investigation work: hypotheses, readings, repair and close-out.
///
/// Reads only core attributes (`state` on hypotheses, `status` on
/// investigations, `repairFor` on repair tasks), so it needs no dependency on
/// the investigation or task modules.
public struct InvestigationCommands: CommandProvider {
    static let liveStates: Set<String> = ["candidate", "unknown"]
    static let evidenceTruth: Set<TruthClass> = [.observed, .recorded]
    static let expectedTruth: Set<TruthClass> = [.modeled, .derived]

    public init() {}

    public func commands(for selection: [ObjectRecord]) -> [Command] {
        if selection.count == 2, selection.allSatisfy({ $0.type == .measurement }) {
            let truths = selection.map(\.provenance.truth)
            let pair = Self.evidenceTruth.contains(truths[0]) && Self.expectedTruth.contains(truths[1])
                || Self.expectedTruth.contains(truths[0]) && Self.evidenceTruth.contains(truths[1])
            return pair ? [Command(.markFirstDivergence, title: "Mark First Divergence", permission: .modifyInternalState)] : []
        }
        guard selection.count == 1, let record = selection.first else { return [] }
        switch record.type {
        case .hypothesis:
            guard case .string(let state)? = record.attributes["state"]?.value, Self.liveStates.contains(state) else { return [] }
            return [
                Command(.confirmHypothesis, title: "Confirm", permission: .modifyInternalState),
                Command(.rejectHypothesis, title: "Reject", permission: .modifyInternalState),
            ]
        case .investigation:
            let status = if case .string(let text)? = record.attributes["status"]?.value { text } else { "open" }
            var commands: [Command] = []
            if status != "closed" {
                commands += [
                    Command(.recordMeasurement, title: "Record Measurement", permission: .createDraft),
                    Command(.proposeHypothesis, title: "Add Hypothesis", permission: .createDraft),
                ]
            }
            if status == "causeConfirmed" {
                commands += [
                    Command(.createRepairTask, title: "Create Repair Task", permission: .modifyInternalState),
                    Command(.closeInvestigation, title: "Close Investigation", permission: .modifyInternalState),
                ]
            }
            commands.append(Command(.generateReport, title: "Generate Report", permission: .createDraft))
            if status == "causeConfirmed" || status == "closed", record.attributes["cause"] != nil {
                commands.append(Command(.generateTrainingScenario, title: "Generate Training Scenario", permission: .createDraft))
            }
            return commands
        case .task:
            guard record.attributes["repairFor"] != nil,
                  case .string(let status)? = record.attributes["status"]?.value, status != "done", status != "cancelled"
            else { return [] }
            return [Command(.verifyRepair, title: "Verify Repair", permission: .modifyInternalState)]
        default:
            return []
        }
    }
}

/// Document passages can be cited as claims.
public struct DocumentCommands: CommandProvider {
    public init() {}

    public func commands(for selection: [ObjectRecord]) -> [Command] {
        guard selection.count == 1, selection[0].type == "passage" else { return [] }
        return [Command(.extractClaim, title: "Cite as Claim", permission: .createDraft)]
    }
}

public struct CommandRegistry: Sendable {
    public var providers: [any CommandProvider]

    public init(
        providers: [any CommandProvider] = [UniversalCommands(), EngineeringCommands(), InvestigationCommands(), DocumentCommands()]
    ) {
        self.providers = providers
    }

    /// Commands from every provider, in provider order, first occurrence of an ID winning.
    public func commands(for selection: [ObjectRecord]) -> [Command] {
        var seen: Set<String> = []
        return providers
            .flatMap { $0.commands(for: selection) }
            .filter { seen.insert($0.id).inserted }
    }
}
