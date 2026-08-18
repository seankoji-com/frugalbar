import SwiftUI
import QuotaBarCore

/// Chooses the menu bar glyph and tint for an aggregate summary.
///
/// The governing rule: **only quota pressure changes the icon.** Providers we
/// cannot read are reported as a decoration, never by replacing the icon.
/// The previous revision ranked "unreadable" above "critical", so a provider
/// with no data source pinned the icon to a permanent error state and made a
/// genuinely exhausted quota impossible to display.
public enum MenuBarPresentation {

    public static func symbolName(for summary: SystemHealthSummary) -> String {
        guard summary.hasAnyReading else { return "gauge.with.dots.needle.bottom.0percent" }
        switch summary.worstUrgency {
        case .none:     return "gauge.with.dots.needle.bottom.0percent"
        case .warning:  return "gauge.with.dots.needle.bottom.50percent"
        case .critical: return "gauge.with.dots.needle.bottom.100percent"
        }
    }

    /// nil means "use the default template rendering", i.e. follow the menu bar
    /// appearance rather than forcing a colour. Only genuine quota pressure
    /// earns a colour.
    public static func tint(for summary: SystemHealthSummary) -> NSColor? {
        guard summary.hasAnyReading else { return nil }
        switch summary.worstUrgency {
        case .none:     return nil
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Whether to show a small dot indicating unreadable providers.
    public static func showsUnavailableBadge(for summary: SystemHealthSummary) -> Bool {
        summary.unavailableCount > 0
    }

    public static func accessibilityDescription(for summary: SystemHealthSummary) -> String {
        var parts: [String] = ["QuotaBar"]
        if summary.hasAnyReading {
            switch summary.worstUrgency {
            case .none:     parts.append("all quotas healthy")
            case .warning:  parts.append("\(summary.warningCount) quota running low")
            case .critical: parts.append("\(summary.criticalCount) quota critically low")
            }
        } else {
            parts.append("no readings available")
        }
        if summary.unavailableCount > 0 {
            parts.append("\(summary.unavailableCount) provider not readable")
        }
        return parts.joined(separator: ", ")
    }
}
