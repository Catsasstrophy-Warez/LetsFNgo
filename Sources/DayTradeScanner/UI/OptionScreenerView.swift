import SwiftUI

/// A thinkorswim "Option Hacker"-style scan across every chain currently
/// held, rather than browsing one underlying at a time — the missing link
/// between the equity recipe system and the options module, which have
/// otherwise stayed fully separate engines.
struct OptionScreenerView: View {
    @Environment(OptionsEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    private let store = OptionScreenFilterStore.shared

    @State private var filter = OptionScreenFilter.default
    @State private var showPresetSave = false
    @State private var newPresetName = ""

    private var matches: [OptionContract] {
        engine.chains.values
            .flatMap(\.contracts)
            .filter(filter.matches)
            .sorted { ($0.volume ?? 0) > ($1.volume ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filterControls
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Scans every contract across your options universe's currently-loaded chains — widen \"Load more expirations\" on a chain to include its later-dated contracts here too.")
                }

                Section {
                    ForEach(matches.prefix(50)) { contract in
                        ScreenerResultRow(contract: contract)
                    }
                    if matches.isEmpty {
                        Text("No contracts match this screen right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Results")
                        Spacer()
                        Text("\(matches.count)")
                    }
                }
            }
            .navigationTitle("Option screener")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Save current as preset") { newPresetName = ""; showPresetSave = true }
                        if !store.presets.isEmpty {
                            Section("Saved screens") {
                                ForEach(store.presets) { preset in
                                    Button(preset.name) { filter = preset }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .alert("Save screen", isPresented: $showPresetSave) {
                TextField("Screen name", text: $newPresetName)
                Button("Save") {
                    let trimmed = newPresetName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    var toSave = filter
                    toSave.name = trimmed
                    store.save(toSave)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sideChips

            VStack(alignment: .leading, spacing: 4) {
                Text("Days to expiration: \(filter.minDaysToExpiration ?? 0)–\(filter.maxDaysToExpiration ?? 90)")
                    .font(.caption)
                RangeSliderPair(
                    lower: Binding(get: { Double(filter.minDaysToExpiration ?? 0) }, set: { filter.minDaysToExpiration = Int($0) }),
                    upper: Binding(get: { Double(filter.maxDaysToExpiration ?? 90) }, set: { filter.maxDaysToExpiration = Int($0) }),
                    range: 0...365
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Delta (absolute): \(String(format: "%.2f", filter.minDelta ?? 0))–\(String(format: "%.2f", filter.maxDelta ?? 1))")
                    .font(.caption)
                RangeSliderPair(
                    lower: Binding(get: { filter.minDelta ?? 0 }, set: { filter.minDelta = $0 }),
                    upper: Binding(get: { filter.maxDelta ?? 1 }, set: { filter.maxDelta = $0 }),
                    range: 0...1
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Min volume: \(filter.minVolume ?? 0)")
                    .font(.caption)
                Slider(value: Binding(get: { Double(filter.minVolume ?? 0) }, set: { filter.minVolume = Int($0) == 0 ? nil : Int($0) }), in: 0...2000, step: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Min open interest: \(filter.minOpenInterest ?? 0)")
                    .font(.caption)
                Slider(value: Binding(get: { Double(filter.minOpenInterest ?? 0) }, set: { filter.minOpenInterest = Int($0) == 0 ? nil : Int($0) }), in: 0...5000, step: 100)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Max spread: \(String(format: "%.0f%%", (filter.maxSpreadPercent ?? 1) * 100))")
                    .font(.caption)
                Slider(value: Binding(get: { filter.maxSpreadPercent ?? 1 }, set: { filter.maxSpreadPercent = $0 == 1 ? nil : $0 }), in: 0.02...1, step: 0.02)
            }
        }
    }

    private var sideChips: some View {
        HStack(spacing: 8) {
            ForEach(OptionScreenFilter.Side.allCases, id: \.self) { side in
                let isSelected = filter.side == side
                Text(side.label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .onTapGesture { filter.side = side }
            }
        }
    }
}

/// Two sliders sharing one track's worth of vertical space, for a simple
/// min/max band — plain SwiftUI `Slider`s stacked rather than a custom
/// dual-thumb control, which SwiftUI has no built-in primitive for.
private struct RangeSliderPair: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: $lower, in: range)
            Slider(value: $upper, in: range)
        }
    }
}

private struct ScreenerResultRow: View {
    let contract: OptionContract

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(contract.underlying).font(.subheadline.monospaced().weight(.medium))
                    Text(contract.type == .call ? "C" : "P")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(contract.type == .call ? Palette.up : Palette.down)
                    Text(Fmt.price(contract.strike)).font(.caption.monospacedDigit())
                }
                HStack(spacing: 8) {
                    Text("\(contract.daysToExpiration)d").font(.caption2).foregroundStyle(.secondary)
                    if let delta = contract.greeks?.delta {
                        Text("Δ \(String(format: "%.2f", delta))").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let iv = contract.impliedVolatility {
                        Text("IV \(String(format: "%.0f%%", iv * 100))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let mid = contract.mid {
                    Text(Fmt.price(mid)).font(.subheadline.monospacedDigit())
                }
                Text("vol \(contract.volume ?? 0) · OI \(contract.openInterest ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
