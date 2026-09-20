import SwiftUI

/// A catalyst calendar built entirely from data the app already fetches —
/// no separate earnings-calendar data source exists on the free tier, so
/// rather than bolting on a paid provider this combines two things already
/// computed: SEC filings that already happened (8-Ks, insider clusters) and
/// each swing candidate's projected next-filing window, extrapolated from
/// that company's own filing cadence (`SwingEngine.estimateDaysToNextFiling`).
/// The projection is explicitly labeled as an estimate, not a confirmed
/// earnings date — free EDGAR data has no forward-looking calendar field.
struct CalendarView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(SwingEngine.self) private var swingEngine
    @Environment(\.dismiss) private var dismiss

    private struct Projection: Identifiable {
        var id: String { symbol }
        let symbol: String
        let days: Int
    }

    private var projections: [Projection] {
        swingEngine.candidates
            .compactMap { candidate -> Projection? in
                guard let days = candidate.snapshot.estimatedDaysToNextFiling, days >= 0 else { return nil }
                return Projection(symbol: candidate.symbol, days: days)
            }
            .sorted { $0.days < $1.days }
    }

    var body: some View {
        NavigationStack {
            List {
                if projections.isEmpty && engine.recentFiled8Ks.isEmpty && engine.insiderClusterList.isEmpty {
                    ContentUnavailableView(
                        "No catalyst data yet",
                        systemImage: "calendar",
                        description: Text("Fills in as the swing watchlist and filing streams run.")
                    )
                }

                if !projections.isEmpty {
                    Section {
                        ForEach(projections.prefix(25)) { projection in
                            HStack {
                                Text(projection.symbol).font(.subheadline.monospaced().weight(.medium))
                                Spacer()
                                Text(projection.days == 0 ? "due" : "~\(projection.days)d")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(projection.days <= 7 ? .orange : .secondary)
                            }
                        }
                    } header: {
                        Text("Projected next filing")
                    } footer: {
                        Text("Extrapolated from each company's own filing cadence — the gap between its last several 10-Q/10-K filings — not a confirmed date. Free EDGAR data has no forward-looking earnings field.")
                    }
                }

                if !engine.insiderClusterList.isEmpty {
                    Section {
                        ForEach(engine.insiderClusterList) { cluster in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cluster.symbol).font(.subheadline.monospaced().weight(.medium))
                                    Text(cluster.companyName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(cluster.distinctFilers) filers")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Insider clusters")
                    }
                }

                if !engine.recentFiled8Ks.isEmpty {
                    Section {
                        ForEach(engine.recentFiled8Ks.prefix(30)) { filing in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(filing.symbol ?? filing.companyName)
                                        .font(.subheadline.monospaced().weight(.medium))
                                    Text(filing.companyName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(filing.filedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } header: {
                        Text("Recent 8-K filings")
                    } footer: {
                        Text("Primary-source, straight from EDGAR's own real-time filing feed — often seconds to minutes ahead of a headline republishing the same event.")
                    }
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
