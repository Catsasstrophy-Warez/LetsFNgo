import SwiftUI
import UniformTypeIdentifiers

struct HaltsView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @State private var showGlossary = false

    var body: some View {
        NavigationStack {
            Group {
                if settings.tradeHorizon != .dayTrade {
                    EmptyStateView(
                        title: "Halts are a day-trade concern",
                        message: "A trading pause matters when you're holding a position that has to be flat by the close. Swing and long-term positions ride through them without the same urgency.",
                        systemImage: "pause.circle"
                    )
                } else {
                    List {
                        intensitySection
                        resumeSection
                        activeSection
                        todaySection
                        AdvancedOnly { glossarySection }
                    }
                    .refreshable { await engine.refreshHalts() }
                }
            }
            .navigationTitle("Halts")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { HorizonPicker() }
            .toolbar {
                ToolbarItem(placement: .principal) { ModeToggle() }
                if settings.tradeHorizon == .dayTrade {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await engine.refreshHalts() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh halts")
                    }
                }
            }
            .task {
                if settings.tradeHorizon == .dayTrade { await engine.refreshHalts() }
            }
        }
    }

    // MARK: - Sections

    private var intensitySection: some View {
        Section {
            HStack {
                Text("Halts today")
                Spacer()
                Text("\(engine.haltEvents.filter { MarketClock.isSameTradingDay($0.haltedAt, Date()) }.count)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            if engine.haltIntensity > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Versus a typical session")
                        Spacer()
                        Text(Fmt.multiple(engine.haltIntensity))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(engine.haltIntensity > 1.5 ? Palette.down : .secondary)
                    }
                    ScoreBar(score: min(engine.haltIntensity / 3, 1), height: 4)
                }
            }
        } footer: {
            Text("Halt count against the pace of an ordinary day. A reading well above 1 means the whole session is volatile, which is worth knowing before sizing anything.")
        }
    }

    /// The opportunity side. Only tradeable codes appear here — a T12 or an SEC
    /// suspension is not a "halt and go", it's a symbol you cannot get out of.
    private var resumeSection: some View {
        Group {
            if !engine.freshResumes.isEmpty {
                Section {
                    ForEach(engine.freshResumes) { event in
                        HaltRow(event: event, highlight: true)
                    }
                } header: {
                    Label("Just resumed", systemImage: "play.circle")
                } footer: {
                    Text("Reopening from a volatility pause, within the last ten minutes. Direction into the pause tells you whether it spiked or collapsed — check it before considering the reopen.")
                }
            }
        }
    }

    private var activeSection: some View {
        let active = engine.haltEvents.filter { !$0.isResumed }
        return Group {
            if active.isEmpty {
                Section {
                    Text("Nothing halted right now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(active) { event in
                        HaltRow(event: event, highlight: false)
                    }
                } header: {
                    Label("Currently halted", systemImage: "pause.circle")
                } footer: {
                    Text("No order executes on any US exchange while a symbol is halted. These are gated out of the scan list unless the halt-resume profile is active.")
                }
            }
        }
    }

    private var todaySection: some View {
        let resumed = engine.haltEvents
            .filter { $0.isResumed && MarketClock.isSameTradingDay($0.haltedAt, Date()) }
        return Group {
            if !resumed.isEmpty {
                Section("Earlier today") {
                    ForEach(resumed.prefix(30)) { event in
                        HaltRow(event: event, highlight: false)
                    }
                }
            }
        }
    }

    private var glossarySection: some View {
        Section {
            DisclosureGroup("Halt code glossary", isExpanded: $showGlossary) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(HaltMonitor.HaltCode.allCases.sorted { $0.severity < $1.severity }, id: \.self) { code in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(code.rawValue)
                                    .font(.caption.monospaced().weight(.medium))
                                Text(code.displayName)
                                    .font(.caption)
                                Spacer()
                                if code.isTradeableResume {
                                    Text("reopen playable")
                                        .font(.caption2)
                                        .foregroundStyle(Palette.up)
                                }
                            }
                            Text(code.explanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .font(.subheadline)
        }
    }
}

struct HaltRow: View {
    @Environment(Settings.self) private var settings
    let event: HaltMonitor.HaltEvent
    let highlight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(event.symbol)
                    .font(.subheadline.monospaced().weight(.medium))

