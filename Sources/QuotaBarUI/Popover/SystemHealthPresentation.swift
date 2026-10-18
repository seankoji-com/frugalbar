import SwiftUI
import QuotaBarCore

/// Shared presentation mapping from a `SystemHealthSummary` to the header and
/// footer indicators.
///
/// The popover footer and the desktop widget header each render an aggregate
/// health indicator (symbol, colour, text). The footer names the most recent
/// check separately from the age of the figures retained after a failed poll.
enum SystemHealthPresentation {

    // `nonisolated`: pure functions of their arguments, so synchronous,
    // non-isolated `@Test`s can call them directly. Kept deliberately free of
    // any main-actor isolation inference so the presentation logic stays
    // purely testable.
    nonisolated static func symbol(for summary: SystemHealthSummary) -> String {
        guard summary.hasAnyReading else { return "minus.circle" }
        switch summary.worstUrgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    nonisolated static func color(for summary: SystemHealthSummary) -> Color {
        guard summary.hasAnyReading else { return Theme.outline }
        switch summary.worstUrgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
        }
    }

    nonisolated static func text(for summary: SystemHealthSummary) -> String {
        var parts: [String] = []
        if summary.hasAnyReading {
            switch summary.worstUrgency {
            case .none:     parts.append("All quotas healthy")
            case .warning:  parts.append("\(summary.warningCount) running low")
            case .critical: parts.append("\(summary.criticalCount) critical")
            }
        } else {
            parts.append("No readings")
        }
        if summary.unavailableCount > 0 {
            parts.append("\(summary.unavailableCount) not readable")
        }
        // Said separately from "not readable": a stale provider still has a
        // reading, so it counts as read everywhere else — but the person
        // looking at hour-old figures needs to know they are hour-old.
        if summary.staleCount > 0 {
            parts.append("\(summary.staleCount) stale")
        }
        return parts.joined(separator: " · ")
    }

    /// `now` is a parameter, not a captured `Date()`, so a test can assert an
    /// exact boundary ("59s", not "60s") instead of racing the clock between
    /// building the input date and reading it back.
    nonisolated static func elapsed(since date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        if interval < 3600 { return "\(Int((interval / 60).rounded()))m" }
        return "\(Int((interval / 3600).rounded()))h"
    }

    nonisolated static func pollStatus(
        lastAttemptAt: Date?, isRefreshing: Bool, now: Date
    ) -> String {
        if isRefreshing { return "Checking…" }
        guard let lastAttemptAt else { return "Not checked" }
        if now.timeIntervalSince(lastAttemptAt) < 60 { return "Checked now" }
        return "Checked \(elapsed(since: lastAttemptAt, now: now)) ago"
    }
}
