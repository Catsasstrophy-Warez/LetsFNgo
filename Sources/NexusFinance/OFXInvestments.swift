import Foundation

/// A security described in an OFX file's SECLIST (STOCKINFO, MFINFO, DEBTINFO, OPTINFO, OTHERINFO).
public struct OFXSecurity: Sendable, Hashable {
    /// SECID/UNIQUEID, usually a CUSIP or ISIN.
    public var uniqueID: String
    public var uniqueIDType: String?
    public var ticker: String?
    public var name: String
    /// The aggregate it came from: STOCKINFO, MFINFO, DEBTINFO, OPTINFO or OTHERINFO.
    public var kind: String
    public var assetClass: AssetClass
    public var unitPrice: Decimal?
    public var priceDate: Date?

    /// The symbol a security object gets: the ticker, else the unique ID.
    public var symbol: String { (ticker?.isEmpty == false ? ticker! : uniqueID).uppercased() }
}

/// A buy, sell or reinvestment in an OFX investment statement.
public struct OFXTrade: Sendable, Hashable {
    public var fitID: String?
    public var date: Date
    public var side: TradeSide
    /// The OFX aggregate: BUYSTOCK, SELLMF, REINVEST, …
    public var kind: String
    public var securityID: String
    /// Units, positive (OFX writes sales as negative units).
    public var units: Decimal
    public var unitPrice: Decimal
    /// COMMISSION + FEES + TAXES + LOAD.
    public var fees: Decimal
    /// TOTAL as stated, signed as the broker wrote it.
    public var total: Decimal?
    public var memo: String?
    public var currency: Currency
}

/// Dividend, interest or capital-gain income paid in cash (OFX INCOME).
public struct OFXIncome: Sendable, Hashable {
    public var fitID: String?
    public var date: Date
    public var securityID: String?
    /// DIV, INTEREST, CGLONG, CGSHORT or MISC.
    public var incomeType: String
    public var total: Money
    public var memo: String?
}

/// A position the broker states (INVPOS inside POSSTOCK, POSMF, …).
public struct OFXPosition: Sendable, Hashable {
    public var securityID: String
    public var units: Decimal
    public var unitPrice: Decimal?
    public var marketValue: Money?
    public var priceDate: Date?
    /// LONG or SHORT.
    public var positionType: String?
}

/// One brokerage statement (INVSTMTRS) read from an OFX file.
public struct OFXInvestmentStatement: Sendable, Hashable {
    public var accountID: String
    public var brokerID: String?
    public var currency: Currency
    public var organization: String?
    public var asOf: Date?
    public var startDate: Date?
    public var endDate: Date?
    public var trades: [OFXTrade]
    public var income: [OFXIncome]
    /// Cash movements (INVBANKTRAN): deposits, withdrawals, fees.
    public var cash: [TransactionDraft]
    public var positions: [OFXPosition]
    public var availableCash: Money?
    /// Securities from the file's SECLIST, by unique ID.
    public var securities: [String: OFXSecurity]
}

extension OFX {
    static let buyAggregates: Set<String> = ["BUYSTOCK", "BUYMF", "BUYDEBT", "BUYOPT", "BUYOTHER"]
    static let sellAggregates: Set<String> = ["SELLSTOCK", "SELLMF", "SELLDEBT", "SELLOPT", "SELLOTHER"]
    static let positionAggregates: Set<String> = ["POSSTOCK", "POSMF", "POSDEBT", "POSOPT", "POSOTHER"]
    static let securityAggregates: Set<String> = ["STOCKINFO", "MFINFO", "DEBTINFO", "OPTINFO", "OTHERINFO"]

    /// Every investment statement (INVSTMTRS) in the file. Empty when it has none.
    public static func investmentStatements(_ text: String) throws -> [OFXInvestmentStatement] {
        try investmentStatements(parse(text))
    }

