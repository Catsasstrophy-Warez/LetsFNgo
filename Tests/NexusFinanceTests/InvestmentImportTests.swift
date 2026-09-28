import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct InvestmentImportTests {
    let person = Origin.user(id: "sam")

    /// OFX 1.02 SGML brokerage statement: two buys, a sale, a sale of a
    /// security bought before the statement, a dividend, a cash deposit, two
    /// stated positions and a security list.
    static let brokerage = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102

        <OFX>
        <SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS><DTSERVER>20260702<LANGUAGE>ENG
        <FI><ORG>Summit Brokerage<FID>77</FI></SONRS></SIGNONMSGSRSV1>
        <INVSTMTMSGSRSV1><INVSTMTTRNRS><TRNUID>1<STATUS><CODE>0<SEVERITY>INFO</STATUS>
        <INVSTMTRS><DTASOF>20260630<CURDEF>USD
        <INVACCTFROM><BROKERID>summit.example.com<ACCTID>INV-5555</INVACCTFROM>
        <INVTRANLIST><DTSTART>20260601<DTEND>20260630
        <BUYSTOCK><INVBUY><INVTRAN><FITID>B-1<DTTRADE>20260603<MEMO>Buy ACME</INVTRAN><SECID><UNIQUEID>000000001<UNIQUEIDTYPE>CUSIP</SECID><UNITS>10<UNITPRICE>50.00<COMMISSION>1.00<TOTAL>-501.00<SUBACCTSEC>CASH<SUBACCTFUND>CASH</INVBUY><BUYTYPE>BUY</BUYSTOCK>
        <BUYMF><INVBUY><INVTRAN><FITID>B-2<DTTRADE>20260605</INVTRAN><SECID><UNIQUEID>000000002<UNIQUEIDTYPE>CUSIP</SECID><UNITS>20.5<UNITPRICE>10.00<TOTAL>-205.00<SUBACCTSEC>CASH<SUBACCTFUND>CASH</INVBUY><BUYTYPE>BUY</BUYMF>
        <SELLSTOCK><INVSELL><INVTRAN><FITID>S-1<DTTRADE>20260620</INVTRAN><SECID><UNIQUEID>000000001<UNIQUEIDTYPE>CUSIP</SECID><UNITS>-4<UNITPRICE>60.00<COMMISSION>1.00<TOTAL>239.00<SUBACCTSEC>CASH<SUBACCTFUND>CASH</INVSELL><SELLTYPE>SELL</SELLSTOCK>
        <SELLSTOCK><INVSELL><INVTRAN><FITID>S-2<DTTRADE>20260621</INVTRAN><SECID><UNIQUEID>000000003<UNIQUEIDTYPE>CUSIP</SECID><UNITS>-5<UNITPRICE>20.00<TOTAL>100.00<SUBACCTSEC>CASH<SUBACCTFUND>CASH</INVSELL><SELLTYPE>SELL</SELLSTOCK>
        <INCOME><INVTRAN><FITID>D-1<DTTRADE>20260615<MEMO>Quarterly dividend</INVTRAN><SECID><UNIQUEID>000000001<UNIQUEIDTYPE>CUSIP</SECID><INCOMETYPE>DIV<TOTAL>3.20<SUBACCTSEC>CASH<SUBACCTFUND>CASH</INCOME>
        <INVBANKTRAN><STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260601<TRNAMT>1000.00<FITID>C-1<NAME>DEPOSIT</STMTTRN><SUBACCTFUND>CASH</INVBANKTRAN>
        </INVTRANLIST>
        <INVPOSLIST>
        <POSSTOCK><INVPOS><SECID><UNIQUEID>000000001<UNIQUEIDTYPE>CUSIP</SECID><HELDINACCT>CASH<POSTYPE>LONG<UNITS>6<UNITPRICE>62.50<MKTVAL>375.00<DTPRICEASOF>20260630</INVPOS></POSSTOCK>
        <POSMF><INVPOS><SECID><UNIQUEID>000000002<UNIQUEIDTYPE>CUSIP</SECID><HELDINACCT>CASH<POSTYPE>LONG<UNITS>20.5<UNITPRICE>10.40<MKTVAL>213.20<DTPRICEASOF>20260630</INVPOS></POSMF>
        </INVPOSLIST>
        <INVBAL><AVAILCASH>536.20<MARGINBALANCE>0<SHORTBALANCE>0</INVBAL>
        </INVSTMTRS></INVSTMTTRNRS></INVSTMTMSGSRSV1>
        <SECLISTMSGSRSV1><SECLIST>
        <STOCKINFO><SECINFO><SECID><UNIQUEID>000000001<UNIQUEIDTYPE>CUSIP</SECID><SECNAME>Acme Corp<TICKER>ACME<UNITPRICE>62.50<DTASOF>20260630</SECINFO></STOCKINFO>
        <MFINFO><SECINFO><SECID><UNIQUEID>000000002<UNIQUEIDTYPE>CUSIP</SECID><SECNAME>Broad Bond Fund<TICKER>BBF</SECINFO><MFTYPE>OPENEND<ASSETCLASS>DOMESTICBOND</MFINFO>
        <STOCKINFO><SECINFO><SECID><UNIQUEID>000000003<UNIQUEIDTYPE>CUSIP</SECID><SECNAME>Old Holding Inc<TICKER>OLDH</SECINFO></STOCKINFO>
        </SECLIST></SECLISTMSGSRSV1>
        </OFX>
        """

    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    @Test func parsesInvestmentStatements() throws {
        let statements = try OFX.investmentStatements(Self.brokerage)
        #expect(statements.count == 1)
        let statement = statements[0]
        #expect(statement.accountID == "INV-5555" && statement.brokerID == "summit.example.com" && statement.organization == "Summit Brokerage")
        #expect(statement.asOf == FinanceCalendar.day(2026, 6, 30) && statement.currency == .usd)
        #expect(statement.trades.map(\.fitID) == ["B-1", "B-2", "S-1", "S-2"])
        let buy = statement.trades[0]
        #expect(buy.side == .buy && buy.kind == "BUYSTOCK" && buy.units == 10 && buy.unitPrice == 50 && buy.fees == 1 && buy.memo == "Buy ACME")
        let sale = statement.trades[2]
        #expect(sale.side == .sell && sale.units == 4, "OFX writes sold units as negative; the trade keeps them positive")
        #expect(statement.trades[1].units == Decimal(string: "20.5"))
        #expect(statement.income.count == 1 && statement.income[0].incomeType == "DIV")
        #expect(try statement.income[0].total == usd("3.20"))
        #expect(statement.cash.count == 1 && statement.cash[0].fitID == "C-1")
        #expect(statement.positions.map(\.units) == [6, Decimal(string: "20.5")!])
        #expect(try statement.positions[0].marketValue == usd("375"))
        #expect(try statement.availableCash == usd("536.20"))
        #expect(statement.securities["000000001"]?.symbol == "ACME" && statement.securities["000000001"]?.assetClass == .equity)
        #expect(statement.securities["000000002"]?.assetClass == .fixedIncome, "A fund's stated bond class")
        // A bank statement file has no investment statements, and an investment file no bank ones.
        #expect(try OFX.investmentStatements(Fixtures.sgmlOFX).isEmpty)
        #expect(throws: FinanceError.self) { try OFX.statements(Self.brokerage) }
    }

    @Test func importsTradesIncomePositionsAndPricesAsRecordedTruth() throws {
        let world = try FinanceWorld()
        let summary = try world.importer.importStatements(Data(Self.brokerage.utf8), named: "summit-june.ofx", by: person)
        #expect(summary.bank.isEmpty && summary.investment.count == 1)
        let result = summary.investment[0]
        let account = result.account
        #expect(account.kind == .brokerage && account.name == "Summit Brokerage ••5555" && account.accountNumber == "INV-5555")

        #expect(Set(result.securitiesCreated.map(\.symbol)) == ["ACME", "BBF", "OLDH"])
        let acme = try #require(try world.portfolio.security(uniqueID: "000000001"))
        #expect(acme.symbol == "ACME" && acme.name == "Acme Corp" && acme.assetClass == .equity)

        // Three trades recorded; the sale of units bought before the statement is skipped, not guessed.
        #expect(result.trades.map(\.fitID) == ["B-1", "B-2", "S-1"])
        #expect(result.skippedTrades.map(\.trade.fitID) == ["S-2"])
        #expect(result.skippedTrades[0].reason.contains("import the earlier statement"))
        for trade in result.trades {
            #expect(trade.record.provenance.truth == .recorded)
            #expect(trade.record.provenance.origin == .importer(source: summary.document.id))
            #expect(trade.record.provenance.dependencies == [summary.document.id])
        }

        // Derived cost basis and gains from the imported trades, priced from the statement.
        let position = try world.portfolio.position(of: acme.id, in: account.id)
        #expect(position.quantity == 6)
        #expect(try position.costBasis == usd("300.60"))
        #expect(try position.realizedGain == usd("38.60"))
        #expect(try position.price?.price == usd("62.50") && position.price?.truth == .recorded)
        #expect(try position.marketValue == usd("375") && position.unrealizedGain == usd("74.40"))
        #expect(result.prices == 2, "The security list repeats ACME's position price, which is stored once")

        // The broker's stated position sits on the holding as recorded truth beside the derived quantity.
        let holding = try #require(try world.portfolio.holding(of: acme.id, in: account.id))
        #expect(Decimal(holding.attributes[FinanceKey.statedQuantity]?.value) == 6)
        #expect(holding.truth(of: FinanceKey.statedQuantity) == .recorded)
        #expect(holding.truth(of: FinanceKey.quantity) == .derived)

        // Income and cash rows are transactions on the account.
        #expect(result.cash.created.map(\.payee).sorted() == ["DEPOSIT", "Dividend ACME"])
        #expect(result.cash.created.allSatisfy { $0.truth == .recorded })

        let allocation = try world.portfolio.allocation(accounts: [account.id], currency: .usd)
        #expect(try allocation.total == usd("588.20"))
        #expect(allocation.slices.map(\.assetClass) == [.equity, .fixedIncome])

        // Re-importing the same file adds nothing.
        let again = try world.importer.importStatements(Data(Self.brokerage.utf8), named: "summit-june.ofx", by: person)
        let second = again.investment[0]
        #expect(again.document.id == summary.document.id && second.account.id == account.id)
        #expect(second.trades.isEmpty && second.duplicateTrades.count == 3 && second.skippedTrades.count == 1)
        #expect(second.cash.created.isEmpty && second.cash.duplicates.count == 2)
        #expect(second.prices == 0 && second.securitiesCreated.isEmpty)
        #expect(try world.portfolio.position(of: acme.id, in: account.id).quantity == 6)
    }

    @Test func theOFXImporterCoversInvestmentFiles() throws {
        let world = try FinanceWorld()
        let results = try world.importer.importOFX(Data(Self.brokerage.utf8), named: "summit.ofx", by: person)
        #expect(results.count == 1 && results[0].created.count == 2, "The cash rows of the investment statement")
        #expect(try world.store.objects(ofType: .trade).count == 3)
        #expect(throws: FinanceError.self) {
            try world.importer.importOFX(Data("<OFX><SIGNONMSGSRSV1></SIGNONMSGSRSV1></OFX>".utf8), named: "empty.ofx", by: person)
        }
    }
}
