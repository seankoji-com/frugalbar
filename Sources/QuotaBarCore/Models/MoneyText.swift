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
/// than guessed at a symbol.
public enum MoneyText {

    /// `amount` in `code`, e.g. "$179.50", "A$12.00", "150.00 CNY".
    public static func format(_ amount: Decimal, code: String) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        switch code.uppercased() {
        case "AUD": return String(format: "A$%.2f", value)
        case "USD": return String(format: "$%.2f", value)
        default:    return String(format: "%.2f %@", value, code)
        }
    }
}
