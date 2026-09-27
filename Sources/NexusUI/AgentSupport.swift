#if canImport(SwiftUI)
import NexusAgents
import NexusPermissions
import Observation
import SwiftUI

extension AgentProfile {
    /// The default assistant for engineering work: reads the world model,
    /// proposes hypotheses, may annotate (asks once per project) and may send
    /// messages (asks every time).
    public static let diagnostician = AgentProfile(
        id: "diagnostic",
        instructions: """
            You help a technician diagnose equipment. Use the tools to read the \
            world model; never state a value you did not read from a tool. \
            Propose hypotheses with testable predictions rather than conclusions.
            """,
        tools: ["search_objects", "get_object", "related_objects", "get_measurements", "propose_hypothesis", "annotate_object", "send_message"]
    )
}

@MainActor
enum AgentRequestFactory {
    static func request(goal: String, env: NexusEnvironment) -> AgentRequest {
        AgentRequest(goal: goal, project: env.context.activeProject ?? env.demo?.project, focus: env.context.selection)
    }
}

/// Holds the approval a running agent is waiting for, so the UI can ask.
@MainActor
@Observable
final class ApprovalCenter {
    static let shared = ApprovalCenter()

    struct Pending: Identifiable {
        let id = UUID()
        let reason: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    var pending: Pending?

    func ask(_ reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            if let previous = pending {
                previous.continuation.resume(returning: false)
            }
            pending = Pending(reason: reason, continuation: continuation)
        }
    }

    func answer(_ approved: Bool) {
        pending?.continuation.resume(returning: approved)
        pending = nil
    }
}

/// Bridges the agent runtime's approval requests to an in-app alert.
struct AlertApprover: ApprovalHandler {
    static let shared = AlertApprover()

    func approve(_ request: PermissionRequest, reason: String) async -> Bool {
        await ApprovalCenter.shared.ask(reason)
    }
}

struct ApprovalAlerts: ViewModifier {
    @State private var center = ApprovalCenter.shared

    func body(content: Content) -> some View {
        content.alert(
            "Allow this action?",
            isPresented: Binding(get: { center.pending != nil }, set: { if !$0 { center.answer(false) } }),
            presenting: center.pending
        ) { _ in
            Button("Allow") { center.answer(true) }
            Button("Decline", role: .cancel) { center.answer(false) }
        } message: { pending in
            Text(pending.reason)
        }
    }
}

extension View {
    /// Shows agent permission requests as alerts.
    public func approvalAlerts() -> some View {
        modifier(ApprovalAlerts())
    }
}
#endif
