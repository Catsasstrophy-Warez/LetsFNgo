import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import Testing

@testable import NexusPermissions

@Suite struct ScopedApprovalTests {
    private func request(types: Set<ObjectType> = [], dataSource: String? = nil, service: String? = nil, project: ObjectID? = nil) -> PermissionRequest {
        PermissionRequest(
            agent: "diag", action: "annotate", level: .modifyInternalState, project: project, objectTypes: types, dataSource: dataSource,
            service: service
        )
    }

    @Test func approvalsDoNotCarryAcrossScopes() {
        let engine = PermissionEngine()
        let project = ObjectID.make()
        engine.recordApproval(of: request(types: ["sensor"], project: project), grant: .askOncePerProject)
        #expect(engine.evaluate(request(types: ["sensor"], project: project)) == .allow)
        #expect(engine.evaluate(request(types: ["testPoint"], project: project)) == .needsApproval(.askOncePerProject))
        #expect(engine.evaluate(request(project: project)) == .needsApproval(.askOncePerProject))

        engine.add(PolicyRule(action: "annotate", grant: .askOncePerSession))
        engine.recordApproval(of: request(dataSource: "documents"), grant: .askOncePerSession)
        #expect(engine.evaluate(request(dataSource: "documents")) == .allow)
        #expect(engine.evaluate(request(dataSource: "meetings")) == .needsApproval(.askOncePerSession))
        engine.recordApproval(of: request(service: "email"), grant: .askOncePerSession)
        #expect(engine.evaluate(request(service: "email")) == .allow)
        #expect(engine.evaluate(request(service: "sms")) == .needsApproval(.askOncePerSession))
    }

    @Test func objectTypeNeverRuleBlocksOnlyThatType() {
        let engine = PermissionEngine(rules: [PolicyRule(objectType: "hypothesis", grant: .never)])
        if case .deny = engine.evaluate(request(types: ["investigation", "hypothesis"])) {} else { Issue.record("Expected deny") }
        #expect(engine.evaluate(request(types: ["sensor"])) == .needsApproval(.askOncePerProject))
    }

    @Test func scopedProjectApprovalsSurviveRestart() throws {
        let store = try NexusStore(.inMemory)
        let project = ObjectID.make()
        let first = try PermissionEngine(store: store)
        first.recordApproval(of: request(types: ["task"], dataSource: "tasks", project: project), grant: .askOncePerProject)
        let second = try PermissionEngine(store: store)
        #expect(second.evaluate(request(types: ["task"], dataSource: "tasks", project: project)) == .allow)
        #expect(second.evaluate(request(types: ["task"], project: project)) == .needsApproval(.askOncePerProject))
    }
}
