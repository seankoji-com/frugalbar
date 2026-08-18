import Foundation
import QuotaBarCore

/// Formats relative time descriptions for reset/renewal timestamps.
enum ResetCountdownBadge {

    static func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Now" }
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600) / 60))m" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    /// Human-readable description
    static func description(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resets now" }
        if interval < 60 { return "Resets in \(Int(interval))s" }
        if interval < 3600 { return "Resets in \(Int(interval / 60))m" }
        if interval < 86400 {
            let h = Int(interval / 3600)
            let m = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
            return "Resets in \(h)h \(m)m"
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "Resets \(df.string(from: date))"
    }
}
