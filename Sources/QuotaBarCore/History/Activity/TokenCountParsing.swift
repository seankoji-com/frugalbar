import Foundation
import CoreFoundation

/// Exact conversion of a JSON number to a non-negative token count.
///
/// `NSNumber.doubleValue` is not an integer parser. `Double(Int.max)` is
/// exactly 2^63, so a value of `Int.max` passed the old rounded upper-bound
/// check and then trapped in `Int(_:)`; `Double` also silently rounds every
/// integer above 2^53. JSONSerialization keeps an exact `Int64`/`UInt64`
/// representation for JSON integers, so the exact value is read from that and
/// only a value that both fits and is integral becomes an observation.
enum TokenCountParsing {

    /// The exact non-negative value, or nil when the number is negative,
    /// fractional, a boolean, or outside `Int`'s range.
    static func nonNegative(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull), let number = value as? NSNumber else { return nil }
        // JSON booleans bridge to NSNumber; they are not counts.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }

        switch String(cString: number.objCType) {
        case "q":
            let exact = number.int64Value
            guard exact >= 0, exact <= Int64(Int.max) else { return nil }
            return Int(exact)
        case "Q":
            let exact = number.uint64Value
            guard exact <= UInt64(Int.max) else { return nil }
            return Int(exact)
        case "d":
            let double = number.doubleValue
            // 2^53 is the last integer a Double holds exactly. A larger
            // integral Double cannot be distinguished from a neighbour the
            // parser already rounded, so it is unrepresentable rather than a
            // count that quietly lost digits.
            let exactLimit = 9_007_199_254_740_992.0
            guard double.isFinite, double >= 0, double <= exactLimit,
                  double == double.rounded(.towardZero) else { return nil }
            return Int(double)
        default:
            return nil
        }
    }
}
