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

        switch interval {
        case ..<60:
            return "\(Int(interval.rounded()))s"
        case ..<3600:
            return "\(minutesRounded(interval))m"
        case ..<86400:
            let (h, m) = hoursMinutes(interval)
            return "\(h)h \(m)m"
        default:
            return absoluteDay(date)
        }
    }

    /// Expanded form for tooltips and accessibility labels.
    public static func description(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Resets now" }

        switch interval {
        case ..<60:
            return "Resets in \(Int(interval.rounded())) seconds"
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

    private static func absoluteDay(_ date: Date) -> String {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMd")
        return df.string(from: date)
    }
}
