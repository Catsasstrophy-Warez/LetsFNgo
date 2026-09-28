import Foundation

/// How a statement writes numbers: which character separates decimals and
/// which groups thousands.
public struct NumberFormat: Sendable, Hashable {
    public var decimalSeparator: Character
    /// Grouping separators to strip. A space also strips no-break and narrow no-break spaces.
    public var groupingSeparators: Set<Character>

    public init(decimalSeparator: Character, groupingSeparators: Set<Character>) {
        self.decimalSeparator = decimalSeparator
        self.groupingSeparators = groupingSeparators
    }

    /// Uses the locale's own separators ("de_DE": "," and ".").
    public init(locale: Locale) {
        let decimal = locale.decimalSeparator?.first ?? "."
        var grouping = Set(locale.groupingSeparator ?? "")
        grouping.remove(decimal)
        self.init(decimalSeparator: decimal, groupingSeparators: grouping)
    }

    /// 1,234.56
    public static let us = NumberFormat(decimalSeparator: ".", groupingSeparators: [","])
    /// 1.234,56
    public static let european = NumberFormat(decimalSeparator: ",", groupingSeparators: ["."])
    /// 1 234,56
    public static let french = NumberFormat(decimalSeparator: ",", groupingSeparators: [" "])
    /// 1'234.56
    public static let swiss = NumberFormat(decimalSeparator: ".", groupingSeparators: ["'", "’"])

    /// Parses a statement amount into an exact decimal. Accepts a leading or
    /// trailing sign, accounting parentheses "(12.50)", a trailing "CR"/"DR",
    /// and currency symbols or codes around the number. Anything else throws.
    public func parse(_ text: String) -> Decimal? {
        let spaces: Set<Character> = ["\u{00A0}", "\u{202F}", " ", "\t"]
        func isAffix(_ character: Character) -> Bool { character.isCurrencySymbol || spaces.contains(character) }
        func isCode(_ text: Substring) -> Bool { text.count == 3 && text.allSatisfy { $0.isASCII && $0.isUppercase } }
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var negative = false
        // "12.50 DR" / "12.50CR", but not a currency code such as IDR.
        let upper = body.uppercased()
        if upper.hasSuffix("DR") || upper.hasSuffix("CR") {
            let before = body.dropLast(2).last
            if before.map({ !$0.isLetter }) ?? false {
                if upper.hasSuffix("DR") { negative = true }
                body = body.dropLast(2)
            }
        }
        // Currency symbols and ISO codes around the number: "$12.50", "12,50 €", "EUR 12.50".
        func stripAffixes() {
            var changed = true
            while changed {
                changed = false
                while let first = body.first, isAffix(first) {
                    body = body.dropFirst()
                    changed = true
                }
                while let last = body.last, isAffix(last) {
                    body = body.dropLast()
                    changed = true
                }
                if isCode(body.prefix(3)), body.dropFirst(3).first.map({ !$0.isLetter }) ?? false {
                    body = body.dropFirst(3)
                    changed = true
                }
                if isCode(body.suffix(3)), body.dropLast(3).last.map({ !$0.isLetter }) ?? false {
                    body = body.dropLast(3)
                    changed = true
                }
            }
        }
        stripAffixes()
        if body.first == "(", body.last == ")" {
            negative.toggle()
            body = body.dropFirst().dropLast()
            stripAffixes()
        }
        guard !body.isEmpty else { return nil }
        var grouping = groupingSeparators
        if grouping.contains(" ") { grouping.formUnion(spaces) }
        var cleaned = ""
        for character in body {
            if character.isASCII && character.isNumber {
                cleaned.append(character)
            } else if character == decimalSeparator {
                cleaned.append(".")
            } else if grouping.contains(character) {
                continue
            } else if character == "-" || character == "+" || character == "\u{2212}" {
                cleaned.append(character == "+" ? "+" : "-")
            } else if spaces.contains(character) {
                continue
            } else {
                return nil
            }
        }
        // A trailing sign: "12.00-".
        if cleaned.hasSuffix("-"), !cleaned.hasPrefix("-") {
            cleaned = "-" + cleaned.dropLast()
        } else if cleaned.hasSuffix("+"), !cleaned.hasPrefix("+") {
            cleaned = String(cleaned.dropLast())
        }
        guard var value = Decimal(exactly: cleaned) else { return nil }
        if negative { value = -value }
        return value
    }
}

extension Character {
    fileprivate var isCurrencySymbol: Bool { unicodeScalars.allSatisfy { $0.properties.generalCategory == .currencySymbol } }
}

/// A column by position (0-based) or by header name (case-insensitive).
public enum CSVColumn: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case index(Int)
    case header(String)

    public init(stringLiteral value: String) { self = .header(value) }
    public init(integerLiteral value: Int) { self = .index(value) }
}