                Text(event.code.rawValue)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(severityColor.opacity(0.18)))
                    .foregroundStyle(severityColor)

                if let percent = event.percentIntoHalt {
                    Text(percent > 0 ? "spiked \(Fmt.percent(percent))" : "dropped \(Fmt.percent(percent))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Palette.direction(percent))
                }

                Spacer()

                if event.isResumed {
                    Text("resumed")
                        .font(.caption2)
                        .foregroundStyle(highlight ? Palette.up : .secondary)
                } else {
                    Text("\(event.minutesHalted)m")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(event.code.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            AdvancedOnly {
                HStack(spacing: 10) {
                    Text("halted \(MarketClock.timeLabel(event.haltedAt))")
                    if let resume = event.resumeTradeAt {
                        Text("· trade \(MarketClock.timeLabel(resume))")
                    }
                    if let expected = event.code.expectedDurationMinutes {
                        Text("· typical \(expected)m")
                    } else {
                        Text("· no fixed duration")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var severityColor: Color {
        switch event.code.severity {
        case 1: return .orange
        case 2, 3: return Palette.down
        default: return Palette.down
        }
    }
}

// MARK: - Recipe picker

/// The named-scan library.
struct RecipePicker: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    private let customStore = CustomRecipeStore.shared

    @State private var showBuilder = false
    @State private var editingRecipe: ScanRecipe?
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        engine.applyRecipe(nil)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No recipe")
                                    .font(.subheadline.weight(.medium))
                                Text("Plain \(settings.activeProfile.displayName.lowercased()) scan with your own weights.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.activeRecipeName == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if !bestPerforming.isEmpty {
                    Section {
                        ForEach(bestPerforming, id: \.name) { recipe in
                            Button {
                                engine.applyRecipe(recipe)
                                dismiss()
                            } label: {
                                RecipeRow(recipe: recipe, isSelected: settings.activeRecipeName == recipe.name)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Best performing")
                    } footer: {
                        Text("Recipes with at least 5 resolved paper trades, ranked by the same nightly self-reweighting fitness that adjusts each recipe's alert threshold.")
                    }
                }

                if !customStore.recipes.isEmpty {
                    Section("Your recipes") {
                        ForEach(customStore.recipes) { recipe in
                            HStack {
                                Button {
                                    engine.applyRecipe(recipe)
                                    dismiss()
                                } label: {
                                    RecipeRow(recipe: recipe, isSelected: settings.activeRecipeName == recipe.name)
                                }
                                .buttonStyle(.plain)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    customStore.delete(named: recipe.name)
                                    if settings.activeRecipeName == recipe.name { engine.applyRecipe(nil) }
                                } label: { Label("Delete", systemImage: "trash") }
                                Button {
                                    editingRecipe = recipe
                                } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.blue)
                            }
                            .contextMenu {
                                if let url = exportURL(for: recipe) {
                                    ShareLink(item: url) { Label("Export as JSON", systemImage: "square.and.arrow.up") }
                                }
                            }
                        }
                    }
                }

                ForEach(groupedRecipes, id: \.0) { profile, recipes in
                    Section(profile.displayName) {
                        ForEach(recipes) { recipe in
                            Button {
                                engine.applyRecipe(recipe)
                                dismiss()
                            } label: {
                                RecipeRow(
                                    recipe: recipe,
                                    isSelected: settings.activeRecipeName == recipe.name
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("recipe." + recipe.name)
                        }
                    }
                }
            }
            .navigationTitle("Scan recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showBuilder = true } label: { Label("New recipe", systemImage: "plus") }
                        Button { showImporter = true } label: { Label("Import from file", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Recipe options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showBuilder) { RecipeBuilderView() }
            .sheet(item: $editingRecipe) { recipe in RecipeBuilderView(existing: recipe) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        let imported = customStore.importJSON(data)
                        importMessage = imported.isEmpty ? "No recipes found in that file." : "Imported \(imported.count) recipe\(imported.count == 1 ? "" : "s")."
                    }
                case .failure:
                    importMessage = "Couldn't read that file."
                }
            }
            .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    /// Every recipe (built-in and custom) that has enough resolved
    /// paper-trade history for `RecipeFitnessEngine` to have an opinion,
    /// sorted best-first — surfaces fitness as something to act on rather
    /// than a badge someone has to notice while scrolling past it.
    private var bestPerforming: [ScanRecipe] {
        let all = RecipeLibrary.all + customStore.recipes
        return all
            .compactMap { recipe -> (ScanRecipe, RecipeFitnessEngine.Fitness)? in
                guard let fitness = engine.recipeFitness.fitness(for: recipe.name) else { return nil }
                return (recipe, fitness)
            }
            .sorted { $0.1.multiplier > $1.1.multiplier }
            .prefix(5)
            .map(\.0)
    }

    private var groupedRecipes: [(ScanProfile, [ScanRecipe])] {
        let grouped = Dictionary(grouping: RecipeLibrary.all, by: \.baseProfile)
        return ScanProfile.allCases.compactMap { profile in
            guard let recipes = grouped[profile], !recipes.isEmpty else { return nil }
            return (profile, recipes)
        }
    }

    /// Writes the recipe's JSON to a temp file so `ShareLink` has something
    /// with a filename and a "JSON document" preview, rather than sharing
    /// raw `Data` with no context.
    private func exportURL(for recipe: ScanRecipe) -> URL? {
        guard let data = customStore.exportJSON(recipe) else { return nil }
        let safeName = recipe.name.replacingOccurrences(of: " ", with: "-").lowercased()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

struct RecipeRow: View {
    @Environment(Settings.self) private var settings
    @Environment(ScannerEngine.self) private var engine
    let recipe: ScanRecipe
    let isSelected: Bool

    private var fitness: RecipeFitnessEngine.Fitness? {
        engine.recipeFitness.fitness(for: recipe.name)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(recipe.name)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    if let fitness {
                        FitnessBadge(fitness: fitness)
                    }
                }
                Text(recipe.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                AdvancedOnly {
                    HStack(spacing: 8) {
                        if let minRVOL = recipe.minRVOL {
                            Text("RVOL ≥\(Fmt.multiple(minRVOL))")
                        }
                        if let change = recipe.minChangePercent {
                            Text("move ≥\(String(format: "%.0f%%", change * 100))")
                        }
                        if let maxFloat = recipe.maxFloatShares {
                            Text("float ≤\(Fmt.compactVolume(maxFloat))")
                        }
                        if recipe.requireNews { Text("news") }
                        if recipe.requireFreshResume { Text("resume") }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A recipe's self-reweighted fitness — recomputed at most once a day from
/// its own resolved paper-trade outcomes — shown as a small hot/cold badge
/// rather than a raw multiplier, since "1.14×" means nothing at a glance
/// but a filled-vs-outline flame does.
struct FitnessBadge: View {
    let fitness: RecipeFitnessEngine.Fitness

    private var isHot: Bool { fitness.multiplier > 1.02 }
    private var isCold: Bool { fitness.multiplier < 0.98 }

    var body: some View {
        if isHot || isCold {
            HStack(spacing: 2) {
                Image(systemName: isHot ? "flame.fill" : "arrow.down.circle.fill")
                Text(String(format: "%.0f%%", fitness.winRate * 100))
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill((isHot ? Palette.up : Palette.down).opacity(0.15)))
            .foregroundStyle(isHot ? Palette.up : Palette.down)
            .accessibilityLabel(isHot ? "Recently performing well, \(Int(fitness.winRate * 100))% win rate" : "Recently underperforming, \(Int(fitness.winRate * 100))% win rate")
        }
    }
}

// MARK: - Recipe bar

/// Shows the active recipe and opens the library.
struct RecipeBar: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Binding var showRecipes: Bool

    var body: some View {
        Button {
            showRecipes = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                if let recipe = engine.activeRecipe {
                    Text(recipe.name)
                        .font(.subheadline.weight(.medium))
                    Text("· \(engine.candidates.count) of \(settings.maxRankedResults)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("All setups")
                        .font(.subheadline)
                    Text("· tap for recipes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scan.recipe")
        .foregroundStyle(engine.activeRecipe != nil ? Color.accentColor : .primary)
    }
}
