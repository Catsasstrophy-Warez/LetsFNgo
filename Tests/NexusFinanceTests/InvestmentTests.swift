import Foundation
import NexusCore
import NexusFinance
import NexusModel
import NexusPersistence
import Testing

@Suite struct InvestmentTests {
    let person = Origin.user(id: "sam")

    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    @Test func costBasisGainsPricesAndAllocation() throws {
        let world = try FinanceWorld()
        let portfolio = world.portfolio
        let brokerage = try world.ledger.addAccount(name: "Brokerage", kind: .brokerage, currency: .usd, by: person)
        let vti = try portfolio.addSecurity(symbol: "vti", name: "Total Stock Market ETF", assetClass: .equity, currency: .usd, by: person)
        let bnd = try portfolio.addSecurity(symbol: "BND", name: "Total Bond Market ETF", assetClass: .fixedIncome, currency: .usd, by: person)
        let gld = try portfolio.addSecurity(symbol: "GLD", name: "Gold Trust", assetClass: .commodity, currency: .usd, by: person)
        #expect(try vti.symbol == "VTI" && portfolio.security(symbol: "vti")?.id == vti.id)
        #expect(throws: FinanceError.duplicateSymbol("VTI")) {
            try portfolio.addSecurity(symbol: "VTI", name: "Again", assetClass: .equity, currency: .usd, by: person)
        }

        func trade(_ month: Int, _ side: TradeSide, _ quantity: Decimal, _ price: String, fees: String? = nil, _ security: Security) throws {
            try portfolio.recordTrade(
                TradeDraft(
                    date: FinanceCalendar.day(2026, month, 2), side: side, quantity: quantity, price: try usd(price), fees: try fees.map { try usd($0) }),
                of: security.id, in: brokerage.id, by: person)
        }
        try trade(1, .buy, 10, "100", fees: "1", vti)
        try trade(2, .buy, 10, "120", fees: "1", vti)
        try trade(3, .sell, 15, "130", fees: "1.50", vti)
        try trade(1, .buy, 20, "75", bnd)
        try trade(1, .buy, Decimal(string: "0.5")!, "180", gld)
        #expect(throws: FinanceError.insufficientQuantity(available: 5, requested: 6)) { try trade(4, .sell, 6, "130", vti) }
        #expect(throws: FinanceError.invalidQuantity(0)) { try trade(4, .buy, 0, "130", vti) }
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) {
            try portfolio.recordTrade(
                TradeDraft(date: Fixtures.t0, side: .buy, quantity: 1, price: try Money("1", .eur)), of: vti.id, in: brokerage.id, by: person)
        }

        // Prices: the broker's feed records, an agent only claims.
        let feed = try world.store.create(
            ObjectRecord(type: .document, title: "Broker price file", provenance: Provenance(origin: person, truth: .recorded, timestamp: Fixtures.t0)))
        let recorded = try portfolio.recordPrice(try usd("140"), of: vti.id, at: FinanceCalendar.day(2026, 3, 31), by: .importer(source: feed.id))
        let claimed = try portfolio.recordPrice(try usd("200"), of: vti.id, at: FinanceCalendar.day(2026, 4, 1), by: .agent(id: "research", run: nil))
        let modelQuote = try portfolio.recordPrice(
            try usd("210"), of: vti.id, at: FinanceCalendar.day(2026, 4, 2), by: .model(ModelRef(provider: "x", modelID: "y")))
        try portfolio.recordPrice(try usd("74"), of: bnd.id, at: FinanceCalendar.day(2026, 3, 31), by: .importer(source: feed.id))
        #expect(recorded.truth == .recorded && claimed.truth == .claimed && modelQuote.truth == .claimed)
        #expect(try portfolio.prices(of: vti.id).count == 3)
        #expect(try portfolio.latestRecordedPrice(of: vti.id)?.price == usd("140"), "Claimed prices never drive gains")

        // FIFO: the sale consumes lot 1 (10 @ 100.10) and half of lot 2 (5 of 10 @ 120.10).
        let fifo = try portfolio.position(of: vti.id, in: brokerage.id, method: .fifo)
        #expect(fifo.quantity == 5 && fifo.lots.count == 1)
        #expect(try fifo.costBasis == usd("600.50") && fifo.lots[0].unitCost == usd("120.10"))
        #expect(try fifo.realizedGain == usd("347"))
        #expect(try fifo.marketValue == usd("700") && fifo.unrealizedGain == usd("99.50"))

        // Average cost: every unit carries 110.10.
        let average = try portfolio.position(of: vti.id, in: brokerage.id, method: .average)
        #expect(try average.quantity == 5 && average.costBasis == usd("550.50"))
        #expect(try average.realizedGain == usd("297") && average.unrealizedGain == usd("149.50"))

        // As of February: two open lots, nothing realised, no recorded price yet.
        let february = try portfolio.position(of: vti.id, in: brokerage.id, asOf: FinanceCalendar.day(2026, 2, 28))
        #expect(february.quantity == 20 && february.lots.count == 2 && february.realizedGain.isZero && february.marketValue == nil)

        // The holding carries derived quantity and cost basis.
        let holding = try #require(try portfolio.holding(of: vti.id, in: brokerage.id))
        #expect(holding.attributes[FinanceKey.quantity]?.value == .string("5") && holding.truth(of: FinanceKey.costBasis) == .derived)
        #expect(try Money(holding.attributes[FinanceKey.costBasis]?.value) == usd("600.50"))
        #expect(holding.provenance.truth == .recorded)
        #expect(try portfolio.holdings(in: brokerage.id).map(\.security.symbol).sorted() == ["BND", "GLD", "VTI"])

        // Allocation from recorded prices; gold has none, so it is listed as unpriced.
        let allocation = try portfolio.allocation(accounts: [brokerage.id], currency: .usd)
        #expect(try allocation.total == usd("2180") && allocation.unpriced == [gld.id])
        let equity = try #require(allocation.slices.first { $0.assetClass == .equity })
        let bonds = try #require(allocation.slices.first { $0.assetClass == .fixedIncome })
        #expect(try equity.value == usd("700") && bonds.value == usd("1480"))
        #expect((equity.weight + bonds.weight).rounded(scale: 20) == 1)
        #expect(equity.weight.rounded(scale: 4) == Decimal(string: "0.3211"))
        #expect(throws: MoneyError.currencyMismatch(.eur, .usd)) { try portfolio.allocation(accounts: [brokerage.id], currency: .eur) }
    }
}
