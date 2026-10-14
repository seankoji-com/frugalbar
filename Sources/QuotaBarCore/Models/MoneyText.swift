import Foundation

/// The one money rendering the popover uses for a balance, a cap or a spend
/// figure.
///
/// Deterministic on purpose. `Decimal.formatted(.currency(code:))` and
/// `NumberFormatter` both consult the *process* locale, which made the same
/// USD figure read "$179.50" on one Mac and "USD 179.50" on the next — and,
/// worse, made a card say "USD 179.50" in its figure while the vendor's own
/// note right beneath it said "$200.00". A balance is a fact about a vendor
/// account, not about the reader's locale, so the symbol is chosen here.
///
/// The vendor's own currency code is always honoured: an AUD account reads
/// "A$", a USD account "$", and anything else is stated with its code rather
/// than guessed at a symbol. The fraction follows the currency's own minor
/// unit count, which is knowable even when the symbol is not: a JPY balance
/// prints no cents, a KWD balance prints three digits, and neither borrows
/// another currency's scale.
public enum MoneyText {

    /// `amount` in `code`, e.g. "$179.50", "A$12.00", "150.00 CNY", "1234 JPY".
    public static func format(_ amount: Decimal, code: String) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let digits = minorUnitDigits(code)
        switch code.uppercased() {
        case "AUD": return String(format: "A$%.\(digits)f", value)
        case "USD": return String(format: "$%.\(digits)f", value)
        default:    return String(format: "%.\(digits)f %@", value, code)
        }
    }

    /// The currency's own minor-unit digit count (ISO 4217).
    ///
    /// The exceptions are published, not guessed: the zero-decimal currencies
    /// plus the three that use thousandths, with two digits for everything
    /// else. Without this a JPY balance read "1234.00 JPY", claiming
    /// hundredths of a yen the vendor never sent.
    static func minorUnitDigits(_ code: String) -> Int {
        switch code.uppercased() {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW",
             "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF":
            return 0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
            return 3
        default:
            return 2
        }
    }
}
