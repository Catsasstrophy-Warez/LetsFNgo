#if canImport(SwiftUI)
import Foundation
import NexusAgents
import NexusAutomation
import NexusCore
import NexusInvestigation
import NexusLearning
import NexusModel
import NexusProjects
import NexusTasks
import SwiftUI

// MARK: Practice

/// The next best thing to practise, and due review cards.
struct PracticeSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var reviewing: [ObjectID]?
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let project = env.context.activeProject ?? env.demo?.project
        let due = (try? env.reviews.dueCards(in: project)) ?? []
        let next = try? env.learners.nextBestThing(for: env.user, in: project)
        return Section("Practice") {
            switch next {
            case .review(let cards, let reason)?:
                Button("Review \(cards.count) due cards", systemImage: "rectangle.stack") { reviewing = cards }
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .scenario(let scenario, let topic, let mastery, let reason)?:
                Button("Practise \(topic) (\(Int(mastery * 100)) % mastered)", systemImage: "graduationcap") {
                    try? env.context.open(scenario, from: .command)
                }
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .upToDate(let nextDue, let reason)?:
                Label(reason, systemImage: "checkmark.circle")
                if let nextDue { Text("Next card due \(nextDue.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
            case nil:
                EmptyView()
            }
            if !due.isEmpty, case .review? = next {} else if !due.isEmpty {
                Button("Review \(due.count) due cards", systemImage: "rectangle.stack") { reviewing = due.map(\.id) }
            }
            if let project {
                Button("Make review cards from this project", systemImage: "plus.rectangle.on.rectangle") {
                    do {
                        _ = try env.reviews.generateCards(forProject: project, by: env.user)
                        error = nil
                    } catch {
                        self.error = classify(error)
                    }
                }
            }
            if let error { ClassifiedErrorView(error) }
        }
        .sheet(item: Binding(get: { reviewing.map(ReviewQueue.init) }, set: { reviewing = $0?.cards })) { queue in
            ReviewSheet(cards: queue.cards).environment(env)
        }
    }
}

struct ReviewQueue: Identifiable {
    let id = UUID()
    var cards: [ObjectID]
}

