#if canImport(SwiftUI)
import Charts
import Foundation
import NexusCore
import NexusFinance
import NexusModel
import SwiftUI
import UniformTypeIdentifiers

// Finance screens reached from the Money section of the Project screen:
// CSV import with a column mapping, the monthly budget, and forecast
// scenarios. All logic lives in NexusFinance (CSVMappingGuesser,
// Budgets.overview, Scenarios and AssumptionDraft); these views only bind it.

// MARK: - CSV import

/// Choose a CSV file, check the guessed column mapping against a preview,
/// pick the account and import. Duplicates are counted before anything is
/// stored, and the mapping is remembered on the account.
struct CSVImportSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var fileName: String?
    @State private var data: Data?
    @State private var text = ""
    @State private var guess: CSVMappingGuess?
    @State private var draft = CSVMappingDraft()
    @State private var accountID: ObjectID?
    @State private var preview: [CSVPreviewRow] = []
    @State private var plan: CSVImportPlan?
    @State private var remember = true
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let accounts = (try? Ledger(store: env.store).accounts()) ?? []
        return NavigationStack {
            Form {
                Section("File") {
                    Button(fileName ?? "Choose a CSV file", systemImage: "doc.text") { picking = true }
                }
                if let guess {
                    Section("Account") {
                        Picker("Import into", selection: $accountID) {
                            Text("Choose an account").tag(ObjectID?.none)
                            ForEach(accounts) { account in Text("\(account.name) (\(account.currency.code))").tag(ObjectID?.some(account.id)) }
                        }
                        if guess.remembered { Label("Using the mapping saved for this account", systemImage: "checkmark.seal").font(.caption) }
                    }
                    Section("Columns") {
                        ForEach(titles(guess).indices, id: \.self) { index in
                            Picker(titles(guess)[index], selection: field(at: index)) {
                                Text("Ignore").tag(CSVField?.none)
                                ForEach(CSVField.allCases, id: \.self) { field in Text(field.label).tag(CSVField?.some(field)) }
                            }
                        }
                        if !draft.missing.isEmpty {
                            Text("Still needed: " + draft.missing.map(\.label).joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("Formats") {
                        Picker("Dates", selection: $draft.dateFormat) {
                            ForEach(dateFormats(guess), id: \.self) { format in
                                Text(guess.dateFormatCandidates.contains(format) ? "\(format) (fits)" : format).tag(format)
                            }
                        }
                        Picker("Numbers", selection: $draft.numberStyle) {
                            ForEach(CSVNumberStyle.allCases, id: \.self) { style in Text(style.example).tag(style) }
                        }
                        Toggle("Flip signs (card exports write purchases as positive)", isOn: $draft.invertSign)
                        Toggle("First row is a header", isOn: $draft.hasHeader)
                    }
                    if !guess.notes.isEmpty {
                        Section("Check") {
                            ForEach(guess.notes, id: \.self) { note in Label(note, systemImage: "exclamationmark.triangle").font(.caption) }
                        }
                    }
                    Section("Preview") {
                        if preview.isEmpty { Text("Map the date, amount and payee columns to see the rows.").foregroundStyle(.secondary) }
                        ForEach(preview.indices, id: \.self) { index in previewRow(preview[index]) }
                    }
                    if let plan {
                        Section("Import") {
                            Label("\(plan.new.count) new transactions", systemImage: "plus.circle")
                            Label("\(plan.duplicates.count) already stored, will be skipped", systemImage: "equal.circle")
                            if let balance = plan.closingBalance {
                                HStack {
                                    Text("Closing balance \(balance.description)")
                                    TruthBadge(.recorded)
                                }
                            }
                            Toggle("Remember this mapping for the account", isOn: $remember)
                            Text("Imported rows are recorded truth pointing at the stored file.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Import CSV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { importFile() }.disabled(plan == nil) }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .data]) { load($0) }
            .onChange(of: draft) { refresh() }
            .onChange(of: accountID) { regenerate() }
        }
    }

    private func titles(_ guess: CSVMappingGuess) -> [String] {
        draft.hasHeader == guess.draft.hasHeader ? guess.columnTitles : guess.columnTitles.indices.map { "Column \($0 + 1)" }
    }

    private func dateFormats(_ guess: CSVMappingGuess) -> [String] {
        var formats = guess.dateFormatCandidates
        for format in CSVMappingGuesser.dateFormats where !formats.contains(format) { formats.append(format) }
        if !formats.contains(draft.dateFormat) { formats.insert(draft.dateFormat, at: 0) }
        return formats
    }

    private func field(at index: Int) -> Binding<CSVField?> {
        Binding(get: { draft.field(at: index) }, set: { draft.assign($0, to: index) })
    }

    @ViewBuilder
    private func previewRow(_ row: CSVPreviewRow) -> some View {
        if let parsed = row.row {
            HStack {
                Text(FinanceCalendar.isoDay(parsed.draft.date)).font(.caption.monospacedDigit())
                Text(parsed.draft.payee).lineLimit(1)
                Spacer()
                Text(parsed.draft.amount.description).font(.callout.monospacedDigit())
                    .foregroundStyle(parsed.draft.amount.isNegative ? Color.primary : Color.green)
            }
        } else {
            Label("Line \(row.line): \(row.error.map { "\($0)" } ?? "unreadable")", systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
        }
    }

    private var account: Account? {
        accountID.flatMap { try? Ledger(store: env.store).account($0) }
    }

    private func load(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try Data(contentsOf: url)
            guard let decoded = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else {
                throw FinanceError.malformedCSV(line: 0, reason: "not text")
            }
            data = bytes
            text = decoded
            fileName = url.lastPathComponent
            regenerate()
        } catch {
            self.error = classify(error)
        }
    }

    /// Guesses again, using the chosen account's remembered mapping and kind.
    private func regenerate() {
        guard !text.isEmpty else { return }
        do {
            let next = try CSVMappingGuesser.guess(text, accountKind: account?.kind, remembered: account?.csvMapping)
            guess = next
            if draft != next.draft { draft = next.draft } else { refresh() }
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func refresh() {
        plan = nil
        preview = []
        guard !text.isEmpty, draft.isComplete, let mapping = try? draft.mapping() else { return }
        let currency = account?.currency ?? .usd
        preview = (try? CSV.preview(text, mapping: mapping, currency: currency)) ?? []
        guard let data, let accountID else { return }
        do {
            plan = try StatementImporter(store: env.store).previewCSV(data, into: accountID, mapping: mapping)
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing has been imported yet.")
        }
    }

    private func importFile() {
        guard let data, let accountID else { return }
        do {
            let result = try StatementImporter(store: env.store).importCSV(
                data, named: fileName ?? "statement.csv", into: accountID, mapping: try draft.mapping(), by: env.user)
            if remember { try Ledger(store: env.store).saveCSVMapping(draft, on: accountID, by: env.user) }
            _ = result
            dismiss()
        } catch {
            self.error = classify(error).preserving("Nothing from the file was stored; an import is all or nothing.")
        }
    }
}

// MARK: - Budgets

/// A month's budget: the person's amount per category (recorded), what was
/// spent (derived from recorded transactions), progress, and rollover.
struct BudgetsView: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var month = YearMonth(Date())
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let budgets = Budgets(store: env.store)
        let overview = try? budgets.overview(for: month)
        return NavigationStack {
            Form {
                Section {
                    HStack {
                        Button("Previous month", systemImage: "chevron.left") { month = month.adding(-1) }.labelStyle(.iconOnly)
                        Spacer()
                        Text(Self.title(month)).font(.headline)
                        Spacer()
                        Button("Next month", systemImage: "chevron.right") { month = month.adding(1) }.labelStyle(.iconOnly)
                    }
                }
                if let overview {
                    Section("This month") {
                        LabeledContent("Budgeted", value: overview.totalAvailable.description)
                        LabeledContent("Spent", value: overview.totalActual.description)
                        LabeledContent("Left", value: overview.totalRemaining.description)
                        if overview.totalAvailable.amount > 0 {
                            ProgressView(value: min((overview.totalActual.amount / overview.totalAvailable.amount).doubleValue, 1))
                                .tint(overview.totalRemaining.isNegative ? Color.red : Color.accentColor)
                        }
                        if !overview.uncategorized.isZero {
                            LabeledContent("Uncategorised spending", value: overview.uncategorized.description).font(.caption)
                        }
                        Toggle("Roll over what's left from last month", isOn: rollover(overview))
                        Button("Copy last month's amounts", systemImage: "doc.on.doc") { copyPrevious() }
                        HStack(spacing: 6) {
                            Text("Amounts").font(.caption)
                            TruthBadge(overview.budgetTruth ?? .recorded)
                            Text("Spent").font(.caption)
                            TruthBadge(.derived)
                        }
                    }
                    let expenses = overview.rows.filter { $0.kind == .expense }
                    let income = overview.rows.filter { $0.kind == .income }
                    Section("Spending") {
                        if expenses.isEmpty { Text("No expense categories yet. Add one from an account.").foregroundStyle(.secondary) }
                        ForEach(expenses) { row in
                            BudgetRowView(row: row, currency: overview.currency) { save($0, row: row, currency: overview.currency) }
                        }
                    }
                    if !income.isEmpty {
                        Section("Income") {
                            ForEach(income) { row in
                                BudgetRowView(row: row, currency: overview.currency) { save($0, row: row, currency: overview.currency) }
                            }
                        }
                    }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Budget")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// "September 2026", in UTC like every finance date.
    static func title(_ month: YearMonth) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.timeZone = TimeZone(identifier: "UTC")!
        return month.start.formatted(style)
    }

    private func rollover(_ overview: BudgetOverview) -> Binding<Bool> {
        Binding(
            get: { overview.rollover },
            set: { enabled in
                perform { try Budgets(store: env.store).setRollover(enabled, for: month, currency: overview.currency, by: env.user) }
            })
    }

    private func save(_ text: String, row: BudgetOverviewRow, currency: Currency) {
        perform {
            let amount = try Budgets.parseAmount(text, currency: currency)
            try Budgets(store: env.store).setAmount(amount, for: row.category, in: month, by: env.user)
        }
    }

    private func copyPrevious() {
        perform { try Budgets(store: env.store).copyBudget(from: month.adding(-1), to: month, by: env.user) }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = classify(error).preserving("The budget was not changed.")
        }
    }
}

/// One category: an editable amount, progress and what is left.
struct BudgetRowView: View {
    let row: BudgetOverviewRow
    let currency: Currency
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name)
                Spacer()
                TextField("No budget", text: $text)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: 120)
                    .focused($focused)
                    .onSubmit { save(text) }
                    .accessibilityLabel("Budget for \(row.name) in \(currency.code)")
            }
            if let progress = row.progress {
                ProgressView(value: min(progress, 1)).tint(tint)
            }
            Text(detail).font(.caption).foregroundStyle(row.status == .over ? Color.red : Color.secondary)
        }
        .onAppear { text = row.budgeted?.amount.plainString ?? "" }
        .onChange(of: row.budgeted) { if !focused { text = row.budgeted?.amount.plainString ?? "" } }
        .onChange(of: focused) { if !focused, text != (row.budgeted?.amount.plainString ?? "") { save(text) } }
    }

    private var tint: Color {
        switch row.status {
        case .over, .incomeShort: .red
        case .nearLimit: .orange
        default: .green
        }
    }

    private var detail: String {
        let verb = row.kind == .income ? "Received" : "Spent"
        var parts = ["\(verb) \(row.actual.description)"]
        if let available = row.available { parts.append("of \(available.description)") }
        if let remaining = row.remaining { parts.append(remaining.isNegative ? "· \(remaining.magnitude.description) over" : "· \(remaining.description) left") }
        if !row.carriedOver.isZero { parts.append("(\(row.carriedOver.description) rolled over)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Forecasts

/// Scenarios: projected balances (modeled) from recorded balances, detected
/// recurring series and the person's assumptions (claimed).
struct ForecastsView: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        _ = env.revision
        let summaries = (try? Scenarios(store: env.store).summaries()) ?? []
        return NavigationStack {
            List {
                if summaries.isEmpty {
                    NextActionEmptyState(
                        "No scenarios", message: "Create a scenario to project your balances from recorded data and your assumptions.",
                        systemImage: "chart.line.uptrend.xyaxis")
                }
                ForEach(summaries) { summary in
                    NavigationLink {
                        ScenarioDetailView(id: summary.id).environment(env)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.scenario.name)
                            HStack {
                                if let ending = summary.ending {
                                    Text("Ends at \(ending.description)").font(.caption.monospacedDigit())
                                    TruthBadge(.modeled)
                                } else {
                                    Text("Not run yet").font(.caption).foregroundStyle(.secondary)
                                }
                                if let negative = summary.firstNegativeMonth {
                                    Text("Below zero in \(negative.description)").font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Forecasts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New scenario", systemImage: "plus") { creating = true } }
            }
            .sheet(isPresented: $creating) { NewScenarioSheet().environment(env) }
        }
    }
}

struct NewScenarioSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<ObjectID> = []
    @State private var start = Date()
    @State private var months = 12
    @State private var includeRecurring = true
    @State private var error: ClassifiedError?

    var body: some View {
        let accounts = (try? Ledger(store: env.store).accounts()) ?? []
        return NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Accounts (their recorded balances are the starting point)") {
                    ForEach(accounts) { account in
                        Toggle(isOn: Binding(get: { selected.contains(account.id) }, set: { if $0 { selected.insert(account.id) } else { selected.remove(account.id) } })) {
                            HStack {
                                Text(account.name)
                                Spacer()
                                Text(account.balance?.description ?? "no balance").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Horizon") {
                    DatePicker("Start month", selection: $start, displayedComponents: .date)
                    Stepper("\(months) months", value: $months, in: 1...120)
                    Toggle("Include detected recurring payments", isOn: $includeRecurring)
                }
                Text("Assumptions you add are claims about the future; the projection is modeled and never changes a recorded balance.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { ClassifiedErrorView(error) }
            }
            .formStyle(.grouped)
            .navigationTitle("New scenario")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create(accounts) }.disabled(name.isEmpty || selected.isEmpty) }
            }
        }
    }

    private func create(_ accounts: [Account]) {
        do {
            let ids = accounts.map(\.id).filter(selected.contains)
            let scenario = try Scenarios(store: env.store).createScenario(
                name, accounts: ids, start: YearMonth(start), months: months, includeRecurring: includeRecurring, by: env.user)
            if let project = env.context.activeProject ?? env.demo?.project { try env.projects.add(scenario.id, to: project, by: env.user) }
            dismiss()
        } catch {
            self.error = classify(error).preserving("No scenario was created.")
        }
    }
}

/// One scenario: the projected-balance chart, its claimed assumptions and
/// the modeled month-by-month projection.
struct ScenarioDetailView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var draft = AssumptionDraft()
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let scenarios = Scenarios(store: env.store)
        let scenario = try? scenarios.scenario(id)
        let forecast = try? scenarios.forecast(id)
        let points = (try? forecast?.chartPoints()) ?? []
        let accounts = ((try? Ledger(store: env.store).accounts()) ?? []).filter { scenario?.accounts.contains($0.id) ?? false }
        let payees = (try? scenarios.recurringPayees(for: id)) ?? []
        return Form {
            if let scenario {
                Section {
                    if points.isEmpty {
                        Text("Run the forecast to see projected balances.").foregroundStyle(.secondary)
                    } else {
                        Chart {
                            ForEach(points.filter { $0.truth == .modeled }) { point in
                                LineMark(x: .value("Month", point.date), y: .value("Balance", point.total))
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                                    .foregroundStyle(by: .value("Truth", "Projected (modeled)"))
                            }
                            ForEach(points) { point in
                                PointMark(x: .value("Month", point.date), y: .value("Balance", point.total))
                                    .foregroundStyle(by: .value("Truth", point.truth == .recorded ? "Opening balance (recorded)" : "Projected (modeled)"))
                            }
                            RuleMark(y: .value("Zero", 0.0)).foregroundStyle(.red.opacity(0.4))
                        }
                        .chartForegroundStyleScale(["Opening balance (recorded)": Color.blue, "Projected (modeled)": Color.purple])
                        .frame(height: 220)
                        .accessibilityLabel(
                            "Projected balance for \(scenario.name), modeled, from \(points.first?.money.description ?? "") to \(points.last?.money.description ?? "")")
                    }
                    Button("Run forecast", systemImage: "play.fill") { run() }
                    if let forecast {
                        HStack {
                            Text("Last run \(forecast.provenance.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            TruthBadge(forecast.provenance.truth)
                        }
                    }
                }
                Section {
                    ForEach(Array(scenario.assumptions.enumerated()), id: \.offset) { index, assumption in
                        Text(assumption.summary)
                            .swipeActions { Button("Remove", role: .destructive) { remove(index) } }
                            .contextMenu { Button("Remove", role: .destructive) { remove(index) } }
                    }
                    if scenario.assumptions.isEmpty { Text("No assumptions: recorded balances and recurring payments only.").foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text("Assumptions")
                        TruthBadge(scenario.assumptionsTruth ?? .claimed)
                    }
                }
                Section("Add an assumption") {
                    Picker("Kind", selection: $draft.kind) { ForEach(AssumptionDraft.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    switch draft.kind {
                    case .oneOff, .monthly:
                        TextField("Label (e.g. Bonus, New car)", text: $draft.label)
                        TextField("Amount (negative is money out)", text: $draft.amount)
                        Picker("Account", selection: $draft.account) {
                            Text("Choose").tag(ObjectID?.none)
                            ForEach(accounts) { Text($0.name).tag(ObjectID?.some($0.id)) }
                        }
                        if draft.kind == .oneOff {
                            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                        } else {
                            Stepper("Day \(draft.day) of each month", value: $draft.day, in: 1...31)
                            DatePicker("From", selection: monthBinding(\.start), displayedComponents: .date)
                        }
                    case .adjustRecurring, .stopRecurring:
                        Picker("Recurring payment", selection: $draft.payee) {
                            Text("Choose").tag("")
                            ForEach(payees, id: \.self) { Text($0).tag($0) }
                        }
                        if draft.kind == .adjustRecurring { TextField("Change in % (e.g. 20 or -10)", text: $draft.percent) }
                        DatePicker("From", selection: monthBinding(\.start), displayedComponents: .date)
                    }
                    Button("Add assumption", systemImage: "plus") { add(currency: accounts.first?.currency ?? .usd) }
                }
                if let forecast {
                    Section {
                        ForEach(forecast.points, id: \.month) { point in
                            LabeledContent(point.month.description, value: point.total.description).font(.callout.monospacedDigit())
                        }
                    } header: {
                        HStack {
                            Text("Projection")
                            TruthBadge(forecast.provenance.truth)
                        }
                    }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
        .formStyle(.grouped)
        .navigationTitle(scenario?.name ?? "Scenario")
        .onAppear { if draft.account == nil { draft.account = scenario?.accounts.first } }
    }

    private func monthBinding(_ keyPath: WritableKeyPath<AssumptionDraft, YearMonth>) -> Binding<Date> {
        Binding(get: { draft[keyPath: keyPath].start }, set: { draft[keyPath: keyPath] = YearMonth($0) })
    }

    private func add(currency: Currency) {
        perform {
            try Scenarios(store: env.store).addAssumption(try draft.assumption(currency: currency), to: id, by: env.user)
            draft = AssumptionDraft(kind: draft.kind, account: draft.account)
        }
    }

    private func remove(_ index: Int) {
        perform { try Scenarios(store: env.store).removeAssumption(at: index, from: id, by: env.user) }
    }

    private func run() {
        perform { try Scenarios(store: env.store).run(id) }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = classify(error).preserving("Recorded balances are unchanged.")
        }
    }
}
#endif
