import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A statement row that matched a stored transaction.
public struct DuplicateRow: Sendable, Hashable {
    public var draft: TransactionDraft
    public var existing: ObjectID
}

/// What one statement import did.
public struct ImportResult: Sendable, Hashable {
    /// The `document` object holding the file (its bytes are a blob).
    public var document: ObjectRecord
    public var account: Account
    public var created: [FinancialTransaction]
    public var duplicates: [DuplicateRow]
    public var balance: Money?
}

/// What an OFX file import did, per statement.
public struct StatementImportSummary: Sendable, Hashable {
    public var document: ObjectRecord
    /// Bank and card statements.
    public var bank: [ImportResult]
    /// Brokerage statements.
    public var investment: [InvestmentImportResult]
}

/// A CSV import worked out before anything is stored, for the person to check.
public struct CSVImportPlan: Sendable, Hashable {
    public var account: Account
    public var rows: [CSVStatementRow]
    /// Rows that would be stored.
    public var new: [TransactionDraft]
    /// Rows that match a stored transaction and would be skipped.
    public var duplicates: [DuplicateRow]
    /// The balance the statement ends on, when the mapping has a balance column.
    public var closingBalance: Money?
}

/// The dedup rules, over an account's stored transactions plus the rows
/// added so far from the file being imported.
struct DuplicateIndex {
    var byFitID: [String: ObjectID] = [:]
    var byContent: [String: (id: ObjectID, hasFitID: Bool)] = [:]
    var occurrences: [String: Int] = [:]

    init(_ existing: [FinancialTransaction]) {
        for transaction in existing {
            if let fitID = transaction.fitID { byFitID[fitID] = transaction.id }
            if let key = transaction.contentKey { byContent[key] = (transaction.id, transaction.fitID != nil) }
        }
    }

    /// The row's occurrence-numbered content key, and the stored transaction it duplicates, if any.
    mutating func classify(_ draft: TransactionDraft) -> (contentKey: String, duplicate: ObjectID?) {
        let hash = draft.contentHash
        occurrences[hash, default: 0] += 1
        let contentKey = "\(hash)#\(occurrences[hash]!)"
        if let fitID = draft.fitID, let match = byFitID[fitID] { return (contentKey, match) }
        if let match = byContent[contentKey], draft.fitID == nil || !match.hasFitID { return (contentKey, match.id) }
        return (contentKey, nil)
    }

    mutating func add(_ id: ObjectID, draft: TransactionDraft, contentKey: String) {
        if let fitID = draft.fitID { byFitID[fitID] = id }
        byContent[contentKey] = (id, draft.fitID != nil)
    }
}

