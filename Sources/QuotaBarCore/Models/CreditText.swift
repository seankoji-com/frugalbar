import Foundation

/// A credit count, as the popover states it: the vendor's own unit, grouped,
/// rounded to the nearest whole credit. The published Decimal is kept intact
/// on the metric; only this display text rounds, so no balance is altered.
public enum CreditText {
    public static func format(_ value: Decimal) -> String {
        var rounded = Decimal()
        var raw = value
        NSDecimalRound(&rounded, &raw, 0, .plain)
        let parts = NSDecimalNumber(decimal: rounded).stringValue.split(separator: ".")
        let negative = parts[0].hasPrefix("-")
        let whole = negative ? String(parts[0].dropFirst()) : String(parts[0])
        let grouped = whole.reversed().enumerated().map { index, digit in
            (index > 0 && index.isMultiple(of: 3) ? "," : "") + String(digit)
        }.joined().reversed()
        return (negative ? "-" : "") + String(grouped)
    }

    /// The same count shortened for a glance: 60,085 → "60k", 1,250,000 →
    /// "1.3M" (owner, 26 Nov 2026). "60,085 credits" in a Wallet row is a
    /// precision the vendor's own console does not print, and it forced the
    /// amount column wider than any other line needs.
    ///
    /// Only figures at ten thousand and above shorten; below that the grouped
    /// number is already short. The exact Decimal is still what the metric, the
    /// history table and the inspector carry (`format`), so inspecting a figure
    /// never loses digits.
    public static func compact(_ value: Decimal) -> String {
        let negative = value < 0
        let magnitude = negative ? -value : value
        let text: String
        if magnitude >= 1_000_000 {
            text = short(magnitude / 1_000_000, places: 1) + "M"
        } else if magnitude >= 10_000 {
            text = short(magnitude / 1_000, places: 0) + "k"
        } else {
            return format(value)
        }
        return (negative ? "-" : "") + text
    }

    /// One rounded figure at `places` decimals, with a trailing ".0" dropped so
    /// "2M" is not printed as "2.0M".
    private static func short(_ value: Decimal, places: Int) -> String {
        var rounded = Decimal()
        var raw = value
        NSDecimalRound(&rounded, &raw, places, .plain)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        return places > 0 && text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
