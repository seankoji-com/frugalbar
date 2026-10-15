import CryptoKit
import Foundation

/// The sync snapshot's JSON, written by hand so the bytes are canonical.
///
/// Keys keep the order they are built in and nothing is pretty-printed, so the
/// same input always yields the same bytes: the fixtures compare them exactly,
/// and the 256 KB budget is measured on exactly what is uploaded. A decimal is
/// a JSON *string* (`^-?\d{1,18}(\.\d{1,8})?$`), never a number a reader could
/// round through a double.
indirect enum ExportJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case fraction(Double)
    case string(String)
    case array([ExportJSON])
    case object([(String, ExportJSON)])

    static func == (lhs: ExportJSON, rhs: ExportJSON) -> Bool {
        lhs.encoded() == rhs.encoded()
    }

    func encoded() -> Data {
        var out = ""
        write(to: &out)
        return Data(out.utf8)
    }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .fraction(let value): out += value.description
        case .string(let value):
            out += "\""
            out += ExportText.escaped(value)
            out += "\""
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                out += "\""
                out += ExportText.escaped(pair.0)
                out += "\":"
                pair.1.write(to: &out)
            }
            out += "}"
        }
    }
}

/// The D§2.2.E value domains, in one place.
public enum ExportText {

    /// Byte limits, measured on the UTF-8 *after* JSON escaping.
    public enum Limit: Int, Sendable, CaseIterable {
        /// `displayName`, `planName`, `label`, `publisherLabel`, `tierName`.
        case name = 64
        /// Units, `currencyCode`, `caption`, `basis`.
        case unit = 32
        /// A reason `message`, `apiCredits[].detail`, an event `title`.
        case message = 160
        /// An event `detail`.
        case eventDetail = 280
        /// An event `url`; longer is dropped, never cut.
        case url = 512
    }

    /// The largest integer a JSON reader can hold exactly (2^53 − 1).
    public static let maxInteger: Int64 = 9_007_199_254_740_991

    static let ellipsis = "…"

    /// `text` cut at a character boundary so that its escaped form, with "…"
    /// appended, fits in `limit` bytes. Text that already fits is unchanged.
    static func truncate(_ text: String, limit: Limit) -> String {
        guard escapedByteCount(text) > limit.rawValue else { return text }
        let budget = limit.rawValue - escapedByteCount(ellipsis)
        var used = 0
        var kept = ""
        for character in text {
            let cost = escapedByteCount(String(character))
            guard used + cost <= budget else { break }
            used += cost
            kept.append(character)
        }
        return kept + ellipsis
    }

    /// The UTF-8 length of `text` once escaped for a JSON string literal.
    public static func escapedByteCount(_ text: String) -> Int {
        escaped(text).utf8.count
    }

    /// JSON string escaping: quote, backslash and control characters only.
    /// Everything else, "/" included, is written as raw UTF-8.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A decimal as its exact text, or nil when it falls outside
    /// `^-?\d{1,18}(\.\d{1,8})?$`. Never rounded to make it fit: a value the
    /// schema cannot carry exactly is reported as out of range instead.
    static func decimal(_ value: Decimal) -> String? {
        guard value.isFinite else { return nil }
        let text = value.description
        guard text.wholeMatch(of: decimalPattern) != nil else { return nil }
        return text
    }

    nonisolated(unsafe) private static let decimalPattern = /-?\d{1,18}(\.\d{1,8})?/

    /// An integer inside 0 … 2^53 − 1, or nil.
    static func integer(_ value: Int) -> Int64? {
        guard value >= 0, Int64(value) <= maxInteger else { return nil }
        return Int64(value)
    }

    /// A fraction inside 0.0 … 1.0, or nil.
    static func fraction(_ value: Double) -> Double? {
        value.isFinite && (0...1).contains(value) ? value : nil
    }

    /// UTC ISO-8601 with milliseconds, e.g. `2026-10-15T06:26:17.000Z`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Every exported identity: the first 32 lowercase hex characters (128 bits)
/// of the SHA-256 of the full source identity. One function everywhere, so a
/// provider's `instanceId` and an event's reference to it stay equal.
public enum SnapshotExportIdentity {
    public static func digest(_ source: String) -> String {
        String(SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32))
    }
}
