#if canImport(SwiftUI)
import Foundation
import NexusAgents
import NexusCore
import NexusMeetings
import NexusModel
import NexusResearch
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: Meeting

/// Notes or a recording become decisions, commitments, tasks, claims and
/// questions, promoted into canonical objects that link back to the meeting.
struct MeetingScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var title = "Meeting"
    @State private var notes = ""
    @State private var participants = ""
    @State private var recorder = NoteRecorder()
    @State private var transcribing = false
    @State private var error: ClassifiedError?
    @State private var promoted: NotePromotion.Promotion?

    var body: some View {
        _ = env.revision
        let preview = NotePromotion.extract(from: notes)
        let meetings = (try? env.store.objects(ofType: .meeting)) ?? []
        return Form {
            Section("Notes") {
                TextField("Title", text: $title)
                TextField("Participants, comma-separated", text: $participants)
                TextEditor(text: $notes)
                    .frame(minHeight: 160)
                    .writingToolsBehavior(.complete)
                    .accessibilityLabel("Meeting notes")
                HStack {
                    if recorder.isRecording {
                        Button("Stop and transcribe", systemImage: "stop.circle") { stopAndTranscribe() }
                    } else {
                        Button("Record", systemImage: "mic") { startRecording() }
                            .disabled(env.transcribe == nil || transcribing)
                    }
                    if transcribing { ProgressView("Transcribing on device…") }
                }
                if env.transcribe == nil {
                    Text("Transcription needs speech recognition on this device.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Will become (\(preview.count))") {
                if preview.isEmpty {
                    Text("Lines like “Decision: …”, “I will …”, “Action: …” or questions become objects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(preview.enumerated()), id: \.offset) { _, item in
                    LabeledContent(item.kind.rawValue.capitalized, value: item.speaker.map { "\($0): \(item.text)" } ?? item.text)
                }
                Button("Promote into the project") { promote() }.disabled(notes.isEmpty)
            }
            if let promoted {
                Section("Promoted") {
                    Button("Open meeting") { try? env.context.open(promoted.meeting, from: .collection) }
                    Text("\(promoted.items.count) items, \(promoted.commitments.count) commitments, \(promoted.participants.count) people")
                        .font(.caption)
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
            Section("Earlier meetings") {
                ForEach(meetings) { meeting in
                    Button { try? env.context.open(meeting.id, from: .collection) } label: { ObjectRow(record: meeting) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func startRecording() {
        do {
            try recorder.start()
            error = nil
        } catch {
            self.error = classify(error).preserving("Your typed notes are unchanged.")
        }
    }

    private func stopAndTranscribe() {
        guard let url = recorder.stop(), let transcribe = env.transcribe else { return }
        transcribing = true
        Task {
            do {
                let text = try await transcribe(url)
                notes += (notes.isEmpty ? "" : "\n") + text
                error = nil
            } catch {
                self.error = classify(error).preserving("The recording is kept at \(url.lastPathComponent); your notes are unchanged.")
            }
            transcribing = false
        }
    }

    private func promote() {
        do {
            let project = env.context.activeProject ?? env.demo?.project
            let names = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            promoted = try NotePromotion.promote(
                transcript: notes, title: title, participants: names, in: env.store, by: env.user, at: Date(),
                about: project.map { [$0] } ?? []
            )
            if let project, let meeting = promoted?.meeting {
                try env.projects.add(meeting, to: project, by: env.user)
            }
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing was promoted; the notes are still here.")
        }
    }
}

/// Records audio to a temporary file for on-device transcription.
@MainActor
@Observable
final class NoteRecorder {
    private(set) var isRecording = false
    #if canImport(AVFoundation)
    @ObservationIgnored private var recorder: AVAudioRecorder?
    #endif
    @ObservationIgnored private var url: URL?

    func start() throws {
        #if canImport(AVFoundation)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
        self.recorder = recorder
        self.url = url
        isRecording = true
        #endif
    }

    func stop() -> URL? {
        #if canImport(AVFoundation)
        recorder?.stop()
        recorder = nil
        #endif
        isRecording = false
        return url
    }
}

// MARK: Research

/// Question → plan → sources → claims → contradictions → applicability →
/// synthesis, over the local library. Every claim cites its passage.
struct ResearchScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var question = ""
    @State private var result: ResearchResult?
    @State private var error: ClassifiedError?

    var body: some View {
        Form {
            Section("Question") {
                TextField("What do you want to know?", text: $question, axis: .vertical)
                if let subject = env.object(env.context.focus) {
                    LabeledContent("About", value: subject.title)
                }
                Button("Research") { run() }.disabled(question.isEmpty)
            }
            if let error { Section { ClassifiedErrorView(error) } }
            if let result {
                Section("Plan") {
                    ForEach(result.plan.subQuestions, id: \.self) { Label($0, systemImage: "list.bullet") }
                    Text(result.plan.method).font(.caption).foregroundStyle(.secondary)
                }
                Section("Sources (\(result.sources.count))") {
                    if result.sources.isEmpty {
                        NextActionEmptyState("No sources found", message: "Import manuals or datasheets in Documents first.", systemImage: "doc.text.magnifyingglass")
                    }
                    ForEach(result.sources, id: \.document) { source in
                        Button { try? env.context.open(source.document, in: .document, from: .collection) } label: {
                            LabeledContent(source.title, value: source.classification.sourceClass.rawValue.capitalized)
                        }
                    }
                }
                Section("Claims") {
                    ForEach(result.evidence, id: \.claim) { evidence in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(evidence.label)] \(evidence.statement)")
                            HStack {
                                Text(evidence.sourceClass.rawValue.capitalized)
                                if let applicability = evidence.applicability { Text("· applies to \(applicability)") }
                                TruthBadge(.claimed)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !result.contradictions.isEmpty {
                    Section("Contradictions") {
                        ForEach(Array(result.contradictions.enumerated()), id: \.offset) { _, contradiction in
                            Label(contradiction.detail, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        }
                    }
                }
                if !result.applicability.isEmpty {
                    Section("Applies to this configuration?") {
                        ForEach(Array(result.applicability.enumerated()), id: \.offset) { _, match in
                            LabeledContent(match.verdict.rawValue.capitalized, value: match.detail)
                        }
                    }
                }
                Section("Synthesis") {
                    Text(result.synthesis).textSelection(.enabled)
                    HStack { TruthBadge(.agentInterpretation); Spacer() }
                    Button("Open report") { try? env.context.open(result.report, from: .collection) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func run() {
        do {
            let project = env.context.activeProject ?? env.demo?.project
            result = try env.research.researchLocally(ResearchQuestion(question, subject: env.context.focus, project: project), by: env.user)
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing was written; the research runs in one transaction.")
        }
    }
}

// MARK: Conversation

/// Natural-language orchestration: the orchestrator picks a specialist, the
/// run streams its steps, and every turn links to its inspectable run.
struct ConversationScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var draft = ""
    @State private var turns: [Turn] = []
    @State private var running: Task<Void, Never>?

    struct Turn: Identifiable {
        let id = UUID()
        var goal: String
        var specialist: String?
        var text: String = ""
        var steps: Int = 0
        var run: ObjectID?
        var status: String?
        var failed = false
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if turns.isEmpty {
                    NextActionEmptyState(
                        "Ask anything about the selection", message: "Nexus routes it to the right specialist and shows every step.",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.goal).font(.headline)
                        if let specialist = turn.specialist { Text("Specialist: \(specialist)").font(.caption).foregroundStyle(.secondary) }
                        Text(turn.text.isEmpty ? (turn.failed ? "" : "Working… (\(turn.steps) steps)") : turn.text).textSelection(.enabled)
                        HStack {
                            TruthBadge(.agentInterpretation)
                            if let status = turn.status { Text(status).font(.caption) }
                            Spacer()
                            if let run = turn.run {
                                Button("Run details") { try? env.context.open(run, in: .agentActivity, from: .conversation) }.font(.caption)
                            }
                        }
                    }
                }
            }
            HStack {
                TextField(env.agents == nil ? "No language model installed (Settings → Models)" : "Ask…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                if running != nil {
                    Button("Stop", systemImage: "stop.fill") { running?.cancel() }.labelStyle(.iconOnly)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .labelStyle(.iconOnly)
                        .disabled(draft.isEmpty || env.agents == nil)
                }
            }
            .padding()
        }
        .onAppear {
            if let goal = env.commands.pendingGoal {
                draft = goal
                env.commands.pendingGoal = nil
            }
        }
    }

    private func send() {
        guard let agents = env.agents else { return }
        let goal = draft
        draft = ""
        turns.append(Turn(goal: goal))
        let index = turns.count - 1
        var request = AgentRequestFactory.request(goal: goal, env: env)
        request.privacy = ModelPrivacy.current.requirement
        let (events, sink) = AsyncStream<AgentEvent>.makeStream()
        running = Task {
            let consumer = Task {
                for await event in events {
                    if case .textDelta(let text) = event { turns[index].text += text }
                    if case .step = event { turns[index].steps += 1 }
                }
            }
            do {
                let outcome = try await agents.run(request, orchestrator: Orchestrator(), approver: AlertApprover.shared) { sink.yield($0) }
                turns[index].specialist = outcome.choice.profile.id
                turns[index].text = outcome.result.output
                turns[index].run = outcome.result.run
                turns[index].status = outcome.result.status.rawValue
            } catch is CancellationError {
                turns[index].failed = true
                turns[index].text = "Stopped. Completed steps stay in the run's ledger."
            } catch {
                turns[index].failed = true
                turns[index].text = classify(error).whatHappened
            }
            sink.finish()
            await consumer.value
            running = nil
        }
    }
}

// MARK: Creative

/// Select → direct edit → AI action → variants → compare → accept. Every
/// edit is a revision; an agent's variant is a separate draft derived from
/// the artifact, and accepting it is a person's revision.
struct CreativeScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var body_ = ""
    @State private var loadedFor: ObjectID?
    @State private var instruction = "Make it clearer and shorter"
    @State private var variant: ObjectRecord?
    @State private var working = false
    @State private var error: ClassifiedError?

    private var artifact: ObjectRecord? {
        if let focus = env.object(env.context.focus), focus.type == .artifact { return focus }
        return nil
    }

    var body: some View {
        _ = env.revision
        let artifacts = (try? env.store.objects(ofType: .artifact)) ?? []
        return Form {
            if let artifact {
                Section(artifact.title) {
                    TextEditor(text: $body_)
                        .frame(minHeight: 180)
                        .writingToolsBehavior(.complete)
                        .onAppear { load(artifact) }
                        .onChange(of: artifact.id) { load(artifact) }
                    Button("Save version") { save(artifact) }
                }
                Section("AI action") {
                    TextField("Instruction", text: $instruction)
                    Button(working ? "Working…" : "Make a variant") { makeVariant(of: artifact) }
                        .disabled(env.agents == nil || working)
                    if env.agents == nil { Text("Needs a language model (Settings → Models).").font(.caption).foregroundStyle(.secondary) }
                }
                if let variant, case .string(let text)? = variant.attributes["body"]?.value {
                    Section("Compare") {
                        Text("Current").font(.caption.bold())
                        Text(body_).font(.callout)
                        Text("Variant").font(.caption.bold())
                        Text(text).font(.callout)
                        HStack { TruthBadge(.agentInterpretation); Text("Draft").font(.caption) }
                        Button("Accept variant") { accept(text, into: artifact, from: variant) }
                        Button("Discard", role: .destructive) { self.variant = nil }
                    }
                }
                Section("Versions") {
                    let revisions = (try? env.store.revisions(of: artifact.id)) ?? []
                    ForEach(revisions.reversed()) { revision in
                        RevisionRow(record: artifact, revision: revision, isHead: revision.id == revisions.last?.id)
                    }
                }
            } else {
                Section {
                    Button("New artifact") { create() }
                }
                Section("Artifacts") {
                    if artifacts.isEmpty {
                        NextActionEmptyState("No artifacts", message: "Create one to write, then ask for variants.", systemImage: "paintbrush")
                    }
                    ForEach(artifacts) { record in
                        Button { try? env.context.open(record.id, in: .creative, from: .collection) } label: { ObjectRow(record: record) }
                    }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
        .formStyle(.grouped)
    }

    private func load(_ artifact: ObjectRecord) {
        guard loadedFor != artifact.id else { return }
        loadedFor = artifact.id
        if case .string(let text)? = artifact.attributes["body"]?.value { body_ = text } else { body_ = "" }
        variant = nil
    }

    private func create() {
        do {
            let record = try env.actions.create(.artifact, title: "Untitled artifact", in: env.context.activeProject ?? env.demo?.project).detail
            try env.context.open(record.id, in: .creative, from: .collection)
        } catch {
            self.error = classify(error)
        }
    }

    private func save(_ artifact: ObjectRecord) {
        do {
            _ = try env.store.update(artifact.id, by: env.user, instruction: "Edited") { $0.attributes["body"] = Attribute(.string(body_)) }
            error = nil
        } catch {
            self.error = classify(error).preserving("Your text is still in the editor.")
        }
    }

    private func makeVariant(of artifact: ObjectRecord) {
        guard let agents = env.agents else { return }
        working = true
        var request = AgentRequest(goal: "\(instruction). Reply with only the rewritten text:\n\n\(body_)", focus: [artifact.id])
        request.privacy = ModelPrivacy.current.requirement
        Task {
            do {
                let result = try await agents.run(request, as: .writing, approver: AlertApprover.shared)
                let now = Date()
                let provenance = Provenance(origin: .agent(id: AgentProfile.writing.id, run: result.run), truth: .agentInterpretation, timestamp: now)
                let draft = try env.store.batch { store in
                    let draft = try store.create(ObjectRecord(
                        type: .artifact, title: "\(artifact.title) — variant", attributes: ["body": Attribute(.string(result.output))],
                        lifecycle: .draft, provenance: provenance
                    ))
                    _ = try store.relate(Relationship(kind: .derivedFrom, from: draft.id, to: artifact.id, validFrom: now, provenance: provenance))
                    return draft
                }
                variant = draft
                error = nil
            } catch {
                self.error = classify(error).preserving("The artifact is unchanged.")
            }
            working = false
        }
    }

    private func accept(_ text: String, into artifact: ObjectRecord, from variant: ObjectRecord) {
        do {
            _ = try env.store.update(artifact.id, by: env.user, instruction: "Accepted variant \(variant.id)") {
                $0.attributes["body"] = Attribute(.string(text))
            }
            body_ = text
            self.variant = nil
            error = nil
        } catch {
            self.error = classify(error).preserving("The artifact and the variant are both unchanged.")
        }
    }
}
#endif
