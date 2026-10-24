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
}
