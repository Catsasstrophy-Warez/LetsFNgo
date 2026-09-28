#if canImport(SwiftUI)
import Foundation
import NexusCareer
import NexusCore
import NexusModel
import SwiftUI
import UniformTypeIdentifiers

/// Career in the Project screen: roles, certifications with their standing,
/// the application pipeline, JSON Resume import, renewal tasks and the résumé.
struct CareerSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var importing = false
    @State private var position = ""
    @State private var employer = ""
    @State private var name = ""
    @State private var summary: String?
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let career = CareerRuntime(store: env.store)
        let roles = (try? career.roles()) ?? []
        let certifications = (try? career.certifications()) ?? []
        let pipeline = (try? career.pipeline()) ?? []
        let now = Date()
        return Section("Career (\(roles.count) roles)") {
            ForEach(roles.prefix(5)) { role in
                Button { try? env.context.open(role.id, from: .project) } label: {
                    LabeledContent(role.position, value: role.end == nil ? "Current" : role.end!.formatted(.dateTime.year()))
                }
            }
            ForEach(certifications) { certification in
                Button { try? env.context.open(certification.id, from: .project) } label: {
                    HStack {
                        Text(certification.name)
                        Spacer()
                        Text(Self.describe(certification.standing(on: now))).font(.caption)
                        TruthBadge(.derived)
                    }
                }
            }
            ForEach(Array(pipeline.enumerated()), id: \.offset) { _, stage in
                DisclosureGroup("\(stage.status.rawValue.capitalized) (\(stage.applications.count))") {
                    ForEach(stage.applications) { application in
                        Button(application.title) { try? env.context.open(application.id, from: .project) }
                    }
                }
            }
            HStack {
                TextField("Position", text: $position)
                TextField("Employer", text: $employer)
                Button("Save job") { addApplication() }.disabled(position.isEmpty || employer.isEmpty)
            }
            Button("Import résumé (JSON Resume)", systemImage: "doc.badge.plus") { importing = true }
            Button("Create renewal tasks for expiring certifications", systemImage: "checklist") { scheduleRenewals() }
            HStack {
                TextField("Name on the résumé", text: $name)
                Button("Generate résumé") { generate() }.disabled(name.isEmpty)
            }
            if let summary { Label(summary, systemImage: "checkmark.circle").font(.caption) }
            if let error { ClassifiedErrorView(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { importResume($0) }
    }

    static func describe(_ standing: CertificationStanding) -> String {
        switch standing {
        case .noExpiry: "No expiry"
        case .valid(let days): "\(days) days left"
        case .expiringSoon(let days): "Expires in \(days) days"
        case .expired(let days): "Expired \(days) days ago"
        }
    }

    private func addApplication() {
        do {
            let application = try CareerRuntime(store: env.store).addApplication(position: position, at: employer, by: env.user)
            if let project = env.context.activeProject ?? env.demo?.project { try env.projects.add(application.id, to: project, by: env.user) }
            position = ""
            employer = ""
            error = nil
        } catch {
            self.error = classify(error).preserving("No application was added.")
        }
    }

    private func scheduleRenewals() {
        do {
            let tasks = try CareerRuntime(store: env.store).scheduleRenewals(asOf: Date(), by: env.user)
            summary = tasks.isEmpty ? "No certification needs a renewal task." : "Added \(tasks.count) renewal task(s)."
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func generate() {
        do {
            let artifact = try ResumeBuilder(store: env.store).generate(name: name, asOf: Date(), by: env.user)
            error = nil
            try env.context.open(artifact.id, from: .project)
        } catch {
            self.error = classify(error)
        }
    }

    private func importResume(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let imported = try ResumeImporter(store: env.store).importJSONResume(Data(contentsOf: url), named: url.lastPathComponent, by: env.user)
            summary = "Imported \(imported.roles.count) roles, \(imported.skills) skills, \(imported.certifications.count) certifications; \(imported.skipped) already present."
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing from the file was stored; an import is all or nothing.")
        }
    }
}

/// A job application inside Object Detail: its stage, the moves allowed
/// from it, and the history of status changes.
struct ApplicationDomainView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var note = ""
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let career = CareerRuntime(store: env.store)
        return Group {
            if let application = try? career.application(id) {
                Section("Application") {
                    HStack {
                        LabeledContent("Status", value: application.status.rawValue.capitalized)
                        TruthBadge(application.record.truth(of: CareerKey.status) ?? application.record.provenance.truth)
                    }
                    let moves = ApplicationStatus.allCases.filter { application.status.canMove(to: $0) }
                    if !moves.isEmpty {
                        TextField("Note (optional)", text: $note)
                        ForEach(moves, id: \.self) { status in
                            Button("Move to \(status.rawValue)") { move(to: status) }
                        }
                    }
                }
                Section("History") {
                    let history = (try? career.history(of: id)) ?? []
                    if history.isEmpty { Text("No status changes yet.").foregroundStyle(.secondary) }
                    ForEach(history) { event in
                        LabeledContent(event.summary, value: event.at.formatted(date: .abbreviated, time: .omitted)).font(.callout)
                    }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
    }

    private func move(to status: ApplicationStatus) {
        do {
            _ = try CareerRuntime(store: env.store).move(id, to: status, note: note.isEmpty ? nil : note, by: env.user)
            note = ""
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}
#endif
