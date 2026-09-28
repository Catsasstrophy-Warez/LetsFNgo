import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A résumé rendered from career objects, and every object it drew on.
public struct ResumeDraft: Sendable, Hashable {
    public var markdown: String
    public var sources: [ObjectID]
}

/// Renders a Markdown résumé from the career objects in the store.
///
/// Only what a person or a file stated goes in: skill links an agent
/// suggested are left out, and so are certifications expired on `asOf`.
public struct ResumeBuilder: Sendable {
    public let career: CareerRuntime

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        career = CareerRuntime(store: store, clock: clock)
    }

    public func draft(name: String, headline: String? = nil, asOf date: Date) throws -> ResumeDraft {
        var sources: [ObjectID] = []
        var lines = ["# \(name)"]
        if let headline, !headline.isEmpty { lines += ["", headline] }
        var skillUse: [ObjectID: (record: ObjectRecord, count: Int)] = [:]
        func confirmedSkills(of subject: ObjectID) throws -> [ObjectRecord] {
            let skills = try career.skills(of: subject).filter { TruthPolicy.protected.contains($0.truth) }.map(\.skill)
            for skill in skills { skillUse[skill.id, default: (skill, 0)].count += 1 }
            return skills
        }

        let roles = try career.roles()
        var inRoles: Set<ObjectID> = []
        if !roles.isEmpty {
            lines += ["", "## Experience"]
            for role in roles {
                sources.append(role.id)
                let employer = try career.employer(of: role.id)
                if let employer { sources.append(employer.id) }
                lines += ["", "### \(role.position)\(employer.map { " — \($0.title)" } ?? "")"]
                if let period = period(role.start, role.end) { lines += ["*\(period)*"] }
                if let summary = role.summary { lines += ["", summary] }
                if !role.highlights.isEmpty { lines += [""] + role.highlights.map { "- \($0)" } }
                let projects = try career.workProjects(of: role.id).sorted { $0.title < $1.title }
                for project in projects {
                    sources.append(project.id)
                    inRoles.insert(project.id)
                    _ = try confirmedSkills(of: project.id)
                    lines.append("- Project: **\(project.title)**\(project.string(CareerKey.summary).map { " — \($0)" } ?? "")")
                }
                let skills = try confirmedSkills(of: role.id)
                if !skills.isEmpty { lines += ["", "Skills: " + skills.map(\.title).joined(separator: ", ")] }
            }
        }

        let otherProjects = try career.workProjects().filter { !inRoles.contains($0.id) }.sorted { $0.title < $1.title }
        if !otherProjects.isEmpty {
            lines += ["", "## Projects", ""]
            for project in otherProjects {
                sources.append(project.id)
                let skills = try confirmedSkills(of: project.id)
                var line = "- **\(project.title)**"
                if let summary = project.string(CareerKey.summary) { line += " — \(summary)" }
                if !skills.isEmpty { line += " (\(skills.map(\.title).joined(separator: ", ")))" }
                lines.append(line)
            }
        }

        // Skills used most first; skills stated on their own (a file's skills list) after.
        let standalone = try career.skills().filter { skillUse[$0.id] == nil && TruthPolicy.protected.contains($0.provenance.truth) }
        let ranked =
            skillUse.values.sorted { ($0.count, $1.record.title) > ($1.count, $0.record.title) }.map(\.record)
            + standalone.sorted { $0.title < $1.title }
        if !ranked.isEmpty {
            sources += ranked.map(\.id)
            lines += ["", "## Skills", "", ranked.map(\.title).joined(separator: " · ")]
        }

        let certifications = try career.certifications().filter {
            if case .expired = $0.standing(on: date) { return false }
            return true
        }
        if !certifications.isEmpty {
            lines += ["", "## Certifications", ""]
            for certification in certifications {
                sources.append(certification.id)
                let issuer = try career.issuer(of: certification.id)
                var line = "- \(certification.name)"
                if let issuer { line += " — \(issuer.title)" }
                var dates: [String] = []
                if let issued = certification.issued { dates.append("issued \(CareerCalendar.monthYear(issued))") }
                if let expires = certification.expires { dates.append("valid until \(CareerCalendar.monthYear(expires))") }
                if !dates.isEmpty { line += " (\(dates.joined(separator: ", ")))" }
                lines.append(line)
            }
        }
        var seen: Set<ObjectID> = []
        return ResumeDraft(markdown: lines.joined(separator: "\n") + "\n", sources: sources.filter { seen.insert($0).inserted })
    }

    /// Stores the résumé as an `artifact` (kind "resume"), derived truth that
    /// depends on every object it drew on. Regenerating updates the same artifact.
    @discardableResult
    public func generate(name: String, headline: String? = nil, asOf date: Date, by author: Origin) throws -> ObjectRecord {
        let draft = try draft(name: name, headline: headline, asOf: date)
        let store = career.store
        let provenance = Provenance(
            origin: author, truth: .derived, timestamp: career.clock.now(), method: "résumé generated from career objects",
            dependencies: draft.sources, transformation: "ResumeBuilder markdown"
        )
        let title = "Résumé — \(name)"
        let attributes: [String: Attribute] = [
            CareerKey.kind: Attribute(.string("resume")),
            CareerKey.format: Attribute(.string("markdown")),
            CareerKey.body: Attribute(.string(draft.markdown)),
        ]
        return try store.batch { store in
            if let existing = try store.objects(ofType: .artifact).first(where: {
                $0.lifecycle != .deleted && $0.string(CareerKey.kind) == "resume" && $0.title == title
            }) {
                return try store.update(existing.id, by: author, instruction: "Regenerated résumé") {
                    $0.provenance = provenance
                    for (key, attribute) in attributes { $0.attributes[key] = Attribute(attribute.value, provenance: provenance) }
                }
            }
            return try store.create(ObjectRecord(type: .artifact, title: title, attributes: attributes, provenance: provenance))
        }
    }

    private func period(_ start: Date?, _ end: Date?) -> String? {
        guard let start else { return end.map { "until \(CareerCalendar.monthYear($0))" } }
        return "\(CareerCalendar.monthYear(start)) – \(end.map(CareerCalendar.monthYear) ?? "present")"
    }
}