/// Where a CSV bank statement keeps each field, and how it writes dates and numbers.
public struct CSVMapping: Sendable, Hashable {
    public enum Amount: Sendable, Hashable {
        /// One signed column.
        case signed(CSVColumn)
        /// Separate debit (out) and credit (in) columns, both written positive.
        case debitCredit(debit: CSVColumn, credit: CSVColumn)
    }

    public var date: CSVColumn
    public var amount: Amount
    public var payee: CSVColumn
    public var memo: CSVColumn?
    public var fitID: CSVColumn?
    public var type: CSVColumn?
    /// A running-balance column. The balance on the latest row becomes the
    /// account's stated balance (recorded, pointing at the file).
    public var balance: CSVColumn?
    /// A `DateFormatter` pattern, e.g. "yyyy-MM-dd", "dd.MM.yyyy", "MM/dd/yyyy", "d MMM yyyy".
    public var dateFormat: String
    /// Locale for month names in dates ("5 Sept. 2026" in en_GB, "5. Sept. 2026" in de_DE).
    public var dateLocale: Locale
    public var numberFormat: NumberFormat
    public var delimiter: Character
    public var hasHeader: Bool
    /// Card exports often write purchases as positive numbers; this flips the sign.
    public var invertSign: Bool

    public init(
        date: CSVColumn, amount: Amount, payee: CSVColumn, memo: CSVColumn? = nil, fitID: CSVColumn? = nil, type: CSVColumn? = nil,
        balance: CSVColumn? = nil, dateFormat: String = "yyyy-MM-dd", dateLocale: Locale = Locale(identifier: "en_US_POSIX"), numberFormat: NumberFormat = .us,
        delimiter: Character = ",", hasHeader: Bool = true, invertSign: Bool = false
    ) {
        self.date = date
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.fitID = fitID
        self.type = type
        self.balance = balance
        self.dateFormat = dateFormat
        self.dateLocale = dateLocale
        self.numberFormat = numberFormat
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.invertSign = invertSign
    }
}

/// RFC 4180 CSV: quoted fields, doubled quotes, delimiters and line breaks
/// inside quotes, CRLF or LF, and a leading byte-order mark.
public enum CSV {
    /// Rows of fields with their 1-based starting line numbers. Blank lines are skipped.
    public static func parse(_ text: String, delimiter: Character = ",") throws -> [(line: Int, fields: [String])] {
        var rows: [(line: Int, fields: [String])] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var quotedField = false
        var line = 1
        var rowStart = 1
        var characters = Array(text)
        if characters.first == "\u{FEFF}" { characters.removeFirst() }
        var index = 0
        func endRow() {
            fields.append(field)
            if !(fields.count == 1 && fields[0].isEmpty && !quotedField) { rows.append((rowStart, fields)) }
            fields = []
            field = ""
            quotedField = false
        }
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character == "\n" || character == "\r\n" { line += 1 }
                    field.append(character)
                }
            } else if character == "\"" {
                guard field.isEmpty else { throw FinanceError.malformedCSV(line: line, reason: "quote inside an unquoted field") }
                inQuotes = true
                quotedField = true
            } else if character == delimiter {
                fields.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                endRow()
                line += 1
                rowStart = line
            } else {
                field.append(character)
            }
            index += 1
        }
        if inQuotes { throw FinanceError.malformedCSV(line: rowStart, reason: "unterminated quoted field") }
        if !field.isEmpty || !fields.isEmpty || quotedField { endRow() }
        return rows
    }

    /// Reads statement rows into transaction drafts with `mapping`.
    public static func transactions(_ text: String, mapping: CSVMapping, currency: Currency) throws -> [(line: Int, draft: TransactionDraft)] {
        try statementRows(text, mapping: mapping, currency: currency).map { ($0.line, $0.draft) }
    }

    /// Reads statement rows with their running balance, when the mapping has one.
    public static func statementRows(_ text: String, mapping: CSVMapping, currency: Currency) throws -> [CSVStatementRow] {
        let reader = try CSVRowReader(text, mapping: mapping, currency: currency)
        return try reader.rows.map { try reader.read($0.line, $0.fields) }
    }

    /// Reads up to `limit` rows, keeping each row's error instead of stopping
    /// at the first one, so a mapping can be previewed before anything is stored.
    public static func preview(_ text: String, mapping: CSVMapping, currency: Currency, limit: Int = 10) throws -> [CSVPreviewRow] {
        let reader = try CSVRowReader(text, mapping: mapping, currency: currency)
        return reader.rows.prefix(limit).map { line, fields in
            do {
                return CSVPreviewRow(line: line, fields: fields, result: .success(try reader.read(line, fields)))
            } catch let error as FinanceError {
                return CSVPreviewRow(line: line, fields: fields, result: .failure(error))
            } catch {
                return CSVPreviewRow(line: line, fields: fields, result: .failure(.malformedCSV(line: line, reason: "\(error)")))
            }
        }
    }

    /// The balance the statement ends on: the running balance on its latest
    /// row. Banks list rows newest first or oldest first; among rows on the
    /// latest day, the one written last in time order wins.
    public static func closingBalance(_ rows: [CSVStatementRow]) -> (balance: Money, date: Date)? {
        let withBalance = rows.filter { $0.balance != nil }
        guard let latest = withBalance.map(\.draft.date).max(), let first = rows.first, let last = rows.last else { return nil }
        let newestFirst = first.draft.date > last.draft.date
        let sameDay = withBalance.filter { $0.draft.date == latest }
        guard let row = newestFirst ? sameDay.first : sameDay.last, let balance = row.balance else { return nil }
        return (balance, latest)
    }
}

