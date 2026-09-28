import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct ImportTests {
    let person = Origin.user(id: "sam")

    @Test func numberFormats() {
        #expect(NumberFormat.us.parse("1,234.56") == Decimal(string: "1234.56"))
        #expect(NumberFormat.us.parse("(1,234.56)") == Decimal(string: "-1234.56"))
        #expect(NumberFormat.us.parse("$-12.50") == Decimal(string: "-12.5"))
        #expect(NumberFormat.us.parse("12.00-") == -12)
        #expect(NumberFormat.us.parse("12.50 DR") == Decimal(string: "-12.5"))
        #expect(NumberFormat.us.parse("12.50CR") == Decimal(string: "12.5"))
        #expect(NumberFormat.us.parse("125000 IDR") == 125_000, "IDR is a currency, not a debit marker")
        #expect(NumberFormat.european.parse("1.234,56") == Decimal(string: "1234.56"))
        #expect(NumberFormat.european.parse("-1.234,56 €") == Decimal(string: "-1234.56"))
        #expect(NumberFormat.european.parse("EUR 0,99") == Decimal(string: "0.99"))
        #expect(NumberFormat.french.parse("1\u{202F}234,56") == Decimal(string: "1234.56"))
        #expect(NumberFormat.swiss.parse("1'234.50") == Decimal(string: "1234.5"))
        #expect(NumberFormat.us.parse("12abc34") == nil)
        #expect(NumberFormat.us.parse("1e5") == nil)
        #expect(NumberFormat.us.parse("1.2.3") == nil)
        #expect(NumberFormat.us.parse("") == nil)
        #expect(NumberFormat(locale: Locale(identifier: "de_DE")).decimalSeparator == ",")
        #expect(NumberFormat(locale: Locale(identifier: "de_DE")).parse("1.234,56") == Decimal(string: "1234.56"))
        #expect(NumberFormat(locale: Locale(identifier: "en_US")).parse("1,234.56") == Decimal(string: "1234.56"))
    }

    @Test func csvQuotingAndLineBreaks() throws {
        let rows = try CSV.parse("\u{FEFF}a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"two\nlines\"\r\n\r\nlast,,\n")
        #expect(rows.map(\.fields) == [["a", "b", "c"], ["x, y", "say \"hi\"", "two\nlines"], ["last", "", ""]])
        #expect(rows.map(\.line) == [1, 2, 5])
        #expect(throws: FinanceError.malformedCSV(line: 1, reason: "unterminated quoted field")) { try CSV.parse("\"open") }
        #expect(throws: FinanceError.malformedCSV(line: 1, reason: "quote inside an unquoted field")) { try CSV.parse("ab\"c") }
    }

    @Test func csvMappingWithLocaleDatesAndDebitCreditColumns() throws {
        let rows = try CSV.transactions(Fixtures.europeanCSV, mapping: Fixtures.europeanMapping, currency: .eur)
        #expect(rows.count == 8)
        #expect(try rows[0].draft.amount == Money("4200", .eur) && rows[0].draft.date == FinanceCalendar.day(2026, 6, 1))
        #expect(try rows[1].draft.amount == Money("-1850", .eur) && rows[1].draft.memo == "Rent June")
        #expect(try rows[4].draft.memo == "Rent; July" && rows[5].draft.amount == Money("-103.90", .eur))

        let us = CSVMapping(date: 0, amount: .signed(2), payee: 1, dateFormat: "MM/dd/yyyy", hasHeader: false, invertSign: true)
        let card = try CSV.transactions("09/05/2026,Book Nook,\"1,024.10\"\n09/06/2026,Refund,-5.00\n", mapping: us, currency: .usd)
        #expect(card.map(\.draft.amount) == [try Money("-1024.10", .usd), try Money("5", .usd)])

        // Month names follow the mapping's locale.
        let english = CSVMapping(date: "Date", amount: .signed("Amount"), payee: "Payee", dateFormat: "d MMMM yyyy", dateLocale: Locale(identifier: "en_GB"))
        let named = try CSV.transactions("Date,Payee,Amount\n5 September 2026,Deli,-3.20\n", mapping: english, currency: .gbp)
        #expect(named.first?.draft.date == FinanceCalendar.day(2026, 9, 5))
        let german = CSVMapping(
            date: "Datum", amount: .signed("Betrag"), payee: "Name", dateFormat: "d. MMMM yyyy", dateLocale: Locale(identifier: "de_DE"),
            numberFormat: NumberFormat(locale: Locale(identifier: "de_DE")), delimiter: ";"
        )
        let deutsch = try CSV.transactions("Datum;Name;Betrag\n3. März 2026;Bäckerei;-1.234,50\n", mapping: german, currency: .eur)
        #expect(deutsch.first?.draft.date == FinanceCalendar.day(2026, 3, 3))
        #expect(try deutsch.first?.draft.amount == Money("-1234.50", .eur))

        #expect(throws: FinanceError.unparsableDate("2026-13-01", line: 2)) {
            try CSV.transactions(
                "Date,Payee,Amount\n2026-13-01,X,1\n", mapping: CSVMapping(date: "Date", amount: .signed("Amount"), payee: "Payee"), currency: .usd)
        }
        #expect(throws: FinanceError.unparsableAmount("12x", line: 2)) {
            try CSV.transactions(
                "Date,Payee,Amount\n2026-01-01,X,12x\n", mapping: CSVMapping(date: "Date", amount: .signed("Amount"), payee: "Payee"), currency: .usd)
        }
        #expect(throws: FinanceError.unknownColumn("Betrag")) {
            try CSV.transactions("Date,Payee,Amount\n", mapping: CSVMapping(date: "Date", amount: .signed("Betrag"), payee: "Payee"), currency: .usd)
        }
    }

    @Test func ofxSGMLAndXMLFlavours() throws {
        let sgml = try OFX.statements(Fixtures.sgmlOFX)
        #expect(sgml.count == 1)
        let checking = sgml[0]
        #expect(checking.accountID == "000123456789" && checking.bankID == "021000021" && checking.accountKind == .checking)
        #expect(checking.organization == "First Harbor Bank" && checking.currency == .usd)
        #expect(checking.transactions.count == 12)
        #expect(checking.transactions[0].fitID == "A-0401-SAL" && checking.transactions[0].memo == "Salary")
        #expect(checking.transactions[0].date == FinanceCalendar.day(2026, 4, 1), "The day as written, whatever the time zone")
        #expect(checking.transactions[11].payee == "CITY WATER & POWER" && checking.transactions[11].checkNumber == "1043")
        #expect(try checking.ledgerBalance == Money("7078.23", .usd) && checking.ledgerBalanceDate == FinanceCalendar.day(2026, 6, 30))

        let xml = try OFX.statements(Fixtures.xmlOFX)
        #expect(xml.count == 1 && xml[0].isCreditCard && xml[0].accountKind == .creditCard && xml[0].organization == "Summit Card")
        #expect(xml[0].transactions.map(\.payee) == ["STREAMFLIX", "Fuel & Go", "PAYMENT THANK YOU"])
        #expect(xml[0].transactions.map(\.amount) == [try Money("-15.99", .usd), try Money("-62.30", .usd), try Money("200", .usd)])
        #expect(try xml[0].ledgerBalance == Money("-512.44", .usd))

        #expect(throws: FinanceError.malformedOFX("no <OFX> element")) { try OFX.statements("hello") }
        #expect(throws: FinanceError.self) {
            try OFX.statements(
                "<OFX><BANKMSGSRSV1><STMTRS><BANKACCTFROM><ACCTID>1</BANKACCTFROM><BANKTRANLIST><STMTTRN><TRNAMT>5</STMTTRN></BANKTRANLIST></STMTRS></BANKMSGSRSV1></OFX>"
            )
        }
        #expect(OFX.date("20260231") == nil && OFX.date("2026-01-01") == nil)
    }

    @Test func importIsRecordedTruthPointingAtTheStoredFile() throws {
        let world = try FinanceWorld()
        let data = Data(Fixtures.sgmlOFX.utf8)
        let results = try world.importer.importOFX(data, named: "checking-q2.ofx", by: person)
        let result = try #require(results.first)
        #expect(result.created.count == 12 && result.duplicates.isEmpty)

        // The file is a blob behind a document object.
        let digest = try #require(result.document.attributes[FinanceKey.blob]?.value)
        guard case .string(let sha) = digest else { Issue.record("no blob digest"); return }
        #expect(try world.store.blobData(sha256: sha) == data)
        #expect(result.document.type == .document && result.document.provenance.origin == person)

        // Every transaction is recorded, from an importer naming that document.
        for transaction in result.created {
            #expect(transaction.truth == .recorded)
            #expect(transaction.record.provenance.origin == .importer(source: result.document.id))
            #expect(transaction.record.provenance.dependencies == [result.document.id])
            #expect(try world.store.relationships(from: transaction.id, kind: .postedTo).map(\.to) == [result.account.id])
        }
        // The account came from the statement; the ledger balance is recorded from the same file.
        #expect(result.account.accountNumber == "000123456789" && result.account.kind == .checking)
        #expect(try result.account.balance == Money("7078.23", .usd) && result.account.balanceTruth == .recorded)
        #expect(result.account.record.attributes[FinanceKey.balance]?.provenance?.origin == .importer(source: result.document.id))
        let events = try world.store.events(about: result.document.id)
        #expect(events.contains { $0.kind == .statementImported && $0.payload["created"] == .int(12) })
    }

    @Test func dedupByFITIDAndByContentHash() throws {
        let world = try FinanceWorld()
        let first = try #require(try world.importer.importOFX(Data(Fixtures.sgmlOFX.utf8), named: "q2.ofx", by: person).first)
        let account = first.account.id

        // The same file again: every row matches by FITID, and the document is reused.
        let again = try #require(try world.importer.importOFX(Data(Fixtures.sgmlOFX.utf8), named: "q2 copy.ofx", by: person).first)
        #expect(again.created.isEmpty && again.duplicates.count == 12 && again.document.id == first.document.id)

        // A CSV of June and July for the same account: June's three rows have no
        // FITID and match the OFX rows by (date, amount, payee); July is new,
        // including two identical coffees on one day.
        let usMapping = Fixtures.europeanMapping
        let csv = try world.importer.importCSV(Data(Fixtures.europeanCSV.utf8), named: "export.csv", into: account, mapping: usMapping, by: person)
        #expect(csv.duplicates.count == 3 && csv.created.count == 5)
        #expect(Set(csv.duplicates.map(\.existing)).isSubset(of: Set(first.created.map(\.id))))
        #expect(csv.created.filter { $0.payee == "Bean There Coffee" }.count == 2)
        #expect(csv.created.allSatisfy { $0.record.provenance.origin == .importer(source: csv.document.id) })

        // Re-importing the CSV adds nothing, though its rows have no FITID.
        let csvAgain = try world.importer.importCSV(Data(Fixtures.europeanCSV.utf8), named: "export.csv", into: account, mapping: usMapping, by: person)
        #expect(csvAgain.created.isEmpty && csvAgain.duplicates.count == 8)

        // A new FITID on an identical row is a different transaction.
        let edited = Fixtures.sgmlOFX.replacingOccurrences(of: "A-0405-3", with: "A-0405-9")
        let partial = try #require(try world.importer.importOFX(Data(edited.utf8), named: "edited.ofx", by: person).first)
        #expect(partial.created.count == 1 && partial.duplicates.count == 11)
        #expect(try world.ledger.transactions(in: [account]).count == 12 + 5 + 1)
    }

    @Test func currencyMismatchesAreRefused() throws {
        let world = try FinanceWorld()
        let euro = try world.ledger.addAccount(name: "Euro", kind: .checking, currency: .eur, by: person)
        #expect(throws: MoneyError.currencyMismatch(.eur, .usd)) {
            try world.importer.importOFX(Data(Fixtures.xmlOFX.utf8), named: "card.ofx", into: euro.id, by: person)
        }
        #expect(throws: MoneyError.currencyMismatch(.eur, .usd)) {
            try world.ledger.addTransaction(TransactionDraft(date: Fixtures.t0, amount: try Money("1", .usd), payee: "x"), to: euro.id, by: person)
        }
        #expect(try world.ledger.transactions().isEmpty, "The failed import rolled back")
    }
}