/// Imports CSV and OFX/QFX bank statements.
///
/// The file is stored first, as a blob behind a `document` object. Every
/// imported transaction is **recorded** truth whose origin is
/// `importer(source:)` naming that document, so each row traces back to the
/// exact bytes it came from. Stated ledger balances are recorded the same way.
///
/// ## Dedup
///
/// A row is a duplicate of a stored transaction on the same account when
/// - both have a FITID and the FITIDs are equal, or
/// - either lacks a FITID and their content keys are equal. A content key is
///   the SHA-256 of (day, amount, currency, normalised payee) plus an
///   occurrence number within the file, so two identical coffees on one day
///   are both kept while re-importing the same file adds nothing.
public struct StatementImporter: Sendable {
    public let store: NexusStore
    public let ledger: Ledger
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.ledger = Ledger(store: store, clock: clock)
        self.clock = clock
    }

    /// Imports a CSV statement into an existing account, in the account's currency.
    @discardableResult
    public func importCSV(_ data: Data, named fileName: String, into accountID: ObjectID, mapping: CSVMapping, by author: Origin) throws -> ImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FinanceError.malformedCSV(line: 0, reason: "not text")
        }
        let account = try ledger.account(accountID)
        let rows = try CSV.statementRows(text, mapping: mapping, currency: account.currency)
        let balance = mapping.balance == nil ? nil : CSV.closingBalance(rows)
        return try store.batch { _ in
            let document = try storeDocument(data, named: fileName, mediaType: "text/csv", format: "CSV", by: author)
            return try insert(
                rows.map { ($0.draft, "CSV line \($0.line)") }, into: account, document: document, format: "CSV", balance: balance, by: author)
        }
    }

    /// What importing a CSV statement into the account would do, without
    /// storing anything: every row read with the mapping and checked against
    /// the account's transactions by the same dedup rules as the import.
    public func previewCSV(_ data: Data, into accountID: ObjectID, mapping: CSVMapping) throws -> CSVImportPlan {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FinanceError.malformedCSV(line: 0, reason: "not text")
        }
        let account = try ledger.account(accountID)
        let rows = try CSV.statementRows(text, mapping: mapping, currency: account.currency)
        var index = DuplicateIndex(try ledger.transactions(in: [account.id]))
        var plan = CSVImportPlan(account: account, rows: rows, new: [], duplicates: [], closingBalance: nil)
        for row in rows {
            let (contentKey, match) = index.classify(row.draft)
            if let match {
                plan.duplicates.append(DuplicateRow(draft: row.draft, existing: match))
            } else {
                plan.new.append(row.draft)
                // A placeholder ID: later rows in this file dedup against earlier ones the same way the import does.
                index.add(ObjectID(uuid: UUID()), draft: row.draft, contentKey: contentKey)
            }
        }
        if mapping.balance != nil { plan.closingBalance = CSV.closingBalance(rows).map { $0.balance } }
        return plan
    }

    /// Imports every statement in an OFX or QFX file. Each statement goes to
    /// the account with its ACCTID (and BANKID), or to a new account created
    /// from the statement, or to `accountID` when the file holds one statement.
    /// Investment statements are imported too (see `importStatements`); the
    /// result lists their cash rows.
    @discardableResult
    public func importOFX(_ data: Data, named fileName: String, into accountID: ObjectID? = nil, by author: Origin) throws -> [ImportResult] {
        let summary = try importStatements(data, named: fileName, into: accountID, by: author)
        return summary.bank + summary.investment.map(\.cash)
    }

    /// Imports every bank, card and investment statement in an OFX or QFX file.
    @discardableResult
    public func importStatements(_ data: Data, named fileName: String, into accountID: ObjectID? = nil, by author: Origin) throws
        -> StatementImportSummary
    {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FinanceError.malformedOFX("not text")
        }
        let root = try OFX.parse(text)
        let statements = try OFX.bankStatements(root)
        let investments = try OFX.investmentStatements(root)
        guard !statements.isEmpty || !investments.isEmpty else { throw FinanceError.malformedOFX("no STMTRS, CCSTMTRS or INVSTMTRS statement") }
        let single = statements.count + investments.count == 1
        return try store.batch { _ in
            let document = try storeDocument(data, named: fileName, mediaType: "application/x-ofx", format: "OFX", by: author)
            let importer = Origin.importer(source: document.id)
            let bank = try statements.map { statement in
                let account: Account
                if let accountID, single {
                    account = try ledger.account(accountID)
                } else if let existing = try ledger.account(number: statement.accountID, bankID: statement.bankID) {
                    account = existing
                } else {
                    let masked = "••" + statement.accountID.suffix(4)
                    account = try ledger.addAccount(
                        name: "\(statement.organization ?? statement.bankID ?? "Account") \(masked)", kind: statement.accountKind,
                        currency: statement.currency, institution: statement.organization, accountNumber: statement.accountID,
                        bankID: statement.bankID, by: importer
                    )
                }
                guard account.currency == statement.currency else { throw MoneyError.currencyMismatch(account.currency, statement.currency) }
                let rows = statement.transactions.map { ($0, "OFX STMTTRN \($0.fitID ?? "without FITID")") }
                var balance: (Money, Date)?
                if let amount = statement.ledgerBalance, let date = statement.ledgerBalanceDate ?? statement.endDate {
                    balance = (amount, date)
                }
                return try insert(rows, into: account, document: document, format: "OFX", balance: balance, by: author)
            }
            let investment = try investments.map { statement in
                try importInvestments(statement, into: single ? accountID : nil, document: document, by: author)
            }
            return StatementImportSummary(document: document, bank: bank, investment: investment)
        }
    }

    /// Stores the file's bytes as a blob and returns the document object for
    /// them, reusing the document when the same bytes were imported before.
    func storeDocument(_ data: Data, named fileName: String, mediaType: String, format: String, by author: Origin) throws -> ObjectRecord {
        let blob = try store.putBlob(data, mediaType: mediaType)
        if let existing = try store.objects(ofType: .document).first(where: { $0.string(FinanceKey.blob) == blob.sha256 }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .document, title: fileName,
                attributes: [
                    FinanceKey.blob: Attribute(.string(blob.sha256)),
                    FinanceKey.mediaType: Attribute(.string(mediaType)),
                    FinanceKey.format: Attribute(.string(format)),
                    "byteCount": Attribute(.int(Int64(blob.byteCount))),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "\(format) statement import")
            ))
    }

    func insert(
        _ rows: [(draft: TransactionDraft, locator: String)], into account: Account, document: ObjectRecord, format: String, balance: (Money, Date)?,
        by author: Origin
    ) throws -> ImportResult {
        var index = DuplicateIndex(try ledger.transactions(in: [account.id]))
        var created: [FinancialTransaction] = []
        var duplicates: [DuplicateRow] = []
        let importer = Origin.importer(source: document.id)
        for (draft, locator) in rows {
            let (contentKey, match) = index.classify(draft)
            if let match {
                duplicates.append(DuplicateRow(draft: draft, existing: match))
                continue
            }
            let provenance = Provenance(
                origin: importer, truth: .recorded, timestamp: clock.now(), method: "\(locator), imported by \(author.financeLabel)",
                dependencies: [document.id]
            )
            let transaction = try ledger.addTransaction(draft, to: account.id, contentKey: contentKey, provenance: provenance)
            index.add(transaction.id, draft: draft, contentKey: contentKey)
            created.append(transaction)
        }
        var updated = account
        if let (amount, date) = balance {
            updated = try ledger.recordBalance(
                amount, asOf: date, on: account.id,
                provenance: Provenance(
                    origin: importer, truth: .recorded, timestamp: clock.now(), method: format == "CSV" ? "CSV running balance" : "\(format) LEDGERBAL",
                    dependencies: [document.id]
                )
            )
        }
        try store.record(
            Event(
                at: clock.now(), kind: .statementImported, subjects: [document.id, account.id],
                summary: "Imported \(created.count) transactions (\(duplicates.count) duplicates) from \(document.title)",
                payload: [
                    "created": .int(Int64(created.count)), "duplicates": .int(Int64(duplicates.count)), FinanceKey.format: .string(format),
                ],
                provenance: Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "\(format) statement import")
            ))
        return ImportResult(document: document, account: updated, created: created, duplicates: duplicates, balance: balance?.0)
    }
}

extension Origin {
    var financeLabel: String {
        switch self {
        case .user(let id): "user:\(id)"
        case .agent(let id, _): "agent:\(id)"
        case .importer(let source): "importer:\(source)"
        case .simulation(let run): "simulation:\(run)"
        case .instrument(let id): "instrument:\(id)"
        case .model(let ref): "model:\(ref.provider)/\(ref.modelID)"
        case .system: "system"
        }
    }
}
