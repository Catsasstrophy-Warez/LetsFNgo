import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct CSVMappingTests {
    let person = Origin.user(id: "sam")

    static let usExport = """
        Date,Description,Amount,Running Balance,Transaction ID
        09/15/2026,COFFEE SHOP,-4.50,"1,245.50",T-3
        09/14/2026,PAYROLL,"2,000.00","1,250.00",T-2
        09/02/2026,RENT,-1500.00,-750.00,T-1
        """

    @Test func guessesAEuropeanExportWithDebitAndCreditColumns() throws {
        let guess = try CSVMappingGuesser.guess(Fixtures.europeanCSV)
        let draft = guess.draft
        #expect(draft.delimiter == ";" && draft.hasHeader)
        #expect(draft.columns == [.date: 0, .payee: 1, .memo: 2, .debit: 3, .credit: 4])
        #expect(draft.dateFormat == "dd.MM.yyyy")
        #expect(draft.numberStyle == .european && !draft.invertSign)
        #expect(guess.columnTitles.first == "Buchungstag" && guess.sampleRows.count == 8 && !guess.remembered)
        #expect(draft.missing.isEmpty)
        // The guessed mapping reads the file exactly as the hand-written one does.
        let guessed = try CSV.transactions(Fixtures.europeanCSV, mapping: draft.mapping(), currency: .eur)
        let written = try CSV.transactions(Fixtures.europeanCSV, mapping: Fixtures.europeanMapping, currency: .eur)
        #expect(guessed.map(\.draft) == written.map(\.draft))
    }

    @Test func guessesAUSExportWithBalanceAndIDColumns() throws {
        let guess = try CSVMappingGuesser.guess(Self.usExport)
        let draft = guess.draft
        #expect(draft.delimiter == "," && draft.columns == [.date: 0, .payee: 1, .amount: 2, .balance: 3, .fitID: 4])
        #expect(draft.dateFormat == "MM/dd/yyyy" && draft.numberStyle == .us)
        #expect(!guess.notes.contains { $0.contains("day-first") }, "15 and 14 can only be days")
        let rows = try CSV.statementRows(Self.usExport, mapping: draft.mapping(), currency: .usd)
        #expect(try rows.map(\.draft.amount) == [Money("-4.50", .usd), Money("2000", .usd), Money("-1500", .usd)])
        #expect(rows.map(\.draft.fitID) == ["T-3", "T-2", "T-1"])
        // Newest first: the closing balance is the first row's.
        let closing = try #require(CSV.closingBalance(rows))
        #expect(try closing.balance == Money("1245.50", .usd) && closing.date == FinanceCalendar.day(2026, 9, 15))
        // Oldest first: the last row's.
        let reversed = try #require(CSV.closingBalance(rows.reversed()))
        #expect(try reversed.balance == Money("1245.50", .usd))
    }

    @Test func ambiguousDatesAreFlaggedAndFollowTheNumberStyle() throws {
        let us = try CSVMappingGuesser.guess("Date,Payee,Amount\n03/04/2026,A,-1.50\n05/06/2026,B,-2.25\n")
        #expect(us.draft.dateFormat == "MM/dd/yyyy")
        #expect(us.notes.contains { $0.contains("day-first or month-first") })
        #expect(us.dateFormatCandidates.contains("dd/MM/yyyy"))
        let european = try CSVMappingGuesser.guess("Datum;Name;Betrag\n03/04/2026;A;-1,50\n05/06/2026;B;-2,25\n")
        #expect(european.draft.dateFormat == "dd/MM/yyyy" && european.draft.numberStyle == .european)
        let rows = try CSV.transactions("Datum;Name;Betrag\n03/04/2026;A;-1,50\n", mapping: european.draft.mapping(), currency: .eur)
        #expect(rows.first?.draft.date == FinanceCalendar.day(2026, 4, 3))
    }

    @Test func headerlessFilesAreMappedByContent() throws {
        let text = "2026-09-01,Green Grocer,-12.50\n2026-09-02,Bean There Coffee,-3.20\n2026-09-03,Payroll,1500.00\n"
        let guess = try CSVMappingGuesser.guess(text)
        #expect(!guess.draft.hasHeader)
        #expect(guess.draft.columns == [.date: 0, .payee: 1, .amount: 2])
        #expect(guess.columnTitles == ["Column 1", "Column 2", "Column 3"])
        #expect(try CSV.transactions(text, mapping: guess.draft.mapping(), currency: .usd).count == 3)
        #expect(CSVMappingGuesser.detectDelimiter("a\tb\tc\n1\t2\t3\n") == "\t")
        #expect(CSVMappingGuesser.detectDelimiter("a;b;c\n1,5;2;3\n") == ";")
    }

    @Test func cardExportsWithPositivePurchasesFlipSigns() throws {
        let text = "Date,Merchant,Amount\n2026-09-01,Book Nook,24.10\n2026-09-02,Fuel & Go,40.00\n2026-09-03,Refund,-5.00\n"
        let card = try CSVMappingGuesser.guess(text, accountKind: .creditCard)
        #expect(card.draft.invertSign && card.notes.contains { $0.contains("Flip signs") })
        #expect(try CSV.transactions(text, mapping: card.draft.mapping(), currency: .usd).first?.draft.amount == Money("-24.10", .usd))
        let checking = try CSVMappingGuesser.guess(text, accountKind: .checking)
        #expect(!checking.draft.invertSign)
    }

    @Test func numberStyleVotes() {
        #expect(CSVMappingGuesser.guessNumberStyle(["1.234,56", "-12,00"]) == .european)
        #expect(CSVMappingGuesser.guessNumberStyle(["1 234,56"]) == .french)
        #expect(CSVMappingGuesser.guessNumberStyle(["1'234.50"]) == .swiss)
        #expect(CSVMappingGuesser.guessNumberStyle(["1,234.56", "12"]) == .us)
        #expect(CSVMappingGuesser.guessNumberStyle(["1.234"]) == .european, "Three digits after a point is grouping")
        #expect(CSVMappingGuesser.guessNumberStyle([]) == .us)
    }

    @Test func assigningAFieldKeepsOneFieldPerColumn() throws {
        var draft = CSVMappingDraft(columns: [.date: 0, .debit: 1, .credit: 2, .payee: 3])
        #expect(draft.missing.isEmpty)
        draft.assign(.amount, to: 1)
        #expect(draft.columns == [.date: 0, .amount: 1, .payee: 3], "A signed amount replaces debit and credit")
        draft.assign(.memo, to: 3)
        #expect(draft.columns[.payee] == nil && draft.field(at: 3) == .memo)
        #expect(draft.missing.isEmpty, "The memo stands in for a missing payee")
        #expect(try draft.mapping().payee == .index(3))
        draft.assign(nil, to: 0)
        #expect(draft.missing == [.date])
        #expect(throws: FinanceError.unknownColumn("Date")) { try draft.mapping() }
        draft.assign(.debit, to: 1)
        #expect(draft.missing == [.date, .credit])
    }

    @Test func previewKeepsGoingPastABadRow() throws {
        let text = "Date,Payee,Amount\n2026-09-01,A,-1.00\n2026-13-01,B,-2.00\n2026-09-03,C,12x\n2026-09-04,D,4.00\n"
        let mapping = CSVMapping(date: "Date", amount: .signed("Amount"), payee: "Payee")
        let rows = try CSV.preview(text, mapping: mapping, currency: .usd)
        #expect(rows.count == 4)
        #expect(rows.map { $0.row != nil } == [true, false, false, true])
        #expect(rows[1].error == .unparsableDate("2026-13-01", line: 3))
        #expect(rows[2].error == .unparsableAmount("12x", line: 4))
        #expect(try CSV.preview(text, mapping: mapping, currency: .usd, limit: 2).count == 2)
    }

    @Test func aMappingIsRememberedOnTheAccountAndFollowsMovedColumns() throws {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: person)
        var draft = try CSVMappingGuesser.guess(Self.usExport).draft
        draft.dateFormat = "M/d/yyyy"
        let saved = try world.ledger.saveCSVMapping(draft, on: account.id, by: person)
        #expect(saved.csvMapping == draft)
        #expect(saved.record.truth(of: FinanceKey.csvMapping) == .recorded)
        #expect(try world.ledger.account(account.id).csvMapping == draft, "Read back from the store")

        // The bank moved its columns; the remembered mapping follows the header names.
        let moved = """
            Transaction ID,Amount,Date,Description
            T-9,-9.99,09/20/2026,STREAMFLIX
            """
        let guess = try CSVMappingGuesser.guess(moved, remembered: saved.csvMapping)
        #expect(guess.remembered && guess.notes == ["Using the mapping saved for this account."])
        #expect(guess.draft.columns == [.fitID: 0, .amount: 1, .date: 2, .payee: 3])
        #expect(guess.draft.dateFormat == "M/d/yyyy", "The person's date choice is kept")
        let rows = try CSV.transactions(moved, mapping: guess.draft.mapping(), currency: .usd)
        #expect(try rows.first?.draft.amount == Money("-9.99", .usd) && rows.first?.draft.payee == "STREAMFLIX")

        // A file that lacks a remembered column is guessed afresh.
        let other = try CSVMappingGuesser.guess("When,Who,How much\n2026-09-01,A,-1.00\n", remembered: saved.csvMapping)
        #expect(!other.remembered && other.notes.first?.contains("doesn't fit") == true)
    }

    @Test func previewCountsDuplicatesAndImportRecordsTheClosingBalance() throws {
        let world = try FinanceWorld()
        let account = try world.ledger.addAccount(name: "Checking", kind: .checking, currency: .usd, by: person)
        let mapping = try CSVMappingGuesser.guess(Self.usExport).draft.mapping()
        let data = Data(Self.usExport.utf8)

        let plan = try world.importer.previewCSV(data, into: account.id, mapping: mapping)
        #expect(plan.new.count == 3 && plan.duplicates.isEmpty)
        #expect(try plan.closingBalance == Money("1245.50", .usd))
        #expect(try world.ledger.transactions(in: [account.id]).isEmpty, "A preview stores nothing")

        let result = try world.importer.importCSV(data, named: "sept.csv", into: account.id, mapping: mapping, by: person)
        #expect(result.created.count == 3 && result.created.allSatisfy { $0.truth == .recorded })
        let updated = try world.ledger.account(account.id)
        #expect(try updated.balance == Money("1245.50", .usd) && updated.balanceTruth == .recorded)
        #expect(updated.balanceAsOf == FinanceCalendar.day(2026, 9, 15))
        let provenance = try #require(updated.record.attributes[FinanceKey.balance]?.provenance)
        #expect(provenance.origin == .importer(source: result.document.id) && provenance.method == "CSV running balance")

        let again = try world.importer.previewCSV(data, into: account.id, mapping: mapping)
        #expect(again.new.isEmpty && again.duplicates.count == 3)
    }
}
