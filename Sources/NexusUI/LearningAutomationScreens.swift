#if canImport(SwiftUI)
import Foundation
import NexusAutomation
import NexusCore
import NexusInvestigation
import NexusLearning
import NexusModel
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

/// Settings → Automations: rules, their runs, approvals, and a simple rule builder.
struct AutomationSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var creating = false
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let rules = (try? env.automation.rules()) ?? []
        return Section("Automations") {
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

/// "When a reading at … goes below/above …, create a task / start an investigation."
struct NewAutomationSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var testPoint: ObjectID?
    @State private var quantity = ""
    @State private var direction = MeasurementThreshold.Direction.below
    @State private var value = ""
    @State private var unit = ""
    @State private var action = Action.task
    @State private var taskTitle = "Check {subject}: {value}"
    @State private var error: ClassifiedError?

    enum Action: String, CaseIterable {
        case task = "Create a task"
        case investigate = "Start an investigation"
    }

    var body: some View {
        let points = ((try? env.store.objects(ofType: .testPoint)) ?? []) + ((try? env.store.objects(ofType: .component)) ?? [])
        return NavigationStack {
            Form {
                TextField("Name", text: $title)
                Section("When an observed reading") {
                    Picker("At", selection: $testPoint) {
                        Text("Choose…").tag(ObjectID?.none)
                        ForEach(points) { Text($0.title).tag(Optional($0.id)) }
                    }
                    TextField("Quantity (e.g. terminalVoltage)", text: $quantity)
                    Picker("Goes", selection: $direction) {
                        Text("below").tag(MeasurementThreshold.Direction.below)
                        Text("above").tag(MeasurementThreshold.Direction.above)
                    }
                    HStack {
                        TextField("Value", text: $value)
                        TextField("Unit", text: $unit)
                    }
                    Text("Modeled and display values never trigger it.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Then") {
                    Picker("Action", selection: $action) {
                        ForEach(Action.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if action == .task { TextField("Task title", text: $taskTitle) }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("New automation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(testPoint == nil || quantity.isEmpty || Double(value) == nil || unit.isEmpty)
                }
            }
        }
    }

    private func create() {
        guard let testPoint, let threshold = Double(value.replacingOccurrences(of: ",", with: ".")) else { return }
        let project = env.context.activeProject ?? env.demo?.project
        let trigger = AutomationTrigger.measurementThreshold(
            MeasurementThreshold(testPoint: testPoint, quantity: quantity, direction, Quantity(threshold, unit))
        )
        let actions: [AutomationAction] = switch action {
        case .task: [.createTask(TaskAction(title: taskTitle, project: project))]
        case .investigate:
            [.command(CommandAction(.investigate, selection: [.triggerSubject], presets: ["symptom": .string("\(quantity) went \(direction.rawValue) \(threshold) \(unit)")]))]
        }
        do {
            let name = title.isEmpty ? "\(quantity) \(direction.rawValue) \(value) \(unit)" : title
            _ = try env.automation.create(AutomationRule(title: name, trigger: trigger, actions: actions, owner: env.user, project: project), by: env.user)
            dismiss()
        } catch {
            self.error = classify(error).preserving("No automation was created.")
        }
    }
}
#endif
