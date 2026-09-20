import SwiftUI

/// Sheet form for the position sizer. Opened with a suggested entry/stop
/// already filled in where the caller has one, but every field stays
/// editable — the suggestion is a starting point, not an answer.
struct PositionSizerView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State var entryPrice: Double
    @State var stopPrice: Double
    @State var direction: TradeDirection = .long

    @State private var allocation = 1.0
    @State private var slippage = 0.0
    @State private var fee = 0.0
    @State private var useTarget = false
    @State private var targetPrice = 0.0
    @State private var useBuyingPower = false
    @State private var buyingPower = 0.0

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Equity")
                        Spacer()
                        TextField("Equity", value: $settings.accountEquity, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Risk per trade")
                            Spacer()
                            Text(String(format: "%.2f%%", settings.defaultRiskPercent * 100))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.defaultRiskPercent, in: 0.0025...0.05)
                    }
                } header: { Text("Account") } footer: {
                    Text("Not connected to any broker — this is a number you maintain yourself, same as any journal's risk calculator.")
                }

                Section("Trade") {
                    Picker("Direction", selection: $direction) {
                        Text("Long").tag(TradeDirection.long)
                        Text("Short").tag(TradeDirection.short)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Entry")
                        Spacer()
                        TextField("Entry", value: $entryPrice, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Stop")
                        Spacer()
                        TextField("Stop", value: $stopPrice, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    LabeledContent("Maximum allocation", value: allocation.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $allocation, in: 0.01...1)
                    Toggle("Set available buying power", isOn: $useBuyingPower)
                    if useBuyingPower {
                        amountField("Buying power", value: $buyingPower)
                    }
                    amountField("Slippage per share", value: $slippage)
                    amountField("Round-trip fees", value: $fee)
                } header: { Text("Capital and execution") } footer: {
                    Text("Sizing respects both the risk budget and capital limit. Slippage is the combined entry and exit allowance per share; fees cover the whole trade. Actual fills can differ.")
                }
                Section("Target") {
                    Toggle("Evaluate a target price", isOn: $useTarget)
                    if useTarget { amountField("Target price", value: $targetPrice) }
                }

                if let result = PositionSizer.calculate(.init(
                    accountEquity: settings.accountEquity,
                    riskPercent: settings.defaultRiskPercent,
                    entryPrice: entryPrice,
                    stopPrice: stopPrice,
                    direction: direction,
                    buyingPower: useBuyingPower ? buyingPower : nil,
                    maxAllocationPercent: allocation,
                    slippagePerShare: slippage,
                    roundTripFee: fee,
                    targetPrice: useTarget ? targetPrice : nil
                )) {
                    Section("Result") {
                        MetricRow(label: "Shares", value: "\(result.shares)")
                        MetricRow(label: "Position value", value: "$\(Fmt.compactVolume(result.positionValue))")
                        MetricRow(
                            label: "% of account",
                            value: String(format: "%.0f%%", result.percentOfAccount * 100),
                            tint: result.percentOfAccount > 1.0 ? Palette.down : .primary
                        )
                        MetricRow(label: "Risk budget", value: "$\(Fmt.compactVolume(result.dollarRisk))")
                        MetricRow(label: "Risk per share", value: Fmt.price(result.riskPerShare))

                        MetricRow(label: "Estimated stop loss", value: Fmt.price(result.actualRisk))
                        MetricRow(label: "Unused risk budget", value: Fmt.price(result.unusedRisk))
                        MetricRow(label: "Capital limit", value: Fmt.price(result.capitalLimit))
                        if result.isCapitalLimited {
                            Text("Share count is capped by available capital.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let profit = result.targetProfit, let ratio = result.rewardRiskRatio {
                            MetricRow(label: "Net profit at target", value: Fmt.price(profit))
                            MetricRow(label: "Reward / risk", value: String(format: "%.2f R", ratio))
                        }
                        if result.isTargetOnWrongSide {
                            Text("Target must be above entry for a long, or below entry for a short.")
                                .font(.footnote).foregroundStyle(Palette.down)
                        }
                        if result.shares == 0 && !result.isStopOnWrongSide {
                            Text("The current risk or capital budget cannot fund one whole share.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if result.isStopOnWrongSide {
                            Label("Stop is on the wrong side of entry for a \(direction.label.lowercased())", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.down)
                                .font(.footnote)
                        } else if result.isStopTooTight {
                            Label("This stop is under 0.15% from entry — likely inside normal noise, not a real risk boundary", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        }
                        if result.percentOfAccount > 1.0 {
                            Label("This position would exceed total account equity", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.down)
                                .font(.footnote)
                        }
                    }
                } else {
                    Section("Check inputs") {
                        Text("Enter positive equity, entry and stop prices. Costs and buying power cannot be negative; an enabled target must be positive.")
                            .foregroundStyle(Palette.down)
                    }
                }
            }
            .navigationTitle("Position size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func amountField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .accessibilityIdentifier("sizer." + title)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
    }
}
