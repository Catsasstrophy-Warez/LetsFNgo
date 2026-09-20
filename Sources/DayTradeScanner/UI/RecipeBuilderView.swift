import SwiftUI

/// Builds a custom `ScanRecipe` out of the same gate fields the built-in
/// library uses, presented as tappable filter chips rather than a form of
/// text fields — a recipe is really a small set of on/off decisions
/// ("above VWAP or not", "which float band") plus a handful of thresholds,
/// and chips make the on/off ones a single tap instead of a picker.
struct RecipeBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    let store = CustomRecipeStore.shared
    /// Non-nil when editing an existing custom recipe rather than creating
    /// a new one.
    var existing: ScanRecipe?

    @State private var name: String = ""
    @State private var summary: String = ""
    @State private var baseProfile: ScanProfile = .dayTrade
    @State private var setup: SetupType = .unclassified

    @State private var priceBand: PriceBand = .any
    @State private var minRVOL: Double? = 2.0
    @State private var minChangePercent: Double? = 0.03
    @State private var floatBand: FloatBand = .any
    @State private var vwapRequirement: VWAPRequirement = .any
    @State private var requireNews = false
    @State private var alertThreshold: Double = 0.6

    enum PriceBand: String, CaseIterable, Identifiable {
        case any, penny, low, mid, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any price"
            case .penny: return "$0.50–5"
            case .low: return "$1–20"
            case .mid: return "$5–50"
            case .large: return "$20+"
            }
        }
        var range: (min: Double?, max: Double?) {
            switch self {
            case .any: return (nil, nil)
            case .penny: return (0.5, 5)
            case .low: return (1, 20)
            case .mid: return (5, 50)
            case .large: return (20, nil)
            }
        }
    }

    enum FloatBand: String, CaseIterable, Identifiable {
        case any, nano, micro, small
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any float"
            case .nano: return "Under 5M"
            case .micro: return "Under 20M"
            case .small: return "Under 80M"
            }
        }
        var maxShares: Double? {
            switch self {
            case .any: return nil
            case .nano: return 5_000_000
            case .micro: return 20_000_000
            case .small: return 80_000_000
            }
        }
    }

    enum VWAPRequirement: String, CaseIterable, Identifiable {
        case any, above, below
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Either side"
            case .above: return "Above VWAP"
            case .below: return "Below VWAP"
            }
        }
        var required: Bool? {
            switch self {
            case .any: return nil
            case .above: return true
            case .below: return false
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Recipe name", text: $name)
                    TextField("One-line summary", text: $summary)
                }

                Section("Base profile") {
                    chipRow(ScanProfile.allCases, selection: $baseProfile) { $0.displayName }
                }

                Section("Price") {
                    chipRow(PriceBand.allCases, selection: $priceBand) { $0.label }
                }

                Section("Volume & move") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Min relative volume: \(Fmt.multiple(minRVOL ?? 0))")
                            .font(.caption)
                        Slider(value: Binding(get: { minRVOL ?? 0 }, set: { minRVOL = $0 == 0 ? nil : $0 }), in: 0...10, step: 0.5)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Min move: \(String(format: "%.0f%%", (minChangePercent ?? 0) * 100))")
                            .font(.caption)
                        Slider(value: Binding(get: { minChangePercent ?? 0 }, set: { minChangePercent = $0 == 0 ? nil : $0 }), in: 0...0.30, step: 0.01)
                    }
                }

                Section("Float") {
                    chipRow(FloatBand.allCases, selection: $floatBand) { $0.label }
                }

                Section("VWAP") {
                    chipRow(VWAPRequirement.allCases, selection: $vwapRequirement) { $0.label }
                }

                Section("Catalyst") {
                    Toggle("Require fresh news", isOn: $requireNews)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alert threshold: \(Fmt.score(alertThreshold))")
                            .font(.caption)
                        Slider(value: $alertThreshold, in: 0.3...0.9, step: 0.02)
                    }
                } footer: {
                    Text("Minimum score for this recipe to fire an alert. Lower surfaces more candidates; higher shows only the strongest.")
                }
            }
            .navigationTitle(existing == nil ? "New recipe" : "Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { populate(from: existing) }
        }
    }

    private func chipRow<T: Hashable & Identifiable>(_ options: [T], selection: Binding<T>, label: @escaping (T) -> String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    let isSelected = option == selection.wrappedValue
                    Text(label(option))
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .onTapGesture { selection.wrappedValue = option }
                }
            }
        }
    }

    private func populate(from recipe: ScanRecipe?) {
        guard let recipe else { return }
        name = recipe.name
        summary = recipe.summary
        baseProfile = recipe.baseProfile
        setup = recipe.setup
        if let min = recipe.minPrice, let max = recipe.maxPrice {
            priceBand = PriceBand.allCases.first { $0.range.min == min && $0.range.max == max } ?? .any
        }
        minRVOL = recipe.minRVOL
        minChangePercent = recipe.minChangePercent
        if let maxFloat = recipe.maxFloatShares {
            floatBand = FloatBand.allCases.first { $0.maxShares == maxFloat } ?? .any
        }
        if let requireAboveVWAP = recipe.requireAboveVWAP {
            vwapRequirement = requireAboveVWAP ? .above : .below
        }
        requireNews = recipe.requireNews
        alertThreshold = recipe.alertThreshold ?? 0.6
    }

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let recipe = ScanRecipe(
            name: trimmedName,
            summary: summary.isEmpty ? "Custom recipe." : summary,
            baseProfile: baseProfile,
            setup: setup,
            minPrice: priceBand.range.min,
            maxPrice: priceBand.range.max,
            minRVOL: minRVOL,
            minChangePercent: minChangePercent,
            maxFloatShares: floatBand.maxShares,
            requireNews: requireNews,
            requireAboveVWAP: vwapRequirement.required,
            alertThreshold: alertThreshold
        )
        store.save(recipe)
        dismiss()
    }
}
