import Foundation
import NexusCore
import NexusModel

// Finance terms on NexusModel's open vocabularies. Accounts, transactions,
// categories, budgets, securities, holdings, trades and scenarios are ordinary
// objects in the shared store. Import files are `document` objects whose
// bytes are a blob. Nothing here keeps state of its own.

extension ObjectType {
    /// A bank, card, loan, cash or brokerage account.
    public static let account: ObjectType = "account"
    /// One posted transaction on an account.
    public static let transaction: ObjectType = "transaction"
    /// A spending, income or transfer category.
    public static let transactionCategory: ObjectType = "transactionCategory"
    /// A categorisation rule (payee contains, amount range, account).
    public static let categoryRule: ObjectType = "categoryRule"
    /// A monthly budget with one amount per category.
    public static let budget: ObjectType = "budget"
    /// A detected series of recurring transactions (derived).
    public static let recurringSeries: ObjectType = "recurringSeries"
    /// A forecast scenario: assumptions (claimed) and a projection (modeled).
    public static let financialScenario: ObjectType = "financialScenario"
    /// A tradable instrument (stock, fund, bond, coin).
    public static let security: ObjectType = "security"
    /// One security held in one account.
    public static let holding: ObjectType = "holding"
    /// A buy or sell of a security.
    public static let trade: ObjectType = "trade"
}

extension RelationKind {
    /// Transaction or trade → the account it posted to.
    public static let postedTo: RelationKind = "postedTo"
    /// Account → holding.
    public static let holds: RelationKind = "holds"
    /// Holding or trade → security.
    public static let ofSecurity: RelationKind = "ofSecurity"
    /// Scenario → account whose balance it projects.
    public static let projects: RelationKind = "projects"
}

extension EventKind {
    /// A statement file was imported. Payload: counts of created and duplicate rows.
    public static let statementImported: EventKind = "statementImported"
    /// A price for a security at a time.
    public static let priceQuote: EventKind = "priceQuote"
    /// A statement or a person stated an account's balance.
    public static let balanceStated: EventKind = "balanceStated"
}

/// Attribute and payload keys used on finance objects.
public enum FinanceKey {
    public static let kind = "kind"
    public static let currency = "currency"
    public static let institution = "institution"
    public static let accountNumber = "accountNumber"
    public static let bankID = "bankID"
    public static let balance = "balance"
    public static let balanceAsOf = "balanceAsOf"
    public static let account = "account"
    public static let date = "date"
    public static let amount = "amount"
    public static let payee = "payee"
    public static let memo = "memo"
    public static let fitID = "fitID"
    public static let checkNumber = "checkNumber"
    public static let transactionType = "transactionType"
    /// Occurrence-numbered (date, amount, payee) hash used for dedup.
    public static let contentKey = "contentKey"
    /// A transaction's category: a reference with its own provenance.
    public static let category = "category"
    public static let parent = "parent"
    public static let blob = "blob"
    public static let mediaType = "mediaType"
    public static let format = "format"
    /// The CSV column mapping remembered on an account.
    public static let csvMapping = "csvMapping"
    // Rules
    public static let payeeContains = "payeeContains"
    public static let minimumAmount = "minimumAmount"
    public static let maximumAmount = "maximumAmount"
    public static let direction = "direction"
    public static let priority = "priority"
    // Budgets
    public static let month = "month"
    public static let lines = "lines"
    // Recurring
    public static let cadence = "cadence"
    public static let seriesKey = "seriesKey"
    public static let lastDate = "lastDate"
    public static let nextDate = "nextDate"
    public static let occurrences = "occurrences"
    public static let amountVaries = "amountVaries"
    // Scenarios
    public static let accounts = "accounts"
    public static let startMonth = "startMonth"
    public static let months = "months"
    public static let includeRecurring = "includeRecurring"
    public static let assumptions = "assumptions"
    public static let projection = "projection"
    // Investments
    public static let symbol = "symbol"
    public static let assetClass = "assetClass"
    public static let security = "security"
    public static let side = "side"
    public static let quantity = "quantity"
    public static let price = "price"
    public static let fees = "fees"
    public static let costBasis = "costBasis"
    /// A security's CUSIP or ISIN from a statement.
    public static let uniqueID = "uniqueID"
    /// A position as the broker stated it (recorded), beside the derived quantity.
    public static let statedQuantity = "statedQuantity"
    public static let statedMarketValue = "statedMarketValue"
    public static let statedAsOf = "statedAsOf"
    // Budgets: carry each category's unspent (or overspent) amount into the next month.
    public static let rollover = "rollover"
}

