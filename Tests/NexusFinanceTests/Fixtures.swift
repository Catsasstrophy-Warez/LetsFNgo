import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence

/// Statement files used across the finance tests.
enum Fixtures {
    static let t0 = Date(timeIntervalSinceReferenceDate: 810_000_000)

    /// OFX 1.02 SGML: a header block, and leaf elements with no end tags.
    /// Three months of a checking account: rent, salary, groceries, coffee.
    static let sgmlOFX = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102
        SECURITY:NONE
        ENCODING:USASCII
        CHARSET:1252
        COMPRESSION:NONE
        OLDFILEUID:NONE
        NEWFILEUID:NONE

        <OFX>
        <SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS><DTSERVER>20260702120000[-5:EST]<LANGUAGE>ENG
        <FI><ORG>First Harbor Bank<FID>1234</FI></SONRS></SIGNONMSGSRSV1>
        <BANKMSGSRSV1><STMTTRNRS><TRNUID>1<STATUS><CODE>0<SEVERITY>INFO</STATUS>
        <STMTRS><CURDEF>USD
        <BANKACCTFROM><BANKID>021000021<ACCTID>000123456789<ACCTTYPE>CHECKING</BANKACCTFROM>
        <BANKTRANLIST><DTSTART>20260401<DTEND>20260630
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260401080000.000[-5:EST]<TRNAMT>4200.00<FITID>A-0401-SAL<NAME>ACME CORP PAYROLL<MEMO>Salary</STMTTRN>
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260401<TRNAMT>-1850.00<FITID>A-0401-RENT<NAME>HARBOR VIEW APTS<MEMO>Rent April</STMTTRN>
        <STMTTRN><TRNTYPE>POS<DTPOSTED>20260405<TRNAMT>-84.12<FITID>A-0405-1<NAME>GREEN GROCER #22</STMTTRN>
        <STMTTRN><TRNTYPE>POS<DTPOSTED>20260405<TRNAMT>-4.50<FITID>A-0405-2<NAME>BEAN THERE COFFEE</STMTTRN>
        <STMTTRN><TRNTYPE>POS<DTPOSTED>20260405<TRNAMT>-4.50<FITID>A-0405-3<NAME>BEAN THERE COFFEE</STMTTRN>
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260501<TRNAMT>4200.00<FITID>A-0501-SAL<NAME>ACME CORP PAYROLL</STMTTRN>
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260501<TRNAMT>-1850.00<FITID>A-0501-RENT<NAME>HARBOR VIEW APTS<MEMO>Rent May</STMTTRN>
        <STMTTRN><TRNTYPE>POS<DTPOSTED>20260510<TRNAMT>-91.40<FITID>A-0510-1<NAME>GREEN GROCER #22</STMTTRN>
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260601<TRNAMT>4200.00<FITID>A-0601-SAL<NAME>ACME CORP PAYROLL</STMTTRN>
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-1850.00<FITID>A-0601-RENT<NAME>HARBOR VIEW APTS<MEMO>Rent June</STMTTRN>
        <STMTTRN><TRNTYPE>POS<DTPOSTED>20260612<TRNAMT>-77.25<FITID>A-0612-1<NAME>GREEN GROCER #22</STMTTRN>
        <STMTTRN><TRNTYPE>CHECK<DTPOSTED>20260620<TRNAMT>-120.00<FITID>A-0620-1<CHECKNUM>1043<NAME>CITY WATER &amp; POWER</STMTTRN>
        </BANKTRANLIST>
        <LEDGERBAL><BALAMT>7078.23<DTASOF>20260630</LEDGERBAL>
        </STMTRS></STMTTRNRS></BANKMSGSRSV1>
        </OFX>
        """

    /// OFX 2.x XML: a credit-card statement, every element closed.
    static let xmlOFX = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <?OFX OFXHEADER="200" VERSION="211" SECURITY="NONE" OLDFILEUID="NONE" NEWFILEUID="NONE"?>
        <OFX>
          <SIGNONMSGSRSV1><SONRS><STATUS><CODE>0</CODE><SEVERITY>INFO</SEVERITY></STATUS><DTSERVER>20260702</DTSERVER><LANGUAGE>ENG</LANGUAGE>
            <FI><ORG>Summit Card</ORG><FID>9</FID></FI></SONRS></SIGNONMSGSRSV1>
          <CREDITCARDMSGSRSV1><CCSTMTTRNRS><TRNUID>2</TRNUID><STATUS><CODE>0</CODE><SEVERITY>INFO</SEVERITY></STATUS>
            <CCSTMTRS>
              <CURDEF>USD</CURDEF>
              <CCACCTFROM><ACCTID>4111000011112222</ACCTID></CCACCTFROM>
              <BANKTRANLIST>
                <DTSTART>20260601</DTSTART><DTEND>20260630</DTEND>
                <STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260603120000</DTPOSTED><TRNAMT>-15.99</TRNAMT><FITID>C-1</FITID>
                  <NAME>STREAMFLIX</NAME><MEMO>Monthly plan</MEMO></STMTTRN>
                <STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260611</DTPOSTED><TRNAMT>-62.30</TRNAMT><FITID>C-2</FITID>
                  <PAYEE><NAME>Fuel &amp; Go</NAME></PAYEE></STMTTRN>
                <STMTTRN><TRNTYPE>CREDIT</TRNTYPE><DTPOSTED>20260620</DTPOSTED><TRNAMT>200.00</TRNAMT><FITID>C-3</FITID>
                  <NAME>PAYMENT THANK YOU</NAME></STMTTRN>
              </BANKTRANLIST>
              <LEDGERBAL><BALAMT>-512.44</BALAMT><DTASOF>20260630</DTASOF></LEDGERBAL>
            </CCSTMTRS>
          </CCSTMTTRNRS></CREDITCARDMSGSRSV1>
        </OFX>
        """

