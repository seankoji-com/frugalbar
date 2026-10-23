import Foundation

/// Credits retain their published decimal precision, independently of money.
public enum CreditText {
    public static func format(_ value: Decimal) -> String {
        let parts = NSDecimalNumber(decimal: value).stringValue.split(separator: ".")
        let negative = parts[0].hasPrefix("-")
        let whole = negative ? String(parts[0].dropFirst()) : String(parts[0])
        let grouped = whole.reversed().enumerated().map { index, digit in
            (index > 0 && index.isMultiple(of: 3) ? "," : "") + String(digit)
        }.joined().reversed()
        return (negative ? "-" : "") + String(grouped) + (parts.count == 2 ? "." + parts[1] : "")
    }
}
