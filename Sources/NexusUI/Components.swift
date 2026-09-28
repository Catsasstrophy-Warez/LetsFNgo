#if canImport(SwiftUI)
import NexusCore
import NexusInvestigation
import NexusModel
import SwiftUI

extension TruthClass {
    public var label: String {
        switch self {
        case .recorded: "Recorded"
        case .observed: "Observed"
        case .modeled: "Modeled"
        case .claimed: "Claimed"
        case .derived: "Derived"
        case .display: "Display"
        case .agentInterpretation: "AI interpretation"
        }
    }

    /// A distinct symbol per class, so truth is never encoded by color alone.
    public var symbol: String {
        switch self {
        case .recorded: "checkmark.seal"
        case .observed: "eye"
        case .modeled: "function"
        case .claimed: "quote.bubble"
        case .derived: "arrow.triangle.branch"
        case .display: "display"
        case .agentInterpretation: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .recorded, .observed: .green
        case .modeled: .blue
        case .claimed: .orange
        case .derived: .teal
        case .display: .gray
        case .agentInterpretation: .purple
        }
    }
}

/// Symbol + text + color for a truth class. Readable in grayscale and by VoiceOver.
public struct TruthBadge: View {
    let truth: TruthClass
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ truth: TruthClass) {
        self.truth = truth
    }

    public var body: some View {
        Label(truth.label, systemImage: truth.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(truth.tint)
            .background(truth.tint.opacity(contrast == .increased ? 0.25 : 0.12), in: Capsule())
            .overlay {
                // Increased contrast: an outline so the badge never relies on a tint.
                if contrast == .increased { Capsule().strokeBorder(truth.tint, lineWidth: 1) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Truth: \(truth.label)")
    }
}

public struct HypothesisStateBadge: View {
    let state: HypothesisState

    public init(_ state: HypothesisState) {
        self.state = state
    }

    public var body: some View {
        let (text, symbol, tint): (String, String, Color) = switch state {
        case .candidate: ("Candidate", "questionmark.circle", .blue)
        case .confirmed: ("Confirmed", "checkmark.circle.fill", .green)
        case .rejected: ("Rejected", "xmark.circle", .red)
        case .unknown: ("Unknown", "circle.dashed", .gray)
        }
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityLabel("Hypothesis \(text)")
    }
}

/// Empty states teach the next useful action instead of saying "nothing here".
public struct NextActionEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    public init(_ title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

func render(_ value: Value) -> String {
    switch value {
    case .string(let text): text
    case .int(let number): String(number)
    case .double(let number): number.formatted(.number.precision(.significantDigits(1...6)))
    case .bool(let flag): flag ? "Yes" : "No"
    case .date(let date): date.formatted(date: .abbreviated, time: .shortened)
    case .quantity(let quantity): "\(quantity.value.formatted(.number.precision(.significantDigits(1...6)))) \(quantity.unit)"
    case .reference(let id): id.description
    case .list(let values): values.map(render).joined(separator: ", ")
    case .map(let map): map.keys.sorted().map { "\($0): \(render(map[$0]!))" }.joined(separator: "; ")
    case .null: "—"
    }
}
#endif
