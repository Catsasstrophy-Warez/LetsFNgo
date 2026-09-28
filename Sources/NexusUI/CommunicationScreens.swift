#if canImport(SwiftUI)
import Foundation
import NexusCommunications
import NexusCore
import NexusModel
import SwiftUI
import UniformTypeIdentifiers
#if canImport(MessageUI)
@preconcurrency import MessageUI
#endif
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// MARK: Threads about an object

/// Email and message threads about an object (Object Detail), with import
/// of .eml/.mbox files and compose prefilled from the object.
///
/// Apple doesn't let apps read Mail or Messages, so threads get here by
/// import or by being sent from Nexus (docs/COMMUNICATIONS.md).
struct CommunicationsSection: View {
    @Environment(NexusEnvironment.self) private var env
    let subject: ObjectID
    @State private var importing = false
    @State private var composing: ComposeRequest?
    @State private var summary: String?
    @State private var error: ClassifiedError?

    var body: some View {
        let _ = env.revision
        let threads = (try? CommunicationLibrary(store: env.store).threads(about: subject)) ?? []
        Section("Communications") {
            if threads.isEmpty {
                Text("No email or messages about this yet. Import .eml or .mbox files, or send one from here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(threads) { thread in
                NavigationLink {
                    ThreadScreen(thread: thread.id).environment(env)
                } label: {
                    ThreadRow(thread: thread)
                }
            }
            Button("Email about this", systemImage: "envelope") { compose(.email) }
            if ComposeRequest.canSendText {
                Button("Message about this", systemImage: "message") { compose(.textMessage) }
            }
            Button("Import email (.eml, .mbox)", systemImage: "tray.and.arrow.down") { importing = true }
            if let summary { Label(summary, systemImage: "checkmark.circle").font(.caption) }
            if let error { ClassifiedErrorView(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: CommunicationFiles.types, allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .sheet(item: $composing) { request in
            ComposeSheet(request: request).environment(env)
        }
    }

    private func compose(_ channel: CommunicationChannel) {
        do {
            composing = ComposeRequest(draft: try CommunicationComposer.draft(about: subject, channel: channel, in: env.store))
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing was sent or stored.")
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            var messages = 0
            var duplicates = 0
            for url in try result.get() {
                let imported = try CommunicationFiles.importFile(at: url, about: [subject], env: env)
                messages += imported.messages.count
                duplicates += imported.duplicates.count
            }
            summary = "Imported \(messages) message(s); \(duplicates) already here were skipped."
            error = nil
        } catch {
            self.error = classify(error).preserving("Files imported before the failure were kept; each file is all or nothing.")
        }
    }
}

/// Reading .eml and .mbox files picked in the file importer.
@MainActor
enum CommunicationFiles {
    static let types: [UTType] =
        [UTType("com.apple.mail.email"), UTType(filenameExtension: "eml"), UTType(filenameExtension: "mbox"), UTType("com.apple.mail.mbox")]
        .compactMap { $0 } + [.data, .folder]

    /// Mail on the Mac exports a mailbox as a folder holding an `mbox` file.
    static func importFile(at url: URL, about subjects: [ObjectID], env: NexusEnvironment) throws -> CommunicationImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        var file = url
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file = url.appendingPathComponent("mbox")
        }
        let data = try Data(contentsOf: file)
        let name = url.lastPathComponent
        let importer = CommunicationImporter(store: env.store)
        if isDirectory.boolValue { return try importer.importMBox(data, named: name, about: subjects, by: env.user) }
        return try importer.importFile(data, named: name, about: subjects, by: env.user)
    }
}

struct ThreadRow: View {
    let thread: CommunicationThread

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(thread.record.title).lineLimit(1)
            HStack {
                Text("\(thread.messageCount) message\(thread.messageCount == 1 ? "" : "s")")
                if let last = thread.lastMessageAt { Text(last.formatted(date: .abbreviated, time: .shortened)) }
                Spacer()
                TruthBadge(thread.record.provenance.truth)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Thread view

/// A thread's messages, oldest first, in its own screen.
struct ThreadScreen: View {
    @Environment(NexusEnvironment.self) private var env
    let thread: ObjectID

    var body: some View {
        Form { ThreadMessagesSection(thread: thread) }
            .formStyle(.grouped)
            .navigationTitle(env.title(thread))
    }
}

/// Participants, what the thread is about, and each message with its
/// sender, recipients, date, body and attachments. Used in the thread
/// screen and in Object Detail for a thread.
struct ThreadMessagesSection: View {
    @Environment(NexusEnvironment.self) private var env
    let thread: ObjectID
    @State private var composing: ComposeRequest?

    var body: some View {
        _ = env.revision
        let library = CommunicationLibrary(store: env.store)
        let summary = try? library.thread(thread)
        let messages = (try? library.messages(in: thread)) ?? []
        let subjects = (try? library.subjects(of: thread)) ?? []
        return Group {
            Section("Thread") {
                if let summary {
                    LabeledContent("Participants", value: env.objects(summary.participants).map(\.title).joined(separator: ", "))
                }
                ForEach(subjects, id: \.self) { subject in
                    Button {
                        try? env.context.open(subject, from: .collection)
                    } label: {
                        Label("About \(env.title(subject))", systemImage: "link")
                    }
                }
                Button("Reply by email", systemImage: "arrowshape.turn.up.left") { reply(to: messages.last) }
            }
            Section("Messages (\(messages.count))") {
                ForEach(messages) { message in
                    MessageView(message: message)
                }
            }
        }
        .sheet(item: $composing) { request in
            ComposeSheet(request: request).environment(env)
        }
    }

    private func reply(to last: CommunicationMessage?) {
        let subject = last.map { $0.subject.lowercased().hasPrefix("re:") ? $0.subject : "Re: \($0.subject)" } ?? env.title(thread)
        let people = last.map { $0.isOutgoing ? $0.to : $0.from } ?? []
        let recipients = people.map { EmailAddress.list($0).first?.address ?? $0 }
        let about = (try? CommunicationLibrary(store: env.store).subjects(of: thread)) ?? []
        composing = ComposeRequest(
            draft: OutgoingCommunication(channel: .email, recipients: recipients, subject: subject, body: "", about: about), thread: thread
        )
    }
}

struct MessageView: View {
    @Environment(NexusEnvironment.self) private var env
    let message: CommunicationMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: message.isOutgoing ? "arrow.up.right" : "arrow.down.left").foregroundStyle(.secondary)
                Text(message.isOutgoing ? "You" : (message.from.first ?? "Unknown sender")).font(.subheadline.bold())
                Spacer()
                TruthBadge(message.record.provenance.truth)
            }
            if !message.to.isEmpty { Text("To: \(message.to.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            if !message.cc.isEmpty { Text("Cc: \(message.cc.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            if let sentAt = message.sentAt { Text(sentAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            Text(message.body).lineLimit(expanded ? nil : 6).textSelection(.enabled)
            if message.body.count > 400 {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.caption).buttonStyle(.borderless)
            }
            ForEach(message.attachments) { file in
                Button {
                    try? env.context.open(file.id, from: .collection)
                } label: {
                    Label(file.title, systemImage: "paperclip").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(env.describe(message.record.provenance.origin)).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Compose

/// A draft to hand to the system composer; `thread` continues an existing thread.
struct ComposeRequest: Identifiable {
    let id = UUID()
    var draft: OutgoingCommunication
    var thread: ObjectID?

    @MainActor static var canSendText: Bool {
        #if canImport(MessageUI) && os(iOS)
        MFMessageComposeViewController.canSendText()
        #else
        false
        #endif
    }
}

/// Lets the person review the prefilled draft, then hands it to the system
/// composer. The message is recorded (a `message` object and a
/// `communicationSent` event) only when the composer reports it sent.
struct ComposeSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State var request: ComposeRequest
    @State private var presenting = false
    @State private var status: String?
    @State private var error: ClassifiedError?
    #if canImport(AppKit) && os(macOS)
    @State private var sharing = MailSharing()
    #endif

    init(request: ComposeRequest) {
        _request = State(initialValue: request)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(request.draft.channel == .email ? "Email" : "Message") {
                    TextField(request.draft.channel == .email ? "To (comma-separated addresses)" : "To (comma-separated numbers)", text: recipients)
                    if request.draft.channel == .email { TextField("Subject", text: $request.draft.subject) }
                    TextEditor(text: $request.draft.body).frame(minHeight: 160).writingToolsBehavior(.complete)
                }
                if !request.draft.about.isEmpty {
                    Section("Will be linked to") {
                        ForEach(request.draft.about, id: \.self) { Text(env.title($0)) }
                    }
                }
                if let status { Label(status, systemImage: "info.circle").font(.caption) }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Compose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open composer") { open() } }
            }
            #if canImport(MessageUI) && os(iOS)
            .sheet(isPresented: $presenting) {
                if request.draft.channel == .email {
                    MailComposer(draft: request.draft) { finished($0) }.ignoresSafeArea()
                } else {
                    MessageComposer(draft: request.draft) { finished($0) }.ignoresSafeArea()
                }
            }
            #endif
        }
    }

    private var recipients: Binding<String> {
        Binding(
            get: { request.draft.recipients.joined(separator: ", ") },
            set: { request.draft.recipients = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }

    private func open() {
        #if canImport(MessageUI) && os(iOS)
        if request.draft.channel == .email, !MFMailComposeViewController.canSendMail() {
            handOffToMailto()
            return
        }
        presenting = true
        #elseif canImport(AppKit) && os(macOS)
        if !sharing.compose(request.draft, onSent: { finished("NSSharingService (compose email) reported shared") }) {
            handOffToMailto()
        }
        #else
        handOffToMailto()
        #endif
    }

    /// No compose sheet: open the mail app with a mailto: link. It reports
    /// nothing back, so nothing is recorded.
    private func handOffToMailto() {
        guard let url = CommunicationComposer.mailtoURL(request.draft) else { return }
        openURL(url)
        status = "Opened your mail app. Mail doesn't tell Nexus whether you sent it, so nothing was recorded."
    }

    /// Called only when the composer reports the message sent; `method` names it.
    private func finished(_ method: String?) {
        presenting = false
        guard let method else {
            status = "Not sent, so nothing was recorded."
            return
        }
        do {
            try CommunicationComposer.recordSent(request.draft, method: method, thread: request.thread, in: env.store, by: env.user, at: Date())
            error = nil
            dismiss()
        } catch {
            self.error = classify(error).preserving("The message was sent; only Nexus's record of it failed.")
        }
    }
}

#if canImport(MessageUI) && os(iOS)
/// Mail's compose sheet. Reports the composer's name when the result is
/// `.sent`, and nil for cancelled, saved or failed.
struct MailComposer: UIViewControllerRepresentable {
    let draft: OutgoingCommunication
    let done: @MainActor (String?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(draft.recipients)
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let done: @MainActor (String?) -> Void

        init(done: @escaping @MainActor (String?) -> Void) {
            self.done = done
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            done(result == .sent ? "MFMailComposeViewController reported sent" : nil)
        }
    }
}

/// Messages' compose sheet. Reports the composer's name when the result is
/// `.sent`, and nil for cancelled or failed.
struct MessageComposer: UIViewControllerRepresentable {
    let draft: OutgoingCommunication
    let done: @MainActor (String?) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = draft.recipients
        controller.body = draft.body
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        let done: @MainActor (String?) -> Void

        init(done: @escaping @MainActor (String?) -> Void) {
            self.done = done
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            done(result == .sent ? "MFMessageComposeViewController reported sent" : nil)
        }
    }
}
#endif

#if canImport(AppKit) && os(macOS)
/// The Mac's "compose email" sharing service, which opens a Mail compose
/// window. Its delegate reports when the items were shared; that is the
/// only signal the Mac gives, so it is what gets recorded.
@MainActor
final class MailSharing: NSObject, @preconcurrency NSSharingServiceDelegate {
    private var onSent: (() -> Void)?

    /// False when the service isn't available (no mail account).
    func compose(_ draft: OutgoingCommunication, onSent: @escaping () -> Void) -> Bool {
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [draft.body]) else { return false }
        service.recipients = draft.recipients
        service.subject = draft.subject
        service.delegate = self
        self.onSent = onSent
        service.perform(withItems: [draft.body])
        return true
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        onSent?()
        onSent = nil
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        onSent = nil
    }
}
#endif
#endif
