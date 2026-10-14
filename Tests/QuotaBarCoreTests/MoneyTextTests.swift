import Testing
import Foundation
@testable import QuotaBarCore

/// The one money rendering.
///
/// Two properties carry it, and both have been broken in this codebase: it does
/// not consult the *process locale* (`.formatted(.currency(code:))` renders a
/// USD balance as "USD 1,234.50" under en_AU), and it does not invent precision
/// a currency does not have ("1234.00 JPY" asserts cents that do not exist).
@Suite("Money text")
struct MoneyTextTests {

    @Test("a known symbol is used, and an unknown code is stated")
    func symbols() {
        #expect(MoneyText.format(Decimal(string: "179.5")!, code: "USD") == "$179.50")
        #expect(MoneyText.format(Decimal(string: "12")!, code: "AUD") == "A$12.00")
        #expect(MoneyText.format(Decimal(string: "150")!, code: "CNY") == "150.00 CNY")
    }

    @Test("the vendor's code is matched however it is cased")
    func caseInsensitive() {
        #expect(MoneyText.format(Decimal(12), code: "usd") == "$12.00")
        #expect(MoneyText.format(Decimal(12), code: "aud") == "A$12.00")
    }

    /// A zero-decimal currency has no cents to print.
    @Test("a zero-decimal currency prints no decimals")
    func zeroDecimalCurrencies() {
        #expect(MoneyText.format(Decimal(1234), code: "JPY") == "1234 JPY")
        #expect(MoneyText.format(Decimal(62_500), code: "KRW") == "62500 KRW")
    }

    /// And a currency with a three-minor-unit scale keeps all three.
    @Test("a three-minor-unit currency prints three decimals")
    func threeDecimalCurrencies() {
        #expect(MoneyText.format(Decimal(string: "12.5")!, code: "KWD") == "12.500 KWD")
    }

    /// An unrecognised code keeps the documented default of two — the minor
    /// unit of most currencies, and the same default the Anthropic payload's
    /// own `decimal_places` takes when it states none.
    @Test("an unrecognised code keeps two decimals")
    func unknownCodeKeepsTwo() {
        #expect(MoneyText.format(Decimal(string: "12.5")!, code: "XYZ") == "12.50 XYZ")
    }

    /// The reason the type exists. This test process runs under en_AU, where
    /// `.formatted(.currency(code: "USD"))` would give "USD 1,234.50" — so the
    /// assertion fails if a locale ever creeps back in.
    @Test("a figure never takes the process locale's wording")
    func neverLocaleWording() {
        #expect(MoneyText.format(Decimal(string: "1234.5")!, code: "USD") == "$1234.50")
        #expect(!MoneyText.format(Decimal(string: "1234.5")!, code: "USD").contains("USD"))
    }
}
