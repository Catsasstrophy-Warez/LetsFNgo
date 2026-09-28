import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks

/// A typed view of a role object. The canonical state stays in the store.
public struct JobRole: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var position: String { record.title }
    public var start: Date? { record.date(CareerKey.start) }
    /// Nil while the role is current.
    public var end: Date? { record.date(CareerKey.end) }
    public var summary: String? { record.string(CareerKey.summary) }
    public var highlights: [String] { record.strings(CareerKey.highlights) }
}

/// A typed view of a certification object.
public struct Certification: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var name: String { record.title }
    public var issued: Date? { record.date(CareerKey.issued) }
    public var expires: Date? { record.date(CareerKey.expires) }

    /// Derived standing on `date`; "soon" is within `soon` days.
    public func standing(on date: Date, soon: Int = 60) -> CertificationStanding {
        guard let expires else { return .noExpiry }
        let days = CareerCalendar.days(from: date, to: expires)
        if days < 0 { return .expired(daysAgo: -days) }
        return days <= soon ? .expiringSoon(daysLeft: days) : .valid(daysLeft: days)
    }
}

/// A typed view of a job application object.
public struct JobApplication: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var title: String { record.title }
    public var status: ApplicationStatus { record.string(CareerKey.status).flatMap(ApplicationStatus.init(rawValue:)) ?? .saved }
    public var position: String? { record.string(CareerKey.position) }
    public var appliedOn: Date? { record.date(CareerKey.appliedOn) }
}

