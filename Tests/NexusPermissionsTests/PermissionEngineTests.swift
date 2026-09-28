import NexusCore
import Foundation
import NexusModel
import NexusPersistence
import Testing
@testable import NexusPermissions

private func request(_ level: PermissionLevel, agent: String = "diag", action: String = "act", project: ObjectID? = nil, types: Set<ObjectType> = []) -> PermissionRequest {
    PermissionRequest(agent: agent, action: action, level: level, project: project, objectTypes: types)
}

@Suite struct PermissionEngineTests {
    @Test func defaultsFollowTheLevel() {
        let engine = PermissionEngine()
        #expect(engine.evaluate(request(.observe)) == .allow)
        #expect(engine.evaluate(request(.analyze)) == .allow)
        #expect(engine.evaluate(request(.createDraft)) == .allow)
        #expect(engine.evaluate(request(.modifyInternalState)) == .needsApproval(.askOncePerProject))
        #expect(engine.evaluate(request(.externalAction)) == .needsApproval(.askEveryTime))
        #expect(engine.evaluate(request(.sensitive)) == .needsApproval(.askEveryTime))
    }

    @Test func approvalsLastAsLongAsTheirGrant() {
        let engine = PermissionEngine()
        let a = ObjectID.make()
        let b = ObjectID.make()
        engine.recordApproval(of: request(.modifyInternalState, project: a), grant: .askOncePerProject)
        #expect(engine.evaluate(request(.modifyInternalState, project: a)) == .allow)
        #expect(engine.evaluate(request(.modifyInternalState, project: b)) == .needsApproval(.askOncePerProject))

        engine.add(PolicyRule(action: "sync", grant: .askOncePerSession))
        engine.recordApproval(of: request(.modifyInternalState, action: "sync"), grant: .askOncePerSession)
        #expect(engine.evaluate(request(.modifyInternalState, action: "sync")) == .allow)
        engine.endSession()
        #expect(engine.evaluate(request(.modifyInternalState, action: "sync")) == .needsApproval(.askOncePerSession))

        // Ask-every-time approvals are never remembered.
        engine.recordApproval(of: request(.externalAction), grant: .askEveryTime)
        #expect(engine.evaluate(request(.externalAction)) == .needsApproval(.askEveryTime))
    }

    @Test func mostSpecificRuleWinsAndTiesGoToTheStricter() {
        let project = ObjectID.make()
        let engine = PermissionEngine(rules: [
            PolicyRule(level: .modifyInternalState, grant: .never),
            PolicyRule(agent: "diag", level: .modifyInternalState, project: project, grant: .always),
            PolicyRule(agent: "writer", grant: .always),
            PolicyRule(action: "annotate", grant: .askEveryTime),
        ])
        #expect(engine.evaluate(request(.modifyInternalState, project: project)) == .allow)
        #expect(engine.evaluate(request(.modifyInternalState)) == .deny(reason: "Policy forbids act for diag"))
        // "writer" and "annotate" are equally specific: the stricter wins.
        #expect(engine.evaluate(request(.analyze, agent: "writer", action: "annotate")) == .needsApproval(.askEveryTime))
    }

    @Test func objectTypeAndServiceScopesMatch() {
        let engine = PermissionEngine(rules: [
            PolicyRule(objectType: .transaction, grant: .never),
            PolicyRule(service: "mail", grant: .askOncePerSession),
        ])
        #expect(engine.evaluate(request(.observe, types: [.transaction, .person])) == .deny(reason: "Policy forbids act for diag"))
        #expect(engine.evaluate(request(.observe, types: [.person])) == .allow)
        let mail = PermissionRequest(agent: "diag", action: "send", level: .modifyInternalState, service: "mail")
        #expect(engine.evaluate(mail) == .needsApproval(.askOncePerSession))
    }

    @Test func sensitiveAndExternalActionsCannotBeBlanketAllowed() {
        let engine = PermissionEngine(rules: [
            PolicyRule(grant: .always),
            PolicyRule(agent: "mailer", action: "send_message", grant: .always),
        ])
        #expect(engine.evaluate(request(.sensitive)) == .needsApproval(.askEveryTime))
        #expect(engine.evaluate(request(.externalAction)) == .needsApproval(.askEveryTime))
        // A rule naming both agent and action may pre-approve an external action…
        #expect(engine.evaluate(request(.externalAction, agent: "mailer", action: "send_message")) == .allow)
        // …but never a sensitive one.
        #expect(engine.evaluate(request(.sensitive, agent: "mailer", action: "send_message")) == .needsApproval(.askEveryTime))

        let forbidden = PermissionEngine(rules: [PolicyRule(level: .sensitive, grant: .never)])
        #expect(forbidden.evaluate(request(.sensitive)) == .deny(reason: "Policy forbids act for diag"))
    }
}

private extension ObjectType {
    static let transaction: ObjectType = "transaction"
}

@Suite struct PersistentPermissionTests {
    @Test func rulesAndProjectApprovalsSurviveRestartSessionApprovalsDoNot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = ObjectID.make()
        let rule = PolicyRule(agent: "diag", action: "annotate", grant: .never)
        do {
            let engine = try PermissionEngine(store: try NexusStore(.file(url)))
            try engine.add(rule, by: .user(id: "admin"))
            engine.add(PolicyRule(action: "sync", grant: .askOncePerSession))
            engine.recordApproval(of: request(.modifyInternalState, project: project), grant: .askOncePerProject)
            engine.recordApproval(of: request(.modifyInternalState, action: "sync"), grant: .askOncePerSession)
        }
        let engine = try PermissionEngine(store: try NexusStore(.file(url)))
        #expect(engine.rules == [rule], "Only rules added with an author are persisted")
        #expect(engine.evaluate(request(.modifyInternalState, project: project)) == .allow)
        #expect(engine.evaluate(request(.modifyInternalState, action: "sync")) == .needsApproval(.askOncePerProject))
        #expect(engine.evaluate(request(.analyze, action: "annotate")) == .deny(reason: "Policy forbids annotate for diag"))

        try engine.remove(rule.id, by: .system)
        #expect(try PermissionEngine(store: try NexusStore(.file(url))).rules.isEmpty)
    }

    @Test func agentsCannotChangePolicy() throws {
        let engine = try PermissionEngine(store: try NexusStore(.inMemory))
        let agent = Origin.agent(id: "diag", run: nil)
        #expect(throws: PermissionError.policyChangeRequiresPerson(agent)) {
            try engine.add(PolicyRule(grant: .always), by: agent)
        }
        #expect(throws: PermissionError.policyChangeRequiresPerson(.model(ModelRef(provider: "p", modelID: "m")))) {
            try engine.remove(.make(), by: .model(ModelRef(provider: "p", modelID: "m")))
        }
        #expect(engine.rules.isEmpty)
    }
}
