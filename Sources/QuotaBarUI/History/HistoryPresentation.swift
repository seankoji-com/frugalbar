import Foundation
import QuotaBarCore

/// Presentation logic and data models for historical quota views and charts.
///
/// Designed as pure, Sendable structures and functions to ensure complete
/// testability without UI lifecycle or database side effects.
public enum HistoryPresentation {

    public enum TimeRange: String, CaseIterable, Identifiable, Sendable {
        case last24Hours = "24h"
        case last7Days = "7d"
        case last30Days = "30d"
        case allTime = "All"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .last24Hours: "24 Hours"
            case .last7Days: "7 Days"
            case .last30Days: "30 Days"
            case .allTime: "All Time"
            }
        }

        public func startDate(from now: Date = Date()) -> Date? {
            switch self {
            case .last24Hours: now.addingTimeInterval(-24 * 3600)
            case .last7Days: now.addingTimeInterval(-7 * 86_400)
            case .last30Days: now.addingTimeInterval(-30 * 86_400)
            case .allTime: nil
            }
        }
    }

    public struct TimelinePoint: Identifiable, Sendable, Equatable {
        /// Derived from the reading's own timestamp rather than freshly minted,
        /// so a recomputed segment does not look like a different point to
        /// SwiftUI. Regenerating identity on every reload made the chart tear
        /// down and rebuild instead of animating.
        public var id: String { "\(timestamp.timeIntervalSince1970)" }

        public let timestamp: Date
        public let fraction: Double
        public let isBlocked: Bool
        public let confidence: Confidence
        public let urgency: Urgency

        public init(
            timestamp: Date,
            fraction: Double,
            isBlocked: Bool,
            confidence: Confidence,
            urgency: Urgency
        ) {
            self.timestamp = timestamp
            self.fraction = fraction
            self.isBlocked = isBlocked
            self.confidence = confidence
            self.urgency = urgency
        }
    }

    public struct TimelineSegment: Identifiable, Sendable, Equatable {
        /// Stable for the same window, so the chart's series identity survives a
        /// recompute.
        public var id: String {
            "\(vendor)|\(barLabel)|\(points.first?.timestamp.timeIntervalSince1970 ?? 0)"
        }

        public let vendor: String
        public let barLabel: String
        public let resetsAt: Date?
        public let points: [TimelinePoint]

        public init(
            vendor: String,
            barLabel: String,
            resetsAt: Date?,
            points: [TimelinePoint]
        ) {
            self.vendor = vendor
            self.barLabel = barLabel
            self.resetsAt = resetsAt
            self.points = points
        }
    }

    public enum PaceStatus: String, Sendable, Equatable {
        case aheadOfPace = "Ahead of Pace"
        case onPace = "On Pace"
        case underPace = "Frugal"
    }

    public struct PaceComparison: Sendable, Equatable {
        public let vendor: String
        public let barLabel: String
        public let consumedFraction: Double
        public let elapsedFraction: Double
        public let paceDelta: Double
        public let status: PaceStatus
        public let headline: String

        public init(
            vendor: String,
            barLabel: String,
            consumedFraction: Double,
            elapsedFraction: Double,
            paceDelta: Double,
            status: PaceStatus,
            headline: String
        ) {
            self.vendor = vendor
            self.barLabel = barLabel
            self.consumedFraction = consumedFraction
            self.elapsedFraction = elapsedFraction
            self.paceDelta = paceDelta
            self.status = status
            self.headline = headline
        }
    }

    /// Segments a stream of readings for a specific vendor and bar label into contiguous
    /// periods. Breaks on window reset, gap timeout, or sudden reset drop to avoid
    /// drawing artificial lines across quota discontinuities.
    ///
    /// `maxGap` is two hours on purpose rather than the "30m" an earlier draft of
    /// the description claimed: polling runs far more often than that, so a
    /// two-hour hole is a genuine ingestion outage. Anything shorter would break
    /// the line on an idle afternoon and imply a reset that never happened.
    public static func segments(
        from readings: [QuotaHistoryStore.ReadingRecord],
        maxGap: TimeInterval = 7200
    ) -> [TimelineSegment] {
        // Sort by timestamp
        let sorted = readings.sorted { $0.measuredAt < $1.measuredAt }

        var result: [TimelineSegment] = []
        var currentPoints: [TimelinePoint] = []
        var currentResetsAt: Date?
        var lastRecord: QuotaHistoryStore.ReadingRecord?
        var currentVendor: String = ""
        var currentLabel: String = ""

        func finalizeSegment() {
            if !currentPoints.isEmpty {
                result.append(TimelineSegment(
                    vendor: currentVendor,
                    barLabel: currentLabel,
                    resetsAt: currentResetsAt,
                    points: currentPoints
                ))
                currentPoints.removeAll()
            }
        }

        for record in sorted {
            guard let fraction = record.fraction else {
                // Outage / unavailable gap breaks the segment
                finalizeSegment()
                lastRecord = nil
                continue
            }

            let point = TimelinePoint(
                timestamp: record.measuredAt,
                fraction: fraction,
                isBlocked: record.isBlocked,
                confidence: record.confidence,
                urgency: record.urgency
            )

            if let prev = lastRecord {
                let isVendorOrLabelMismatch = prev.vendor != record.vendor || prev.barLabel != record.barLabel
                let isGap = record.measuredAt.timeIntervalSince(prev.measuredAt) > maxGap
                let resetsAtChanged = prev.resetsAt != nil && record.resetsAt != nil && prev.resetsAt != record.resetsAt
                let windowExpired = prev.resetsAt.map { record.measuredAt >= $0 } ?? false
                let negativeResetJump = (prev.fraction != nil) && (fraction < prev.fraction! - 0.15)

                if isVendorOrLabelMismatch || isGap || resetsAtChanged || windowExpired || negativeResetJump {
                    finalizeSegment()
                    currentVendor = record.vendor
                    currentLabel = record.barLabel
                    currentResetsAt = record.resetsAt
                }
            } else {
                currentVendor = record.vendor
                currentLabel = record.barLabel
                currentResetsAt = record.resetsAt
            }

            currentPoints.append(point)
            lastRecord = record
        }

        finalizeSegment()
        return result
    }

    /// Readings that measure consumption rather than elapsed time.
    ///
    /// A billing-cycle row is drawn in the popover because a bar is the right
    /// picture of "how far through the period are we" — but 90% elapsed is not
    /// 90% of quota used, and on a "Used %" axis it would read as consumption.
    /// `DualBarMetrics` draws that distinction for exactly this reason.
    public static func consumptionReadings(
        _ readings: [QuotaHistoryStore.ReadingRecord]
    ) -> [QuotaHistoryStore.ReadingRecord] {
        readings.filter { !$0.elapsedOnly }
    }

    /// Evaluates burn pace for an active sliding or fixed window.
    ///
    /// Compares fraction of quota consumed against fraction of window elapsed.
    /// Returns `nil` for a window that only measures elapsed time: its fraction
    /// *is* the elapsed fraction, so the comparison would be a quantity against
    /// itself — permanently "on pace", under a label that says "consumed".
    public static func computePace(
        reading: QuotaHistoryStore.ReadingRecord,
        now: Date = Date()
    ) -> PaceComparison? {
        guard !reading.elapsedOnly,
              let windowLength = reading.windowLength,
              let resetsAt = reading.resetsAt,
              let fraction = reading.fraction,
              windowLength > 0 else {
            return nil
        }

        let remainingTime = max(0, resetsAt.timeIntervalSince(now))
        let elapsedTime = max(0, windowLength - remainingTime)
        let elapsedFraction = min(1.0, max(0.0, elapsedTime / windowLength))
        let consumedFraction = min(1.0, max(0.0, fraction))
        let delta = consumedFraction - elapsedFraction

        let status: PaceStatus
        if delta > 0.10 {
            status = .aheadOfPace
        } else if delta < -0.10 {
            status = .underPace
        } else {
            status = .onPace
        }

        let consumedPercent = Int(round(consumedFraction * 100))
        let elapsedPercent = Int(round(elapsedFraction * 100))
        let deltaPercent = Int(round(abs(delta) * 100))

        let headline: String
        switch status {
        case .aheadOfPace:
            headline = "\(consumedPercent)% consumed with \(elapsedPercent)% window elapsed (+\(deltaPercent)% burn)"
        case .underPace:
            headline = "\(consumedPercent)% consumed with \(elapsedPercent)% window elapsed (-\(deltaPercent)% frugal)"
        case .onPace:
            headline = "\(consumedPercent)% consumed with \(elapsedPercent)% window elapsed (on pace)"
        }

        return PaceComparison(
            vendor: reading.vendor,
            barLabel: reading.barLabel,
            consumedFraction: consumedFraction,
            elapsedFraction: elapsedFraction,
            paceDelta: delta,
            status: status,
            headline: headline
        )
    }
}
