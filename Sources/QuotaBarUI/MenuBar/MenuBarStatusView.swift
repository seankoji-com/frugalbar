import SwiftUI
import AppKit
import QuotaBarCore

/// Chooses the menu bar glyph, recommended platform logo, and remaining quota metrics for the menu bar.
public enum MenuBarPresentation {

    public struct RecommendationDetails: Sendable {
        public let vendorId: VendorIdentifier?
        public let lowestRemainingFraction: Double?
        public let remainingPctText: String?
        public let timeLeftText: String?
        public let displayText: String?
        public let isUrgent: Bool
        /// Tint for the *recommended vendor's own* reading, keyed to that
        /// snapshot's urgency rather than the whole-summary worst urgency.
        /// nil means "no pressure from this vendor" — follow the menu bar's
        /// own label/template colour.
        public let recommendedTint: NSColor?

        public init(
            vendorId: VendorIdentifier?,
            lowestRemainingFraction: Double?,
            remainingPctText: String?,
            timeLeftText: String?,
            displayText: String?,
            isUrgent: Bool,
            recommendedTint: NSColor? = nil
        ) {
            self.vendorId = vendorId
            self.lowestRemainingFraction = lowestRemainingFraction
            self.remainingPctText = remainingPctText
            self.timeLeftText = timeLeftText
            self.displayText = displayText
            self.isUrgent = isUrgent
            self.recommendedTint = recommendedTint
        }
    }

    public static func recommendationDetails(
        advice: QuotaAdvice,
        snapshots: [QuotaSnapshot],
        summary: SystemHealthSummary
    ) -> RecommendationDetails {
        var targetVendor = advice.vendorId
        if targetVendor == nil {
            // Healthy-first: when advice names no specific vendor, prefer one
            // with real headroom over one merely first in canonical order —
            // recommending a 25%-remaining vendor over a 90%-remaining one
            // just because it sorts earlier would be a bad recommendation.
            // `status.urgency == .none` alone isn't enough to mean "healthy":
            // an `.unavailable` status also reports urgency `.none`, so the
            // `.measured` filter must apply to both clauses, or an unreadable
            // provider could still win the first search and get presented as
            // a reading nobody ever took.
            targetVendor = snapshots.first(where: {
                $0.category == .aiSubscriptions && $0.status.confidence == .measured && $0.status.urgency == .none
            })?.vendorId
                ?? snapshots.first(where: { $0.category == .aiSubscriptions && $0.status.confidence == .measured })?.vendorId
        }

        guard let vendorId = targetVendor,
              let snapshot = snapshots.first(where: { $0.vendorId == vendorId }) else {
            return RecommendationDetails(
                vendorId: nil,
                lowestRemainingFraction: nil,
                remainingPctText: nil,
                timeLeftText: nil,
                displayText: nil,
                isUrgent: summary.worstUrgency == .critical
            )
        }


        // Find the bar with the lowest remaining capacity (highest primaryFraction)
        var lowestRemaining = 1.0
        var matchingResetText: String? = nil
        var foundBar = false

        for bar in snapshot.quotaBars {
            // A bar with no fraction (blocked, no percentage reported) has
            // nothing to measure "remaining" against — skip it rather than
            // coercing the missing reading to 0% or 100% remaining.
            guard let used = bar.primaryFraction else { continue }
            let remaining = max(0.0, min(1.0, 1.0 - used))
            if !foundBar || remaining < lowestRemaining {
                lowestRemaining = remaining
                matchingResetText = bar.resetText
                foundBar = true
            }
        }

        if !foundBar {
            if let fraction = snapshot.consumptionFraction {
                lowestRemaining = max(0.0, min(1.0, 1.0 - fraction))
                matchingResetText = nil
                foundBar = true
            }
        }

        let remainingPctStr: String?
        if foundBar {
            let remainingInt = Int((lowestRemaining * 100).rounded())
            remainingPctStr = "\(remainingInt)%"
        } else {
            remainingPctStr = nil
        }

        let timeLeftStr = formatTimeLeft(matchingResetText)

        let displayParts: [String] = [remainingPctStr, timeLeftStr].compactMap { $0 }
        let displayText = displayParts.isEmpty ? nil : displayParts.joined(separator: " ")

        // Tint the recommended vendor's own number, not the whole-summary worst
        // urgency. An unrelated vendor being critical must not paint this
        // healthy recommendation red. Only a genuine `.measured` reading earns
        // a colour; an unreadable provider has no pressure to display.
        let recommendedTint: NSColor?
        if snapshot.status.confidence == .measured {
            recommendedTint = tint(forUrgency: snapshot.status.urgency)
        } else {
            recommendedTint = nil
        }

        return RecommendationDetails(
            vendorId: vendorId,
            lowestRemainingFraction: foundBar ? lowestRemaining : nil,
            remainingPctText: remainingPctStr,
            timeLeftText: timeLeftStr,
            displayText: displayText,
            isUrgent: true,
            recommendedTint: recommendedTint
        )
    }

    public static func formatTimeLeft(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        // Match and compact from the same spellings, keeping months distinct
        // from minutes and preserving the vendor's reported unit.
        let units = [
            (pattern: #"mo(?:nths?)?"#, compact: "mo"),
            (pattern: #"w(?:eeks?)?"#, compact: "w"),
            (pattern: #"d(?:ays?)?"#, compact: "d"),
            (pattern: #"h(?:ours?|rs?)?"#, compact: "h"),
            (pattern: #"m(?:in(?:ute)?s?)?"#, compact: "m")
        ]
        let unitPattern = units.map(\.pattern).joined(separator: "|")
        let part = #"\d+\s*(?:\#(unitPattern))(?![a-z])"#
        let pattern = #"(?<![\d.])\#(part)(?:\s*\#(part))*"#
        guard let range = lower.range(of: pattern, options: .regularExpression) else { return nil }
        // RelativeDateTimeFormatter emits full units; compact only those units.
        let duration = units.reduce(String(lower[range])) { result, unit in
            result.replacingOccurrences(of: #"\s*\#(unit.pattern)\b"#,
                with: unit.compact, options: .regularExpression)
        }
        return duration.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

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
        return tint(forUrgency: summary.worstUrgency)
    }

    /// Maps an `Urgency` to a menu bar colour. Shared by `tint(for:)` and
    /// `recommendationDetails` so the colour scheme is defined in exactly one
    /// place. Reusing the same mapping is what lets a healthy recommended
    /// vendor stay untinted even when the whole summary is critical.
    private static func tint(forUrgency urgency: Urgency) -> NSColor? {
        switch urgency {
        case .none:     return nil
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Whether to show a small dot indicating unreadable providers.
    public static func showsUnavailableBadge(for summary: SystemHealthSummary) -> Bool {
        summary.unavailableCount > 0
    }

    public static func accessibilityDescription(
        for summary: SystemHealthSummary, recommendation: RecommendationDetails? = nil
    ) -> String {
        var parts: [String] = ["FrugalBar"]
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
        if let recommendation {
            if let percentage = recommendation.remainingPctText {
                parts.append("\(recommendation.vendorId?.displayName ?? "Recommended provider") \(percentage) remaining")
            }
            if let reset = recommendation.timeLeftText {
                parts.append("resets in \(reset)")
            }
        }
        return parts.joined(separator: ", ")
    }

}

