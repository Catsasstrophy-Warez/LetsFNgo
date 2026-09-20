import SwiftUI

struct PaperLogView: View {
    @Environment(PaperTradeLog.self) private var log
    @Environment(Settings.self) private var settings
    @State private var showDeleteConfirm = false
    @State private var filter: Filter = .all
    @State private var horizonFilter: TradeHorizon?
    @State private var export: ExportedFile?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case open = "Open"
        case wins = "Up"
        case losses = "Down"
        var id: String { rawValue }
    }

    private var horizonScoped: [PaperTrade] {
        guard let horizonFilter else { return log.trades }
        return log.trades(for: horizonFilter)
    }

    private var filtered: [PaperTrade] {
        switch filter {
        case .all: return horizonScoped
        case .open: return horizonScoped.filter { $0.status == .open }
        case .wins: return horizonScoped.filter { ($0.bestAvailableReturn ?? 0) > 0 }
        case .losses: return horizonScoped.filter { ($0.bestAvailableReturn ?? 0) < 0 }
        }
    }

    /// Exports whatever the current filter/horizon selection is showing,
    /// not always the full journal — a CSV of "just my losses this week" is
    /// as legitimate an export as the whole history.
    private func makeExportURL() -> URL? {
        CSVExporter.writeTempFile(CSVExporter.export(filtered), named: "paper-trading-journal")
    }

    var body: some View {
        NavigationStack {
            Group {
                if log.trades.isEmpty {
                    EmptyStateView(
                        title: "No paper trades yet",
                        message: "Every alert gets recorded here with the exact signal values that triggered it, then marked at 15, 30 and 60 minutes. That record is what turns guesswork into tuning.",
                        systemImage: "list.bullet.rectangle"
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Paper log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ModeToggle() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        LazyExportButton(title: "Export CSV", export: $export, makeURL: makeExportURL)
                        Button("Clear all", role: .destructive) { showDeleteConfirm = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Journal options")
                }
            }
            .confirmationDialog("Delete every paper trade?", isPresented: $showDeleteConfirm) {
                Button("Delete all", role: .destructive) { log.deleteAll() }
            }
            .sheet(item: $export) { file in ActivityView(url: file.url) }
        }
    }

    private var horizonFilterBar: some View {
        Picker("Horizon", selection: $horizonFilter) {
            Text("All").tag(TradeHorizon?.none)
            ForEach(TradeHorizon.allCases) { horizon in
                Text(horizon.displayName).tag(TradeHorizon?.some(horizon))
            }
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private var list: some View {
        List {
            Section { horizonFilterBar }
            summarySection

            setupSection
            AdvancedOnly { floatSection }
            AdvancedOnly { scoreBandSection }
            AdvancedOnly { timeOfDaySection }

            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                ForEach(filtered) { trade in
                    TradeRow(trade: trade)
                        .swipeActions {
                            Button("Delete", role: .destructive) { log.delete(trade) }
                        }
                }
            }
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            let summary = log.summary
            MetricRow(label: "Alerts logged", value: "\(summary.total)")
            MetricRow(label: "Resolved", value: "\(summary.resolved)")
            if summary.resolved > 0 {
                MetricRow(
                    label: "Went the right way",
                    value: "\(Int(summary.winRate * 100))%",
                    tint: Palette.direction(summary.winRate - 0.5)
                )
                MetricRow(
                    label: "Average outcome",
                    value: Fmt.percent(summary.averageReturn),
                    tint: Palette.direction(summary.averageReturn)
                )
                if let efficiency = summary.averageExitEfficiency {
                    MetricRow(
                        label: "Exit efficiency",
                        value: String(format: "%.0f%% of best move captured", efficiency * 100),
                        tint: efficiency < 0.4 ? .orange : .primary
                    )
                }
                AdvancedOnly {
                    MetricRow(label: "Median outcome", value: Fmt.percent(summary.medianReturn))
                    MetricRow(label: "Average best excursion", value: Fmt.percent(summary.averageMFE), tint: Palette.up)
                    MetricRow(label: "Average worst excursion", value: Fmt.percent(summary.averageMAE), tint: Palette.down)
                }
            }
        }
    }

    /// Outcome by setup. More directly actionable than the component
    /// breakdown — it says which strategies to keep running.
    private var setupSection: some View {
        let rows = log.performanceBySetup().filter { $0.count >= 2 }
        return Group {
            if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.setup) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.setup.displayName)
                                    .font(.subheadline)
                                Spacer()
                                Text(Fmt.percent(row.averageReturn))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(Palette.direction(row.averageReturn))
                            }
                            Text("\(row.count) trades · \(Int(row.winRate * 100))% up · best excursion \(Fmt.percent(row.averageMFE))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                } header: {
                    Text("Outcome by setup")
                } footer: {
                    Text("Which setups are actually paying. Needs at least a couple of resolved trades per row before it means anything.")
                }
            }
        }
    }

    /// Whether tight floats are paying for the halt risk they carry.
    private var floatSection: some View {
        let rows = log.performanceByFloat()
        return Group {
            if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.category) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.category.displayName)
                                    .font(.subheadline)
                                Text(row.category.shortLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(Fmt.percent(row.averageReturn))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(Palette.direction(row.averageReturn))
                            }
                            HStack(spacing: 8) {
                                Text("\(row.count) trades")
                                if row.haltRate > 0 {
                                    Text("· halted mid-trade \(Int(row.haltRate * 100))%")
                                        .foregroundStyle(Palette.down)
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }

                    if log.haltExposureRate > 0.05 {
                        Text("\(Int(log.haltExposureRate * 100))% of resolved trades were halted while open. A modelled exit isn't available during a halt, so these outcomes are more optimistic than reality.")
                            .font(.caption)
                            .foregroundStyle(Palette.down)
                    }
                } header: {
                    Text("Outcome by float")
                }
            }
        }
    }

    private var scoreBandSection: some View {
        let bands = log.performanceByScoreBand()
        return Group {
            if !bands.isEmpty {
                Section {
                    ForEach(bands, id: \.band) { row in
                        HStack {
                            Text(row.band)
                                .font(.footnote.monospacedDigit())
                                .frame(width: 62, alignment: .leading)
                            ScoreBar(score: min(max(row.averageReturn * 20 + 0.5, 0), 1), height: 5)
                            Text(Fmt.percent(row.averageReturn))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.direction(row.averageReturn))
                                .frame(width: 60, alignment: .trailing)
                            Text("n=\(row.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("Outcome by score band")
                } footer: {
                    Text("Higher bands should produce better average outcomes. If they don't, the weights are ranking noise.")
                }
            }
        }
    }

    private var timeOfDaySection: some View {
        let buckets = log.performanceByTimeOfDay()
        return Group {
            if !buckets.isEmpty {
                Section {
                    ForEach(buckets, id: \.bucket) { row in
                        HStack {
                            Text(row.bucket)
                                .font(.footnote.monospacedDigit())
                                .frame(width: 52, alignment: .leading)
                            Spacer()
                            Text(Fmt.percent(row.averageReturn))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.direction(row.averageReturn))
                            Text("n=\(row.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("Outcome by time of day")
                } footer: {
                    Text("Times are Eastern, bucketed by half hour from the open.")
                }
            }
        }
    }
}

struct TradeRow: View {
    @Environment(Settings.self) private var settings
    let trade: PaperTrade

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(trade.symbol)
                    .font(.subheadline.monospaced().weight(.medium))

                Text(trade.direction.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))

                if trade.horizon != .dayTrade {
                    Text(trade.horizon.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }

                if trade.status == .open {
                    Text("open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if trade.haltedDuringTrade {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.down)
                }

                Spacer()

                if let outcome = trade.bestAvailableReturn {
                    Text(Fmt.percent(outcome))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(Palette.direction(outcome))
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(trade.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 10) {
                Text(trade.setup.displayName)
                Text(MarketClock.timeLabel(trade.openedAt) + " ET")
                Text("@ \(Fmt.price(trade.entryPrice))")
                Text("score \(Fmt.score(trade.score))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

            AdvancedOnly {
                let labels = trade.markLabels
                HStack(spacing: 12) {
                    horizon(labels.0, trade.return15m)
                    horizon(labels.1, trade.return30m)
                    horizon(labels.2, trade.return60m)
                    horizon("final", trade.closeReturn)
                    Spacer()
                    Text("MFE \(Fmt.percent(trade.maxFavorable))")
                        .foregroundStyle(Palette.up)
                    Text("MAE \(Fmt.percent(trade.maxAdverse))")
                        .foregroundStyle(Palette.down)
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .padding(.vertical, 3)
    }

    private func horizon(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.tertiary)
            if let value {
                Text(Fmt.percent(value)).foregroundStyle(Palette.direction(value))
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}
