import Foundation
import NexusCore
import NexusModel

// Career terms on NexusModel's open vocabularies. Roles, skills,
// certifications, work projects and job applications are ordinary objects;
// employers are the shared `organization` type and a résumé is an `artifact`
// derived from the rest. Renewal reminders are `task` objects. Nothing here
// keeps state of its own.

extension ObjectType {
    /// A position held: title, dates, summary and highlights.
    public static let jobRole: ObjectType = "jobRole"
    /// Something the person can do, e.g. "Swift" or "PLC programming".
    public static let skill: ObjectType = "skill"
    /// A credential with an issuer and, often, an expiry date.
    public static let certification: ObjectType = "certification"
    /// A piece of work done in a role or on the side. Not a Nexus `project`,
    /// which organizes objects.
    public static let workProject: ObjectType = "workProject"
    /// An application for a job, moving through `ApplicationStatus`.
    public static let jobApplication: ObjectType = "jobApplication"
}

extension RelationKind {
    /// Role → the organization that employed the person.
    public static let employedBy: RelationKind = "employedBy"
    /// Role or work project → a skill it used.
    public static let usesSkill: RelationKind = "usesSkill"
    /// Role → a work project done in it.
    public static let workedOn: RelationKind = "workedOn"
    /// Certification → the organization that issued it.
    public static let issuedBy: RelationKind = "issuedBy"
    /// Job application → the organization applied to.
    public static let appliedTo: RelationKind = "appliedTo"
    /// Task → the certification it renews.
    public static let renews: RelationKind = "renews"
}

extension EventKind {
    /// An application moved between statuses. Payload: `from`, `to`, optional `note`.
    public static let applicationStatusChanged: EventKind = "applicationStatusChanged"
    /// A résumé file was imported. Payload: counts of created objects.
    public static let resumeImported: EventKind = "resumeImported"
}

/// Attribute and payload keys used on career objects.
public enum CareerKey {
    public static let start = "start"
    public static let end = "end"
    public static let summary = "summary"
    public static let highlights = "highlights"
    public static let url = "url"
    /// A skill's group, e.g. "Languages".
    public static let category = "category"
    public static let level = "level"
    public static let issued = "issued"
    public static let expires = "expires"
    public static let credentialID = "credentialID"
    /// A job application's `ApplicationStatus` raw value.
    public static let status = "status"
    public static let position = "position"
    public static let appliedOn = "appliedOn"
    /// An artifact's kind; résumés are "resume".
    public static let kind = "kind"
    public static let format = "format"
    public static let body = "body"
    public static let blob = "blob"
    public static let mediaType = "mediaType"
}

/// Where a job application stands. The active stages run in order; any
/// active application can be rejected or withdrawn; only an offer can be accepted.
public enum ApplicationStatus: String, Codable, Sendable, CaseIterable {
    case saved
    case applied
    case screening
    case interviewing
    case offer
    case accepted
    case rejected
    case withdrawn

    /// The active stages, in pipeline order.
    public static let pipeline: [ApplicationStatus] = [.saved, .applied, .screening, .interviewing, .offer]

    public var isClosed: Bool { [.accepted, .rejected, .withdrawn].contains(self) }

    /// Forward to any later stage (steps may be skipped), rejected or
    /// withdrawn while open, accepted only from an offer. Closed is final.
    public func canMove(to next: ApplicationStatus) -> Bool {
        guard !isClosed, next != self else { return false }
        switch next {
        case .rejected, .withdrawn: return true
        case .accepted: return self == .offer
        default:
            guard let from = Self.pipeline.firstIndex(of: self), let to = Self.pipeline.firstIndex(of: next) else { return false }
            return to > from
        }
    }
}

/// Where a certification stands on a date. Derived; never stored.
public enum CertificationStanding: Sendable, Hashable {
    case noExpiry
    case valid(daysLeft: Int)
    case expiringSoon(daysLeft: Int)
    case expired(daysAgo: Int)
}

public enum CareerError: Error, Equatable, Sendable {
    case notFound(ObjectID, expected: ObjectType)
    case invalidTransition(ObjectID, from: ApplicationStatus, to: ApplicationStatus)
    case malformedResume(String)
    case unparsableDate(String)
}

/// Calendar days in UTC, as JSON Resume writes them ("2021-03-01", "2021-03", "2021").
public enum CareerCalendar {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static func day(_ year: Int, _ month: Int = 1, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Parses "2021-03-01", "2021-03" or "2021".
    public static func parse(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }), let year = parts[0], (1900...2200).contains(year) else { return nil }
        let month = parts.count > 1 ? parts[1]! : 1
        let day = parts.count > 2 ? parts[2]! : 1
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return self.day(year, month, day)
    }

    public static func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }

    /// "Mar 2021".
    public static func monthYear(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[parts.month! - 1]) \(parts.year!)"
    }

    /// "2027-03-01".
    public static func isoDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

extension Origin {
    /// The truth class of a value this author enters: a person's entry is an
    /// observation, an importer's a record, an agent's an interpretation.
    var entryTruth: TruthClass {
        if case .user = self { return .observed }
        return defaultTruth
    }
}

extension ObjectRecord {
    func string(_ key: String) -> String? {
        if case .string(let text)? = attributes[key]?.value { return text }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let date)? = attributes[key]?.value { return date }
        return nil
    }

    func strings(_ key: String) -> [String] {
        guard case .list(let values)? = attributes[key]?.value else { return [] }
        return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }
}

func sameName(_ a: String, _ b: String) -> Bool {
    a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
}