/// Roles, employers, skills, certifications, work projects and job
/// applications as objects, relationships and events in the shared store.
///
/// A person's entries are observed truth and an importer's recorded truth.
/// A skill link an agent suggests is an agent interpretation: it is kept,
/// shown as a suggestion, and left out of the résumé until a person links it.
public struct CareerRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    func provenance(_ author: Origin, method: String? = nil) -> Provenance {
        Provenance(origin: author, truth: author.entryTruth, timestamp: clock.now(), method: method)
    }

    // MARK: Organizations and skills

    /// The organization with this name, created when there is none.
    @discardableResult
    public func organization(named name: String, provenance: Provenance) throws -> ObjectRecord {
        if let existing = try store.objects(ofType: .organization).first(where: { $0.lifecycle != .deleted && sameName($0.title, name) }) {
            return existing
        }
        return try store.create(ObjectRecord(type: .organization, title: name, provenance: provenance))
    }

    /// The skill with this name, created when there is none.
    @discardableResult
    public func skill(named name: String, category: String? = nil, provenance: Provenance) throws -> ObjectRecord {
        if let existing = try skills().first(where: { sameName($0.title, name) }) { return existing }
        var attributes: [String: Attribute] = [:]
        if let category, !category.isEmpty { attributes[CareerKey.category] = Attribute(.string(category)) }
        return try store.create(ObjectRecord(type: .skill, title: name, attributes: attributes, provenance: provenance))
    }

    public func skills() throws -> [ObjectRecord] {
        try store.objects(ofType: .skill).filter { $0.lifecycle != .deleted }
    }

    /// Links a skill to a role or work project. From an agent this is a
    /// suggestion (agent interpretation); from a person, an observation that
    /// also retires any suggestion for the same pair.
    @discardableResult
    public func linkSkill(_ name: String, to subject: ObjectID, by author: Origin) throws -> Relationship {
        try link(name, to: subject, provenance: provenance(author, method: "linked skill"))
    }

    func link(_ name: String, to subject: ObjectID, provenance: Provenance) throws -> Relationship {
        try store.batch { store in
            guard let record = try store.object(subject), [.jobRole, .workProject].contains(record.type) else {
                throw CareerError.notFound(subject, expected: .jobRole)
            }
            let skill = try skill(named: name, provenance: provenance)
            let existing = try store.relationships(from: subject, kind: .usesSkill).filter { $0.to == skill.id && $0.validTo == nil }
            // A link a person or a file made stands; so does an identical suggestion.
            if let kept = existing.first(where: { TruthPolicy.protected.contains($0.provenance.truth) || $0.provenance.truth == provenance.truth }) {
                return kept
            }
            for suggestion in existing {
                try store.end(suggestion.id, at: clock.now(), by: provenance.origin, instruction: "Superseded by a confirmed skill")
            }
            return try store.relate(Relationship(kind: .usesSkill, from: subject, to: skill.id, provenance: provenance))
        }
    }

    /// Skills linked to a role or work project, with the truth of each link.
    public func skills(of subject: ObjectID) throws -> [(skill: ObjectRecord, truth: TruthClass)] {
        let edges = try store.relationships(from: subject, kind: .usesSkill).filter { $0.validTo == nil }
        let records = Dictionary(uniqueKeysWithValues: try store.objects(edges.map(\.to)).map { ($0.id, $0) })
        return edges.compactMap { edge in records[edge.to].map { ($0, edge.provenance.truth) } }.sorted { $0.skill.title < $1.skill.title }
    }

    // MARK: Roles and projects

    @discardableResult
    public func addRole(
        _ position: String, at employer: String, start: Date?, end: Date? = nil, summary: String? = nil, highlights: [String] = [], by author: Origin
    ) throws -> JobRole {
        try addRole(position, at: employer, start: start, end: end, summary: summary, highlights: highlights, provenance: provenance(author))
    }

    func addRole(
        _ position: String, at employer: String, start: Date?, end: Date?, summary: String?, highlights: [String], provenance: Provenance
    ) throws -> JobRole {
        try store.batch { store in
            let organization = try organization(named: employer, provenance: provenance)
            var attributes: [String: Attribute] = [:]
            if let start { attributes[CareerKey.start] = Attribute(.date(start)) }
            if let end { attributes[CareerKey.end] = Attribute(.date(end)) }
            if let summary, !summary.isEmpty { attributes[CareerKey.summary] = Attribute(.string(summary)) }
            if !highlights.isEmpty { attributes[CareerKey.highlights] = Attribute(.list(highlights.map(Value.string))) }
            let record = try store.create(ObjectRecord(type: .jobRole, title: position, attributes: attributes, provenance: provenance))
            try store.relate(Relationship(kind: .employedBy, from: record.id, to: organization.id, validFrom: start, validTo: end, provenance: provenance))
            return JobRole(record: record)
        }
    }

    /// Live roles, most recent first (current roles before past ones).
    public func roles() throws -> [JobRole] {
        try store.objects(ofType: .jobRole).filter { $0.lifecycle != .deleted }.map(JobRole.init).sorted {
            ($0.end ?? .distantFuture, $0.start ?? .distantPast) > ($1.end ?? .distantFuture, $1.start ?? .distantPast)
        }
    }

    public func employer(of roleID: ObjectID) throws -> ObjectRecord? {
        guard let edge = try store.relationships(from: roleID, kind: .employedBy).first else { return nil }
        return try store.object(edge.to)
    }

    @discardableResult
    public func addWorkProject(_ name: String, summary: String? = nil, in roleID: ObjectID? = nil, by author: Origin) throws -> ObjectRecord {
        try addWorkProject(name, summary: summary, in: roleID, provenance: provenance(author))
    }

    func addWorkProject(_ name: String, summary: String?, in roleID: ObjectID?, provenance: Provenance) throws -> ObjectRecord {
        try store.batch { store in
            var attributes: [String: Attribute] = [:]
            if let summary, !summary.isEmpty { attributes[CareerKey.summary] = Attribute(.string(summary)) }
            let record = try store.create(ObjectRecord(type: .workProject, title: name, attributes: attributes, provenance: provenance))
            if let roleID { try store.relate(Relationship(kind: .workedOn, from: roleID, to: record.id, provenance: provenance)) }
            return record
        }
    }

    public func workProjects(of roleID: ObjectID) throws -> [ObjectRecord] {
        try store.objects(try store.relationships(from: roleID, kind: .workedOn).filter { $0.validTo == nil }.map(\.to))
    }

    public func workProjects() throws -> [ObjectRecord] {
        try store.objects(ofType: .workProject).filter { $0.lifecycle != .deleted }
    }

    // MARK: Certifications

    @discardableResult
    public func addCertification(_ name: String, issuer: String?, issued: Date?, expires: Date?, credentialID: String? = nil, by author: Origin) throws
        -> Certification
    {
        try addCertification(name, issuer: issuer, issued: issued, expires: expires, credentialID: credentialID, provenance: provenance(author))
    }

    func addCertification(_ name: String, issuer: String?, issued: Date?, expires: Date?, credentialID: String?, provenance: Provenance) throws
        -> Certification
    {
        try store.batch { store in
            var attributes: [String: Attribute] = [:]
            if let issued { attributes[CareerKey.issued] = Attribute(.date(issued)) }
            if let expires { attributes[CareerKey.expires] = Attribute(.date(expires)) }
            if let credentialID, !credentialID.isEmpty { attributes[CareerKey.credentialID] = Attribute(.string(credentialID)) }
            let record = try store.create(ObjectRecord(type: .certification, title: name, attributes: attributes, provenance: provenance))
            if let issuer, !issuer.isEmpty {
                let organization = try organization(named: issuer, provenance: provenance)
                try store.relate(Relationship(kind: .issuedBy, from: record.id, to: organization.id, provenance: provenance))
            }
            return Certification(record: record)
        }
    }

    public func certifications() throws -> [Certification] {
        try store.objects(ofType: .certification).filter { $0.lifecycle != .deleted }.map(Certification.init).sorted {
            ($0.expires ?? .distantFuture, $0.name) < ($1.expires ?? .distantFuture, $1.name)
        }
    }

    public func issuer(of certificationID: ObjectID) throws -> ObjectRecord? {
        guard let edge = try store.relationships(from: certificationID, kind: .issuedBy).first else { return nil }
        return try store.object(edge.to)
    }

    /// Creates a "Renew …" task, due on the expiry date, for each
    /// certification expiring within `lead` days of `date` (or already
    /// expired) that has no renewal task yet. From an agent the tasks are
    /// drafts for a person to approve. Returns the new tasks.
    @discardableResult
    public func scheduleRenewals(asOf date: Date, lead: Int = 60, by author: Origin) throws -> [TaskItem] {
        let tasks = TaskRuntime(store: store, clock: clock)
        return try store.batch { store in
            var created: [TaskItem] = []
            for certification in try certifications() {
                guard let expires = certification.expires, CareerCalendar.days(from: date, to: expires) <= lead else { continue }
                let pending = try store.relationships(to: certification.id, kind: .renews).contains { edge in
                    guard let task = try? tasks.task(edge.from) else { return false }
                    return task.lifecycle != .deleted && task.status != .cancelled
                }
                guard !pending else { continue }
                let task = try tasks.create(
                    "Renew \(certification.name)", successCondition: "A renewed \(certification.name) with a new expiry date is recorded",
                    dueAt: expires, by: author
                )
                try store.relate(
                    Relationship(kind: .renews, from: task.id, to: certification.id, provenance: provenance(author, method: "certification expiry")))
                created.append(task)
            }
            return created
        }
    }

    /// A person records a renewed certification: the new expiry, and any open
    /// renewal task marked done.
    @discardableResult
    public func renew(_ certificationID: ObjectID, expires: Date, by author: Origin) throws -> Certification {
        try store.batch { store in
            guard let record = try store.object(certificationID), record.type == .certification else {
                throw CareerError.notFound(certificationID, expected: .certification)
            }
            let stamp = provenance(author, method: "renewed")
            let updated = try store.update(certificationID, by: author, instruction: "Renewed until \(CareerCalendar.isoDay(expires))") {
                $0.attributes[CareerKey.expires] = Attribute(.date(expires), provenance: stamp)
            }
            if case .user = author {
                let tasks = TaskRuntime(store: store, clock: clock)
                for edge in try store.relationships(to: certificationID, kind: .renews) {
                    guard let task = try? tasks.task(edge.from), task.lifecycle == .active, task.status.canMove(to: .done) else { continue }
                    try tasks.setStatus(.done, of: task.id, reason: "Certification renewed", by: author)
                }
            }
            return Certification(record: updated)
        }
    }

    // MARK: Applications

    @discardableResult
    public func addApplication(
        position: String, at employer: String, status: ApplicationStatus = .saved, appliedOn: Date? = nil, url: String? = nil, by author: Origin
    ) throws -> JobApplication {
        try store.batch { store in
            let stamp = provenance(author)
            let organization = try organization(named: employer, provenance: stamp)
            var attributes: [String: Attribute] = [
                CareerKey.status: Attribute(.string(status.rawValue)),
                CareerKey.position: Attribute(.string(position)),
            ]
            if let appliedOn { attributes[CareerKey.appliedOn] = Attribute(.date(appliedOn)) }
            if let url, !url.isEmpty { attributes[CareerKey.url] = Attribute(.string(url)) }
            let record = try store.create(
                ObjectRecord(type: .jobApplication, title: "\(position) at \(employer)", attributes: attributes, provenance: stamp))
            try store.relate(Relationship(kind: .appliedTo, from: record.id, to: organization.id, provenance: stamp))
            return JobApplication(record: record)
        }
    }

    public func application(_ id: ObjectID) throws -> JobApplication {
        guard let record = try store.object(id), record.type == .jobApplication else { throw CareerError.notFound(id, expected: .jobApplication) }
        return JobApplication(record: record)
    }

    public func applications() throws -> [JobApplication] {
        try store.objects(ofType: .jobApplication).filter { $0.lifecycle != .deleted }.map(JobApplication.init)
    }

    /// Open applications grouped by stage, in pipeline order, then the closed ones.
    public func pipeline() throws -> [(status: ApplicationStatus, applications: [JobApplication])] {
        let all = try applications()
        return ApplicationStatus.allCases.compactMap { status in
            let matching = all.filter { $0.status == status }.sorted { $0.title < $1.title }
            return matching.isEmpty ? nil : (status, matching)
        }
    }

    /// Moves an application along the pipeline, as a new revision plus an
    /// `applicationStatusChanged` event at `date` (default: now).
    @discardableResult
    public func move(_ id: ObjectID, to status: ApplicationStatus, on date: Date? = nil, note: String? = nil, by author: Origin) throws -> JobApplication {
        try store.batch { store in
            let application = try application(id)
            let from = application.status
            guard from.canMove(to: status) else { throw CareerError.invalidTransition(id, from: from, to: status) }
            let stamp = provenance(author, method: "application status")
            let at = date ?? clock.now()
            let updated = try store.update(id, by: author, instruction: "Status \(from.rawValue) → \(status.rawValue)") {
                $0.attributes[CareerKey.status] = Attribute(.string(status.rawValue), provenance: stamp)
                if status == .applied, $0.attributes[CareerKey.appliedOn] == nil {
                    $0.attributes[CareerKey.appliedOn] = Attribute(.date(at), provenance: stamp)
                }
            }
            var payload: [String: Value] = ["from": .string(from.rawValue), "to": .string(status.rawValue)]
            if let note, !note.isEmpty { payload["note"] = .string(note) }
            let employer = try store.relationships(from: id, kind: .appliedTo).map(\.to)
            try store.record(
                Event(
                    at: at, kind: .applicationStatusChanged, subjects: [id] + employer, summary: "\(application.title): \(from.rawValue) → \(status.rawValue)",
                    payload: payload, provenance: stamp
                ))
            return JobApplication(record: updated)
        }
    }

    /// An application's status changes, oldest first.
    public func history(of id: ObjectID) throws -> [Event] {
        try store.events(about: id).filter { $0.kind == .applicationStatusChanged }.sorted { $0.at < $1.at }
    }
}
