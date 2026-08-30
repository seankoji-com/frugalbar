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

        public init(
            vendorId: VendorIdentifier?,
            lowestRemainingFraction: Double?,
            remainingPctText: String?,
            timeLeftText: String?,
            displayText: String?,
            isUrgent: Bool
        ) {
            self.vendorId = vendorId
            self.lowestRemainingFraction = lowestRemainingFraction
            self.remainingPctText = remainingPctText
            self.timeLeftText = timeLeftText
            self.displayText = displayText
            self.isUrgent = isUrgent
        }
    }

    public static func recommendationDetails(
        advice: QuotaAdvice,
        snapshots: [QuotaSnapshot],
        summary: SystemHealthSummary
    ) -> RecommendationDetails {
        var targetVendor = advice.vendorId
        if targetVendor == nil {
            targetVendor = snapshots.first(where: { $0.category == .aiSubscriptions && $0.status.confidence == .measured })?.vendorId
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

        for bar in snapshot.bars {
            let used = bar.primaryFraction
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

        return RecommendationDetails(
            vendorId: vendorId,
            lowestRemainingFraction: foundBar ? lowestRemaining : nil,
            remainingPctText: remainingPctStr,
            timeLeftText: timeLeftStr,
            displayText: displayText,
            isUrgent: true
        )
    }

    public static func formatTimeLeft(_ text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return nil }
        let lower = text.lowercased()

        // 1. Look for days and hours: e.g. "4d 22h", "4d 6h", "13d"
        if let range = lower.range(of: #"(\d+)\s*d(\s*(\d+)\s*h)?"#, options: .regularExpression) {
            let match = String(lower[range])
            let parts = match.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let d = Double(parts.first ?? "") {
                if parts.count > 1, let h = Double(parts[1]), h > 0 {
                    let totalD = d + (h / 24.0)
                    return String(format: "%.1fd", totalD)
                } else {
                    return String(format: "%.0fd", d)
                }
            }
        }

        // 2. Look for hours and minutes: e.g. "3h 29m", "167h 25m", "1h 05m", "2h 10m"
        if let range = lower.range(of: #"(\d+)\s*h(\s*(\d+)\s*m)?"#, options: .regularExpression) {
            let match = String(lower[range])
            let parts = match.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let h = Double(parts.first ?? "") {
                if parts.count > 1, let m = Double(parts[1]), m > 0 {
                    let totalH = h + (m / 60.0)
                    return String(format: "%.2fhr", totalH)
                } else {
                    return String(format: "%.0fhr", h)
                }
            }
        }

        // 3. Look for minutes only: e.g. "42m"
        if let range = lower.range(of: #"(\d+)\s*m"#, options: .regularExpression) {
            let match = String(lower[range])
            let parts = match.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let m = Double(parts.first ?? "") {
                let totalH = m / 60.0
                return String(format: "%.2fhr", totalH)
            }
        }

        return nil
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
        return parts.joined(separator: ", ")
    }

}

