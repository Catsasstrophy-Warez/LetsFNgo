import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// P0–P5 from the handoff.
public enum PermissionLevel: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case observe = 0
    case analyze = 1
    case createDraft = 2
    case modifyInternalState = 3
    case externalAction = 4
    case sensitive = 5

    public static func < (lhs: PermissionLevel, rhs: PermissionLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How a matching rule answers.
public enum Grant: String, Codable, Sendable, Hashable {
    case always
    case askOncePerProject
    case askOncePerSession
    case askEveryTime
    case never

    /// Higher is more restrictive; used to break ties between equally specific rules.
    var restrictiveness: Int {
        switch self {
        case .always: 0
        case .askOncePerProject: 1
        case .askOncePerSession: 2
        case .askEveryTime: 3
        case .never: 4
        }
    }
}

/// Who wants to do what, where. Every nil field in a rule's scope is a wildcard.
public struct PermissionRequest: Sendable, Hashable {
    public var agent: String
    public var action: String
    public var level: PermissionLevel
    public var project: ObjectID?
    public var objectTypes: Set<ObjectType>
    public var dataSource: String?
    public var service: String?

    public init(
        agent: String,
        action: String,
        level: PermissionLevel,
        project: ObjectID? = nil,
        objectTypes: Set<ObjectType> = [],
        dataSource: String? = nil,
        service: String? = nil
    ) {
        self.agent = agent
        self.action = action
        self.level = level
        self.project = project
        self.objectTypes = objectTypes
        self.dataSource = dataSource
        self.service = service
    }
}

public struct PolicyRule: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var agent: String?
    public var action: String?
    public var level: PermissionLevel?
    public var project: ObjectID?
    public var objectType: ObjectType?
    public var dataSource: String?
    public var service: String?
    public var grant: Grant

    public init(
        id: ObjectID = .make(),
        agent: String? = nil,
        action: String? = nil,
        level: PermissionLevel? = nil,
        project: ObjectID? = nil,
        objectType: ObjectType? = nil,
        dataSource: String? = nil,
        service: String? = nil,
        grant: Grant
    ) {
        self.id = id
        self.agent = agent
        self.action = action
        self.level = level
        self.project = project
        self.objectType = objectType
        self.dataSource = dataSource
        self.service = service
        self.grant = grant
    }

    func matches(_ request: PermissionRequest) -> Bool {
        (agent == nil || agent == request.agent)
            && (action == nil || action == request.action)
            && (level == nil || level == request.level)
            && (project == nil || project == request.project)
            && (objectType == nil || request.objectTypes.contains(objectType!))
            && (dataSource == nil || dataSource == request.dataSource)
            && (service == nil || service == request.service)
    }

    var specificity: Int {
        [agent != nil, action != nil, level != nil, project != nil, objectType != nil, dataSource != nil, service != nil]
            .filter { $0 }.count
    }
}

public enum PermissionError: Error, Equatable, Sendable {
    case policyChangeRequiresPerson(Origin)
}

public enum PermissionDecision: Sendable, Hashable {
    case allow
    /// A person must approve. `grant` says how long an approval lasts.
    case needsApproval(Grant)
    case deny(reason: String)
}

/// Evaluates requests against policy and remembers approvals.
///
/// Resolution: the most specific matching rule wins; equally specific rules
/// resolve to the most restrictive. With no matching rule, defaults apply by
/// level (P0–P2 allowed, P3 asked once per project, P4–P5 asked every time).
///
/// Two invariants no rule can override: sensitive or irreversible actions (P5)
/// are asked every time, and external actions (P4) are never granted
/// `always` by a rule that doesn't name the agent and the action.
///
/// With a backing store, rules and per-project approvals survive restarts;
/// session approvals never do. Only people and the system may change policy.
public final class PermissionEngine: @unchecked Sendable {
    public private(set) var rules: [PolicyRule]
    private let lock = NSLock()
    private let store: NexusStore?
    private var sessionApprovals: Set<ApprovalKey> = []
    private var projectApprovals: Set<ApprovalKey> = []

    static let rulesNamespace = "permissions.rules"
    static let approvalsNamespace = "permissions.projectApprovals"

    /// An in-memory engine, for tests and previews.
    public init(rules: [PolicyRule] = []) {
        self.rules = rules
        self.store = nil
    }