    /// A European-style CSV export of the same checking account for June and
    /// July: dd.MM.yyyy dates, "," decimals, "." grouping, ";" delimiter,
    /// debit and credit columns. June overlaps the OFX file and has no FITIDs.
    static let europeanCSV = """
        Buchungstag;Empfänger;Verwendungszweck;Soll;Haben
        01.06.2026;ACME Corp Payroll;Salary;;4.200,00
        01.06.2026;Harbor View Apts;Rent June;1.850,00;
        12.06.2026;Green Grocer #22;;77,25;
        01.07.2026;ACME Corp Payroll;Salary;;4.200,00
        01.07.2026;Harbor View Apts;"Rent; July";1.850,00;
        09.07.2026;Green Grocer #22;;"103,90";
        15.07.2026;Bean There Coffee;;4,50;
        15.07.2026;Bean There Coffee;;4,50;
        """

    static let europeanMapping = CSVMapping(
        date: "Buchungstag", amount: .debitCredit(debit: "Soll", credit: "Haben"), payee: "Empfänger", memo: "Verwendungszweck",
        dateFormat: "dd.MM.yyyy", numberFormat: .european, delimiter: ";"
    )

    static func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
    }

    static func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".blobs"))
    }
}

/// Every finance runtime over one store.
struct FinanceWorld {
    let store: NexusStore
    let clock: ManualClock
    let ledger: Ledger
    let importer: StatementImporter
    let categorizer: Categorizer
    let budgets: Budgets
    let recurring: RecurringDetector
    let scenarios: Scenarios
    let portfolio: Portfolio

    init(_ location: NexusStore.Location = .inMemory, clock: ManualClock = ManualClock(Fixtures.t0)) throws {
        store = try NexusStore(location, clock: clock)
        self.clock = clock
        ledger = Ledger(store: store, clock: clock)
        importer = StatementImporter(store: store, clock: clock)
        categorizer = Categorizer(store: store, clock: clock)
        budgets = Budgets(store: store, clock: clock)
        recurring = RecurringDetector(store: store, clock: clock)
        scenarios = Scenarios(store: store, clock: clock)
        portfolio = Portfolio(store: store, clock: clock)
    }
}

/// A model stub that suggests by keyword.
struct KeywordSuggester: CategorySuggester {
    let model = ModelRef(provider: "test", modelID: "keyword-suggester")
    let keywords: [String: ObjectID]
    let confidence: Double

    func suggest(for transaction: FinancialTransaction, among categories: [TransactionCategory]) async throws -> CategorySuggestion? {
        guard let match = keywords.first(where: { transaction.payee.uppercased().contains($0.key) }) else { return nil }
        return CategorySuggestion(category: match.value, confidence: confidence, rationale: "payee mentions \(match.key)")
    }
}
