import Foundation
import NexusCore
import NexusModel
import NexusPersistence

// Column mapping for CSV statements: a guess from the file's headers and
// contents, a draft the person corrects, and the draft remembered on the
// account so the next export from the same bank maps itself.

/// What a CSV column holds.
public enum CSVField: String, CaseIterable, Sendable, Codable {
    case date
    /// One signed amount column.
    case amount
    /// Money out, written positive.
    case debit
    /// Money in, written positive.
    case credit
    case payee
    case memo
    /// The running balance after the row.
    case balance
    /// The bank's own transaction ID.
    case fitID
    case type

    public var label: String {
        switch self {
        case .date: "Date"
        case .amount: "Amount (signed)"
        case .debit: "Debit (money out)"
        case .credit: "Credit (money in)"
        case .payee: "Payee"
        case .memo: "Memo"
        case .balance: "Balance"
        case .fitID: "Transaction ID"
        case .type: "Type"
        }
    }
}

/// The number conventions a statement can use.
public enum CSVNumberStyle: String, CaseIterable, Sendable, Codable {
    /// 1,234.56
    case us
    /// 1.234,56
    case european
    /// 1 234,56
    case french
    /// 1'234.56
    case swiss

    public var format: NumberFormat {
        switch self {
        case .us: .us
        case .european: .european
        case .french: .french
        case .swiss: .swiss
        }
    }

    public var example: String {
        switch self {
        case .us: "1,234.56"
        case .european: "1.234,56"
        case .french: "1 234,56"
        case .swiss: "1'234.56"
        }
    }
}

/// A column mapping as the person edits it: one field per column, with
/// the date pattern and the number and sign conventions. It becomes a
/// `CSVMapping` for import and is remembered on the account.
public struct CSVMappingDraft: Sendable, Hashable {
    public var delimiter: Character
    public var hasHeader: Bool
    /// The column (0-based) holding each field.
    public var columns: [CSVField: Int]
    /// The header names when the mapping was made, used to find the same
    /// columns in a later file whose columns moved.
    public var headers: [String]
    public var dateFormat: String
    /// Locale identifier for month names in dates.
    public var dateLocale: String
    public var numberStyle: CSVNumberStyle
    /// Card exports often write purchases as positive numbers.
    public var invertSign: Bool

    public init(
        delimiter: Character = ",", hasHeader: Bool = true, columns: [CSVField: Int] = [:], headers: [String] = [], dateFormat: String = "yyyy-MM-dd",
        dateLocale: String = "en_US_POSIX", numberStyle: CSVNumberStyle = .us, invertSign: Bool = false
    ) {
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.columns = columns
        self.headers = headers
        self.dateFormat = dateFormat
        self.dateLocale = dateLocale
        self.numberStyle = numberStyle
        self.invertSign = invertSign
    }

    /// The field mapped to a column, if any.
    public func field(at column: Int) -> CSVField? {
        columns.first { $0.value == column }?.key
    }

    /// Maps `column` to `field` (nil clears it). A column holds one field, a
    /// field sits in one column, and a signed amount excludes debit/credit
    /// columns (and the reverse).
    public mutating func assign(_ field: CSVField?, to column: Int) {
        for (key, value) in columns where value == column { columns[key] = nil }
        guard let field else { return }
        columns[field] = column
        switch field {
        case .amount:
            columns[.debit] = nil
            columns[.credit] = nil
        case .debit, .credit:
            columns[.amount] = nil
        default: break
        }
    }

    /// Fields that must be mapped before an import can run.
    public var missing: [CSVField] {
        var missing: [CSVField] = []
        if columns[.date] == nil { missing.append(.date) }
        if columns[.amount] == nil {
            switch (columns[.debit], columns[.credit]) {
            case (nil, nil): missing.append(.amount)
            case (nil, _): missing.append(.debit)
            case (_, nil): missing.append(.credit)
            default: break
            }
        }
        if columns[.payee] == nil && columns[.memo] == nil { missing.append(.payee) }
        return missing
    }

