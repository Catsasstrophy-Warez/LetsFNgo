import Foundation
import NexusCore
import NexusDocuments
import NexusGraph
import NexusInvestigation
import NexusLearning
import NexusModel
import NexusProjects
import NexusSearch
import NexusSimulation
import NexusTasks

extension ObjectType {
    /// A user-made grouping. It `contains` its members; members stay where they were.
    public static let collection: ObjectType = "collection"
}

// MARK: Results

/// What an executor operation did.
///
/// `produced` are objects the operation created (measurements, tasks,
/// reports…); `changed` are existing objects it revised. `screen` and `focus`
/// tell the UI where to go next, so a command both does its work and lands
/// the person on the result.
public struct ActionResult<Detail: Sendable>: Sendable {
    /// The operation's own typed output.
    public var detail: Detail
    public var produced: [ObjectID]
    public var changed: [ObjectID]
    public var screen: ScreenFamily
    public var focus: ObjectID?
    /// One line for a toast, an undo menu or the timeline.
    public var summary: String

    public init(
        detail: Detail,
        produced: [ObjectID] = [],
        changed: [ObjectID] = [],
        screen: ScreenFamily,
        focus: ObjectID?,
        summary: String
    ) {
        self.detail = detail
        self.produced = produced
        self.changed = changed
        self.screen = screen
        self.focus = focus
        self.summary = summary
    }

    /// The same result with its detail wrapped for `perform`.
    public func erased(_ wrap: (Detail) -> ActionDetail) -> ActionReport {
        ActionReport(detail: wrap(detail), produced: produced, changed: changed, screen: screen, focus: focus, summary: summary)
    }
}

extension ActionResult: Equatable where Detail: Equatable {}
extension ActionResult: Hashable where Detail: Hashable {}

/// A result from `perform`, whose detail is one of the typed outputs.
public typealias ActionReport = ActionResult<ActionDetail>

/// Every typed output an operation can produce.
public enum ActionDetail: Sendable, Hashable {
    case none
    case object(ObjectRecord)
    case investigation(InvestigationStart)
    case measurement(MeasurementOutcome)
    case relationship(Relationship)
    case comparison(Comparison)
    case export(ExportedData)
    case simulation(SimulationRun)
    case trace(SignalTrace)
    case hypothesis(Hypothesis)
    case divergence(Event)
    case repairTask(TaskItem)
    case verification(RepairVerification)
    case report(ObjectRecord)
    case trainingScenario(TrainingScenario)
    case document(IngestResult)
    case claim(Claim)
    case search([SearchResult])
    case analysis([ObjectAnalysis])
    case recommendations([TestRecommendation])
    case handoff(AgentHandoff)
}

/// What `perform` did with a command.
public enum ActionOutcome: Sendable, Hashable {
    /// The operation ran.
    case completed(ActionReport)
    /// The command needs these values from the person before it can run.
    /// Fill them into `ActionParameters` (each field names its property) and
    /// call `perform` again.
    case needsInput([InputField])
    /// The command does not apply to this object, with the reason in words.
    case unsupported(Unsupported)

    public var report: ActionReport? {
        if case .completed(let report) = self { return report }
        return nil
    }
}

/// A clear "this does not apply here", as a value rather than a crash or a silent no-op.
public struct Unsupported: Sendable, Hashable {
    public var command: CommandID?
    public var subject: ObjectID?
    public var type: ObjectType?
    public var reason: String

    public init(command: CommandID? = nil, subject: ObjectID? = nil, type: ObjectType? = nil, reason: String) {
        self.command = command
        self.subject = subject
        self.type = type
        self.reason = reason
    }
}

public enum ActionError: Error, Equatable, Sendable {
    case emptySelection(CommandID)
    case selectionSize(CommandID, expected: String, got: Int)
    case wrongType(ObjectID, expected: Set<ObjectType>, got: ObjectType)
    case missingValue(ActionParameters.Field)
    case invalidUnit(String, reason: String)
    case invalidValue(ActionParameters.Field, reason: String)
    /// The truth class is not one a person can record this way.
    case invalidTruth(TruthClass, allowed: Set<TruthClass>)
    /// The instrument's accuracy spec is in a unit the reading cannot be converted to.
    case incompatibleInstrument(ObjectID, readingUnit: String, specUnit: String)
    case outOfRange(value: Double, low: Double?, high: Double?)
    case causeNotConfirmed(ObjectID)
    /// The hypothesis or measurement belongs to no investigation (or to several, and none was named).
    case noInvestigation(ObjectID)
    case ambiguousInvestigation(ObjectID, candidates: [ObjectID])
    case notARepairTask(ObjectID)
    /// Verification readings must be taken after the repair task was created.
    case evidenceBeforeRepair(ObjectID)
    case unsupported(Unsupported)
}

// MARK: Operation details

public struct InvestigationStart: Sendable, Hashable {
    public var investigation: ObjectRecord
    public var subjects: [ObjectID]
    /// Projects the investigation was added to.
    public var projects: [ObjectID]
}

/// One hypothesis that moved because of a reading.
public struct HypothesisChange: Sendable, Hashable {
    public var hypothesis: ObjectID
    public var from: HypothesisState
    public var to: HypothesisState
}

