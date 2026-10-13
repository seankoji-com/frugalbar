import Foundation
import QuotaBarCore

/// Pure logic behind the History window's at-a-glance strip and its
/// provider picker.
///
/// The strip is small multiples: one card per provider instance, each with
/// that instance's own longest window drawn from its own readings. Nothing is
/// summed or averaged across cards — vendors meter different things over
/// different windows — and a card's figure is always the latest reading the
/// store holds for that window, never one carried over from an older poll.
public enum HistoryOverviewPresentation {

    /// One thing the History window can chart: a vendor, or one OpenCode Go
    /// workspace.
    public struct Subject: Identifiable, Sendable, Equatable, Hashable {
        /// The instance key readings are stored under.
        public let id: String
        public let vendor: VendorIdentifier
        public let name: String
        /// Every stored key that belongs to this subject. The workspace that
        /// inherited the pre-workspace `opencode` key also owns the readings an
        /// install recorded under that key before workspaces existed.
        public let keys: [String]

        public init(id: String, vendor: VendorIdentifier, name: String, keys: [String]? = nil) {
            self.id = id
            self.vendor = vendor
            self.name = name
            self.keys = keys ?? [id]
        }
    }

    /// The subjects to offer, in the user's provider order and, for OpenCode
    /// Go, the user's workspace order — the same order the popover draws.
    ///
    /// A hidden provider is left out, as it is everywhere else: it is not
    /// polled, so a History entry for it would chart readings that stopped
    /// arriving the moment it was hidden. A disabled workspace is left out
    /// for the same reason.
    public static func subjects(
        order: [VendorIdentifier],
        hidden: Set<VendorIdentifier>,
        workspaces: [OpenCodeGoWorkspace]
    ) -> [Subject] {
        order.filter { !hidden.contains($0) }.flatMap { vendor -> [Subject] in
            guard vendor == .opencode else {
                return [Subject(id: vendor.rawValue, vendor: vendor, name: vendor.displayName)]
            }
            return workspaces.filter(\.isEnabled).map { workspace in
                Subject(
                    id: workspace.instanceID,
                    vendor: .opencode,
                    name: workspace.name,
                    keys: workspace.id == OpenCodeGoWorkspaceStore.legacyID
                        ? [workspace.instanceID, VendorIdentifier.opencode.rawValue]
                        : [workspace.instanceID]
                )
            }
        }
    }

    /// The names of hidden providers, in the user's order, so the window can
    /// say why they are absent rather than leave the user hunting for them.
    public static func hiddenNames(order: [VendorIdentifier], hidden: Set<VendorIdentifier>) -> [String] {
        order.filter { hidden.contains($0) }.map(\.displayName)
    }

    /// One small-multiple card.
    public struct Card: Identifiable, Sendable, Equatable {
        public var id: String { subject.id }
        public let subject: Subject
        /// The window drawn: the longest one with a measured reading in range.
        public let barLabel: String
        /// The window's readings in range, oldest first. Gaps and resets
        /// break the line exactly as on the main chart.
        public let segments: [HistoryPresentation.TimelineSegment]
        /// The newest reading for the window, whatever it said. Its fraction
        /// is nil when that poll got no figure, and the card then shows none
        /// rather than an older one.
        public let latest: QuotaHistoryStore.ReadingRecord
        public let readingCount: Int

        /// The figure the card leads with, or nil when the latest poll had
        /// none.
        public var latestPercent: Int? {
            latest.fraction.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        }
    }

    /// Cards for the subjects that have a consumption reading in `readings`,
    /// in subject order; `empty` names the ones that have none.
    public static func overview(
        subjects: [Subject],
        readings: [QuotaHistoryStore.ReadingRecord]
    ) -> (cards: [Card], empty: [Subject]) {
        let consumption = HistoryPresentation.consumptionReadings(readings)
        var cards: [Card] = []
        var empty: [Subject] = []
        for subject in subjects {
            let own = consumption.filter { subject.keys.contains($0.vendor) }
            guard let label = longestMeasuredLabel(own) else {
                empty.append(subject)
                continue
            }
            let window = own.filter { $0.barLabel == label }.sorted { $0.measuredAt < $1.measuredAt }
            guard let latest = window.last else {
                empty.append(subject)
                continue
            }
            cards.append(Card(
                subject: subject,
                barLabel: label,
                segments: HistoryPresentation.segments(from: window),
                latest: latest,
                readingCount: window.count
            ))
        }
        return (cards, empty)
    }

    /// The longest window that has at least one measured reading; ties and
    /// windows of unpublished length fall back to the label, so the choice is
    /// stable from one reload to the next.
    static func longestMeasuredLabel(_ readings: [QuotaHistoryStore.ReadingRecord]) -> String? {
        var lengths: [String: TimeInterval] = [:]
        for record in readings where record.fraction != nil {
            lengths[record.barLabel] = max(lengths[record.barLabel] ?? -1, record.windowLength ?? -1)
        }
        return lengths.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }

    /// Bucket width for the overview read: about 120 points per sparkline
    /// whatever the range, never finer than a poll.
    public static func sampleBucketSeconds(range: HistoryPresentation.TimeRange, retention: TimeInterval) -> Int {
        let span: TimeInterval = switch range {
        case .last24Hours: 86_400
        case .last7Days: 7 * 86_400
        case .last30Days: 30 * 86_400
        case .allTime: retention
        }
        return max(120, Int(span / 120))
    }

    /// Why a subject has no card, in words: the window is being asked to
    /// explain an absence, not to draw one.
    public static func emptyExplanation(isSampleMode: Bool, range: HistoryPresentation.TimeRange) -> String {
        if isSampleMode {
            return "The sample data has no readings for these in this range."
        }
        return range == .allTime
            ? "No readings recorded yet. FrugalBar records a reading each time it polls a configured provider."
            : "No readings in the last \(range.title.lowercased()). FrugalBar records a reading each time it polls a configured provider."
    }

    // MARK: - Inspecting a point

    /// The reading nearest to `date` on each segment's window, for the chart's
    /// hover readout. One per window label, nearest first; nil when nothing
    /// was recorded within `tolerance` of `date`, so the readout never names a
    /// reading from hours away as "this point".
    public static func nearestPoints(
        to date: Date,
        in segments: [HistoryPresentation.TimelineSegment],
        tolerance: TimeInterval
    ) -> [(barLabel: String, point: HistoryPresentation.TimelinePoint)] {
        var best: [String: HistoryPresentation.TimelinePoint] = [:]
        var order: [String] = []
        for segment in segments {
            for point in segment.points {
                let distance = abs(point.timestamp.timeIntervalSince(date))
                guard distance <= tolerance else { continue }
                if let current = best[segment.barLabel] {
                    if distance < abs(current.timestamp.timeIntervalSince(date)) { best[segment.barLabel] = point }
                } else {
                    best[segment.barLabel] = point
                    order.append(segment.barLabel)
                }
            }
        }
        return order.compactMap { label in best[label].map { (label, $0) } }
    }

    /// How close the pointer must be to a reading for the readout to claim
    /// it: a fiftieth of the visible span, at least five minutes.
    public static func inspectionTolerance(range: HistoryPresentation.TimeRange, now: Date, earliest: Date?) -> TimeInterval {
        let start = range.startDate(from: now) ?? earliest ?? now.addingTimeInterval(-86_400)
        return max(300, now.timeIntervalSince(start) / 50)
    }
}