    static func investmentStatements(_ root: OFXElement) throws -> [OFXInvestmentStatement] {
        let organization = root.first("FI")?["ORG"]
        let securities = Dictionary(
            try root.all("SECLIST").flatMap(\.children).filter { securityAggregates.contains($0.name) }.map(security).map { ($0.uniqueID, $0) },
            uniquingKeysWith: { first, _ in first })
        return try root.all("INVSTMTRS").map { response in
            guard let from = response.child("INVACCTFROM"), let accountID = from["ACCTID"] else {
                throw FinanceError.malformedOFX("investment statement without an account ID")
            }
            let currency = try Currency(response["CURDEF"] ?? "USD")
            let list = response.child("INVTRANLIST")
            var trades: [OFXTrade] = []
            var income: [OFXIncome] = []
            var cash: [TransactionDraft] = []
            for entry in list?.children ?? [] {
                if buyAggregates.contains(entry.name) || sellAggregates.contains(entry.name) {
                    let isBuy = buyAggregates.contains(entry.name)
                    guard let detail = entry.child(isBuy ? "INVBUY" : "INVSELL") else {
                        throw FinanceError.malformedOFX("\(entry.name) without \(isBuy ? "INVBUY" : "INVSELL")")
                    }
                    trades.append(try trade(detail, kind: entry.name, side: isBuy ? .buy : .sell, currency: currency))
                } else if entry.name == "REINVEST" {
                    trades.append(try trade(entry, kind: entry.name, side: .buy, currency: currency))
                } else if entry.name == "INCOME" {
                    let (fitID, date, memo) = try invTran(entry)
                    guard let totalText = entry["TOTAL"], let total = NumberFormat.ofx.parse(totalText) else {
                        throw FinanceError.malformedOFX("INCOME without a valid TOTAL (\(fitID ?? "?"))")
                    }
                    let entryCurrency = try entry.child("CURRENCY")?["CURSYM"].map(Currency.init) ?? currency
                    income.append(
                        OFXIncome(
                            fitID: fitID, date: date, securityID: entry.child("SECID")?["UNIQUEID"], incomeType: entry["INCOMETYPE"] ?? "MISC",
                            total: Money(total, entryCurrency), memo: memo
                        ))
                } else if entry.name == "INVBANKTRAN", let transaction = entry.child("STMTTRN") {
                    cash.append(try statementTransaction(transaction, currency: currency))
                }
            }
            let positions = try (response.child("INVPOSLIST")?.children ?? []).filter { positionAggregates.contains($0.name) }.map { aggregate in
                guard let position = aggregate.child("INVPOS"), let id = position.child("SECID")?["UNIQUEID"], let unitsText = position["UNITS"],
                    let units = NumberFormat.ofx.parse(unitsText)
                else { throw FinanceError.malformedOFX("\(aggregate.name) without SECID or UNITS") }
                return OFXPosition(
                    securityID: id, units: units, unitPrice: position["UNITPRICE"].flatMap(NumberFormat.ofx.parse),
                    marketValue: position["MKTVAL"].flatMap(NumberFormat.ofx.parse).map { Money($0, currency) },
                    priceDate: position["DTPRICEASOF"].flatMap(date), positionType: position["POSTYPE"]
                )
            }
            return OFXInvestmentStatement(
                accountID: accountID, brokerID: from["BROKERID"], currency: currency, organization: organization,
                asOf: response["DTASOF"].flatMap(date), startDate: list?["DTSTART"].flatMap(date), endDate: list?["DTEND"].flatMap(date),
                trades: trades, income: income, cash: cash, positions: positions,
                availableCash: response.child("INVBAL")?["AVAILCASH"].flatMap(NumberFormat.ofx.parse).map { Money($0, currency) },
                securities: securities
            )
        }
    }

    static func invTran(_ entry: OFXElement) throws -> (fitID: String?, date: Date, memo: String?) {
        let tran = entry.child("INVTRAN")
        guard let text = tran?["DTTRADE"], let date = date(text) else {
            throw FinanceError.malformedOFX("\(entry.name) without a valid DTTRADE (\(tran?["FITID"] ?? "?"))")
        }
        return (tran?["FITID"], date, tran?["MEMO"])
    }

