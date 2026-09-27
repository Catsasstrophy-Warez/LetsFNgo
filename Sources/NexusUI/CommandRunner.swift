#if canImport(SwiftUI)
import Foundation
import NexusActions
import NexusCore
import NexusModel
import NexusProjects
import SwiftUI
import UniformTypeIdentifiers

/// A command waiting for the person to fill in what it needs.
public struct CommandRequest: Identifiable {
    public let id = UUID()
    public var command: CommandID
    public var title: String
    public var selection: [ObjectID]
    public var parameters: ActionParameters
    public var fields: [InputField]
}

/// Runs commands through `ActionExecutor` and turns the outcome into
/// navigation, a one-line confirmation, a form for missing input, or a
/// classified error that says what survived.
@MainActor
@Observable
public final class CommandRunner {
    /// Set when a command needs input; the root presents a form for it.
    public var request: CommandRequest?
    /// The last completed command, in one line.
    public var confirmation: String?
    public var error: ClassifiedError?
    /// An export ready to share or save.
    public var export: ExportedData?
    /// A goal the Ask surfaces should pick up (from the `ask` command).
    public var pendingGoal: String?

    @ObservationIgnored weak var env: NexusEnvironment?

    init() {}

    /// Runs `command` on `selection` (the current selection by default).
    public func run(
        _ command: CommandID, title: String? = nil, selection: [ObjectID]? = nil, parameters: ActionParameters = .init()
    ) {
        guard let env else { return }
        let selection = selection ?? env.context.selection
        error = nil
        do {
            switch try env.actions.perform(command, selection: selection, parameters: parameters) {
            case .completed(let report):
                confirmation = report.summary
                request = nil
                follow(report, command: command, parameters: parameters, env: env)
            case .needsInput(let fields):
                request = CommandRequest(
                    command: command, title: title ?? command.rawValue, selection: selection, parameters: parameters, fields: fields
                )
            case .unsupported(let unsupported):
                request = nil
                error = ClassifiedError(
                    category: .userInput, whatHappened: unsupported.reason, whatSurvived: ["Nothing was changed."],
                    nextActions: [NextAction("Select a different object and try again")]
                )
            }
        } catch {
            self.error = classify(error).preserving("Nothing from this command was saved; the store rolled it back.")
        }
    }

    private func follow(_ report: ActionReport, command: CommandID, parameters: ActionParameters, env: NexusEnvironment) {
        switch report.detail {
        case .export(let data):
            export = data
            return
        default:
            break
        }
        if command == .ask {
            pendingGoal = parameters.goal
            env.context.open(.conversation)
            return
        }
        if let focus = report.focus {
            try? env.context.open(focus, in: report.screen, from: .command)
        } else {
            env.context.open(report.screen)
        }
    }
}

