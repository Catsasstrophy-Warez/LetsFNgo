import Foundation
import NexusActions
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence
import NexusTasks

/// Runs `automation` rules against the store's change feed and a clock.
///
/// - **Change feed.** `start()` subscribes to `observeChanges`; `process()`
///   reads `changes(after:)` from each rule's saved cursor, so a reload
///   catches up on what it missed and never replays what it handled.
/// - **Idempotent.** Each rule's cursor, arming and latches live in the
///   `automation.state` settings namespace and are saved in the same batch
///   as the firing's writes and its `automationRun` event.
/// - **Loops.** Changes a firing writes carry its depth; a rule triggered by
///   them fires one level deeper, and a firing past the rule's `maxDepth` is
///   recorded as `loopLimit` instead of running. `minimumInterval` drops
///   triggers that come too fast.
/// - **Permissions.** Each action is checked with `PermissionEngine` as agent
///   `automation:<rule id>`. P0–P2 follow policy. P3 needs a policy grant or
///   a recorded approval. P4 and P5 need a rule that names this automation
///   and this action with grant `always`; nothing else makes them automatic.
///   A blocked firing runs nothing and is recorded as `awaitingApproval`.
/// - **Atomic.** A firing's actions run in one `store.batch`. If one fails,
///   everything the firing wrote is rolled back and a `failed` run records
///   the error.
/// - **Schedules** fire from `tick(now:)`; the runtime owns no timers.
/// - **Conditional tasks.** Tasks with a start condition (see
///   `startTask(_:when:startAs:by:)`) are moved on when it holds, with the
///   reason logged on the status change.
///
/// The runtime never calls a model: "start an agent goal" leaves a pending
/// `agentRequest` object and an `agentRequested` event for the app to run.
public final class AutomationRuntime: @unchecked Sendable {
    public let store: NexusStore
    public let permissions: PermissionEngine
    public let tasks: TaskRuntime
    /// Loops the command executor can simulate.
    public var loops: [LoopBinding]
    let clock: NexusClock

    static let stateNamespace = "automation.state"

    private let lock = NSLock()
    private var running = false
    private var dirty = false
    /// Depth of the firing that wrote each change sequence; absent means 0.
    private var depths: [Int64: Int] = [:]
    private var observation: ChangeObservation?
    /// The last error from processing triggered by the change feed.
    public private(set) var lastError: (any Error)?

    public init(store: NexusStore, permissions: PermissionEngine, clock: NexusClock = SystemClock(), loops: [LoopBinding] = []) {
        self.store = store
        self.permissions = permissions
        self.tasks = TaskRuntime(store: store, clock: clock)
        self.clock = clock
        self.loops = loops
    }

    // MARK: Lifecycle

    /// Subscribes to the change feed and catches up on anything missed.
    public func start() throws {
        let observation = store.observeChanges { [weak self] _ in
            guard let self else { return }
            do { try self.process() } catch { self.lock.withLock { self.lastError = error } }
        }
        lock.withLock { self.observation = observation }
        try process()
    }

    public func stop() {
        let observation = lock.withLock {
            defer { self.observation = nil }
            return self.observation
        }
        observation?.cancel()
    }

    // MARK: Rules