    static func trade(_ detail: OFXElement, kind: String, side: TradeSide, currency: Currency) throws -> OFXTrade {
        let (fitID, date, memo) = try invTran(detail)
        guard let securityID = detail.child("SECID")?["UNIQUEID"] else { throw FinanceError.malformedOFX("\(kind) without SECID (\(fitID ?? "?"))") }
        guard let unitsText = detail["UNITS"], let units = NumberFormat.ofx.parse(unitsText), units != 0 else {
            throw FinanceError.malformedOFX("\(kind) without valid UNITS (\(fitID ?? "?"))")
        }
        guard let priceText = detail["UNITPRICE"], let price = NumberFormat.ofx.parse(priceText) else {
            throw FinanceError.malformedOFX("\(kind) without a valid UNITPRICE (\(fitID ?? "?"))")
        }
        let fees = ["COMMISSION", "FEES", "TAXES", "LOAD"].compactMap { detail[$0].flatMap(NumberFormat.ofx.parse) }.reduce(0, +)
        let tradeCurrency = try detail.child("CURRENCY")?["CURSYM"].map(Currency.init) ?? currency
        return OFXTrade(
            fitID: fitID, date: date, side: side, kind: kind, securityID: securityID, units: units.magnitude, unitPrice: price.magnitude, fees: fees,
            total: detail["TOTAL"].flatMap(NumberFormat.ofx.parse), memo: memo, currency: tradeCurrency
        )
    }

    static func statementTransaction(_ entry: OFXElement, currency: Currency) throws -> TransactionDraft {
        guard let posted = entry["DTPOSTED"], let date = date(posted) else {
            throw FinanceError.malformedOFX("STMTTRN without a valid DTPOSTED (\(entry["FITID"] ?? "?"))")
        }
        guard let amountText = entry["TRNAMT"], let amount = NumberFormat.ofx.parse(amountText) else {
            throw FinanceError.malformedOFX("STMTTRN without a valid TRNAMT (\(entry["FITID"] ?? "?"))")
        }
        let entryCurrency = try entry.child("CURRENCY")?["CURSYM"].map(Currency.init) ?? currency
        let payee = entry["NAME"] ?? entry.child("PAYEE")?["NAME"] ?? entry["MEMO"] ?? ""
        return TransactionDraft(
            date: date, amount: Money(amount, entryCurrency), payee: payee, memo: entry["MEMO"], fitID: entry["FITID"],
            checkNumber: entry["CHECKNUM"], type: entry["TRNTYPE"]
        )
    }

    static func security(_ aggregate: OFXElement) throws -> OFXSecurity {
        guard let info = aggregate.child("SECINFO"), let id = info.child("SECID")?["UNIQUEID"] else {
            throw FinanceError.malformedOFX("\(aggregate.name) without SECINFO/SECID")
        }
        let assetClass: AssetClass
        let stated = (aggregate["ASSETCLASS"] ?? "").uppercased()
        switch aggregate.name {
        case "DEBTINFO": assetClass = .fixedIncome
        case "OPTINFO", "OTHERINFO": assetClass = .other
        default:
            if stated.contains("BOND") {
                assetClass = .fixedIncome
            } else if stated.contains("MONEYMRKT") {
                assetClass = .cash
            } else if aggregate.name == "STOCKINFO" || stated.contains("STOCK") {
                assetClass = .equity
            } else {
                // A fund without a stated asset class could hold anything.
                assetClass = .other
            }
        }
        return OFXSecurity(
            uniqueID: id, uniqueIDType: info.child("SECID")?["UNIQUEIDTYPE"], ticker: info["TICKER"], name: info["SECNAME"] ?? info["TICKER"] ?? id,
            kind: aggregate.name, assetClass: assetClass, unitPrice: info["UNITPRICE"].flatMap(NumberFormat.ofx.parse),
            priceDate: info["DTASOF"].flatMap(date)
        )
    }
}