/// A form for the fields a command asked for.
struct CommandInputForm: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let request: CommandRequest

    @State private var text: [ActionParameters.Field: String] = [:]
    @State private var dates: [ActionParameters.Field: Date] = [:]
    @State private var objects: [ActionParameters.Field: ObjectID] = [:]
    @State private var many: [ActionParameters.Field: Set<ObjectID>] = [:]
    @State private var truth: TruthClass?
    @State private var file: (data: Data, mediaType: String, name: String)?
    @State private var importing: ActionParameters.Field?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(request.fields, id: \.field) { field in
                    row(field)
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { submit() }.accessibilityIdentifier("command.run")
                }
            }
            .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }), allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        let type = UTType(filenameExtension: url.pathExtension)
                        file = (data, type?.preferredMIMEType ?? "application/octet-stream", url.lastPathComponent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ field: InputField) -> some View {
        let label = field.required ? field.label : "\(field.label) (optional)"
        switch field.kind {
        case .text, .unit, .relationKind, .objectType:
            TextField(label, text: binding(field.field))
                .accessibilityIdentifier("field.\(field.field.rawValue)")
        case .number:
            TextField(label, text: binding(field.field))
                .accessibilityIdentifier("field.\(field.field.rawValue)")
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        case .date:
            DatePicker(label, selection: Binding(get: { dates[field.field] ?? Date() }, set: { dates[field.field] = $0 }))
        case .truth(let options):
            Picker(label, selection: Binding(get: { truth ?? options.first ?? .observed }, set: { truth = $0 })) {
                ForEach(options, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        case .choice(let options):
            Picker(label, selection: Binding(get: { text[field.field] ?? options.first ?? "" }, set: { text[field.field] = $0 })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .object(let types):
            Picker(label, selection: Binding(get: { objects[field.field] }, set: { objects[field.field] = $0 })) {
                Text("Choose…").tag(ObjectID?.none)
                ForEach(candidates(types)) { Text($0.title).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("field.\(field.field.rawValue)")
        case .objects(let types):
            Section(label) {
                ForEach(candidates(types)) { record in
                    Toggle(record.title, isOn: Binding(
                        get: { many[field.field]?.contains(record.id) ?? false },
                        set: { on in
                            var set = many[field.field] ?? []
                            if on { set.insert(record.id) } else { set.remove(record.id) }
                            many[field.field] = set
                        }
                    ))
                }
            }
        case .file:
            Button(file?.name ?? label) { importing = field.field }
        }
    }

    private func binding(_ field: ActionParameters.Field) -> Binding<String> {
        Binding(get: { text[field] ?? "" }, set: { text[field] = $0 })
    }

    /// Objects the field may point at: the project's members of those types,
    /// or every object of those types.
    private func candidates(_ types: Set<ObjectType>?) -> [ObjectRecord] {
        let project = env.context.activeProject ?? env.demo?.project
        let members = (try? project.map { try env.projects.members(of: $0, transitive: true) }) ?? nil
        let pool = members ?? (types ?? []).flatMap { (try? env.store.objects(ofType: $0)) ?? [] }
        return pool.filter { types?.contains($0.type) ?? true }.sorted { $0.title < $1.title }
    }

    private func submit() {
        var parameters = request.parameters
        for field in request.fields {
            let value = text[field.field]?.trimmingCharacters(in: .whitespaces)
            if field.required, isEmpty(field) {
                problem = "\(field.label) is needed. Nothing was run."
                return
            }
            switch field.field {
            case .title: parameters.title = value
            case .type: parameters.type = value.map { ObjectType(rawValue: $0) }
            case .relation: parameters.relation = value.map { RelationKind(rawValue: $0) }
            case .symptom: parameters.symptom = value
            case .goal: parameters.goal = value
            case .query: parameters.query = value
            case .statement: parameters.statement = value
            case .reason: parameters.reason = value
            case .resolution: parameters.resolution = value
            case .summary: parameters.summary = value
            case .quantity: parameters.quantity = value
            case .unit: parameters.unit = value
            case .loading: parameters.loading = value
            case .applicability: parameters.applicability = value
            case .mediaType: parameters.mediaType = value
            case .value: parameters.value = number(value)
            case .uncertainty: parameters.uncertainty = number(value)
            case .rangeLow: parameters.rangeLow = number(value)
            case .rangeHigh: parameters.rangeHigh = number(value)
            case .prior: parameters.prior = number(value)
            case .confidence: parameters.confidence = number(value)
            case .seconds: parameters.seconds = number(value)
            case .sampledAt: parameters.sampledAt = dates[field.field]
            case .dueAt: parameters.dueAt = dates[field.field]
            case .truth: parameters.truth = truth ?? .observed
            case .project: parameters.project = objects[field.field]
            case .target: parameters.target = objects[field.field]
            case .testPoint: parameters.testPoint = objects[field.field]
            case .instrument: parameters.instrument = objects[field.field]
            case .investigation: parameters.investigation = objects[field.field]
            case .procedure: parameters.procedure = objects[field.field]
            case .dependsOn: parameters.dependsOn = Array(many[field.field] ?? [])
            case .evidence: parameters.evidence = Array(many[field.field] ?? [])
            case .steps: parameters.steps = (value ?? "").split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
            case .safetyNotes: parameters.safetyNotes = (value ?? "").split(separator: "\n").map { String($0) }
            case .sourceClass: parameters.sourceClass = value.flatMap { SourceClass(rawValue: $0.lowercased()) }
            case .format: parameters.format = value.flatMap { ExportFormat(rawValue: $0.lowercased()) }
            case .data:
                parameters.data = file?.data
                parameters.mediaType = parameters.mediaType ?? file?.mediaType
            case .owner: parameters.owner = value.map { .user(id: $0) }
            case .attributes, .tests, .predictions, .faults, .loop:
                break  // Structured values come from the screen that started the command.
            }
        }
        dismiss()
        env.commands.run(request.command, title: request.title, selection: request.selection, parameters: parameters)
    }

    private func isEmpty(_ field: InputField) -> Bool {
        switch field.kind {
        case .object: objects[field.field] == nil
        case .objects: (many[field.field] ?? []).isEmpty
        case .date: false
        case .truth: false
        case .file: file == nil
        case .choice: false
        default: (text[field.field] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func number(_ text: String?) -> Double? {
        text.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }
}

/// What happened, what survived, and what to do next — for any error.
public struct ClassifiedErrorView: View {
    let error: ClassifiedError

    public init(_ error: ClassifiedError) {
        self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.whatHappened, systemImage: symbol).font(.callout.bold())
            Text(category).font(.caption).foregroundStyle(.secondary)
            ForEach(error.whatSurvived, id: \.self) { Label($0, systemImage: "checkmark.shield").font(.caption) }
            ForEach(error.nextActions, id: \.title) { Label($0.title, systemImage: "arrow.right.circle").font(.caption) }
        }
        .accessibilityElement(children: .combine)
    }

    private var category: String {
        switch error.category {
        case .userInput: "Input problem"
        case .dataSource: "Data or source problem"
        case .systemRuntime: "System problem"
        case .agentTool: "Agent or tool problem"
        case .evidenceVerification: "Evidence or verification problem"
        }
    }

    private var symbol: String {
        switch error.category {
        case .userInput: "pencil.and.outline"
        case .dataSource: "externaldrive.badge.exclamationmark"
        case .systemRuntime: "exclamationmark.octagon"
        case .agentTool: "person.crop.circle.badge.exclamationmark"
        case .evidenceVerification: "checkmark.seal.trianglebadge.exclamationmark"
        }
    }
}

/// Presents command forms, confirmations, errors and exports over any root.
struct CommandPresentation: ViewModifier {
    @Environment(NexusEnvironment.self) private var env

    func body(content: Content) -> some View {
        @Bindable var runner = env.commands
        return content
            .sheet(item: $runner.request) { request in
                CommandInputForm(request: request).environment(env)
            }
            .safeAreaInset(edge: .top) {
                if let error = runner.error {
                    banner { ClassifiedErrorView(error) } dismiss: { runner.error = nil }
                } else if let confirmation = runner.confirmation {
                    banner { Label(confirmation, systemImage: "checkmark.circle").font(.callout) } dismiss: { runner.confirmation = nil }
                        .task(id: confirmation) {
                            try? await Task.sleep(for: .seconds(4))
                            if runner.confirmation == confirmation { runner.confirmation = nil }
                        }
                }
            }
            .fileExporter(
                isPresented: Binding(get: { runner.export != nil }, set: { if !$0 { runner.export = nil } }),
                document: runner.export.map(ExportDocument.init),
                contentType: runner.export?.mediaType == "text/csv" ? .commaSeparatedText : .json,
                defaultFilename: runner.export?.suggestedFilename
            ) { _ in runner.export = nil }
    }

    private func banner<Body: View>(@ViewBuilder _ body: () -> Body, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            body()
            Spacer()
            Button { dismiss() } label: { Label("Dismiss", systemImage: "xmark") }.labelStyle(.iconOnly)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data

    init(_ export: ExportedData) {
        data = export.data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension View {
    /// Command forms, confirmations, classified errors and exports.
    public func commandPresentation() -> some View {
        modifier(CommandPresentation())
    }
}
#endif