/// One CSV row read with a mapping.
public struct CSVStatementRow: Sendable, Hashable {
    public var line: Int
    public var draft: TransactionDraft
    /// The running balance after this row, when the mapping has a balance column.
    public var balance: Money?
}

/// One row of a mapping preview: the raw fields and what they read as.
public struct CSVPreviewRow: Sendable {
    public var line: Int
    public var fields: [String]
    public var result: Result<CSVStatementRow, FinanceError>

    public var row: CSVStatementRow? { try? result.get() }

    public var error: FinanceError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

/// Resolves a mapping's columns once, then reads rows with it.
struct CSVRowReader {
    let mapping: CSVMapping
    let currency: Currency
    let rows: [(line: Int, fields: [String])]
    let dateIndex: Int
    let payeeIndex: Int
    let memoIndex: Int?
    let fitIndex: Int?
    let typeIndex: Int?
    let balanceIndex: Int?
    let amountIndexes: (Int, Int?)
    let formatter: DateFormatter

    init(_ text: String, mapping: CSVMapping, currency: Currency) throws {
        self.mapping = mapping
        self.currency = currency
        var rows = try CSV.parse(text, delimiter: mapping.delimiter)
        var headers: [String: Int] = [:]
        if mapping.hasHeader, !rows.isEmpty {
            for (index, name) in rows.removeFirst().fields.enumerated() {
                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                if headers[key] == nil { headers[key] = index }
            }
        }
        self.rows = rows
        func resolve(_ column: CSVColumn) throws -> Int {
            switch column {
            case .index(let index): return index
            case .header(let name):
                guard let index = headers[name.trimmingCharacters(in: .whitespaces).lowercased()] else { throw FinanceError.unknownColumn(name) }
                return index
            }
        }
        dateIndex = try resolve(mapping.date)
        payeeIndex = try resolve(mapping.payee)
        memoIndex = try mapping.memo.map(resolve)
        fitIndex = try mapping.fitID.map(resolve)
        typeIndex = try mapping.type.map(resolve)
        balanceIndex = try mapping.balance.map(resolve)
        switch mapping.amount {
        case .signed(let column): amountIndexes = (try resolve(column), nil)
        case .debitCredit(let debit, let credit): amountIndexes = (try resolve(debit), try resolve(credit))
        }

        formatter = DateFormatter()
        formatter.locale = mapping.dateLocale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = FinanceCalendar.calendar
        formatter.dateFormat = mapping.dateFormat
        formatter.isLenient = false
    }

    func read(_ line: Int, _ fields: [String]) throws -> CSVStatementRow {
        func field(_ index: Int?) -> String? {
            guard let index, index < fields.count else { return nil }
            let text = fields[index].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        func number(_ text: String) throws -> Decimal {
            guard let value = mapping.numberFormat.parse(text) else { throw FinanceError.unparsableAmount(text, line: line) }
            return value
        }
        guard let dateText = field(dateIndex) else { throw FinanceError.unparsableDate("", line: line) }
        guard let date = formatter.date(from: dateText) else { throw FinanceError.unparsableDate(dateText, line: line) }
        var amount: Decimal
        switch amountIndexes {
        case (let index, nil):
            amount = try number(field(index) ?? "")
        case (let debitIndex, let creditIndex?):
            let debitText = field(debitIndex)
            let creditText = field(creditIndex)
            guard debitText != nil || creditText != nil else { throw FinanceError.unparsableAmount("", line: line) }
            let debit = try debitText.map(number) ?? 0
            let credit = try creditText.map(number) ?? 0
            amount = credit.magnitude - debit.magnitude
        }
        if mapping.invertSign { amount = -amount }
        let balance = try field(balanceIndex).map { Money(try number($0), currency) }
        let draft = TransactionDraft(
            date: date, amount: Money(amount, currency), payee: field(payeeIndex) ?? "", memo: field(memoIndex), fitID: field(fitIndex),
            type: field(typeIndex)
        )
        return CSVStatementRow(line: line, draft: draft, balance: balance)
    }
}