    /// Stores a rule. An agent or model may only propose one: its rule is a
    /// disabled draft until a person enables it.
    @discardableResult
    public func create(_ rule: AutomationRule, by author: Origin) throws -> AutomationRule {
        guard !rule.actions.isEmpty else { throw AutomationError.noActions }
        var rule = rule
        let human = Self.isHuman(author)
        if !human { rule.enabled = false }
        return try store.batch { store in
            let now = clock.now()
            let record = try store.create(
                ObjectRecord(
                    id: rule.id, type: .automation, title: rule.title, attributes: try rule.attributes, lifecycle: human ? .active : .draft,
                    provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "automation rule")
                ))
            var state = RuleState(cursor: store.latestChangeSequence, eventWatermark: .make())
            state.nextDue = Self.firstDue(rule.trigger, createdAt: record.createdAt)
            try save(state, for: rule.id)
            rule.record = record
            return rule
        }
    }

    public func rule(_ id: ObjectID) throws -> AutomationRule {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        return try AutomationRule(record: record)
    }

    /// Every rule that isn't deleted. Corrupt rules are skipped.
    public func rules() throws -> [AutomationRule] {
        try store.objects(ofType: .automation).filter { $0.lifecycle != .deleted }.compactMap { try? AutomationRule(record: $0) }
    }

    /// Turns a rule on or off. Enabling is for people only; a draft rule becomes active.
    @discardableResult
    public func setEnabled(_ enabled: Bool, rule id: ObjectID, by author: Origin) throws -> AutomationRule {
        if enabled, !Self.isHuman(author) { throw AutomationError.requiresHuman(author) }
        _ = try rule(id)
        // One batch, so the change feed never sees the rule enabled with its old cursor.
        let record = try store.batch { store in
            let record = try store.update(id, by: author, instruction: enabled ? "Enabled automation" : "Disabled automation") {
                $0.attributes[AutomationRule.Keys.enabled] = Attribute(
                    .bool(enabled), provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now())
                )
                if enabled, $0.lifecycle == .draft { $0.lifecycle = .active }
            }
            if enabled {
                // Start from now: a rule switched on doesn't act on the past.
                var fresh = try state(for: id) ?? RuleState(cursor: 0, eventWatermark: .make())
                fresh.cursor = store.latestChangeSequence
                fresh.eventWatermark = .make()
                try save(fresh, for: id)
            }
            return record
        }
        return try AutomationRule(record: record)
    }

    /// Firings of a rule, oldest first.
    public func runs(of rule: ObjectID) throws -> [AutomationRun] {
        try store.events(about: rule).compactMap { AutomationRun(event: $0) }.filter { $0.rule == rule }
    }

    // MARK: Processing

    /// Evaluates every enabled rule against changes since its cursor, fires
    /// what matches, then starts conditional tasks whose condition now holds.
    /// Returns the runs recorded. Safe to call from several places: a call
    /// made while processing is folded into the running pass.
    @discardableResult
    public func process() throws -> [AutomationRun] {
        try pumping { try self.drain(now: self.clock.now()) }
    }

    /// Fires schedule triggers that are due at `now`, once each however many
    /// periods were missed, then processes the change feed. Tests pass their
    /// own `now`; the app calls it from its own timer.
    @discardableResult
    public func tick(now: Date) throws -> [AutomationRun] {
        try pumping {
            var runs: [AutomationRun] = []
            for rule in try self.activeRules() {
                guard case .schedule(let schedule) = rule.trigger else { continue }
                var state = try self.loadState(rule)
                guard !state.finished, let due = state.nextDue, now >= due else { continue }
                var missed = 0
                switch schedule {
                case .every(let seconds, _):
                    var next = due
                    while next <= now {
                        next += max(seconds, 1)
                        missed += 1
                    }
                    state.nextDue = next
                case .once:
                    state.finished = true
                    state.nextDue = nil
                }
                let firing = Firing(
                    subject: nil, summary: "Scheduled for \(due)",
                    inputs: [
                        "trigger": .string("schedule"), "scheduledFor": .date(due), "firedAt": .date(now),
                        "periods": .int(Int64(max(missed, 1))),
                    ])
                if let run = try self.consider(rule, firing, depth: 1, state: &state, at: now) { runs.append(run) }
                try self.save(state, for: rule.id)
            }
            return runs + (try self.drain(now: now))
        }
    }

    private func pumping(_ body: () throws -> [AutomationRun]) throws -> [AutomationRun] {
        let entered = lock.withLock {
            if running {
                dirty = true
                return false
            }
            running = true
            return true
        }
        guard entered else { return [] }
        defer { lock.withLock { running = false } }
        var runs: [AutomationRun] = []
        repeat {
            lock.withLock { dirty = false }
            runs += try body()
        } while lock.withLock({ dirty })
        return runs
    }

    private func drain(now: Date) throws -> [AutomationRun] {
        var runs: [AutomationRun] = []
        while true {
            let startSequence = store.latestChangeSequence
            runs += try processChanges(now: now)
            try activateWaitingTasks(now: now)
            if store.latestChangeSequence == startSequence { break }
        }
        return runs
    }

    private func processChanges(now: Date) throws -> [AutomationRun] {
        var runs: [AutomationRun] = []
        while true {
            let rules = try activeRules().filter { if case .schedule = $0.trigger { false } else { true } }
            guard !rules.isEmpty else { return runs }
            var states: [ObjectID: RuleState] = [:]
            for rule in rules { states[rule.id] = try loadState(rule) }
            let from = states.values.map(\.cursor).min() ?? store.latestChangeSequence
            let changes = try store.changes(after: from, limit: 500)
            guard !changes.isEmpty else { return runs }
            // Events written after this fetch (by the firings below) wait for
            // the next fetch, so each is seen at its own change and depth.
            let horizon = ObjectID.make()
            for change in changes {
                for rule in rules {
                    guard var state = states[rule.id], state.cursor < change.seq else { continue }
                    for firing in try match(rule, change, horizon: horizon, state: &state) {
                        if let run = try consider(rule, firing, depth: depth(of: change.seq) + 1, state: &state, at: now, seq: change.seq) {
                            runs.append(run)
                        }
                    }
                    state.cursor = change.seq
                    states[rule.id] = state
                }
            }
            for (id, state) in states { try save(state, for: id) }
            pruneDepths(below: states.values.map(\.cursor).min() ?? 0)
        }
    }

    // MARK: Matching

    struct Firing {
        var subject: ObjectID?
        var measurement: ObjectID?
        var summary: String
        var inputs: [String: Value]
    }

    private func match(_ rule: AutomationRule, _ change: StoreChange, horizon: ObjectID, state: inout RuleState) throws -> [Firing] {
        switch rule.trigger {
        case .schedule:
            return []

        case .event(let kind, let subject, let subjectType):
            guard change.kind == .event else { return [] }
            var firings: [Firing] = []
            for event in try store.events(about: change.object) where event.kind == kind && event.id > state.eventWatermark && event.id < horizon {
                state.eventWatermark = max(state.eventWatermark, event.id)
                if let subject, !event.subjects.contains(subject) { continue }
                if let subjectType, try !store.objects(event.subjects).contains(where: { $0.type == subjectType }) { continue }
                firings.append(
                    Firing(
                        subject: subject ?? event.subjects.first, summary: event.summary,
                        inputs: [
                            "trigger": .string("event"), "event": .reference(event.id), "kind": .string(kind.rawValue),
                            "summary": .string(event.summary), "subjects": .list(event.subjects.map(Value.reference)),
                        ]))
            }
            return firings

        case .measurementThreshold(let threshold):
            guard change.kind == .created, let reading = try store.measurement(change.object),
                reading.testPoint == threshold.testPoint, reading.quantityName == threshold.quantity,
                threshold.truths.contains(reading.provenance.truth), reading.value.unit == threshold.threshold.unit
            else { return [] }
            let value = reading.value.value
            let limit = threshold.threshold.value
            let crossed = threshold.direction == .below ? value < limit : value > limit
            let rearm = threshold.direction == .below ? value >= limit + threshold.hysteresis : value <= limit - threshold.hysteresis
            if !state.armed {
                if rearm { state.armed = true }
                return []
            }
            guard crossed else { return [] }
            return [
                Firing(
                    subject: reading.testPoint, measurement: reading.id,
                    summary: "\(reading.quantityName) \(Value.format(value)) \(reading.value.unit) \(threshold.direction.rawValue) \(Value.format(limit))",
                    inputs: [
                        "trigger": .string("measurementThreshold"), "measurement": .reference(reading.id), "subject": .reference(reading.testPoint),
                        "value": .quantity(reading.value), "truth": .string(reading.provenance.truth.rawValue),
                        "threshold": .quantity(threshold.threshold), "direction": .string(threshold.direction.rawValue),
                    ])
            ]

        case .taskStatus(let task, let status):
            guard change.kind == .created || change.kind == .updated, task == nil || task == change.object,
                let record = try store.object(change.object), record.type == .task
            else { return [] }
            let satisfied = record.attributes["status"]?.value == .string(status.rawValue)
            return latch(
                satisfied, record, state: &state,
                Firing(
                    subject: record.id, summary: "\(record.title) is \(status.rawValue)",
                    inputs: ["trigger": .string("taskStatus"), "subject": .reference(record.id), "status": .string(status.rawValue)]))

        case .attribute(let object, let objectType, let key, let comparison, let value, let truths):
            guard change.kind == .created || change.kind == .updated, object == nil || object == change.object,
                let record = try store.object(change.object), objectType == nil || objectType == record.type
            else { return [] }
            var satisfied = false
            if let current = record.attributes[key]?.value, truths.map({ $0.contains(record.truth(of: key) ?? .recorded) }) ?? true {
                satisfied = comparison.holds(current, value) ?? false
            }
            return latch(
                satisfied, record, state: &state,
                Firing(
                    subject: record.id, summary: "\(record.title) \(key) \(comparison.symbol) \(value.displayText)",
                    inputs: [
                        "trigger": .string("attribute"), "subject": .reference(record.id), "key": .string(key),
                        "value": record.attributes[key]?.value ?? .null,
                    ]))
        }
    }

    /// Edge detection for level conditions: fire when an object starts to
    /// satisfy, not again until it stops.
    private func latch(_ satisfied: Bool, _ record: ObjectRecord, state: inout RuleState, _ firing: Firing) -> [Firing] {
        if !satisfied {
            state.latched.remove(record.id)
            return []
        }
        guard !state.latched.contains(record.id) else { return [] }
        state.latched.insert(record.id)
        return [firing]
    }

    // MARK: Firing

    /// Applies rate limit, conditions, depth and permissions, then fires.
    /// Nil when the trigger is dropped without a run (rate limit, unmet conditions).
    private func consider(
        _ rule: AutomationRule, _ firing: Firing, depth: Int, state: inout RuleState, at now: Date, seq: Int64? = nil
    ) throws -> AutomationRun? {
        if let last = state.lastFiredAt, rule.minimumInterval > 0, now.timeIntervalSince(last) < rule.minimumInterval {
            state.suppressed += 1
            undoTrigger(rule, firing, &state)
            return nil
        }
        for condition in rule.conditions {
            if try !evaluate(condition, at: now).holds {
                undoTrigger(rule, firing, &state)
                return nil
            }
        }
        if case .measurementThreshold = rule.trigger { state.armed = false }
        if let seq { state.cursor = seq }
        state.lastFiredAt = now

        if depth > rule.maxDepth {
            return try record(
                rule, firing, status: .loopLimit, depth: depth, results: [], error: "Depth \(depth) exceeds the rule's limit of \(rule.maxDepth)",
                state: state, at: now)
        }

        var results: [AutomationActionResult] = []
        var blocked: AutomationRunStatus?
        for action in rule.actions {
            let request = PermissionRequest(agent: rule.agentID, action: action.permissionAction, level: action.level, project: rule.project)
            let verdict = authorize(request, rule: rule)
            results.append(
                AutomationActionResult(
                    kind: action.kind, level: action.level, permissionAction: action.permissionAction,
                    status: verdict == nil ? "pending" : "blocked", summary: verdict?.reason ?? "", produced: [], error: nil))
            if let verdict, blocked != .denied { blocked = verdict.status }
        }
        if let blocked {
            return try record(rule, firing, status: blocked, depth: depth, results: results, error: nil, state: state, at: now)
        }
        return try execute(rule, firing, depth: depth, state: state, at: now)
    }

    /// A dropped trigger leaves level triggers un-latched so the next change can fire.
    private func undoTrigger(_ rule: AutomationRule, _ firing: Firing, _ state: inout RuleState) {
        switch rule.trigger {
        case .taskStatus, .attribute: if let subject = firing.subject { state.latched.remove(subject) }
        default: break
        }
    }

    /// Nil when allowed; otherwise how the firing is blocked and why.
    private func authorize(_ request: PermissionRequest, rule: AutomationRule) -> (status: AutomationRunStatus, reason: String)? {
        if request.level >= .externalAction {
            let explicit = permissions.rules.contains { policy in
                policy.agent == request.agent && policy.action == request.action && policy.grant == .always
                    && (policy.level == nil || policy.level == request.level) && (policy.project == nil || policy.project == request.project)
            }
            if permissions.rules.contains(where: { $0.agent == request.agent && $0.action == request.action && $0.grant == .never }) {
                return (.denied, "Policy forbids \(request.action) for this automation")
            }
            return explicit ? nil : (.awaitingApproval, "P\(request.level.rawValue) \(request.action) needs an explicit grant for \(request.agent)")
        }
        switch permissions.evaluate(request) {
        case .allow: return nil
        case .deny(let reason): return (.denied, reason)
        case .needsApproval(let grant):
            return (.awaitingApproval, "P\(request.level.rawValue) \(request.action) needs approval (\(grant.rawValue))")
        }
    }

    private func execute(_ rule: AutomationRule, _ firing: Firing, depth: Int, state: RuleState, at now: Date, approving: ObjectID? = nil)
        throws -> AutomationRun
    {
        var results: [AutomationActionResult] = []
        do {
            return try store.batch { store in
                let before = store.latestChangeSequence
                var previous: ObjectID?
                for action in rule.actions {
                    let result = try perform(action, rule: rule, firing: firing, previous: previous, at: now)
                    previous = result.produced.first ?? previous
                    results.append(result)
                }
                let run = try record(
                    rule, firing, status: .completed, depth: depth, results: results, error: nil, state: state, at: now, approving: approving,
                    markDepth: false)
                markDepth(after: before, depth)
                return run
            }
        } catch {
            let failedIndex = results.count
            var outcome = results.map { result in
                var result = result
                result.status = "rolledBack"
                result.produced = []
                return result
            }
            for (index, action) in rule.actions.enumerated() where index >= failedIndex {
                outcome.append(
                    AutomationActionResult(
                        kind: action.kind, level: action.level, permissionAction: action.permissionAction,
                        status: index == failedIndex ? "failed" : "skipped", summary: "", produced: [],
                        error: index == failedIndex ? String(describing: error) : nil))
            }
            return try record(
                rule, firing, status: .failed, depth: depth, results: outcome, error: classify(error).whatHappened + " (\(error))", state: state,
                at: now, approving: approving)
        }
    }

    private func perform(_ action: AutomationAction, rule: AutomationRule, firing: Firing, previous: ObjectID?, at now: Date) throws
        -> AutomationActionResult
    {
        let actor = rule.owner
        func resolve(_ targets: [AutomationTarget]) throws -> [ObjectID] {
            try targets.map { target in
                switch target {
                case .object(let id): return id
                case .triggerSubject: if let subject = firing.subject { return subject }
                case .triggerMeasurement: if let measurement = firing.measurement { return measurement }
                case .previousResult: if let previous { return previous }
                }
                throw AutomationError.unresolvedTarget(target)
            }
        }
        let render = { (text: String) throws -> String in try self.render(text, rule: rule, firing: firing) }
        func result(_ summary: String, _ produced: [ObjectID]) -> AutomationActionResult {
            AutomationActionResult(
                kind: action.kind, level: action.level, permissionAction: action.permissionAction, status: "completed", summary: summary,
                produced: produced, error: nil)
        }

        switch action {
        case .command(let command):
            var presets: [String: Value] = [:]
            for (key, value) in command.presets {
                switch value {
                case .string("$subject"): presets[key] = .reference(try resolve([.triggerSubject])[0])
                case .string("$measurement"): presets[key] = .reference(try resolve([.triggerMeasurement])[0])
                case .string("$previous"): presets[key] = .reference(try resolve([.previousResult])[0])
                case .string(let text): presets[key] = .string(try render(text))
                default: presets[key] = value
                }
            }
            let executor = ActionExecutor(store: store, actor: actor, clock: clock, loops: loops)
            let outcome = try executor.perform(
                command.commandID, selection: try resolve(command.selection), parameters: try ActionParameters(presets: presets))
            switch outcome {
            case .completed(let report): return result(report.summary, report.produced)
            case .needsInput(let fields): throw AutomationError.commandNeedsInput(command.command, fields: fields.map(\.field.rawValue))
            case .unsupported(let unsupported): throw AutomationError.commandUnsupported(command.command, reason: unsupported.reason)
            }

        case .createTask(let spec):
            let about = try resolve(spec.about)
            let task = try tasks.create(
                try render(spec.title), successCondition: spec.successCondition, owner: actor, dueAt: spec.dueIn.map { now + $0 },
                in: spec.project, lifecycle: spec.draft ? .draft : nil,
                attributes: ["automation": Attribute(.reference(rule.id)), "about": Attribute(.list(about.map(Value.reference)))],
                by: actor)
            if let condition = spec.startsWhen {
                try tasks.setStartCondition(try ValueCoding.encode(condition), text: try describe(condition), on: task.id, by: actor)
            }
            return result("Created task \(task.title)", [task.id])

        case .startAgent(let spec):
            let subjects = try resolve(spec.subjects)
            let goal = try render(spec.goal)
            let provenance = Provenance(
                origin: actor, truth: actor.defaultTruth, timestamp: now, method: "automation", dependencies: [rule.id] + subjects)
            let request = try store.create(
                ObjectRecord(
                    type: .agentRequest, title: goal,
                    attributes: [
                        "goal": Attribute(.string(goal)), "profile": Attribute(.string(spec.profile)), "status": Attribute(.string("pending")),
                        "subjects": Attribute(.list(subjects.map(Value.reference))), "automation": Attribute(.reference(rule.id)),
                        "requestedAt": Attribute(.date(now)),
                    ],
                    provenance: provenance))
            try store.record(
                Event(
                    at: now, kind: .agentRequested, subjects: [request.id] + subjects, summary: "Agent goal queued: \(goal)",
                    payload: ["profile": .string(spec.profile), "goal": .string(goal), "automation": .reference(rule.id)], provenance: provenance))
            return result("Queued \(spec.profile) agent: \(goal)", [request.id])

        case .notify(let spec):
            let subjects = try resolve(spec.subjects)
            let message = try render(spec.message)
            var seen: Set<ObjectID> = []
            try store.record(
                Event(
                    at: now, kind: .notification, subjects: ([rule.id] + subjects).filter { seen.insert($0).inserted }, summary: message,
                    payload: [
                        "message": .string(message), "severity": .string(spec.severity.rawValue), "external": .bool(spec.external),
                        "automation": .reference(rule.id),
                    ],
                    provenance: Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now, method: "automation", dependencies: [rule.id])))
            return result("Notified: \(message)", [])
        }
    }

    /// Fills `{subject}`, `{value}` and `{rule}` in action text.
    private func render(_ text: String, rule: AutomationRule, firing: Firing) throws -> String {
        guard text.contains("{") else { return text }
        var output = text.replacingOccurrences(of: "{rule}", with: rule.title)
        if output.contains("{subject}") {
            let title = try firing.subject.flatMap { try store.object($0)?.title } ?? "?"
            output = output.replacingOccurrences(of: "{subject}", with: title)
        }
        return output.replacingOccurrences(of: "{value}", with: firing.inputs["value"]?.displayText ?? "?")
    }

    /// Records the run and saves the rule's state, in one batch.
    @discardableResult
    private func record(
        _ rule: AutomationRule,
        _ firing: Firing,
        status: AutomationRunStatus,
        depth: Int,
        results: [AutomationActionResult],
        error: String?,
        state: RuleState,
        at now: Date,
        approving: ObjectID? = nil,
        markDepth mark: Bool = true
    ) throws -> AutomationRun {
        try store.batch { store in
            let before = store.latestChangeSequence
            var payload: [String: Value] = [
                "automation": .reference(rule.id), "status": .string(status.rawValue), "depth": .int(Int64(depth)),
                "inputs": .map(firing.inputs), "actions": try ValueCoding.encode(results),
                "permissionLevel": .int(Int64(rule.permissionLevel.rawValue)),
            ]
            if let error { payload["error"] = .string(error) }
            if let approving { payload["approves"] = .reference(approving) }
            var subjects = [rule.id]
            if let subject = firing.subject, try store.object(subject) != nil { subjects.append(subject) }
            for produced in results.flatMap(\.produced) where !subjects.contains(produced) { subjects.append(produced) }
            let summary =
                switch status {
                case .completed: "\(rule.title) ran: \(firing.summary)"
                case .failed: "\(rule.title) failed: \(error ?? "error")"
                case .awaitingApproval: "\(rule.title) is waiting for approval"
                case .denied: "\(rule.title) was denied by policy"
                case .loopLimit: "\(rule.title) stopped at depth \(depth)"
                }
            let event = Event(
                at: now, kind: .automationRun, subjects: subjects, summary: summary, payload: payload,
                provenance: Provenance(origin: rule.owner, truth: .recorded, timestamp: now, method: "automation runtime", dependencies: [rule.id]))
            try store.record(event)
            try save(state, for: rule.id)
            if mark { markDepth(after: before, depth) }
            return AutomationRun(event: event)!
        }
    }

    // MARK: Approval

    /// A person approves a run that was waiting: its actions run now, as a
    /// new run that `approves` the old one. Each blocked run can be approved once.
    @discardableResult
    public func approve(_ run: AutomationRun, by author: Origin) throws -> AutomationRun {
        guard Self.isHuman(author) else { throw AutomationError.requiresHuman(author) }
        guard run.status == .awaitingApproval, try !runs(of: run.rule).contains(where: { $0.approves == run.id }) else {
            throw AutomationError.notAwaitingApproval(run.id)
        }
        let rule = try rule(run.rule)
        var subject: ObjectID?
        if case .reference(let id)? = run.inputs["subject"] {
            subject = id
        } else if case .list(let subjects)? = run.inputs["subjects"], case .reference(let id)? = subjects.first {
            subject = id
        }
        var measurement: ObjectID?
        if case .reference(let id)? = run.inputs["measurement"] { measurement = id }
        var inputs = run.inputs
        inputs["approvedBy"] = .string(String(describing: author))
        let firing = Firing(subject: subject, measurement: measurement, summary: "approved run \(run.id)", inputs: inputs)
        let approved = try execute(rule, firing, depth: run.depth, state: try loadState(rule), at: clock.now(), approving: run.id)
        try process()
        return approved
    }

    // MARK: Conditional tasks

    /// "Start this task when …": the task waits (blocked) until `condition`
    /// holds, then moves to `startAs`. Checked on every change and tick.
    @discardableResult
    public func startTask(_ task: ObjectID, when condition: SystemCondition, startAs: TaskStatus = .open, by author: Origin) throws -> TaskItem {
        let item = try tasks.setStartCondition(
            try ValueCoding.encode(condition), text: try describe(condition), startAs: startAs, on: task, by: author)
        try process()
        return try tasks.task(item.id)
    }

    /// The structured start condition of a task, if it has one this module can read.
    public func startCondition(of task: ObjectID) throws -> SystemCondition? {
        try tasks.conditions(for: task).first.flatMap { try? ValueCoding.decode(SystemCondition.self, from: $0.condition) }
    }

    private func activateWaitingTasks(now: Date) throws {
        for task in try tasks.waitingOnConditions() {
            guard let stored = try tasks.conditions(for: task.id).first,
                let condition = try? ValueCoding.decode(SystemCondition.self, from: stored.condition)
            else { continue }
            let verdict = try evaluate(condition, at: now)
            guard verdict.holds else { continue }
            try tasks.activate(task.id, reason: "\(stored.text) (\(verdict.evidence.joined(separator: "; ")))", by: .system)
        }
    }

    // MARK: Conditions

    /// Whether `condition` holds at `now`, with the values that decided it.
    public func evaluate(_ condition: SystemCondition, at now: Date? = nil) throws -> (holds: Bool, evidence: [String]) {
        let now = now ?? clock.now()
        switch condition {
        case .measurement(let testPoint, let quantity, let comparison, let value, let truths):
            let latest = try store.measurements(at: testPoint).last {
                $0.quantityName == quantity && truths.contains($0.provenance.truth) && $0.value.unit == value.unit
            }
            guard let latest else { return (false, ["no \(quantity) reading"]) }
            let text = "\(quantity) \(Value.format(latest.value.value)) \(latest.value.unit) \(latest.provenance.truth.rawValue)"
            return (comparison.holds(latest.value.value, value.value), [text])
        case .attribute(let object, let key, let comparison, let value, let truths):
            guard let record = try store.object(object), let current = record.attributes[key]?.value else { return (false, ["no \(key)"]) }
            if let truths, !truths.contains(record.truth(of: key) ?? .recorded) { return (false, ["\(key) has another truth class"]) }
            return (comparison.holds(current, value) ?? false, ["\(record.title) \(key) \(current.displayText)"])
        case .taskStatus(let task, let status):
            let current = try tasks.task(task)
            return (current.status == status, ["\(current.title) \(current.status.rawValue)"])
        case .after(let date):
            return (now >= date, ["now \(now)"])
        case .all(let conditions):
            var evidence: [String] = []
            for condition in conditions {
                let verdict = try evaluate(condition, at: now)
                evidence += verdict.evidence
                if !verdict.holds { return (false, evidence) }
            }
            return (true, evidence)
        case .any(let conditions):
            var evidence: [String] = []
            for condition in conditions {
                let verdict = try evaluate(condition, at: now)
                if verdict.holds { return (true, verdict.evidence) }
                evidence += verdict.evidence
            }
            return (false, evidence)
        }
    }

    /// The condition in words, with object titles: "TB-4 voltage > 20 V".
    public func describe(_ condition: SystemCondition) throws -> String {
        func title(_ id: ObjectID) throws -> String { try store.object(id)?.title ?? id.description }
        switch condition {
        case .measurement(let testPoint, let quantity, let comparison, let value, let truths):
            let qualifier = Set(truths) == Set(observedOrRecorded) ? "" : " (\(truths.map(\.rawValue).joined(separator: "/")))"
            return "\(try title(testPoint)) \(quantity) \(comparison.symbol) \(Value.format(value.value)) \(value.unit)\(qualifier)"
        case .attribute(let object, let key, let comparison, let value, _):
            return "\(try title(object)) \(key) \(comparison.symbol) \(value.displayText)"
        case .taskStatus(let task, let status):
            return "\(try title(task)) is \(status.rawValue)"
        case .after(let date):
            return "after \(date)"
        case .all(let conditions):
            return try conditions.map(describe).joined(separator: " and ")
        case .any(let conditions):
            return try conditions.map(describe).joined(separator: " or ")
        }
    }

    // MARK: State

    struct RuleState: Codable, Sendable {
        /// Last change sequence this rule has handled.
        var cursor: Int64
        /// Newest event ID the rule has looked at, so an event about several objects is seen once.
        var eventWatermark: ObjectID
        /// Threshold triggers: may fire on the next crossing.
        var armed = true
        /// Level triggers: objects currently satisfying the trigger.
        var latched: Set<ObjectID> = []
        var lastFiredAt: Date?
        var suppressed = 0
        /// Schedules: next due time, and whether a one-shot is spent.
        var nextDue: Date?
        var finished = false
    }

    private func activeRules() throws -> [AutomationRule] {
        try rules().filter { $0.enabled && $0.record?.lifecycle == .active }
    }

    func state(for id: ObjectID) throws -> RuleState? {
        guard let json = try store.setting(Self.stateNamespace, id.description) else { return nil }
        return try JSONDecoder().decode(RuleState.self, from: Data(json.utf8))
    }

    /// Saved state, or a fresh one that starts from now.
    private func loadState(_ rule: AutomationRule) throws -> RuleState {
        if let state = try state(for: rule.id) { return state }
        var state = RuleState(cursor: store.latestChangeSequence, eventWatermark: .make())
        state.nextDue = Self.firstDue(rule.trigger, createdAt: rule.record?.createdAt ?? clock.now())
        try save(state, for: rule.id)
        return state
    }

    private func save(_ state: RuleState, for id: ObjectID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try store.putSetting(Self.stateNamespace, id.description, String(decoding: try encoder.encode(state), as: UTF8.self))
    }

    private static func firstDue(_ trigger: AutomationTrigger, createdAt: Date) -> Date? {
        guard case .schedule(let schedule) = trigger else { return nil }
        switch schedule {
        case .every(let seconds, let start): return start ?? createdAt + seconds
        case .once(let date): return date
        }
    }

    private func depth(of seq: Int64) -> Int {
        lock.withLock { depths[seq] ?? 0 }
    }

    private func markDepth(after before: Int64, _ depth: Int) {
        let after = store.latestChangeSequence
        guard after > before else { return }
        lock.withLock {
            for seq in (before + 1)...after { depths[seq] = max(depths[seq] ?? 0, depth) }
        }
    }

    private func pruneDepths(below seq: Int64) {
        lock.withLock { depths = depths.filter { $0.key > seq } }
    }

    static func isHuman(_ origin: Origin) -> Bool {
        switch origin {
        case .user, .system: true
        default: false
        }
    }
}
