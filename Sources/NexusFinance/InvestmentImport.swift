import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A trade in a statement that was not recorded, and why.
public struct SkippedTrade: Sendable, Hashable {
    public var trade: OFXTrade
    public var reason: String
}

/// What importing one brokerage statement did.
public struct InvestmentImportResult: Sendable, Hashable {
    public var account: Account
    /// Securities the statement introduced.
    public var securitiesCreated: [Security]
    /// Trades recorded (recorded truth, pointing at the file).
    public var trades: [Trade]
    /// Trades already stored, matched by FITID or by content.
    public var duplicateTrades: [OFXTrade]
    /// Trades that could not be recorded, such as a sale of units bought before the statement began.
    public var skippedTrades: [SkippedTrade]
    /// Income (dividends, interest) and cash movements, as transactions on the account.
    public var cash: ImportResult
    /// Positions as the broker stated them.
    public var positions: [OFXPosition]
    /// Price quotes recorded from the statement.
    public var prices: Int
}

extension StatementImporter {
    /// Imports an investment statement: securities, buys and sells as trades
    /// on the account's holdings, income and cash rows as transactions, and
    /// the broker's stated positions and prices. Everything is **recorded**
    /// truth whose origin is the stored file. Derived cost basis and gains
    /// then come from `Portfolio` as for trades entered by hand.
    func importInvestments(_ statement: OFXInvestmentStatement, into accountID: ObjectID?, document: ObjectRecord, by author: Origin) throws
        -> InvestmentImportResult
    {
        let importer = Origin.importer(source: document.id)
        let portfolio = Portfolio(store: store, clock: clock)
        func provenance(_ locator: String) -> Provenance {
            Provenance(
                origin: importer, truth: .recorded, timestamp: clock.now(), method: "\(locator), imported by \(author.financeLabel)",
                dependencies: [document.id]
            )
        }

        let account: Account
        if let accountID {
            account = try ledger.account(accountID)
        } else if let existing = try ledger.account(number: statement.accountID, bankID: statement.brokerID) {
            account = existing
        } else {
            let masked = "••" + statement.accountID.suffix(4)
            account = try ledger.addAccount(
                name: "\(statement.organization ?? statement.brokerID ?? "Brokerage") \(masked)", kind: .brokerage, currency: statement.currency,
                institution: statement.organization, accountNumber: statement.accountID, bankID: statement.brokerID, by: importer
            )
        }
        guard account.currency == statement.currency else { throw MoneyError.currencyMismatch(account.currency, statement.currency) }

        // Securities, found by CUSIP/ISIN, then by symbol, else created.
        var known: [String: Security] = [:]
        var securitiesCreated: [Security] = []
        func security(_ uniqueID: String) throws -> Security {
            if let cached = known[uniqueID] { return cached }
            let info = statement.securities[uniqueID]
            let symbol = info?.symbol ?? uniqueID.uppercased()
            let found: Security
            if let existing = try portfolio.security(uniqueID: uniqueID) ?? portfolio.security(symbol: symbol) {
                found = existing
            } else {
                found = try portfolio.addSecurity(
                    symbol: symbol, name: info?.name ?? symbol, assetClass: info?.assetClass ?? .other, currency: statement.currency, uniqueID: uniqueID,
                    by: importer, provenance: provenance("OFX \(info?.kind ?? "SECID") \(uniqueID)")
                )
                securitiesCreated.append(found)
            }
            known[uniqueID] = found
            return found
        }

        // Trades, oldest first and buys before sells on the same day.
        let existingTrades = try store.objects(try store.relationships(to: account.id, kind: .postedTo).map(\.from))
            .filter { $0.type == .trade && $0.lifecycle == .active }.map(Trade.init)
        var fitIDs = Set(existingTrades.compactMap(\.fitID))
        var contentCounts: [String: Int] = [:]
        func contentKey(date: Date, side: TradeSide, quantity: Decimal, price: Decimal, security: ObjectID) -> String {
            "\(FinanceCalendar.isoDay(date))|\(side.rawValue)|\(quantity.plainString)|\(price.plainString)|\(security)"
        }
        for trade in existingTrades where trade.fitID == nil {
            guard let price = trade.price, let security = trade.security else { continue }
            contentCounts[contentKey(date: trade.date, side: trade.side, quantity: trade.quantity, price: price.amount, security: security), default: 0] += 1
        }
        var recorded: [Trade] = []
        var duplicates: [OFXTrade] = []
        var skipped: [SkippedTrade] = []
        let ordered = statement.trades.enumerated().sorted { a, b in
            (a.element.date, a.element.side == .buy ? 0 : 1, a.offset) < (b.element.date, b.element.side == .buy ? 0 : 1, b.offset)
        }.map(\.element)
        for trade in ordered {
            let target = try security(trade.securityID)
            if let fitID = trade.fitID, fitIDs.contains(fitID) {
                duplicates.append(trade)
                continue
            }
            if trade.fitID == nil {
                let key = contentKey(date: trade.date, side: trade.side, quantity: trade.units, price: trade.unitPrice, security: target.id)
                if let count = contentCounts[key], count > 0 {
                    contentCounts[key] = count - 1
                    duplicates.append(trade)
                    continue
                }
            }
            guard trade.currency == target.currency else {
                skipped.append(SkippedTrade(trade: trade, reason: "priced in \(trade.currency), but \(target.symbol) is priced in \(target.currency)"))
                continue
            }
            if trade.side == .sell {
                let held = try portfolio.position(of: target.id, in: account.id, asOf: trade.date).quantity
                guard held >= trade.units else {
                    skipped.append(
                        SkippedTrade(
                            trade: trade,
                            reason:
                                "sells \(trade.units.plainString) \(target.symbol) but only \(held.plainString) are recorded; import the earlier statement first"
                        ))
                    continue
                }
            }
            let draft = TradeDraft(
                date: trade.date, side: trade.side, quantity: trade.units, price: Money(trade.unitPrice, trade.currency),
                fees: trade.fees == 0 ? nil : Money(trade.fees, trade.currency)
            )
            recorded.append(
                try portfolio.recordTrade(
                    draft, of: target.id, in: account.id, provenance: provenance("OFX \(trade.kind) \(trade.fitID ?? "without FITID")"), fitID: trade.fitID))
            if let fitID = trade.fitID { fitIDs.insert(fitID) }
        }

        // Income and cash movements, deduped like any statement row.
        var rows: [(draft: TransactionDraft, locator: String)] = try statement.income.map { income in
            let symbol = try income.securityID.map { try security($0).symbol }
            let label =
                switch income.incomeType {
                case "DIV": "Dividend"
                case "INTEREST": "Interest"
                case "CGLONG": "Long-term capital gain"
                case "CGSHORT": "Short-term capital gain"
                default: "Investment income"
                }
            let draft = TransactionDraft(
                date: income.date, amount: income.total, payee: [label, symbol].compactMap { $0 }.joined(separator: " "), memo: income.memo,
                fitID: income.fitID, type: "INCOME:\(income.incomeType)"
            )
            return (draft, "OFX INCOME \(income.fitID ?? "without FITID")")
        }
        rows += statement.cash.map { ($0, "OFX INVBANKTRAN \($0.fitID ?? "without FITID")") }
        let cash = try insert(rows, into: account, document: document, format: "OFX", balance: nil, by: author)

        // Prices from the security list and the positions, and each stated position on its holding.
        var prices = 0
        func recordPrice(_ unitPrice: Decimal?, at date: Date?, of target: Security, locator: String) throws {
            guard let unitPrice, let date, target.currency == statement.currency else { return }
            let price = Money(unitPrice, statement.currency)
            let already = try portfolio.prices(of: target.id, truth: [.recorded]).contains { $0.at == date && $0.price == price }
            guard !already else { return }
            try portfolio.recordPrice(price, of: target, at: date, provenance: provenance(locator))
            prices += 1
        }
        for position in statement.positions {
            let target = try security(position.securityID)
            try recordPrice(position.unitPrice, at: position.priceDate ?? statement.asOf, of: target, locator: "OFX INVPOS \(position.securityID)")
            let stated = provenance("OFX INVPOS \(position.securityID)")
            let holding = try portfolio.ensureHolding(of: target, in: account.id, provenance: stated)
            let asOf = position.priceDate ?? statement.asOf ?? clock.now()
            if let current = holding.date(FinanceKey.statedAsOf), current > asOf { continue }
            try store.update(holding.id, by: importer, instruction: "Position stated by \(document.title)") {
                $0.attributes[FinanceKey.statedQuantity] = Attribute(position.units.value, provenance: stated)
                $0.attributes[FinanceKey.statedAsOf] = Attribute(.date(asOf), provenance: stated)
                if let value = position.marketValue { $0.attributes[FinanceKey.statedMarketValue] = Attribute(value.value, provenance: stated) }
            }
        }
        for (id, info) in statement.securities.sorted(by: { $0.key < $1.key }) where known[id] != nil {
            try recordPrice(info.unitPrice, at: info.priceDate, of: known[id]!, locator: "OFX SECINFO \(id)")
        }
        return InvestmentImportResult(
            account: try ledger.account(account.id), securitiesCreated: securitiesCreated, trades: recorded, duplicateTrades: duplicates,
            skippedTrades: skipped, cash: cash, positions: statement.positions, prices: prices
        )
    }
}
