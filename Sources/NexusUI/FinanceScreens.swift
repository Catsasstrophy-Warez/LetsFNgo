#if canImport(SwiftUI)
import Foundation
import NexusCore
import NexusFinance
import NexusModel
import SwiftUI
import UniformTypeIdentifiers

/// Accounts in the Project screen: balances with their truth, statement
/// import and new accounts. Imported rows are recorded truth pointing at the
/// stored statement; forecasts never touch a recorded balance.
struct MoneySection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var importing = false
    @State private var adding = false
    @State private var sheet: FinanceSheet?
    @State private var summary: String?
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let accounts = (try? Ledger(store: env.store).accounts()) ?? []
        return Section("Money (\(accounts.count) accounts)") {
            ForEach(accounts) { account in
                Button { try? env.context.open(account.id, from: .project) } label: {
                    HStack {
                        Text(account.name)
                        Spacer()
                        if let balance = account.balance {
                            Text(balance.description).font(.callout.monospacedDigit())
                            TruthBadge(account.balanceTruth ?? .recorded)
                        }
                    }
                }
            }
            Button("Import bank or brokerage statement (OFX/QFX)", systemImage: "square.and.arrow.down") { importing = true }
            Button("Import CSV statement", systemImage: "tablecells") { sheet = .csv }
            Button("Budget", systemImage: "chart.bar.doc.horizontal") { sheet = .budgets }
            Button("Forecasts", systemImage: "chart.line.uptrend.xyaxis") { sheet = .forecasts }
            Button("Add account", systemImage: "plus") { adding = true }
            if let summary { Label(summary, systemImage: "checkmark.circle").font(.caption) }
            if let error { ClassifiedErrorView(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ofx") ?? .data, UTType(filenameExtension: "qfx") ?? .data, .data]) {
            importStatement($0)
        }
        .sheet(isPresented: $adding) { AddAccountSheet().environment(env) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .csv: CSVImportSheet().environment(env)
            case .budgets: BudgetsView().environment(env)
            case .forecasts: ForecastsView().environment(env)
            }
        }
    }

    enum FinanceSheet: String, Identifiable {
        case csv
        case budgets
        case forecasts

        var id: String { rawValue }
    }

    private func importStatement(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let imported = try StatementImporter(store: env.store).importStatements(Data(contentsOf: url), named: url.lastPathComponent, by: env.user)
            let results = imported.bank + imported.investment.map(\.cash)
            let created = results.map(\.created.count).reduce(0, +)
            let duplicates = results.map(\.duplicates.count).reduce(0, +) + imported.investment.map(\.duplicateTrades.count).reduce(0, +)
            var text = "Imported \(created) transactions into \(imported.bank.count + imported.investment.count) account(s); \(duplicates) already present were skipped."
            let trades = imported.investment.map(\.trades.count).reduce(0, +)
            if !imported.investment.isEmpty {
                text += " \(trades) trades, \(imported.investment.map(\.positions.count).reduce(0, +)) stated positions."
            }
            let skipped = imported.investment.flatMap(\.skippedTrades)
            if !skipped.isEmpty { text += " \(skipped.count) trades skipped: " + skipped.map(\.reason).joined(separator: "; ") }
            summary = text
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing from the file was stored; an import is all or nothing.")
        }
    }
}

struct AddAccountSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = AccountKind.checking
    @State private var currency = "USD"
    @State private var error: ClassifiedError?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Currency (ISO code)", text: $currency)
                if let error { ClassifiedErrorView(error) }
            }
            .navigationTitle("Add account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(name.isEmpty) }
            }
        }
    }

    private func add() {
        do {
            let account = try Ledger(store: env.store).addAccount(
                name: name, kind: kind, currency: try Currency(currency.uppercased()), by: env.user
            )
            if let project = env.context.activeProject ?? env.demo?.project { try env.projects.add(account.id, to: project, by: env.user) }
            dismiss()
        } catch {
            self.error = classify(error).preserving("No account was added.")
        }
    }
}

/// An account inside Object Detail: its transactions with who set each
/// category, a person's category override, and this month's budget.
struct AccountDomainView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var newCategory = ""
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let ledger = Ledger(store: env.store)
        let transactions = ((try? ledger.transactions(in: [id])) ?? []).sorted { $0.date > $1.date }.prefix(100)
        let categories = (try? ledger.categories()) ?? []
        return Group {
            Section("Transactions") {
                if transactions.isEmpty { Text("No transactions. Import a statement from the project.").foregroundStyle(.secondary) }
                ForEach(Array(transactions)) { transaction in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(transaction.payee)
                            Spacer()
                            Text(transaction.amount.description).font(.callout.monospacedDigit())
                        }
                        HStack {
                            Text(transaction.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                            Menu(transaction.category.flatMap { id in categories.first { $0.id == id }?.name } ?? "Uncategorised") {
                                ForEach(categories) { category in
                                    Button(category.name) { set(category.id, on: transaction.id) }
                                }
                            }
                            .font(.caption)
                            if let truth = transaction.categoryTruth { TruthBadge(truth) }
                        }
                    }
                }
            }
            Section("Categories") {
                HStack {
                    TextField("New category", text: $newCategory)
                    Button("Add") { addCategory() }.disabled(newCategory.isEmpty)
                }
                Text("A category you choose is recorded and is never replaced by a rule or a model.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
    }

    private func set(_ category: ObjectID, on transaction: ObjectID) {
        do {
            _ = try Ledger(store: env.store).setCategory(category, on: transaction, by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func addCategory() {
        do {
            _ = try Ledger(store: env.store).addCategory(newCategory, by: env.user)
            newCategory = ""
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}
#endif
