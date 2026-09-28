import Foundation

/// One element of an OFX document. Aggregates have children; leaves have text.
public struct OFXElement: Sendable, Hashable {
    public var name: String
    public var text: String?
    public var children: [OFXElement]

    public init(name: String, text: String? = nil, children: [OFXElement] = []) {
        self.name = name
        self.text = text
        self.children = children
    }

    /// The first direct child named `name`.
    public func child(_ name: String) -> OFXElement? { children.first { $0.name == name } }

    /// The text of the first direct child named `name`.
    public subscript(_ name: String) -> String? { child(name)?.text }

    /// Every descendant named `name`, in document order.
    public func all(_ name: String) -> [OFXElement] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    public func first(_ name: String) -> OFXElement? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }
}

/// One bank or card statement (STMTRS / CCSTMTRS) read from an OFX file.
public struct OFXStatement: Sendable, Hashable {
    public var accountID: String
    public var bankID: String?
    /// CHECKING, SAVINGS, MONEYMRKT, CREDITLINE, or nil for a card statement.
    public var accountType: String?
    public var isCreditCard: Bool
    public var currency: Currency
    public var organization: String?
    public var startDate: Date?
    public var endDate: Date?
    public var transactions: [TransactionDraft]
    public var ledgerBalance: Money?
    public var ledgerBalanceDate: Date?

    public var accountKind: AccountKind {
        if isCreditCard { return .creditCard }
        switch accountType {
        case "SAVINGS", "MONEYMRKT": return .savings
        case "CREDITLINE": return .loan
        default: return .checking
        }
    }
}

/// Reads OFX and QFX statements in both flavours: OFX 1.x SGML (a header
/// block, then tags whose leaf elements have no end tags) and OFX 2.x XML.
public enum OFX {
    /// Parses the document into its `<OFX>` element.
    public static func parse(_ text: String) throws -> OFXElement {
        guard let start = text.range(of: "<OFX>", options: .caseInsensitive) else { throw FinanceError.malformedOFX("no <OFX> element") }
        let body = text[start.lowerBound...]

        // A stack of open elements; the bottom one is a synthetic root.
        var stack: [OFXElement] = [OFXElement(name: "")]
        // Set when the top element has text and so may be an SGML leaf without an end tag.
        var pendingLeaf = false

        func closeTop() {
            let element = stack.removeLast()
            stack[stack.count - 1].children.append(element)
        }

        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "<" {
                if body[index...].hasPrefix("<!--") {
                    guard let end = body.range(of: "-->", range: index..<body.endIndex) else { throw FinanceError.malformedOFX("unterminated comment") }
                    index = end.upperBound
                    continue
                }
                guard let close = body[index...].firstIndex(of: ">") else { throw FinanceError.malformedOFX("unterminated tag") }
                var tag = String(body[body.index(after: index)..<close]).trimmingCharacters(in: .whitespaces)
                index = body.index(after: close)
                if tag.hasPrefix("?") || tag.hasPrefix("!") { continue }
                if tag.hasPrefix("/") {
                    let name = String(tag.dropFirst()).trimmingCharacters(in: .whitespaces).uppercased()
                    pendingLeaf = false
                    // Close up to and including the matching element; ignore a stray end tag.
                    guard let depth = stack.lastIndex(where: { $0.name == name }), depth > 0 else { continue }
                    while stack.count > depth { closeTop() }
                    continue
                }
                if pendingLeaf {
                    closeTop()
                    pendingLeaf = false
                }
                let selfClosing = tag.hasSuffix("/")
                if selfClosing { tag = String(tag.dropLast()) }
                let name = String(tag.split(separator: " ").first ?? "").uppercased()
                guard !name.isEmpty else { throw FinanceError.malformedOFX("empty tag") }
                stack.append(OFXElement(name: name))
                if selfClosing { closeTop() }
            } else {
                let end = body[index...].firstIndex(of: "<") ?? body.endIndex
                let text = body[index..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                index = end
                guard !text.isEmpty, stack.count > 1 else { continue }
                stack[stack.count - 1].text = decodeEntities(text)
                pendingLeaf = true
            }
        }
        while stack.count > 1 { closeTop() }
        guard let root = stack[0].children.first(where: { $0.name == "OFX" }) else { throw FinanceError.malformedOFX("no <OFX> element") }
        return root
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// OFX dates are "YYYYMMDD[HHMMSS[.XXX]][[+-]H:TZ]". A posted date is the
    /// calendar day as written, whatever the time zone suffix.
    public static func date(_ text: String) -> Date? {
        let digits = text.prefix(8)
        guard digits.count == 8, digits.allSatisfy(\.isNumber), let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
            let day = Int(digits.suffix(2)), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let date = FinanceCalendar.day(year, month, day)
        guard FinanceCalendar.calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// Every bank and card statement in the file.
    public static func statements(_ text: String) throws -> [OFXStatement] {
        let statements = try bankStatements(parse(text))
        guard !statements.isEmpty else { throw FinanceError.malformedOFX("no STMTRS or CCSTMTRS statement") }
        return statements
    }

    /// Bank and card statements under `root`; empty when there are none.
    static func bankStatements(_ root: OFXElement) throws -> [OFXStatement] {
        let organization = root.first("FI")?["ORG"]
        let responses = root.all("STMTRS").map { ($0, false) } + root.all("CCSTMTRS").map { ($0, true) }
        return try responses.map { response, isCard in
            guard let from = response.child(isCard ? "CCACCTFROM" : "BANKACCTFROM"), let accountID = from["ACCTID"] else {
                throw FinanceError.malformedOFX("statement without an account ID")
            }
            let currency = try Currency(response["CURDEF"] ?? "USD")
            let list = response.child("BANKTRANLIST")
            let transactions = try (list?.all("STMTTRN") ?? []).map { entry -> TransactionDraft in
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
            let ledger = response.child("LEDGERBAL")
            return OFXStatement(
                accountID: accountID, bankID: from["BANKID"], accountType: from["ACCTTYPE"], isCreditCard: isCard, currency: currency,
                organization: organization, startDate: list?["DTSTART"].flatMap(date), endDate: list?["DTEND"].flatMap(date),
                transactions: transactions,
                ledgerBalance: ledger?["BALAMT"].flatMap(NumberFormat.ofx.parse).map { Money($0, currency) },
                ledgerBalanceDate: ledger?["DTASOF"].flatMap(date)
            )
        }
    }
}

extension NumberFormat {
    /// OFX amounts: "." decimal (some banks write ","), no grouping.
    static let ofx = NumberFormat(decimalSeparator: ".", groupingSeparators: [])
}