public struct MeasurementOutcome: Sendable, Hashable {
    public var measurement: MeasurementRecord
    /// Empty unless an investigation was given.
    public var assessments: [EvidenceAssessment]
    public var changes: [HypothesisChange]
    /// The next tests, re-ranked after this reading. Empty unless tests were passed.
    public var rankedTests: [TestRecommendation]
}

public struct ComparedObject: Sendable, Hashable {
    public var id: ObjectID
    public var title: String
    public var type: ObjectType
    public var truth: TruthClass
}

/// One value in a comparison, with the truth class and origin it was stored with.
public struct ComparisonCell: Sendable, Hashable {
    public var value: Value
    public var text: String
    public var truth: TruthClass
    public var origin: Origin
    public var timestamp: Date
}

public struct ComparisonRow: Sendable, Hashable {
    /// Attribute key. Measurement fields are prefixed `measurement.`.
    public var attribute: String
    /// One cell per compared object, in selection order; nil where the object lacks it.
    public var cells: [ComparisonCell?]
    /// Values differ, or some objects lack the attribute. Truth classes are
    /// shown, not compared: equal values of different truth do not "differ",
    /// but the cells keep both classes.
    public var differs: Bool
    /// More than one truth class in this row.
    public var mixedTruth: Bool
}

public struct Comparison: Sendable, Hashable {
    public var objects: [ComparedObject]
    public var rows: [ComparisonRow]
}

public enum ExportFormat: String, Sendable, Hashable, CaseIterable {
    case json
    case csv

    public var mediaType: String {
        switch self {
        case .json: "application/json"
        case .csv: "text/csv"
        }
    }
}

public struct ExportedData: Sendable, Hashable {
    public var format: ExportFormat
    public var data: Data
    public var mediaType: String
    public var suggestedFilename: String
}

/// A loop the executor can simulate, with what training needs to replay it.
public struct LoopBinding: Sendable, Hashable {
    public var loop: InstrumentLoop
    /// Faults known for this loop, e.g. the demo's corroded terminal. Used
    /// for training scenarios, never injected into a simulation unasked.
    public var faults: [SimulatedFault]
    public var tests: [TestOption]

    public init(loop: InstrumentLoop, faults: [SimulatedFault] = [], tests: [TestOption] = []) {
        self.loop = loop
        self.faults = faults
        self.tests = tests
    }

    public var members: Set<ObjectID> {
        [loop.tank, loop.transmitter, loop.terminal, loop.card, loop.controller, loop.valve]
    }
}

public struct SimulationRun: Sendable, Hashable {
    public var run: ObjectID
    public var loop: InstrumentLoop
    public var seconds: Double
    public var faults: [SimulatedFault]
    /// Final state values of the subject object.
    public var values: [String: Double]
    /// Modeled readings stored from the run, at the loop's test points.
    public var modeled: [MeasurementRecord]
}

public enum SimulationOutcome: Sendable, Hashable {
    case ran(SimulationRun)
    case unsupported(Unsupported)
}

public struct SignalTrace: Sendable, Hashable {
    public var origin: ObjectID
    /// Objects feeding this one, nearest first.
    public var upstream: [Reach]
    /// Objects this one feeds, nearest first.
    public var downstream: [Reach]
    /// What physically contains it, innermost first.
    public var containers: [ObjectID]
    /// The simulated loop it belongs to, if any.
    public var loop: InstrumentLoop?
}

public enum TraceOutcome: Sendable, Hashable {
    case traced(SignalTrace)
    case unsupported(Unsupported)
}

public struct RepairVerification: Sendable, Hashable {
    public var task: TaskItem
    public var investigation: ObjectID
    public var event: Event
}

public struct ObjectAnalysis: Sendable, Hashable {
    public var record: ObjectRecord
    /// How many attributes carry each truth class.
    public var attributeTruth: [TruthClass: Int]
    /// Current relationships by kind, both directions.
    public var relationships: [RelationKind: Int]
    public var eventCount: Int
    public var lastEvent: Event?
    public var revisionCount: Int
    /// Latest reading per quantity and truth class at this object.
    public var latestMeasurements: [MeasurementRecord]
    /// Investigations of this object that are not closed.
    public var openInvestigations: [ObjectID]
}

/// Questions go to the agent runtime; the executor says what to ask about.
public struct AgentHandoff: Sendable, Hashable {
    public var goal: String
    public var subjects: [ObjectID]
}

// MARK: Input

/// A value `perform` needs from the person.
public struct InputField: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case text
        case number
        /// A unit code, validated with `Units`.
        case unit
        case date
        case truth([TruthClass])
        case choice([String])
        case object(types: Set<ObjectType>?)
        case objects(types: Set<ObjectType>?)
        case relationKind
        case objectType
        case file(mediaTypes: [String])
    }

    /// The `ActionParameters` property to fill.
    public var field: ActionParameters.Field
    public var label: String
    public var kind: Kind
    public var required: Bool

    public init(_ field: ActionParameters.Field, _ label: String, _ kind: Kind, required: Bool = true) {
        self.field = field
        self.label = label
        self.kind = kind
        self.required = required
    }
}
