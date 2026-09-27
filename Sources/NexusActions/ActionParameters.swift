import Foundation
import NexusCore
import NexusDocuments
import NexusInvestigation
import NexusModel
import NexusSimulation

/// Everything a command may need beyond the selection, for
/// `ActionExecutor.perform`. Every property is optional; a command that lacks
/// a value it needs answers `.needsInput` naming the `Field`s to fill.
///
/// Which command reads what:
///
/// | Command | Selection | Reads |
/// |---|---|---|
/// | `ask` | any | `goal` |
/// | `create` | none | `type`, `title`, `project`, `attributes`; for a document `data`, `mediaType` |
/// | `search` | none | `query`, `project` |
/// | `run` | none | `target`, `seconds`, `faults` |
/// | `open`, `analyze` | one object | — |
/// | `link` | one object (the source) | `target`, `relation` |
/// | `compare`, `runAnalysis` | two or more | — |
/// | `group` | one or more | `title`, `project` |
/// | `export` | one or more | `format` |
/// | `trace` | one physical object | — |
/// | `simulate` | one physical object | `seconds`, `faults` |
/// | `investigate` | physical objects | `symptom`, `project` |
/// | `measure`, `recordMeasurement` | a test point, or an investigation | `quantity`, `value`, `unit`, `testPoint` (with an investigation), `instrument`, `uncertainty`, `rangeLow`/`rangeHigh`, `loading`, `sampledAt`, `truth`, `investigation`, `tests` |
/// | `proposeHypothesis` | an investigation | `statement`, `predictions`, `prior`, `safetyNotes`, `dependsOn` |
/// | `confirmHypothesis` | a hypothesis | `investigation` (when it is in several) |
/// | `rejectHypothesis` | a hypothesis | `reason`, `investigation` |
/// | `markFirstDivergence` | an observed and a modeled measurement | `summary`, `investigation` |
/// | `createRepairTask` | an investigation with a confirmed cause | `procedure`, or `steps` (and `title`) to write one; `owner`, `dueAt` |
/// | `verifyRepair` | a repair task | `evidence`, `summary` |
/// | `closeInvestigation` | an investigation | `resolution`, `evidence` |
/// | `generateReport` | an investigation | — |
/// | `generateTrainingScenario` | a resolved investigation | `loop`, `faults` (first is used), `tests` |
/// | `extractClaim` | a passage | `statement`, `sourceClass`, `applicability`, `confidence` |
public struct ActionParameters: Sendable {
    /// Names of the properties, for `InputField`.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case title, type, project, target, relation, attributes
        case symptom, goal, query, statement, reason, resolution, summary
        case quantity, value, unit, testPoint, instrument, uncertainty, rangeLow, rangeHigh, loading, sampledAt, truth
        case investigation, tests, predictions, prior, safetyNotes, dependsOn
        case procedure, steps, owner, dueAt, evidence
        case format, seconds, faults, loop
        case data, mediaType, sourceClass, applicability, confidence
    }

    // Objects and links.
    /// Title for a new object, group, task or procedure.
    public var title: String?
    /// Type for `create`.
    public var type: ObjectType?
    /// Project to put new objects in, or to scope a search.
    public var project: ObjectID?
    /// The other end of a `link`, or what `run` simulates.
    public var target: ObjectID?
    public var relation: RelationKind?
    /// Extra attributes for `create`.
    public var attributes: [String: Attribute] = [:]

    // Words.
    public var symptom: String?
    public var goal: String?
    public var query: String?
    /// A hypothesis or a claim, in words.
    public var statement: String?
    public var reason: String?
    public var resolution: String?
    public var summary: String?

    // A reading.
    /// What was measured, e.g. "terminalVoltage".
    public var quantity: String?
    public var value: Double?
    /// UCUM-style unit code, validated with `Units` (e.g. "V", "mA", "psi", "L/min").
    public var unit: String?
    public var testPoint: ObjectID?
    /// An instrument object; with an accuracy spec it supplies uncertainty,
    /// resolution and range.
    public var instrument: ObjectID?
    /// Half-width of the accuracy limit. Overrides the instrument's spec.
    public var uncertainty: Double?
    public var rangeLow: Double?
    public var rangeHigh: Double?
    /// Measurement condition, e.g. "high level", "under load".
    public var loading: String?
    public var sampledAt: Date?
    /// `.observed` (default) for a reading taken, `.display` for a value read
    /// off a device's screen, `.recorded` for a trusted system record.
    public var truth: TruthClass?

    // Investigation.
    /// Investigation to assess a reading in, or to disambiguate.
    public var investigation: ObjectID?
    /// Candidate tests to rank after a reading, or for a training scenario.
    public var tests: [TestOption] = []
    public var predictions: [Prediction] = []
    public var prior: Double?
    public var safetyNotes: [String] = []
    /// Claims or evidence a hypothesis relies on.
    public var dependsOn: [ObjectID] = []

    // Repair.
    public var procedure: ObjectID?
    /// Steps for a new procedure when no `procedure` is given.
    public var steps: [String] = []
    public var owner: Origin?
    public var dueAt: Date?
    /// Verification readings.
    public var evidence: [ObjectID] = []

    // Output and simulation.
    public var format: ExportFormat?
    /// Simulated seconds to run; default 600.
    public var seconds: Double?
    /// Faults to inject into a simulation, or the case's fault for training.
    public var faults: [SimulatedFault] = []
    public var loop: InstrumentLoop?

    // Documents.
    public var data: Data?
    public var mediaType: String?
    public var sourceClass: SourceClass?
    public var applicability: String?
    public var confidence: Double?

    public init() {}

    /// Builds parameters in place: `.with { $0.symptom = "…" }`.
    public static func with(_ fill: (inout ActionParameters) -> Void) -> ActionParameters {
        var parameters = ActionParameters()
        fill(&parameters)
        return parameters
    }
}
