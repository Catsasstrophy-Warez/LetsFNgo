import Foundation
import NexusFinance
import Testing

@Suite struct MoneyTests {
    func usd(_ text: String) throws -> Money { try Money(text, .usd) }

    @Test func arithmeticIsExactDecimal() throws {
        // 0.1 + 0.2 is exactly 0.3, unlike a binary float.
        #expect(try usd("0.1") + usd("0.2") == usd("0.3"))
        #expect(try usd("10.00") - usd("0.01") == usd("9.99"))
        #expect(try usd("19.99") * 3 == usd("59.97"))
        #expect(try -usd("5") == usd("-5"))
        #expect(try Money.sum([usd("1.10"), usd("2.20"), usd("3.30")], in: .usd) == usd("6.6"))
        #expect(try Money.sum([Money](), in: .eur) == .zero(.eur))
        #expect(try usd("2").ratio(to: usd("8")) == Decimal(string: "0.25"))
    }

    @Test func currenciesNeverMixSilently() throws {
        let dollars = try usd("10")
        let euros = try Money("10", .eur)
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) { try dollars + euros }
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) { try dollars - euros }
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) { try dollars.compare(euros) }
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) { try Money.sum([dollars, euros], in: .usd) }
        #expect(throws: MoneyError.currencyMismatch(.usd, .eur)) { try Money.sum([euros], in: .usd) }
        #expect(dollars != euros)
    }

    @Test func currencyCodesAndMinorUnits() throws {
        #expect(try Currency("usd") == .usd)
        #expect(throws: MoneyError.invalidCurrency("US")) { try Currency("US") }
        #expect(throws: MoneyError.invalidCurrency("U$D")) { try Currency("U$D") }
        #expect(try Currency.usd.minorUnits == 2 && Currency.jpy.minorUnits == 0 && Currency("KWD").minorUnits == 3)
    }

    @Test func roundingRules() throws {
        #expect(try usd("2.345").rounded(.halfEven) == usd("2.34"))
        #expect(try usd("2.355").rounded(.halfEven) == usd("2.36"))
        #expect(try usd("2.345").rounded(.halfUp) == usd("2.35"))
        #expect(try usd("-2.345").rounded(.halfUp) == usd("-2.35"))
        #expect(try usd("-2.345").rounded(.halfEven) == usd("-2.34"))
        #expect(try usd("2.349").rounded(.towardZero) == usd("2.34"))
        #expect(try usd("-2.349").rounded(.towardZero) == usd("-2.34"))
        #expect(try usd("2.341").rounded(.awayFromZero) == usd("2.35"))
        #expect(try usd("-2.341").rounded(.awayFromZero) == usd("-2.35"))
        #expect(try Money("1234.5", .jpy).rounded() == Money("1234", .jpy))
        #expect(try Money("1.2345", try Currency("KWD")).rounded() == Money("1.234", try Currency("KWD")))
        #expect(try usd("12.3456").rounded(scale: 3) == usd("12.346"))
        #expect(try usd("1.005").isWholeMinorUnits == false && usd("1.01").isWholeMinorUnits)
    }

    @Test func allocationAddsUpExactly() throws {
        let parts = try usd("100").allocate([1, 1, 1])
        #expect(parts == [try usd("33.34"), try usd("33.33"), try usd("33.33")])
        #expect(try Money.sum(parts, in: .usd) == usd("100"))
        let negative = try usd("-0.05").allocate([1, 1])
        #expect(negative == [try usd("-0.03"), try usd("-0.02")])
        #expect(throws: MoneyError.divisionByZero) { try usd("1").allocate([0]) }
    }

    @Test func parsingAndDescription() throws {
        #expect(try usd("-12.5").description == "-12.50 USD")
        #expect(try Money("1234.5", .jpy).description == "1234 JPY")
        #expect(try usd("0.005").description == "0.00 USD")
        #expect(throws: MoneyError.invalidAmount("1e3")) { try usd("1e3") }
        #expect(throws: MoneyError.invalidAmount("12abc")) { try usd("12abc") }
        #expect(throws: MoneyError.invalidAmount("1.2.3")) { try usd("1.2.3") }
        #expect(Decimal(exactly: "+0.25") == Decimal(string: "0.25"))
        #expect(Decimal(exactly: "5.") == nil && Decimal(exactly: ".5") == nil && Decimal(exactly: "") == nil)
    }

    @Test func codableKeepsTheAmountAsAString() throws {
        let money = try usd("12345678901234567.89")
        let data = try JSONEncoder().encode(money)
        #expect(String(decoding: data, as: UTF8.self).contains("\"12345678901234567.89\""))
        #expect(try JSONDecoder().decode(Money.self, from: data) == money)
        #expect(Money(money.value) == money)
    }

    @Test func yearMonth() {
        let september = YearMonth(2026, 9)
        #expect(september.description == "2026-09" && YearMonth("2026-09") == september)
        #expect(september.adding(4) == YearMonth(2027, 1) && september.adding(-9) == YearMonth(2025, 12))
        #expect(september.contains(FinanceCalendar.day(2026, 9, 30)) && !september.contains(FinanceCalendar.day(2026, 10, 1)))
        #expect(YearMonth(FinanceCalendar.day(2026, 2, 28)) == YearMonth(2026, 2))
    }
}
