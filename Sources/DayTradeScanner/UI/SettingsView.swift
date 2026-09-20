import SwiftUI

struct SettingsView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(SwingEngine.self) private var swingEngine
    @Environment(LongTermEngine.self) private var longTermEngine
    @Environment(Settings.self) private var settings

    @State private var universeText = ""
    @State private var swingUniverseText = ""
    @State private var longTermUniverseText = ""
    @State private var showSecret = false
    @State private var showRebuildConfirm = false
    @State private var accountVerification: AccountVerificationState = .unverified

    enum AccountVerificationState {
        case unverified
        case verifying
        case verified(AlpacaREST.AccountSummary)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                credentialsSection
                themeSection
                universeSection
                swingUniverseSection
                longTermUniverseSection
                behaviourSection
                alertTypesSection
                squawkSection
                positionSizingSection
                secFloatSection
                baselineSection
                AdvancedOnly { diagnosticsSection }
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { ModeToggle() } }
            .onAppear {
                universeText = settings.universe.joined(separator: ", ")
                swingUniverseText = settings.swingUniverse.joined(separator: ", ")
                longTermUniverseText = settings.longTermUniverse.joined(separator: ", ")
            }
            .confirmationDialog(
                "Rebuild volume baselines?",
                isPresented: $showRebuildConfirm,
                titleVisibility: .visible
            ) {
                Button("Rebuild", role: .destructive) {
                    Task {
                        await engine.clearBaselines()
                        await engine.restart()
                    }
                }
            } message: {
                Text("This refetches 20 sessions of minute bars for every symbol. It takes a few minutes.")
            }
        }
    }

    // MARK: - Sections

    private var themeSection: some View {
        @Bindable var settings = settings
        return Section("Visual theme") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text("\(theme.name) · \(theme.era)").tag(theme)
                }
            }
            Text("Twenty retro trading-desk palettes spanning the 80s, 90s, and early 2000s. The selected accent applies to navigation and live signal emphasis.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialsSection: some View {
        @Bindable var settings = settings

        return Section {
            if settings.credentialsAppearInvalid {
                Label("Alpaca rejected these keys on the last request (401). Double-check them below, then Reconnect.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.down)
            }

            TextField("Key ID", text: $settings.alpacaKeyID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))

            HStack {
                if showSecret {
                    TextField("Secret key", text: $settings.alpacaSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("Secret key", text: $settings.alpacaSecret)
                        .font(.system(.body, design: .monospaced))
                }
                Button {
                    showSecret.toggle()
                } label: {
                    Image(systemName: showSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showSecret ? "Hide secret key" : "Show secret key")
            }

            if settings.hasCredentials {
                Button("Reconnect") { Task { await engine.restart() } }

                Button {
                    Task { await verifyAccount() }
                } label: {
                    if case .verifying = accountVerification {
                        HStack { ProgressView(); Text("Verifying…") }
                    } else {
                        Text("Verify paper account")
                    }
                }
                .disabled({ if case .verifying = accountVerification { return true }; return false }())

                switch accountVerification {
                case .unverified, .verifying:
                    EmptyView()
                case .verified(let summary):
                    Label("Confirmed paper account #\(summary.accountNumber) — no real money at risk", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.up)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.down)
                }
            }
        } header: {
            Text("Alpaca")
        } footer: {
            Text("Keys are stored in the iOS keychain, never in preferences. This app only ever calls Alpaca's paper-trading endpoint — there is no order-submission code path anywhere in it, on any host. A free paper account works. Generate keys at alpaca.markets under Paper Trading, then tap \"Verify paper account\" to confirm the keys are valid before scanning starts.")
        }
    }

    private func verifyAccount() async {
        accountVerification = .verifying
        do {
            let summary = try await engine.verifyPaperAccount()
            accountVerification = .verified(summary)
        } catch {
            accountVerification = .failed("Could not verify: \(error.localizedDescription). If these are live-trading keys rather than paper keys, they will never authenticate here — paper and live keys are separate credential pairs.")
        }
    }

    private var universeSection: some View {
        Section {
            TextEditor(text: $universeText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 110)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            HStack {
                Text("\(settings.universe.count) symbols")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { applyUniverse() }
                    .disabled(parsedUniverse == settings.universe)
            }

            Button("Restore starter list") {
                universeText = Settings.starterUniverse.joined(separator: ", ")
            }
            .font(.footnote)
        } header: {
            Text("Universe")
        } footer: {
            Text("Comma or space separated. Minute-bar channels are uncapped on the free plan, so the practical ceiling is your phone rather than Alpaca — a few hundred liquid symbols runs comfortably. Thin names produce too few IEX prints to score reliably.")
        }
    }

    private var swingUniverseSection: some View {
        Section {
            TextEditor(text: $swingUniverseText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 70)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            HStack {
                Text("\(settings.swingUniverse.count) symbols")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { applySwingUniverse() }
                    .disabled(parsedSwingUniverse == settings.swingUniverse)
            }
        } header: {
            Text("Swing watchlist")
        } footer: {
            Text("Refreshed every 15 minutes from daily bars. A few dozen liquid names with clean technical structure works better here than the hundreds the day-trade universe carries.")
        }
    }

    private var longTermUniverseSection: some View {
        Section {
            TextEditor(text: $longTermUniverseText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 60)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            HStack {
                Text("\(settings.longTermUniverse.count) symbols")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { applyLongTermUniverse() }
                    .disabled(parsedLongTermUniverse == settings.longTermUniverse)
            }
        } header: {
            Text("Long-term watchlist")
        } footer: {
            Text("Keep this short. Fundamentals scoring across hundreds of tickers produces hundreds of shallow opinions — a good long-term list is usually a dozen or two companies actually worth understanding.")
        }
    }

    private var positionSizingSection: some View {
        @Bindable var settings = settings

        return Section {
            HStack {
                Text("Account equity")
                Spacer()
                TextField("Equity", value: $settings.accountEquity, format: .currency(code: "USD"))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Default risk per trade")
                    Spacer()
                    Text(String(format: "%.2f%%", settings.defaultRiskPercent * 100))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.defaultRiskPercent, in: 0.0025...0.05)
            }
        } header: {
            Text("Position sizing")
        } footer: {
            Text("Used by the position size calculator on any candidate. Not connected to a broker — you keep this number current yourself.")
        }
    }

    private var behaviourSection: some View {
        @Bindable var settings = settings

        return Section {
            Toggle("Alert notifications", isOn: $settings.notificationsEnabled)
            Toggle("Log every alert as a paper trade", isOn: $settings.autoPaperTradeOnAlert)
            Toggle("Include pre-market in VWAP", isOn: $settings.includePremarketInVWAP)
            Toggle("Halt and resume notifications", isOn: $settings.haltNotifications)
            Toggle("Auto-watch symbols that halt", isOn: $settings.autoAdoptHaltedSymbols)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("Pre-market bars are thin and erratic. Leaving them out anchors VWAP to the same open everyone else is watching. Halt notifications bypass the alert budget — a halt on something you may be holding isn't an opportunity to be rationed.")
        }
    }

    private var alertTypesSection: some View {
        Section {
            NavigationLink("Alert types") { SignalAlertTypesView() }
        } footer: {
            Text("Subscribe or mute individual signal types — a muted signal still ranks and shows in the scan list, it just won't be the reason an alert notifies you.")
        }
    }

    private var squawkSection: some View {
        @Bindable var settings = settings

        return Section {
            Toggle("Audio squawk box", isOn: $settings.audioSquawkEnabled)
            if settings.audioSquawkEnabled {
                Toggle("Speak halts and resumes", isOn: $settings.squawkHalts)
                Toggle("Speak new filings", isOn: $settings.squawkFilings)
                Toggle("Speak top-ranked setups", isOn: $settings.squawkTopSetups)
                Toggle("Speak strategy bot alerts", isOn: $settings.squawkStrategyBot)
            }
        } header: {
            Text("Audio squawk")
        } footer: {
            Text("Reads alerts aloud, trading-desk squawk-box style, so you don't have to keep eyes on the screen. Top-setup squawking is off by default since it fires far more often than halts or filings.")
        }
    }

    /// SEC float. The EDGAR data APIs need no key, but they do require a
    /// User-Agent naming the app and a contact address.
    private var secFloatSection: some View {
        @Bindable var settings = settings

        return Section {
            TextField("Contact email for SEC requests", text: $settings.secContactEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .font(.system(.body, design: .monospaced))

            if engine.isRefreshingFloat {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: engine.floatProgress)
                    Text(engine.floatMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Refresh float from SEC") {
                    Task { await engine.refreshFloat(force: true) }
                }
                .disabled(settings.secContactEmail.isEmpty)
            }

            MetricRow(label: "Trending symbols tracked", value: "\(engine.trendingSocial.count)")
            MetricRow(label: "Insider clusters today", value: "\(engine.insiderClusterList.count)")
            if let refreshed = engine.socialLastRefreshed {
                MetricRow(label: "Social last refreshed", value: refreshed.formatted(date: .omitted, time: .standard))
            }
            MetricRow(label: "Symbols with float", value: "\(engine.floatRecordCount)")
            if let refreshed = engine.floatLastRefreshed {
                MetricRow(
                    label: "Last refreshed",
                    value: refreshed.formatted(date: .abbreviated, time: .shortened)
                )
            }
        } header: {
            Text("Float, social & filings")
        } footer: {
            Text("Float is pulled free from SEC EDGAR's XBRL API, refreshed weekly. Trending symbols and sentiment come from StockTwits' public endpoints, refreshed every 90 seconds. Insider clusters and live 8-Ks come from EDGAR's own current-filings feed, polled every 45 seconds — all three sources are free and require no key beyond the contact email above.")
        }
    }

    private var baselineSection: some View {
        @Bindable var settings = settings

        return Section {
            Stepper(
                "Baseline window: \(settings.baselineSessions) sessions",
                value: $settings.baselineSessions,
                in: 5...60,
                step: 5
            )
            MetricRow(
                label: "Coverage",
                value: "\(Int(engine.diagnostics.baselineCoverage * 100))% of universe"
            )
            Button("Rebuild baselines") { showRebuildConfirm = true }
        } header: {
            Text("Volume baselines")
        } footer: {
            Text("The median volume curve each symbol's live volume is compared against. Longer windows are steadier but slower to reflect a changed liquidity profile.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            let diagnostics = engine.diagnostics
            HStack {
                Text("Bar stream")
                Spacer()
                StatusDot(status: diagnostics.barStreamStatus)
                Text(diagnostics.barStreamStatus.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("News stream")
                Spacer()
                StatusDot(status: diagnostics.newsStreamStatus)
                Text(diagnostics.newsStreamStatus.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            MetricRow(label: "Subscribed symbols", value: "\(diagnostics.subscribedSymbols)")
            MetricRow(label: "Bars received", value: "\(diagnostics.barsReceived)")
            MetricRow(label: "Bars per minute", value: String(format: "%.0f", diagnostics.barsPerMinute))
            MetricRow(label: "Dropped bars", value: "\(diagnostics.droppedBars)")
            MetricRow(label: "Symbols with baseline", value: "\(diagnostics.symbolsWithBaseline)")
            MetricRow(label: "Last scoring pass", value: String(format: "%.0f ms", diagnostics.scoringDurationMs))
            if let date = diagnostics.shortVolumeFileDate {
                MetricRow(label: "Short volume file", value: date.formatted(date: .abbreviated, time: .omitted))
            }
            if let error = diagnostics.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.down)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("A 406 error on the bar stream usually means another session is already connected — the free plan allows one concurrent connection per feed.")
        }
    }

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("What this app is not")
                    .font(.subheadline.weight(.medium))
                Text("It ranks and records; it does not advise. Nothing here is a recommendation to buy or sell, and no order is ever placed. Scores are a summary of conditions, not a prediction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Data limits worth remembering")
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
                Text("Volume comes from IEX only, a fraction of consolidated volume — ratios are meaningful, absolute figures are not. Float is quarterly and misses post-filing dilution. FINRA short volume is off-exchange flow from the previous session, not short interest. Scanning stops when the app leaves the foreground.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Helpers

    private var parsedUniverse: [String] {
        Self.parseSymbols(universeText)
    }

    private func applyUniverse() {
        let symbols = parsedUniverse
        guard !symbols.isEmpty else { return }
        settings.universe = symbols
        universeText = symbols.joined(separator: ", ")
        Task { await engine.updateUniverse(symbols) }
    }

    private var parsedSwingUniverse: [String] { Self.parseSymbols(swingUniverseText) }
    private func applySwingUniverse() {
        let symbols = parsedSwingUniverse
        guard !symbols.isEmpty else { return }
        settings.swingUniverse = symbols
        swingUniverseText = symbols.joined(separator: ", ")
        Task { await swingEngine.refresh() }
    }

    private var parsedLongTermUniverse: [String] { Self.parseSymbols(longTermUniverseText) }
    private func applyLongTermUniverse() {
        let symbols = parsedLongTermUniverse
        guard !symbols.isEmpty else { return }
        settings.longTermUniverse = symbols
        longTermUniverseText = symbols.joined(separator: ", ")
        Task { await longTermEngine.refresh() }
    }

    private static func parseSymbols(_ text: String) -> [String] {
        text
            .split(whereSeparator: { ", \n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && $0.count <= 6 }
            .reduce(into: [String]()) { result, symbol in
                if !result.contains(symbol) { result.append(symbol) }
            }
    }
}