    public var isComplete: Bool { missing.isEmpty }

    /// The import mapping. When no payee column is mapped the memo stands in.
    public func mapping() throws -> CSVMapping {
        if let field = missing.first { throw FinanceError.unknownColumn(field.label) }
        let amount: CSVMapping.Amount
        if let signed = columns[.amount] {
            amount = .signed(.index(signed))
        } else {
            amount = .debitCredit(debit: .index(columns[.debit]!), credit: .index(columns[.credit]!))
        }
        let payee = columns[.payee] ?? columns[.memo]!
        return CSVMapping(
            date: .index(columns[.date]!), amount: amount, payee: .index(payee), memo: columns[.payee] == nil ? nil : columns[.memo].map(CSVColumn.index),
            fitID: columns[.fitID].map(CSVColumn.index), type: columns[.type].map(CSVColumn.index), balance: columns[.balance].map(CSVColumn.index),
            dateFormat: dateFormat, dateLocale: Locale(identifier: dateLocale), numberFormat: numberStyle.format, delimiter: delimiter,
            hasHeader: hasHeader, invertSign: invertSign
        )
    }

    /// The same mapping for a file whose header row is `newHeaders`: each
    /// field follows its header name when the file has it, else keeps its
    /// position when that still exists.
    public func adapted(to newHeaders: [String]) -> CSVMappingDraft {
        var copy = self
        let lookup = Dictionary(newHeaders.enumerated().map { (CSVMappingGuesser.normalized($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        copy.columns = [:]
        for (field, index) in columns {
            if index < headers.count {
                if let moved = lookup[CSVMappingGuesser.normalized(headers[index])] { copy.columns[field] = moved }
            } else if index < newHeaders.count {
                copy.columns[field] = index
            }
        }
        copy.headers = newHeaders
        return copy
    }

    // MARK: Store encoding

    public var value: Value {
        .map([
            "delimiter": .string(String(delimiter)),
            "hasHeader": .bool(hasHeader),
            "columns": .map(Dictionary(uniqueKeysWithValues: columns.map { ($0.key.rawValue, Value.int(Int64($0.value))) })),
            "headers": .list(headers.map(Value.string)),
            "dateFormat": .string(dateFormat),
            "dateLocale": .string(dateLocale),
            "numberStyle": .string(numberStyle.rawValue),
            "invertSign": .bool(invertSign),
        ])
    }

    public init?(_ value: Value?) {
        guard case .map(let fields)? = value, case .string(let delimiter)? = fields["delimiter"], let character = delimiter.first,
            case .map(let columnValues)? = fields["columns"], case .string(let dateFormat)? = fields["dateFormat"]
        else { return nil }
        var columns: [CSVField: Int] = [:]
        for (key, value) in columnValues {
            if let field = CSVField(rawValue: key), case .int(let index) = value { columns[field] = Int(index) }
        }
        var headers: [String] = []
        if case .list(let values)? = fields["headers"] { headers = values.compactMap { if case .string(let text) = $0 { text } else { nil } } }
        var locale = "en_US_POSIX"
        if case .string(let text)? = fields["dateLocale"] { locale = text }
        var style = CSVNumberStyle.us
        if case .string(let text)? = fields["numberStyle"], let parsed = CSVNumberStyle(rawValue: text) { style = parsed }
        var hasHeader = true
        if case .bool(let flag)? = fields["hasHeader"] { hasHeader = flag }
        var invert = false
        if case .bool(let flag)? = fields["invertSign"] { invert = flag }
        self.init(
            delimiter: character, hasHeader: hasHeader, columns: columns, headers: headers, dateFormat: dateFormat, dateLocale: locale,
            numberStyle: style, invertSign: invert
        )
    }
}

/// A guessed mapping with what the guess was based on.
public struct CSVMappingGuess: Sendable {
    public var draft: CSVMappingDraft
    /// Column titles: the header row, or "Column 1", "Column 2", … without one.
    public var columnTitles: [String]
    /// The first data rows, as raw fields.
    public var sampleRows: [[String]]
    /// Every date pattern that reads all sampled dates, best first.
    public var dateFormatCandidates: [String]
    /// Things the person should check, in plain words.
    public var notes: [String]
    /// Whether the draft came from the mapping remembered on the account.
    public var remembered: Bool
}

/// Guesses a CSV statement's delimiter, header row, columns, date pattern
/// and number conventions. A guess only fills the form; the person confirms
/// it against a preview before anything is stored.
public enum CSVMappingGuesser {
    /// Patterns tried for dates, in order of preference.
    public static let dateFormats: [String] = [
        "yyyy-MM-dd", "yyyy/MM/dd", "yyyyMMdd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
        "MM/dd/yyyy", "M/d/yyyy", "dd/MM/yyyy", "d/M/yyyy", "dd.MM.yyyy", "d.M.yyyy", "dd-MM-yyyy", "MM-dd-yyyy",
        "d MMM yyyy", "dd MMM yyyy", "dd-MMM-yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy", "d. MMMM yyyy",
        "MM/dd/yy", "dd/MM/yy", "dd.MM.yy",
    ]
    static let dayFirst: Set<String> = ["dd/MM/yyyy", "d/M/yyyy", "dd.MM.yyyy", "d.M.yyyy", "dd-MM-yyyy", "dd/MM/yy", "dd.MM.yy"]
    static let monthFirst: Set<String> = ["MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy", "MM/dd/yy"]
    /// Locales tried for month names when the POSIX one reads nothing.
    static let dateLocales = ["en_US_POSIX", "en_GB", "de_DE", "fr_FR", "es_ES", "it_IT", "nl_NL"]
    static let delimiters: [Character] = [",", ";", "\t", "|"]

    /// Header words per field, checked in this order (lower case, accents folded).
    static let headerWords: [(CSVField, [String])] = [
        (.balance, ["balance", "saldo", "solde", "kontostand", "running"]),
        (.fitID, ["transaction id", "reference number", "ref no", "fitid", "id"]),
        (.date, ["date", "datum", "fecha", "buchungstag", "valuta", "posted", "day"]),
        (.debit, ["debit", "withdrawal", "money out", "paid out", "outflow", "soll", "ausgang", "charges"]),
        (.credit, ["credit", "deposit", "money in", "paid in", "inflow", "haben", "eingang"]),
        (.amount, ["amount", "betrag", "montant", "importe", "importo", "bedrag", "sum", "value", "amt"]),
        (.type, ["type", "typ", "art"]),
        (
            .payee,
            [
                "payee", "description", "name", "merchant", "beneficiary", "empfanger", "libelle", "counterparty", "details", "narrative",
                "concepto", "auftraggeber", "tegenpartij",
            ]
        ),
        (.memo, ["memo", "note", "reference", "verwendungszweck", "purpose", "remark", "comment", "communication", "info"]),
    ]

    /// Lower case, accents folded, punctuation as single spaces.
    public static func normalized(_ header: String) -> String {
        let folded = header.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    /// The delimiter that splits the first rows into the same number of fields (more than one).
    public static func detectDelimiter(_ text: String) -> Character {
        var best: (delimiter: Character, fields: Int, consistent: Bool) = (",", 0, false)
        for delimiter in delimiters {
            guard let rows = try? CSV.parse(text, delimiter: delimiter).prefix(20), !rows.isEmpty else { continue }
            let counts = rows.map(\.fields.count)
            let consistent = Set(counts).count == 1
            let fields = counts.max() ?? 0
            guard fields > 1 else { continue }
            if (consistent && !best.consistent) || (consistent == best.consistent && fields > best.fields) { best = (delimiter, fields, consistent) }
        }
        return best.delimiter
    }

    /// Guesses the mapping for a statement. With a mapping `remembered` for
    /// the account whose required fields all fit this file, that is used.
    public static func guess(_ text: String, accountKind: AccountKind? = nil, remembered: CSVMappingDraft? = nil) throws -> CSVMappingGuess {
        let delimiter = remembered?.delimiter ?? detectDelimiter(text)
        let rows = try CSV.parse(text, delimiter: delimiter).map(\.fields)
        guard let first = rows.first else { throw FinanceError.malformedCSV(line: 1, reason: "the file has no rows") }
        let width = rows.prefix(50).map(\.count).max() ?? first.count
        let hasHeader = looksLikeHeader(first, next: Array(rows.dropFirst().prefix(20)))
        let body = Array(rows.dropFirst(hasHeader ? 1 : 0))
        let samples = Array(body.prefix(50))
        let headers = hasHeader ? first : []
        let titles = (0..<width).map { index in index < headers.count && !headers[index].isEmpty ? headers[index] : "Column \(index + 1)" }
        func column(_ index: Int) -> [String] {
            samples.compactMap { index < $0.count ? $0[index].trimmingCharacters(in: .whitespaces) : nil }.filter { !$0.isEmpty }
        }
        var notes: [String] = []

        if let remembered, remembered.hasHeader == hasHeader {
            let adapted = hasHeader ? remembered.adapted(to: headers) : remembered
            if adapted.isComplete, adapted.columns.values.allSatisfy({ $0 < width }) {
                let dates = adapted.columns[.date].map(column) ?? []
                let candidates = dateCandidates(dates).map(\.format)
                return CSVMappingGuess(
                    draft: adapted, columnTitles: titles, sampleRows: Array(body.prefix(10)),
                    dateFormatCandidates: candidates.contains(adapted.dateFormat) ? candidates : [adapted.dateFormat] + candidates,
                    notes: ["Using the mapping saved for this account."], remembered: true
                )
            }
            notes.append("The mapping saved for this account doesn't fit this file, so it was guessed again.")
        }

        var draft = CSVMappingDraft(delimiter: delimiter, hasHeader: hasHeader, headers: headers)
        // 1. Header words.
        for (index, header) in headers.enumerated() {
            let name = normalized(header)
            guard !name.isEmpty else { continue }
            let words = Set(name.split(separator: " ").map(String.init))
            for (field, keywords) in headerWords where draft.columns[field] == nil {
                // Whole words; longer keywords also match as a prefix ("Withdrawals", "Deposits").
                let hit = keywords.contains { keyword in
                    keyword.contains(" ") ? name.contains(keyword) : words.contains(keyword) || (keyword.count >= 5 && name.hasPrefix(keyword))
                }
                if hit {
                    draft.columns[field] = index
                    break
                }
            }
        }
        // A "Debit/Credit" column naming both is one signed amount (or a type marker).
        if let debit = draft.columns[.debit], debit == draft.columns[.credit] {
            draft.columns[.debit] = nil
            draft.columns[.credit] = nil
        }
        if let debit = draft.columns[.debit], draft.columns[.credit] == nil {
            // A lone "Debit" column is not a pair.
            draft.columns[.debit] = nil
            if draft.columns[.amount] == nil { draft.columns[.amount] = debit }
        }
        if let credit = draft.columns[.credit], draft.columns[.debit] == nil {
            draft.columns[.credit] = nil
            if draft.columns[.amount] == nil { draft.columns[.amount] = credit }
        }
        if draft.columns[.debit] != nil { draft.columns[.amount] = nil }

        // 2. Contents, for fields the headers didn't name.
        let taken = { Set(draft.columns.values) }
        if draft.columns[.date] == nil {
            draft.columns[.date] = (0..<width).first { !taken().contains($0) && fraction(column($0), where: isDate) >= 0.8 }
        }
        let styleSamples = [draft.columns[.amount], draft.columns[.debit], draft.columns[.credit], draft.columns[.balance]].compactMap { $0 }
            .flatMap(column)
        let numericColumns = (0..<width).filter { index in
            !taken().contains(index) && !column(index).isEmpty && fraction(column(index), where: { looksNumeric($0) }) >= 0.9
        }
        if draft.columns[.amount] == nil && draft.columns[.debit] == nil, let index = numericColumns.first {
            draft.columns[.amount] = index
        }
        if draft.columns[.payee] == nil {
            let textual = (0..<width).filter { !taken().contains($0) }.map { index -> (Int, Double) in
                let values = column(index)
                let letters = values.map { $0.filter(\.isLetter).count }.reduce(0, +)
                return (index, values.isEmpty ? 0 : Double(letters) / Double(values.count))
            }
            if let best = textual.max(by: { $0.1 < $1.1 }), best.1 >= 2 { draft.columns[.payee] = best.0 }
        }

        // 3. Number conventions.
        let amounts =
            styleSamples.isEmpty ? [draft.columns[.amount], draft.columns[.debit], draft.columns[.credit]].compactMap { $0 }.flatMap(column) : styleSamples
        draft.numberStyle = guessNumberStyle(amounts)

        // 4. Date pattern.
        var candidates: [String] = []
        if let dateColumn = draft.columns[.date] {
            let found = dateCandidates(column(dateColumn), preferDayFirst: draft.numberStyle != .us)
            candidates = found.map(\.format)
            if let best = found.first {
                draft.dateFormat = best.format
                draft.dateLocale = best.locale
            } else {
                notes.append("No date pattern reads the date column; choose one.")
            }
            let formats = Set(candidates)
            if !formats.isDisjoint(with: dayFirst) && !formats.isDisjoint(with: monthFirst) {
                notes.append("Dates could be day-first or month-first (\(draft.dateFormat) was chosen); check the preview.")
            }
        }

        // 5. Sign convention.
        if let signed = draft.columns[.amount] {
            let values = column(signed).compactMap(draft.numberStyle.format.parse)
            let positives = values.filter { $0 > 0 }.count
            let negatives = values.filter { $0 < 0 }.count
            if accountKind == .creditCard, positives > negatives {
                draft.invertSign = true
                notes.append("Most amounts are positive on a card account, so purchases are read as money out. Turn off \"Flip signs\" if that's wrong.")
            } else if negatives == 0 && positives > 0 {
                notes.append("Every amount is positive. If purchases should be money out, turn on \"Flip signs\" or map debit and credit columns.")
            }
        }
        for field in draft.missing { notes.append("Choose the \(field.label.lowercased()) column.") }
        return CSVMappingGuess(
            draft: draft, columnTitles: titles, sampleRows: Array(body.prefix(10)), dateFormatCandidates: candidates, notes: notes, remembered: false
        )
    }

    // MARK: Pieces

    static func fraction(_ values: [String], where predicate: (String) -> Bool) -> Double {
        values.isEmpty ? 0 : Double(values.filter(predicate).count) / Double(values.count)
    }

    static func isDate(_ text: String) -> Bool {
        dateFormats.contains { format in
            dateLocales.prefix(format.contains("MMM") ? dateLocales.count : 1).contains { parse(text, format: format, locale: $0) != nil }
        }
    }

    static func looksNumeric(_ text: String) -> Bool {
        guard text.contains(where: \.isNumber) else { return false }
        return CSVNumberStyle.allCases.contains { $0.format.parse(text) != nil }
    }

    /// A header row has no dates or numbers while the rows under it do.
    static func looksLikeHeader(_ row: [String], next: [[String]]) -> Bool {
        let cells = row.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }
        if cells.contains(where: { isDate($0) || looksNumeric($0) }) { return false }
        guard !next.isEmpty else { return true }
        return next.contains { $0.contains { isDate($0.trimmingCharacters(in: .whitespaces)) || looksNumeric($0) } }
    }

    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formatterLock = NSLock()

    /// The literal separators in a pattern ("/" in "dd/MM/yyyy"), outside quotes.
    static func separators(_ format: String) -> Set<Character> {
        var quoted = false
        var result: Set<Character> = []
        for character in format {
            if character == "'" {
                quoted.toggle()
            } else if !quoted && !character.isLetter {
                result.insert(character)
            }
        }
        return result
    }

    static func parse(_ text: String, format: String, locale: String) -> Date? {
        // ICU reads "01.06.2026" with "dd/MM/yyyy" even when strict, so the
        // pattern's own separators must appear in the text.
        guard separators(format).isSubset(of: Set(text)) else { return nil }
        let formatter = formatterLock.withLock { () -> DateFormatter in
            let key = format + "|" + locale
            if let cached = formatters[key] { return cached }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: locale)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.calendar = FinanceCalendar.calendar
            formatter.dateFormat = format
            formatter.isLenient = false
            formatters[key] = formatter
            return formatter
        }
        let date = formatterLock.withLock { formatter.date(from: text) }
        guard let date else { return nil }
        let year = FinanceCalendar.calendar.component(.year, from: date)
        return (1970...2100).contains(year) ? date : nil
    }

    /// Patterns (with locale) that read every sample, best first. When both
    /// day-first and month-first patterns fit, `preferDayFirst` breaks the tie.
    public static func dateCandidates(_ samples: [String], preferDayFirst: Bool = false) -> [(format: String, locale: String)] {
        guard !samples.isEmpty else { return [] }
        var found: [(format: String, locale: String)] = []
        for format in dateFormats {
            let locales = format.contains("MMM") ? dateLocales : ["en_US_POSIX"]
            if let locale = locales.first(where: { locale in samples.allSatisfy { parse($0, format: format, locale: locale) != nil } }) {
                found.append((format, locale))
            }
        }
        guard preferDayFirst else { return found }
        return found.filter { !monthFirst.contains($0.format) } + found.filter { monthFirst.contains($0.format) }
    }

    /// Votes on the decimal separator from where the last "." or "," sits:
    /// followed by one or two digits it is a decimal point; followed by three
    /// it is grouping.
    public static func guessNumberStyle(_ samples: [String]) -> CSVNumberStyle {
        var votes: [CSVNumberStyle: Int] = [:]
        for sample in samples {
            let text = sample.trimmingCharacters(in: .whitespaces)
            if text.contains("'") || text.contains("’") {
                votes[.swiss, default: 0] += 2
                continue
            }
            let groupedBySpace = text.contains { $0 == "\u{00A0}" || $0 == "\u{202F}" } || text.range(of: #"\d \d"#, options: .regularExpression) != nil
            guard let index = text.lastIndex(where: { $0 == "." || $0 == "," }) else { continue }
            let digitsAfter = text[text.index(after: index)...].prefix { $0.isNumber }.count
            let separator = text[index]
            if digitsAfter == 1 || digitsAfter == 2 {
                if separator == "," {
                    votes[groupedBySpace ? .french : .european, default: 0] += 2
                } else {
                    votes[.us, default: 0] += 2
                }
            } else if digitsAfter == 3 {
                votes[separator == "," ? .us : .european, default: 0] += 1
            }
        }
        // Ties go to the first style in `allCases`, so no evidence means US.
        var best = CSVNumberStyle.us
        for style in CSVNumberStyle.allCases where (votes[style] ?? 0) > (votes[best] ?? 0) { best = style }
        return best
    }
}

// MARK: - Remembered mappings

extension Account {
    /// The CSV column mapping last used for this account, if any.
    public var csvMapping: CSVMappingDraft? { CSVMappingDraft(record.attributes[FinanceKey.csvMapping]?.value) }
}

extension Ledger {
    /// Remembers a CSV mapping on the account, as the person's own setting.
    @discardableResult
    public func saveCSVMapping(_ draft: CSVMappingDraft, on accountID: ObjectID, by author: Origin) throws -> Account {
        _ = try account(accountID)
        let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "CSV column mapping")
        let record = try store.update(accountID, by: author, instruction: "Remember CSV mapping") {
            $0.attributes[FinanceKey.csvMapping] = Attribute(draft.value, provenance: provenance)
        }
        return Account(record: record)
    }
}