/// One card at a time: recall, reveal, grade 0–5 (SM-2).
struct ReviewSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let cards: [ObjectID]
    @State private var index = 0
    @State private var revealed = false
    @State private var error: ClassifiedError?

    private static let grades: [(Int, String)] = [(0, "Blank"), (1, "Wrong"), (2, "Hard miss"), (3, "Hard"), (4, "Good"), (5, "Easy")]

    var body: some View {
        NavigationStack {
            Form {
                if index < cards.count, let card = try? env.reviews.card(cards[index]) {
                    Section("Card \(index + 1) of \(cards.count) · \(card.kind.rawValue)") {
                        Text(card.front).font(.title3)
                    }
                    if revealed {
                        Section("Answer") {
                            Text(card.back)
                            ForEach(card.sources, id: \.self) { source in
                                Label(env.title(source), systemImage: "link").font(.caption)
                            }
                        }
                        Section("How well did you recall it?") {
                            ForEach(Self.grades, id: \.0) { grade, label in
                                Button("\(grade) · \(label)") { submitGrade(card, grade) }
                            }
                        }
                    } else {
                        Button("Show answer") { revealed = true }
                    }
                } else {
                    NextActionEmptyState("All done", message: "Cards come back when they're due.", systemImage: "checkmark.seal")
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("Review")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func submitGrade(_ card: ReviewCard, _ grade: Int) {
        do {
            _ = try env.reviews.review(card.id, grade: grade, by: env.user)
            _ = try env.learners.recordPractice(
                [card.topic: Double(grade) / 5], source: card.id, learner: env.user, method: "review card", summary: "Reviewed \(card.kind.rawValue) card"
            )
            revealed = false
            index += 1
            error = nil
        } catch {
            self.error = classify(error).preserving("The card keeps its previous schedule.")
        }
    }
}

/// A training scenario inside Object Detail: run tests on the simulated
/// fault, ask the tutor for hints, and submit a diagnosis.
struct ScenarioPracticeView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var testsRun: [String] = []
    @State private var readings: [String: Double] = [:]
    @State private var hints: [String] = []
    @State private var diagnosis = ""
    @State private var result: String?
    @State private var answer: String?
    @State private var error: ClassifiedError?

    var body: some View {
        Group {
            if let scenario = try? env.learning.scenario(id) {
                Section("Briefing") { Text(scenario.briefing) }
                Section("Tests") {
                    ForEach(scenario.tests, id: \.title) { test in
                        HStack {
                            Button(test.title) { run(test, in: scenario) }.disabled(testsRun.contains(test.title))
                            Spacer()
                            if let value = readings[test.title] {
                                Text(value.formatted(.number.precision(.significantDigits(1...4)))).font(.callout.monospacedDigit())
                                TruthBadge(.modeled)
                            }
                        }
                    }
                }
                Section("Tutor") {
                    ForEach(hints, id: \.self) { Label($0, systemImage: "lightbulb").font(.callout) }
                    Button("Hint (costs \(Int(TutorPolicy.pointsPerHint)) points)", systemImage: "questionmark.bubble") { hint() }
                }
                Section("Diagnosis") {
                    Picker("Cause", selection: $diagnosis) {
                        Text("Choose…").tag("")
                        ForEach(scenario.choices, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Submit") { submit(scenario) }.disabled(diagnosis.isEmpty)
                    if let result { Text(result) }
                    Button("Reveal the answer") { reveal() }
                    if let answer { Text(answer).font(.callout) }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
        }
    }

    private func tutor() throws -> Tutor { try Tutor(learning: env.learning, scenario: id, learner: env.user) }

    private func run(_ test: TestOption, in scenario: TrainingScenario) {
        do {
            let values = try scenario.simulator.readings(for: [test], faulted: true)
            readings.merge(values) { $1 }
            testsRun.append(test.title)
        } catch {
            self.error = classify(error)
        }
    }

    private func hint() {
        do {
            hints.append(try tutor().hint(testsRun: testsRun).text)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func submit(_ scenario: TrainingScenario) {
        do {
            let graded = try tutor().submit(testsRun: testsRun, diagnosis: diagnosis)
            _ = try env.learners.record(graded, on: scenario, learner: env.user)
            result = graded.correctDiagnosis
                ? "Correct. Score \(graded.score)." : "Not the cause. Score \(graded.score). Run the tests that split the candidates, then try again."
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func reveal() {
        do {
            let revealed = try tutor().revealAnswer()
            answer = "Cause: \(revealed.cause). Expert path: \(revealed.expertPath.joined(separator: " → "))."
            error = nil
        } catch {
            self.error = classify(error).suggesting(NextAction("Make an attempt first; the answer unlocks after a few tries"))
        }
    }
}

// MARK: Automation

/// Settings → Automations: rules, their runs, approvals, the agent goals
/// they queued, and the rule builder.
struct AutomationSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var creating = false
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let rules = (try? env.automation.rules()) ?? []
        return Group {
            Section("Automations") {
                if rules.isEmpty { Text("No automations yet.").foregroundStyle(.secondary) }
                ForEach(rules) { rule in
                    let runs = (try? env.automation.runs(of: rule.id)) ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(rule.title, isOn: Binding(get: { rule.enabled }, set: { enable($0, rule) }))
                        Text("P\(rule.permissionLevel.rawValue) · \(runs.count) runs").font(.caption).foregroundStyle(.secondary)
                        ForEach(runs.filter { $0.status == .awaitingApproval }) { run in
                            Button("Approve run from \(run.at.formatted(date: .omitted, time: .shortened))") { approve(run) }
                                .font(.caption)
                        }
                    }
                }
                Button("New automation", systemImage: "bolt.badge.clock") { creating = true }
                if let error { ClassifiedErrorView(error) }
            }
            AgentRequestsSection()
        }
        .sheet(isPresented: $creating) { NewAutomationSheet().environment(env) }
    }

    private func enable(_ on: Bool, _ rule: AutomationRule) {
        do {
            _ = try env.automation.setEnabled(on, rule: rule.id, by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func approve(_ run: AutomationRun) {
        do {
            _ = try env.automation.approve(run, by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}

/// Agent goals automations queued: what's waiting, running or blocked, and
/// the latest that finished. Blocked goals list what they need; approving
/// lets the next attempt use exactly that.
struct AgentRequestsSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var error: ClassifiedError?

    /// Finished goals shown, newest first.
    private static let recentLimit = 5

    var body: some View {
        _ = env.revision
        let all = (try? env.agentRequests.requests()) ?? []
        let open = all.filter { !$0.status.isFinal }
        let recent = Array(all.filter(\.status.isFinal).suffix(Self.recentLimit).reversed())
        return Section("Agent goals") {
            if all.isEmpty {
                Text("Automations that ask an agent queue their goals here.").foregroundStyle(.secondary)
            }
            if env.agents == nil, open.contains(where: { $0.status == .pending }) {
                Text("Pending goals run once a language model is installed. See Settings → Models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(open + recent) { request in
                row(request)
            }
            if let error { ClassifiedErrorView(error) }
        }
    }

    private func row(_ request: QueuedAgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(request.goal, systemImage: Self.symbol(request.status))
                Spacer()
                Text(request.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(request.profile) agent · queued \(request.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if request.status == .blocked {
                ForEach(request.needs, id: \.self) { need in
                    Text("Needs P\(need.level.rawValue) \(need.action)\(need.service.map { " via \($0)" } ?? "")")
                        .font(.caption)
                }
            }
            if let error = request.error, request.status == .failed {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let output = request.output, request.status == .done {
                Text(output).font(.caption).lineLimit(3)
                TruthBadge(.agentInterpretation)
            }
            HStack {
                if request.status == .blocked {
                    Button("Approve and run again") { decide { try env.agentRequests.approve(request.id, by: env.user) } }
                }
                if request.status == .pending || request.status == .blocked {
                    Button("Cancel", role: .destructive) { decide { try env.agentRequests.cancel(request.id, by: env.user) } }
                }
                if let run = request.run {
                    Button("Open run") { try? env.context.open(run, in: .agentActivity, from: .command) }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
    }

    private func decide(_ body: () throws -> QueuedAgentRequest) {
        do {
            _ = try body()
            error = nil
            if env.agents != nil { Task { await env.drainAgentRequests() } }
        } catch {
            self.error = classify(error)
        }
    }

    private static func symbol(_ status: AgentRequestStatus) -> String {
        switch status {
        case .pending: "clock"
        case .running: "gearshape.2"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .blocked: "hand.raised"
        case .cancelled: "xmark.circle"
        }
    }
}

/// The rule builder: a trigger, optional conditions (all or any), and one or
/// more actions. The form's values and their conversion to a rule live in
/// `AutomationRuleForm` (NexusAutomation), where they are tested.
struct NewAutomationSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var form = AutomationRuleForm()
    @State private var error: ClassifiedError?

    /// Event kinds people most often automate on; any other can be typed.
    private static let eventKinds: [EventKind] = [
        .note, .measured, .stateChanged, .firstDivergence, .repair, .message, .notification, .agentRequested, .agentRequestStatus,
        .automationRun, .objectEdited, .lifecycleChanged,
    ]
    private static let objectTypes: [ObjectType] = [.equipment, .component, .sensor, .testPoint, .task, .investigation, .project]

    var body: some View {
        _ = env.revision
        let points = ((try? env.store.objects(ofType: .testPoint)) ?? []) + ((try? env.store.objects(ofType: .component)) ?? [])
        let things = Self.objectTypes.filter { $0 != .task && $0 != .project }.flatMap { (try? env.store.objects(ofType: $0)) ?? [] }
        let tasks = (try? env.store.objects(ofType: .task)) ?? []
        return NavigationStack {
            Form {
                TextField("Name (optional)", text: $form.title)
                Section("When") {
                    Picker("Trigger", selection: $form.trigger) {
                        ForEach(AutomationRuleForm.TriggerKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    trigger(points: points, things: things, tasks: tasks)
                }
                Section {
                    if form.conditions.count > 1 {
                        Picker("Match", selection: $form.match) {
                            ForEach(AutomationRuleForm.Match.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    ForEach($form.conditions) { $condition in
                        ConditionEditor(condition: $condition, points: points, things: things, tasks: tasks) {
                            form.conditions.removeAll { $0.id == condition.id }
                        }
                    }
                    Menu("Add condition", systemImage: "plus") {
                        ForEach(ConditionForm.Kind.allCases, id: \.self) { kind in
                            Button(kind.rawValue) { form.conditions.append(ConditionForm(kind: kind)) }
                        }
                    }
                } header: {
                    Text("Only if")
                } footer: {
                    Text("Optional. Checked when the trigger fires.")
                }
                ForEach($form.actions) { $action in
                    Section("Then") {
                        ActionEditor(action: $action, things: things)
                        if form.actions.count > 1 {
                            Button("Remove action", role: .destructive) { form.actions.removeAll { $0.id == action.id } }
                        }
                    }
                }
                Section {
                    Menu("Add action", systemImage: "plus") {
                        ForEach(ActionForm.Kind.allCases, id: \.self) { kind in
                            Button(kind.rawValue) { form.actions.append(ActionForm(kind: kind)) }
                        }
                    }
                    TextField("At most once every … seconds (optional)", text: $form.minimumInterval)
                    if let level = try? form.rule(owner: env.user, project: nil).permissionLevel {
                        Text("Needs P\(level.rawValue). P3 and above wait for a grant or your approval; P4 and P5 need an explicit grant.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("New automation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() } }
            }
        }
    }

    @ViewBuilder
    private func trigger(points: [ObjectRecord], things: [ObjectRecord], tasks: [ObjectRecord]) -> some View {
        switch form.trigger {
        case .measurement:
            ObjectChoice(title: "At", selection: $form.testPoint, objects: points)
            TextField("Quantity (e.g. terminalVoltage)", text: $form.quantity)
            Picker("Goes", selection: $form.direction) {
                Text("below").tag(MeasurementThreshold.Direction.below)
                Text("above").tag(MeasurementThreshold.Direction.above)
            }
            HStack {
                TextField("Value", text: $form.threshold)
                TextField("Unit", text: $form.unit)
            }
            TextField("Re-arm band (optional, same unit)", text: $form.hysteresis)
            Text("Only observed and recorded readings count; modeled and display values never trigger it.")
                .font(.caption).foregroundStyle(.secondary)
        case .event:
            Picker("Kind", selection: $form.eventKind) {
                Text("Choose…").tag("")
                ForEach(Self.eventKinds, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                if !form.eventKind.isEmpty, !Self.eventKinds.map(\.rawValue).contains(form.eventKind) {
                    Text(form.eventKind).tag(form.eventKind)
                }
            }
            TextField("Or type an event kind", text: $form.eventKind)
            ObjectChoice(title: "About", selection: $form.eventSubject, objects: things, anyLabel: "Anything")
            TypeChoice(title: "About a", selection: $form.eventSubjectType, types: Self.objectTypes)
        case .schedule:
            Picker("Runs", selection: $form.scheduleMode) {
                ForEach(AutomationRuleForm.ScheduleMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if form.scheduleMode == .every {
                HStack {
                    TextField("Every", text: $form.interval)
                    Picker("Unit", selection: $form.intervalUnit) {
                        ForEach(AutomationRuleForm.IntervalUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            } else {
                DatePicker("At", selection: $form.runAt)
            }
            Text("Checked once a minute while Nexus is open.").font(.caption).foregroundStyle(.secondary)
        case .taskStatus:
            ObjectChoice(title: "Task", selection: $form.task, objects: tasks, anyLabel: "Any task")
            TaskStatusChoice(selection: $form.taskStatus)
        case .attribute:
            ObjectChoice(title: "Object", selection: $form.attributeObject, objects: things, anyLabel: "Any object")
            if form.attributeObject == nil {
                TypeChoice(title: "Of type", selection: $form.attributeObjectType, types: Self.objectTypes)
            }
            AttributeTestEditor(test: $form.attribute)
        }
    }

    private func create() {
        let project = env.context.activeProject ?? env.demo?.project
        do {
            _ = try env.automation.create(try form.rule(owner: env.user, project: project), by: env.user)
            dismiss()
        } catch {
            self.error = classify(error).preserving("No automation was created.")
        }
    }
}

/// One condition in the builder.
private struct ConditionEditor: View {
    @Binding var condition: ConditionForm
    let points: [ObjectRecord]
    let things: [ObjectRecord]
    let tasks: [ObjectRecord]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(condition.kind.rawValue).font(.headline)
                Spacer()
                Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove).labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            switch condition.kind {
            case .measurement:
                ObjectChoice(title: "At", selection: $condition.object, objects: points)
                TextField("Quantity", text: $condition.quantity)
                HStack {
                    ComparisonChoice(selection: $condition.comparison)
                    TextField("Value", text: $condition.value)
                    TextField("Unit", text: $condition.unit)
                }
            case .attribute:
                ObjectChoice(title: "Object", selection: $condition.object, objects: things)
                AttributeTestEditor(test: $condition.attribute)
            case .taskStatus:
                ObjectChoice(title: "Task", selection: $condition.object, objects: tasks)
                TaskStatusChoice(selection: $condition.taskStatus)
            case .after:
                DatePicker("After", selection: $condition.date)
            }
        }
    }
}

/// One action in the builder.
private struct ActionEditor: View {
    @Binding var action: ActionForm
    let things: [ObjectRecord]

    var body: some View {
        Picker("Action", selection: $action.kind) {
            ForEach(ActionForm.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        switch action.kind {
        case .createTask:
            TextField("Task title", text: $action.taskTitle)
            TextField("Done when (optional)", text: $action.successCondition)
            TextField("Due in hours (optional)", text: $action.dueInHours)
            Toggle("Draft for me to approve", isOn: $action.draft)
        case .command:
            Picker("Command", selection: $action.command) {
                ForEach(CommandID.all, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("On", selection: $action.selection) {
                ForEach(ActionForm.Selection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if action.selection == .object {
                ObjectChoice(title: "Object", selection: $action.selectionObject, objects: things)
            }
            TextField("Inputs, one field=value per line", text: $action.presets, axis: .vertical)
                .lineLimit(2...6)
            Text("Values can be $subject, $measurement or $previous; text can use {subject}, {value} and {rule}.")
                .font(.caption).foregroundStyle(.secondary)
        case .agentGoal:
            Picker("Agent", selection: $action.profile) {
                ForEach(AgentProfile.specialists, id: \.id) { Text($0.id.capitalized).tag($0.id) }
            }
            TextField("Goal", text: $action.goal, axis: .vertical)
            Text("Queued for the agent; it runs with the agent's usual permissions and stops to ask you for anything more.")
                .font(.caption).foregroundStyle(.secondary)
        case .notify:
            TextField("Message", text: $action.message, axis: .vertical)
            Picker("Severity", selection: $action.severity) {
                Text("Info").tag(NotifyAction.Severity.info)
                Text("Warning").tag(NotifyAction.Severity.warning)
                Text("Critical").tag(NotifyAction.Severity.critical)
            }
            Toggle("Send outside Nexus (P4, needs a grant)", isOn: $action.external)
        }
    }
}

private struct AttributeTestEditor: View {
    @Binding var test: AttributeTest

    var body: some View {
        TextField("Attribute (e.g. state)", text: $test.key)
        HStack {
            ComparisonChoice(selection: $test.comparison)
            TextField("Value", text: $test.value)
            TextField("Unit (optional)", text: $test.unit)
        }
    }
}

private struct ObjectChoice: View {
    let title: String
    @Binding var selection: ObjectID?
    let objects: [ObjectRecord]
    var anyLabel = "Choose…"

    var body: some View {
        Picker(title, selection: $selection) {
            Text(anyLabel).tag(ObjectID?.none)
            ForEach(objects) { Text($0.title).tag(Optional($0.id)) }
        }
    }
}

private struct TypeChoice: View {
    let title: String
    @Binding var selection: String
    let types: [ObjectType]

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Any type").tag("")
            ForEach(types, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
        }
    }
}

private struct ComparisonChoice: View {
    @Binding var selection: Comparison

    var body: some View {
        Picker("Compare", selection: $selection) {
            ForEach(Comparison.allCases, id: \.self) { Text($0.symbol).tag($0) }
        }
        .labelsHidden()
    }
}

private struct TaskStatusChoice: View {
    @Binding var selection: TaskStatus

    var body: some View {
        Picker("Status", selection: $selection) {
            ForEach(TaskStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
}
#endif
