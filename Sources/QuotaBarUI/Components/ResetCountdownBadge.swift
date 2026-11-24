import Foundation

/// Formats relative time descriptions for reset/renewal timestamps.
///
/// Rounds to nearest rather than truncating. Truncation made a reset 2m59s
/// away read as "2m", and made any test that built a date from `Date()` race
/// the clock — `Int(179.97 / 60)` is 2, not 3.
public enum ResetCountdownBadge {

    /// Compact form for the popover row: `45s`, `12m`, `3h 20m`, `Mar 4`.
    public static func format(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Now" }

        // Round once, then branch on rounded value to avoid straddling thresholds.
        let totalSeconds = Int(interval.rounded())
        switch totalSeconds {
        case ..<1:
            return "1s"   // never show "0s"
        case ..<60:
            return "\(totalSeconds)s"
        case ..<3600:
            return "\(minutesRounded(interval))m"
        case ..<86400:
            let (h, m) = hoursMinutes(interval)
            return "\(h)h \(m)m"
        default:
            return absoluteDay(date)
        }
    }

    /// One unit, rounded: what the compact cell text and its spoken form both
    /// say, computed once so the two can never disagree.
    private enum CompactReset {
        case now
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    private static func compactReset(_ date: Date?, now: Date) -> CompactReset? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return .now }
        let minutes = Int((interval / 60).rounded())
        switch minutes {
        case ..<1:
            return .minutes(1)
        case ..<60:
            return .minutes(minutes)
        case ..<(24 * 60):
            // 23.6h rounds to 24: that is a day, not "24h".
            let hours = Int((interval / 3600).rounded())
            return hours >= 24 ? .days(1) : .hours(hours)
        default:
            return .days(Int((interval / 86_400).rounded()))
        }
    }

    /// The shortest form, for a cell under a bar: `45m`, `3h`, `6d`. One unit,
    /// rounded, so it fits a 53pt column beside a percentage. nil when there
    /// is no reset time; `now` once it has passed.
    public static func compact(_ date: Date?, now: Date = Date()) -> String? {
        switch compactReset(date, now: now) {
        case nil:             nil
        // Passed: the reset is owed and no reading has shown it yet. "now"
        // beside a 100% bar read as "back now" while it was still spent.
        case .now:            "due"
        case .minutes(let n): "\(n)m"
        case .hours(let n):   "\(n)h"
        case .days(let n):    "\(n)d"
        }
    }

    /// The spoken form of `compact`, for VoiceOver: "resets in 3 hours". A
    /// figure a sighted user can read in the cell has to reach the row's
    /// label too. nil when there is no reset time.
    public static func compactSpoken(_ date: Date?, now: Date = Date()) -> String? {
        guard let span = spanSpoken(date, now: now) else { return nil }
        return span == "now" ? "reset due, awaiting a reading" : "resets in \(span)"
    }

    /// `compact` as a phrase for the inspector: "Resets in 3h", "Resets in 6d",
    /// "Resets now". One unit, so it never disagrees with the Subscriptions
    /// cell the inspector was opened from.
    public static func compactDescription(_ date: Date, now: Date = Date()) -> String {
        guard let span = compact(date, now: now), span != "due" else { return "Reset due · awaiting a reading" }
        return "Resets in \(span)"
    }

    /// A `compact` figure in a spoken sentence: "resets in 3h", or for a
    /// passed reset "reset due, awaiting a reading" (never "resets in due").
    public static func spokenClause(forCompact span: String) -> String {
        span == "due" ? "reset due, awaiting a reading" : "resets in \(span)"
    }

    /// `compact`'s span in words, with no verb: "3 hours", "6 days", or "now"
    /// once it has passed. For a countdown that is not a reset ("runs out in").
    public static func spanSpoken(_ date: Date?, now: Date = Date()) -> String? {
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        switch compactReset(date, now: now) {
        case nil:             return nil
        case .now:            return "now"
        case .minutes(let n): return unit(n, "minute")
        case .hours(let n):   return unit(n, "hour")
        case .days(let n):    return unit(n, "day")
        }
    }

    /// Expanded form for tooltips and accessibility labels.
    public static func description(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Resets now" }

        let totalSeconds = Int(interval.rounded())
        switch totalSeconds {
        case ..<1:
            return "Resets in 1 second"
        case ..<60:
            return "Resets in \(totalSeconds) seconds"
        case ..<3600:
            let m = minutesRounded(interval)
            return "Resets in \(m) minute\(m == 1 ? "" : "s")"
        case ..<86400:
            let (h, m) = hoursMinutes(interval)
            return "Resets in \(h)h \(m)m"
        default:
            return "Resets \(absoluteDay(date))"
        }
    }

    // MARK: - Helpers

    /// Rounds to nearest minute, but never reports 60 — that belongs in the
    /// hours branch, and returning it produced "60m" where "1h 0m" was meant.
    private static func minutesRounded(_ interval: TimeInterval) -> Int {
        min(max(Int((interval / 60).rounded()), 1), 59)
    }

    private static func hoursMinutes(_ interval: TimeInterval) -> (Int, Int) {
        let totalMinutes = Int((interval / 60).rounded())
        return (totalMinutes / 60, totalMinutes % 60)
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMd")
        return df
    }()

    private static func absoluteDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