public enum AccountKind: String, Codable, Sendable, CaseIterable {
    case checking
    case savings
    case creditCard
    case loan
    case brokerage
    case retirement
    case cash
    case other
}

public enum CategoryKind: String, Codable, Sendable, CaseIterable {
    case expense
    case income
    /// Money moving between the person's own accounts; left out of cash flow.
    case transfer
}

public enum AssetClass: String, Codable, Sendable, CaseIterable {
    case cash
    case equity
    case fixedIncome
    case realEstate
    case commodity
    case crypto
    case other
}

public enum FinanceError: Error, Equatable, Sendable {
    case notFound(ObjectID, expected: ObjectType)
    case missingField(ObjectID, String)
    /// A modeled, claimed or interpreted value was offered where only
    /// recorded or observed truth belongs (an account balance, a budget actual).
    case truthNotAllowed(TruthClass, field: String)
    case malformedCSV(line: Int, reason: String)
    case malformedOFX(String)
    case unparsableDate(String, line: Int)
    case unparsableAmount(String, line: Int)
    case unknownColumn(String)
    case insufficientQuantity(available: Decimal, requested: Decimal)
    case invalidQuantity(Decimal)
    case missingBalance(ObjectID)
    case duplicateSymbol(String)
    /// A form field that must be filled was left blank.
    case missingInput(String)
}

/// The calendar all finance dates use: Gregorian in UTC. A posted date is a
/// calendar day, stored as midnight UTC, so it never shifts with the device's time zone.
public enum FinanceCalendar {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    public static func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(start), to: startOfDay(end)).day ?? 0
    }

    public static func adding(days: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }

    public static func adding(months: Int, to date: Date) -> Date { calendar.date(byAdding: .month, value: months, to: date)! }

    /// "2026-09-05".
    public static func isoDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// A calendar month, the period budgets and cash-flow statements use.
public struct YearMonth: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init(_ year: Int, _ month: Int) {
        precondition((1...12).contains(month), "month must be 1...12")
        self.year = year
        self.month = month
    }

    public init(_ date: Date) {
        let parts = FinanceCalendar.calendar.dateComponents([.year, .month], from: date)
        self.init(parts.year!, parts.month!)
    }

    /// Parses "2026-09".
    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        self.init(year, month)
    }

    public var start: Date { FinanceCalendar.day(year, month, 1) }
    /// The first instant of the following month (exclusive end).
    public var end: Date { next.start }
    public var interval: DateInterval { DateInterval(start: start, end: end) }
    public var next: YearMonth { adding(1) }

    public func adding(_ months: Int) -> YearMonth {
        let index = year * 12 + (month - 1) + months
        return YearMonth(index / 12, index % 12 + 1)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public var description: String { String(format: "%04d-%02d", year, month) }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool { (lhs.year, lhs.month) < (rhs.year, rhs.month) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = YearMonth(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid month \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Store encoding

extension Money {
    /// Stored as `{amount: "-12.5", currency: "USD"}`: the decimal stays a
    /// string, so no binary float ever touches a stored amount.
    public var value: Value { .map(["amount": .string(amount.plainString), "currency": .string(currency.code)]) }

    public init?(_ value: Value?) {
        guard case .map(let fields)? = value, case .string(let text)? = fields["amount"], case .string(let code)? = fields["currency"],
            let amount = Decimal(exactly: text), let currency = try? Currency(code)
        else { return nil }
        self.init(amount, currency)
    }
}

extension Decimal {
    public var value: Value { .string(plainString) }

    public init?(_ value: Value?) {
        guard case .string(let text)? = value, let decimal = Decimal(exactly: text) else { return nil }
        self = decimal
    }
}

extension ObjectRecord {
    func string(_ key: String) -> String? {
        if case .string(let text)? = attributes[key]?.value { return text }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let date)? = attributes[key]?.value { return date }
        return nil
    }

    func reference(_ key: String) -> ObjectID? {
        if case .reference(let id)? = attributes[key]?.value { return id }
        return nil
    }

    func money(_ key: String) -> Money? { Money(attributes[key]?.value) }

    func decimal(_ key: String) -> Decimal? { Decimal(attributes[key]?.value) }

    func int(_ key: String) -> Int? {
        if case .int(let number)? = attributes[key]?.value { return Int(number) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let flag)? = attributes[key]?.value { return flag }
        return nil
    }
}

/// Normalises a payee for matching: upper case, letters and digits only, single spaces.
public func normalizedPayee(_ payee: String) -> String {
    String(payee.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
}
