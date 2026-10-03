import Foundation
import QuotaBarCore

/// Pure presentation logic for the desktop widget's Overview layout.
///
/// One tile per provider, each carrying that provider's own windows. There is
/// deliberately no total, average or "overall" figure: vendors meter different
/// things over different windows, so any single number would assert something
/// nobody published. The only cross-provider line is the health summary,
/// which counts providers rather than combining quotas.
public enum OverviewPresentation {

    public struct WindowCell: Identifiable, Sendable, Equatable {
        public var id: String { label }
        public let label: String
        /// 0…1 in the filter's metric (used or remaining). nil when the vendor
        /// gave no percentage — drawn as an absence, never as 0 or 100.
        public let fraction: Double?
        public let isBlocked: Bool
        /// A hand-entered billing cycle: elapsed time, not consumption.
        public let measuresElapsedTimeOnly: Bool
        public let resetsAt: Date?
        public let metrics: DualBarMetrics
    }

    public struct Tile: Identifiable, Sendable, Equatable {
        public var id: VendorIdentifier { vendorId }
        public let vendorId: VendorIdentifier
        public let name: String
        public let planName: String?
        public let status: ProviderStatus
        public let isExhausted: Bool
        public let windows: [WindowCell]
        /// Set when the provider could not be read.
        public let unavailableHeadline: String?
        public let unavailableRemedy: String?
    }

    /// Tiles for the snapshots, in the order given (the store's order, which
    /// already follows the user's provider preferences).
    ///
    /// A provider that is not configured is left out: a desktop panel has
    /// nothing useful to say about it. One that is configured but unreadable
    /// keeps its tile and says why, so a failure never reads as health.
    public static func tiles(snapshots: [QuotaSnapshot], filters: WidgetFilters) -> [Tile] {
        snapshots.compactMap { snapshot in
            if snapshot.status.unavailableReason == .notConfigured { return nil }
            if !filters.vendors.isEmpty, !filters.vendors.contains(snapshot.vendorId) { return nil }

            let measured = snapshot.status.confidence == .measured
            let windows: [WindowCell] = measured ? snapshot.displayBars.map { bar in
                let used = bar.primaryFraction.map { min(max($0, 0), 1) }
                return WindowCell(
                    label: bar.label,
                    fraction: used.map { filters.metric == .used ? $0 : 1 - $0 },
                    isBlocked: bar.isBlocked,
                    measuresElapsedTimeOnly: bar.measuresElapsedTimeOnly,
                    resetsAt: bar.resetsAt,
                    metrics: bar
                )
            } : []

            let reason = snapshot.status.unavailableReason
            let exhausted = snapshot.isQuotaExhausted || snapshot.isFullyBlockedWithoutReading
            return Tile(
                vendorId: snapshot.vendorId,
                name: snapshot.shortVendorName,
                planName: snapshot.shortPlanName.isEmpty ? nil : snapshot.shortPlanName,
                status: snapshot.status,
                isExhausted: measured && exhausted,
                windows: windows,
                unavailableHeadline: reason?.headline,
                unavailableRemedy: reason?.remedy
            )
        }
    }

    /// The spoken form of a tile: every figure a sighted user can read.
    public static func accessibilityLabel(for tile: Tile, metric: WidgetFilters.Metric, now: Date = Date()) -> String {
        var parts = [tile.planName.map { "\(tile.name), \($0)" } ?? tile.name]
        if let headline = tile.unavailableHeadline {
            parts.append(headline)
            if let remedy = tile.unavailableRemedy { parts.append(remedy) }
            return parts.joined(separator: ". ")
        }
        let word = metric == .used ? "used" : "remaining"
        for window in tile.windows {
            var text = WindowColumn.column(forLabel: window.label)?.spokenName ?? window.label
            if window.measuresElapsedTimeOnly {
                text += " cycle"
                if let fraction = window.fraction {
                    // Elapsed share, never a quota figure.
                    text += " \(Int((fraction * 100).rounded())) percent \(metric == .used ? "elapsed" : "left")"
                }
            } else if let fraction = window.fraction {
                text += " \(Int((fraction * 100).rounded())) percent \(word)"
            } else {
                text += window.isBlocked ? " blocked" : " no reading"
            }
            if window.resetsAt != nil {
                text += ", \(ResetCountdownBadge.description(window.resetsAt, now: now).lowercased())"
            }
            parts.append(text)
        }
        if tile.isExhausted { parts.append("exhausted") }
        return parts.joined(separator: ". ")
    }
}