    /// An engine backed by the store: loads saved rules and project approvals.
    public init(store: NexusStore) throws {
        self.store = store
        let decoder = JSONDecoder()
        rules = try store.settings(Self.rulesNamespace).values
            .map { try decoder.decode(PolicyRule.self, from: Data($0.utf8)) }
            .sorted { $0.id < $1.id }
        projectApprovals = Set(try store.settings(Self.approvalsNamespace).values
            .map { try decoder.decode(ApprovalKey.self, from: Data($0.utf8)) })
    }

    /// Adds a rule without persisting it or checking the author; for
    /// in-memory engines and fixtures.
    public func add(_ rule: PolicyRule) {
        lock.withLock { rules.append(rule) }
    }

    /// Adds and persists a rule. Agents and models may never change policy.
    public func add(_ rule: PolicyRule, by author: Origin) throws {
        try requirePerson(author)
        try store?.putSetting(Self.rulesNamespace, rule.id.description, try encode(rule))
        lock.withLock { rules.append(rule) }
    }

    public func remove(_ ruleID: ObjectID, by author: Origin) throws {
        try requirePerson(author)
        try store?.putSetting(Self.rulesNamespace, ruleID.description, nil)
        lock.withLock { rules.removeAll { $0.id == ruleID } }
    }

    private func requirePerson(_ author: Origin) throws {
        switch author {
        case .user, .system: return
        default: throw PermissionError.policyChangeRequiresPerson(author)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public func evaluate(_ request: PermissionRequest) -> PermissionDecision {
        lock.withLock {
            let grant = effectiveGrant(for: request)
            switch grant {
            case .always:
                return .allow
            case .never:
                return .deny(reason: "Policy forbids \(request.action) for \(request.agent)")
            case .askOncePerSession:
                return sessionApprovals.contains(ApprovalKey(request, project: false)) ? .allow : .needsApproval(grant)
            case .askOncePerProject:
                return projectApprovals.contains(ApprovalKey(request, project: true)) ? .allow : .needsApproval(grant)
            case .askEveryTime:
                return .needsApproval(grant)
            }
        }
    }

    /// Records a person's approval so later identical requests follow the
    /// grant's lifetime. Project approvals are persisted when store-backed.
    public func recordApproval(of request: PermissionRequest, grant: Grant) {
        let persist: ApprovalKey? = lock.withLock {
            switch grant {
            case .askOncePerSession:
                sessionApprovals.insert(ApprovalKey(request, project: false))
                return nil
            case .askOncePerProject:
                let key = ApprovalKey(request, project: true)
                return projectApprovals.insert(key).inserted ? key : nil
            case .always, .askEveryTime, .never:
                return nil
            }
        }
        if let key = persist, let store {
            // An approval that fails to save still holds for this run; it
            // will simply be asked again after a restart.
            try? store.putSetting(Self.approvalsNamespace, key.storageKey, try encode(key))
        }
    }

    /// Ends the session: session-scoped approvals are forgotten.
    public func endSession() {
        lock.withLock { sessionApprovals.removeAll() }
    }

    private func effectiveGrant(for request: PermissionRequest) -> Grant {
        let matching = rules.filter { $0.matches(request) }
        let chosen = matching.max { lhs, rhs in
            if lhs.specificity != rhs.specificity { return lhs.specificity < rhs.specificity }
            return lhs.grant.restrictiveness < rhs.grant.restrictiveness
        }
        var grant = chosen?.grant ?? Self.defaultGrant(for: request.level)

        if request.level == .sensitive, grant != .never {
            grant = .askEveryTime
        }
        if request.level == .externalAction, grant == .always, chosen.map({ $0.agent == nil || $0.action == nil }) ?? true {
            grant = .askEveryTime
        }
        return grant
    }

    public static func defaultGrant(for level: PermissionLevel) -> Grant {
        switch level {
        case .observe, .analyze, .createDraft: .always
        case .modifyInternalState: .askOncePerProject
        case .externalAction, .sensitive: .askEveryTime
        }
    }

    private struct ApprovalKey: Hashable, Codable {
        var agent: String
        var action: String
        var level: PermissionLevel
        var project: ObjectID?

        init(_ request: PermissionRequest, project: Bool) {
            agent = request.agent
            action = request.action
            level = request.level
            self.project = project ? request.project : nil
        }

        var storageKey: String {
            "\(agent)|\(action)|\(level.rawValue)|\(project?.description ?? "-")"
        }
    }
}
