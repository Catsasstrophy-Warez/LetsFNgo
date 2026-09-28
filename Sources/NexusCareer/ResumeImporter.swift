import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// The parts of a JSON Resume (jsonresume.org, schema 1.0) that map onto
/// career objects. Unknown sections are ignored. Certificates may carry a
/// non-standard `expiryDate`, which many exporters add.
public struct JSONResume: Decodable, Sendable, Hashable {
    public struct Basics: Decodable, Sendable, Hashable {
        public var name: String?
        public var label: String?
        public var summary: String?
    }

    public struct Work: Decodable, Sendable, Hashable {
        public var name: String?
        public var position: String?
        public var startDate: String?
        public var endDate: String?
        public var summary: String?
        public var highlights: [String]?
        public var url: String?
    }

    public struct Skill: Decodable, Sendable, Hashable {
        public var name: String?
        public var level: String?
        public var keywords: [String]?
    }

    public struct Certificate: Decodable, Sendable, Hashable {
        public var name: String?
        public var date: String?
        public var issuer: String?
        public var url: String?
        public var expiryDate: String?
    }

    public struct Project: Decodable, Sendable, Hashable {
        public var name: String?
        public var description: String?
        public var startDate: String?
        public var endDate: String?
        public var keywords: [String]?
        /// The organization the project was done for; matched to a role's employer.
        public var entity: String?
    }

    public var basics: Basics?
    public var work: [Work]?
    public var skills: [Skill]?
    public var certificates: [Certificate]?
    public var projects: [Project]?

    public static func parse(_ data: Data) throws -> JSONResume {
        do {
            return try JSONDecoder().decode(JSONResume.self, from: data)
        } catch {
            throw CareerError.malformedResume("not a JSON Resume: \(error)")
        }
    }
}

/// What one résumé import did.
public struct ResumeImportResult: Sendable, Hashable {
    public var document: ObjectRecord
    public var roles: [JobRole]
    public var skills: Int
    public var certifications: [Certification]
    public var projects: Int
    /// Entries already in the store (same employer, position and start; same name).
    public var skipped: Int
}

/// Imports a JSON Resume into roles, employers, skills, certifications and
/// work projects. The file is stored as a blob behind a `document`; every
/// object is **recorded** truth from `importer(source:)` naming it.
/// Re-importing skips what is already there.
public struct ResumeImporter: Sendable {
    public let store: NexusStore
    public let career: CareerRuntime
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.career = CareerRuntime(store: store, clock: clock)
        self.clock = clock
    }

    @discardableResult
    public func importJSONResume(_ data: Data, named fileName: String, by author: Origin) throws -> ResumeImportResult {
        let resume = try JSONResume.parse(data)
        func date(_ text: String?) throws -> Date? {
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let date = CareerCalendar.parse(text) else { throw CareerError.unparsableDate(text) }
            return date
        }
        return try store.batch { store in
            let document = try storeDocument(data, named: fileName, by: author)
            let provenance = Provenance(
                origin: .importer(source: document.id), truth: .recorded, timestamp: clock.now(), method: "JSON Resume entry",
                dependencies: [document.id]
            )
            var skipped = 0
            var roles: [JobRole] = []
            let existingRoles = try career.roles()
            for work in resume.work ?? [] {
                guard let position = work.position ?? work.name, let employer = work.name ?? work.position else { continue }
                let start = try date(work.startDate)
                let duplicate = try existingRoles.contains { role in
                    guard sameName(role.position, position), role.start == start else { return false }
                    return try career.employer(of: role.id).map { sameName($0.title, employer) } == true
                }
                if duplicate {
                    skipped += 1
                    continue
                }
                roles.append(
                    try career.addRole(
                        position, at: employer, start: start, end: try date(work.endDate), summary: work.summary, highlights: work.highlights ?? [],
                        provenance: provenance
                    ))
            }

            let skillsBefore = try career.skills().count
            for group in resume.skills ?? [] {
                let keywords = (group.keywords ?? []).filter { !$0.isEmpty }
                if keywords.isEmpty, let name = group.name, !name.isEmpty {
                    try career.skill(named: name, provenance: provenance)
                }
                for keyword in keywords { try career.skill(named: keyword, category: group.name, provenance: provenance) }
            }

            var certifications: [Certification] = []
            let existingCertifications = try career.certifications()
            for certificate in resume.certificates ?? [] {
                guard let name = certificate.name, !name.isEmpty else { continue }
                if existingCertifications.contains(where: { sameName($0.name, name) }) {
                    skipped += 1
                    continue
                }
                certifications.append(
                    try career.addCertification(
                        name, issuer: certificate.issuer, issued: try date(certificate.date), expires: try date(certificate.expiryDate), credentialID: nil,
                        provenance: provenance
                    ))
            }

            var projects = 0
            let existingProjects = try career.workProjects()
            let allRoles = try career.roles()
            for project in resume.projects ?? [] {
                guard let name = project.name, !name.isEmpty else { continue }
                if existingProjects.contains(where: { sameName($0.title, name) }) {
                    skipped += 1
                    continue
                }
                let start = try date(project.startDate)
                let role = try project.entity.flatMap { entity in
                    try allRoles.first { role in
                        guard try career.employer(of: role.id).map({ sameName($0.title, entity) }) == true else { return false }
                        guard let start, let roleStart = role.start else { return true }
                        return start >= roleStart && start <= (role.end ?? .distantFuture)
                    }
                }
                let record = try career.addWorkProject(name, summary: project.description, in: role?.id, provenance: provenance)
                for keyword in project.keywords ?? [] where !keyword.isEmpty {
                    try career.link(keyword, to: record.id, provenance: provenance)
                }
                projects += 1
            }
            let skillCount = try career.skills().count - skillsBefore
            try store.record(
                Event(
                    at: clock.now(), kind: .resumeImported, subjects: [document.id] + roles.map(\.id),
                    summary:
                        "Imported \(roles.count) roles, \(skillCount) skills, \(certifications.count) certifications and \(projects) projects from \(document.title)",
                    payload: [
                        "roles": .int(Int64(roles.count)), "skills": .int(Int64(skillCount)), "certifications": .int(Int64(certifications.count)),
                        "projects": .int(Int64(projects)), "skipped": .int(Int64(skipped)),
                    ],
                    provenance: Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "JSON Resume import")
                ))
            return ResumeImportResult(
                document: document, roles: roles, skills: skillCount, certifications: certifications, projects: projects, skipped: skipped)
        }
    }

    /// Stores the file's bytes as a blob and returns its document object,
    /// reusing the document when the same bytes were imported before.
    func storeDocument(_ data: Data, named fileName: String, by author: Origin) throws -> ObjectRecord {
        let blob = try store.putBlob(data, mediaType: "application/json")
        if let existing = try store.objects(ofType: .document).first(where: { $0.string(CareerKey.blob) == blob.sha256 }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .document, title: fileName,
                attributes: [
                    CareerKey.blob: Attribute(.string(blob.sha256)),
                    CareerKey.mediaType: Attribute(.string("application/json")),
                    CareerKey.format: Attribute(.string("JSON Resume")),
                    "byteCount": Attribute(.int(Int64(blob.byteCount))),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "JSON Resume import")
            ))
    }
}
