import Foundation
import QuotaBarCore

// `TimeRange` is a String-backed enum; persisting the widget's filters needs it
// Codable, and the synthesised conformance encodes the raw value.
extension HistoryPresentation.TimeRange: Codable {}

/// What the desktop widget's chart is showing. Persisted as JSON.
public struct WidgetFilters: Codable, Equatable, Sendable {

    public enum Metric: String, Codable, CaseIterable, Sendable {
        case used
        case remaining

        public var title: String {
            switch self {
            case .used: "Used"
            case .remaining: "Remaining"
            }
        }
    }

    /// Empty means every vendor with a consumable window.
    public var vendors: Set<VendorIdentifier>
    /// nil means each vendor's longest consumable window.
    public var windowLabel: String?
    public var range: HistoryPresentation.TimeRange
    public var metric: Metric

    public init(
        vendors: Set<VendorIdentifier> = [],
        windowLabel: String? = nil,
        range: HistoryPresentation.TimeRange = .last24Hours,
        metric: Metric = .remaining
    ) {
        self.vendors = vendors
        self.windowLabel = windowLabel
        self.range = range
        self.metric = metric
    }

    private enum CodingKeys: String, CodingKey {
        case vendors, windowLabel, range, metric
    }

    /// Tolerant decoding: a vendor removed in a later release is dropped rather
    /// than failing the whole set, and a missing or unknown field takes its
    /// default instead of discarding every other choice the user made.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawVendors = (try? c.decodeIfPresent([String].self, forKey: .vendors)) ?? nil
        vendors = Set((rawVendors ?? []).compactMap(VendorIdentifier.init(rawValue:)))
        windowLabel = (try? c.decodeIfPresent(String.self, forKey: .windowLabel)) ?? nil
        range = ((try? c.decodeIfPresent(HistoryPresentation.TimeRange.self, forKey: .range)) ?? nil) ?? .last24Hours
        metric = ((try? c.decodeIfPresent(Metric.self, forKey: .metric)) ?? nil) ?? .remaining
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vendors.map(\.rawValue).sorted(), forKey: .vendors)
        try c.encodeIfPresent(windowLabel, forKey: .windowLabel)
        try c.encode(range, forKey: .range)
        try c.encode(metric, forKey: .metric)
    }

    /// Reads persisted filters; anything undecodable yields the defaults.
    public static func decode(_ data: Data?) -> WidgetFilters {
        guard let data, let decoded = try? JSONDecoder().decode(WidgetFilters.self, from: data) else {
            return WidgetFilters()
        }
        return decoded
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// Pure presentation logic for the desktop widget's cross-subscription chart.
///
/// Every figure here is a reading some vendor actually reported. There is
/// deliberately no "combined quota": vendors meter different things over
/// different windows, so adding or normalising them into one allowance would
/// assert a number nobody published. The only cross-vendor line is
/// `average(of:)`, an honestly labelled mean of real readings.
public enum AggregateBurndownPresentation {

    public struct SeriesPoint: Identifiable, Sendable, Equatable {
        public var id: String { "\(timestamp.timeIntervalSince1970)" }
        public let timestamp: Date
        /// 0…1, used or remaining per the filter's metric.
        public let value: Double
        public let urgency: Urgency
        public let isBlocked: Bool

        public init(timestamp: Date, value: Double, urgency: Urgency, isBlocked: Bool) {
            self.timestamp = timestamp
            self.value = value
            self.urgency = urgency
            self.isBlocked = isBlocked
        }
    }

    /// One unbroken stretch of a window. A reset, an outage, or a long gap
    /// starts a new segment, so the line is never drawn across it.
    public struct SeriesSegment: Identifiable, Sendable, Equatable {
        public var id: String { "\(points.first?.timestamp.timeIntervalSince1970 ?? 0)" }
        public let points: [SeriesPoint]

        public init(points: [SeriesPoint]) {
            self.points = points
        }
    }

    /// One vendor window's history, as chosen by the filters.
    public struct VendorSeries: Identifiable, Sendable, Equatable {
        public var id: String { "\(vendorId.rawValue)|\(barLabel)" }
        public let vendorId: VendorIdentifier
        public let barLabel: String
        public let segments: [SeriesSegment]

        public init(vendorId: VendorIdentifier, barLabel: String, segments: [SeriesSegment]) {
            self.vendorId = vendorId
            self.barLabel = barLabel
            self.segments = segments
        }

        public var allPoints: [SeriesPoint] { segments.flatMap(\.points) }
        public var latest: SeriesPoint? { allPoints.max { $0.timestamp < $1.timestamp } }
    }

    /// A bucket's mean across the series that had a reading in it.
    public struct AveragePoint: Identifiable, Sendable, Equatable {
        public var id: String { "\(timestamp.timeIntervalSince1970)" }
        /// Start of the bucket.
        public let timestamp: Date
        public let value: Double
        /// How many series contributed — never padded to the selected count.
        public let sampleCount: Int
        /// Increments across a gap, so the chart breaks the line there instead
        /// of drawing through a stretch with no readings.
        public let segment: Int

        public init(timestamp: Date, value: Double, sampleCount: Int, segment: Int) {
            self.timestamp = timestamp
            self.value = value
            self.sampleCount = sampleCount
            self.segment = segment
        }
    }

    public struct HeadroomItem: Identifiable, Sendable, Equatable {
        public var id: String { "\(vendorId.rawValue)|\(barLabel)" }
        public let vendorId: VendorIdentifier
        public let barLabel: String
        /// nil when the vendor gave no percentage — drawn as an absence.
        public let remainingFraction: Double?
        public let resetsAt: Date?
        public let urgency: Urgency
        public let isBlocked: Bool
        public let status: ProviderStatus

        public init(
            vendorId: VendorIdentifier,
            barLabel: String,
            remainingFraction: Double?,
            resetsAt: Date?,
            urgency: Urgency,
            isBlocked: Bool,
            status: ProviderStatus
        ) {
            self.vendorId = vendorId
            self.barLabel = barLabel
            self.remainingFraction = remainingFraction
            self.resetsAt = resetsAt
            self.urgency = urgency
            self.isBlocked = isBlocked
            self.status = status
        }
    }

    // MARK: - Vendor and window universe

    /// Vendors with at least one consumable window, in snapshot order. A
    /// vendor that only meters spend or only tracks a billing cycle has no
    /// burndown to draw.
    public static func availableVendors(snapshots: [QuotaSnapshot]) -> [VendorIdentifier] {
        var seen = Set<VendorIdentifier>()
        return snapshots.compactMap { snapshot in
            guard !snapshot.quotaBars.isEmpty, seen.insert(snapshot.vendorId).inserted else { return nil }
            return snapshot.vendorId
        }
    }

    /// Consumable window labels present across the snapshots, longest first.
    public static func availableWindowLabels(snapshots: [QuotaSnapshot]) -> [String] {
        var lengths: [String: TimeInterval] = [:]
        for bar in snapshots.flatMap(\.quotaBars) {
            let length = bar.windowLength ?? -1
            lengths[bar.label] = max(lengths[bar.label] ?? -1, length)
        }
        return lengths.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }.map(\.key)
    }

    /// The vendors the filters select. Empty filter means every vendor with a
    /// consumable window.
    public static func selectedVendors(snapshots: [QuotaSnapshot], filters: WidgetFilters) -> [VendorIdentifier] {
        let available = availableVendors(snapshots: snapshots)
        guard !filters.vendors.isEmpty else { return available }
        let ordered = available.filter { filters.vendors.contains($0) }
        let extra = filters.vendors.subtracting(ordered).sorted { $0.rawValue < $1.rawValue }
        return ordered + extra
    }

    /// The label to chart for one vendor: the explicit filter label, or the
    /// window with the largest `windowLength` among the vendor's latest
    /// consumption readings, falling back to the snapshot's longest quota bar.
    static func barLabel(
        for vendor: VendorIdentifier,
        consumptionReadings: [QuotaHistoryStore.ReadingRecord],
        snapshot: QuotaSnapshot?,
        filters: WidgetFilters
    ) -> String? {
        if let label = filters.windowLabel { return label }

        var latestByLabel: [String: QuotaHistoryStore.ReadingRecord] = [:]
        for record in consumptionReadings {
            if let existing = latestByLabel[record.barLabel], existing.measuredAt >= record.measuredAt { continue }
            latestByLabel[record.barLabel] = record
        }
        let longest = latestByLabel.values
            .compactMap { record -> (String, TimeInterval)? in
                record.windowLength.map { (record.barLabel, $0) }
            }
            .max { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0 > rhs.0 }
        if let longest { return longest.0 }
        // `bars` sorts longest first, so the first consumable one is the longest.
        if let label = snapshot?.quotaBars.first?.label { return label }
        return latestByLabel.values.max { $0.measuredAt < $1.measuredAt }?.barLabel
    }

    // MARK: - Series

    /// One series per selected vendor, each the window the filters choose.
    ///
    /// Only consumption readings are used: an elapsed-time-only billing cycle
    /// at 90% is not 90% of quota used. Readings without a fraction break the
    /// line rather than being drawn as 0 or 100. Segmentation reuses
    /// `HistoryPresentation.segments`, so a reset never connects to the
    /// previous window's line.
    public static func series(
        readings: [QuotaHistoryStore.ReadingRecord],
        snapshots: [QuotaSnapshot],
        filters: WidgetFilters,
        now: Date
    ) -> [VendorSeries] {
        let start = filters.range.startDate(from: now)
        let inRange = HistoryPresentation.consumptionReadings(readings).filter { record in
            record.measuredAt <= now && (start.map { record.measuredAt >= $0 } ?? true)
        }

        let vendors: [VendorIdentifier]
        if snapshots.isEmpty && filters.vendors.isEmpty {
            // Nothing polled yet: chart whatever history exists.
            vendors = Set(inRange.compactMap { VendorIdentifier(rawValue: $0.vendor) })
                .sorted { $0.rawValue < $1.rawValue }
        } else {
            vendors = selectedVendors(snapshots: snapshots, filters: filters)
        }

        return vendors.compactMap { vendor in
            let vendorReadings = inRange.filter { $0.vendor == vendor.rawValue }
            let snapshot = snapshots.first { $0.vendorId == vendor }
            guard let label = barLabel(
                for: vendor,
                consumptionReadings: vendorReadings,
                snapshot: snapshot,
                filters: filters
            ) else { return nil }

            let windowReadings = vendorReadings.filter { $0.barLabel == label }
            let segments = HistoryPresentation.segments(from: windowReadings).map { segment in
                SeriesSegment(points: segment.points.map { point in
                    let used = min(max(point.fraction, 0), 1)
                    return SeriesPoint(
                        timestamp: point.timestamp,
                        value: filters.metric == .used ? used : 1 - used,
                        urgency: point.urgency,
                        isBlocked: point.isBlocked
                    )
                })
            }.filter { !$0.points.isEmpty }
            guard !segments.isEmpty else { return nil }
            return VendorSeries(vendorId: vendor, barLabel: label, segments: segments)
        }
    }

    // MARK: - Average

    /// Time-bucketed mean across the given series.
    ///
    /// This is an average of real readings — NOT a combined quota. The windows
    /// being averaged can be different lengths from different vendors; the
    /// line answers "how much headroom does a typical selected window have",
    /// never "how much do I have in total".
    ///
    /// A bucket includes only the series that have a reading inside it (a
    /// series with several readings in one bucket contributes its own mean
    /// once), and `sampleCount` says how many did. Buckets with no readings
    /// produce no point: gaps are never filled or interpolated, and a gap
    /// longer than `maxGap` starts a new `segment` so the line breaks there.
    public static func average(
        of series: [VendorSeries],
        bucket: TimeInterval = 300,
        maxGap: TimeInterval = 7200,
        now: Date
    ) -> [AveragePoint] {
        guard bucket > 0 else { return [] }
        // bucket start -> per-series values
        var buckets: [TimeInterval: [String: [Double]]] = [:]
        for s in series {
            for point in s.allPoints where point.timestamp <= now {
                let t = point.timestamp.timeIntervalSince1970
                let key = (t / bucket).rounded(.down) * bucket
                buckets[key, default: [:]][s.id, default: []].append(point.value)
            }
        }

        var result: [AveragePoint] = []
        var segment = 0
        var previous: TimeInterval?
        for key in buckets.keys.sorted() {
            let perSeries = buckets[key]!.values.map { $0.reduce(0, +) / Double($0.count) }
            if let previous, key - previous > maxGap { segment += 1 }
            previous = key
            result.append(AveragePoint(
                timestamp: Date(timeIntervalSince1970: key),
                value: perSeries.reduce(0, +) / Double(perSeries.count),
                sampleCount: perSeries.count,
                segment: segment
            ))
        }
        return result
    }

    /// Legend text for the average line: "Average (3 windows)", or a range
    /// when buckets drew on different numbers of series.
    public static func averageLabel(for points: [AveragePoint]) -> String {
        let counts = points.map(\.sampleCount)
        guard let lo = counts.min(), let hi = counts.max() else { return "Average" }
        let noun = hi == 1 ? "window" : "windows"
        return lo == hi ? "Average (\(hi) \(noun))" : "Average (\(lo)–\(hi) windows)"
    }

    /// Average bucket width per range, keeping the average line to a few
    /// hundred points whatever the range.
    public static func bucketInterval(for range: HistoryPresentation.TimeRange) -> TimeInterval {
        switch range {
        case .last24Hours: 300
        case .last7Days: 1800
        case .last30Days, .allTime: 7200
        }
    }

    /// Thins each segment to at most `maxPointsPerSeries` points in total
    /// (shared across segments by size) for drawing. Keeps every segment's
    /// first and last reading and every point where urgency or the blocked
    /// flag changes, so a transition that mattered is never thinned away. Only
    /// ever drops real points — it never invents or averages one.
    public static func decimated(_ series: VendorSeries, maxPointsPerSeries: Int = 300) -> VendorSeries {
        let total = series.allPoints.count
        guard total > maxPointsPerSeries, maxPointsPerSeries > 0 else { return series }
        let stride = Int((Double(total) / Double(maxPointsPerSeries)).rounded(.up))
        let segments = series.segments.map { segment in
            let last = segment.points.count - 1
            let points = segment.points
            let kept = points.indices.filter { index in
                if index == 0 || index == last || index % stride == 0 { return true }
                let prev = points[index - 1], point = points[index]
                return point.urgency != prev.urgency || point.isBlocked != prev.isBlocked
            }.map { points[$0] }
            return SeriesSegment(points: kept)
        }
        return VendorSeries(vendorId: series.vendorId, barLabel: series.barLabel, segments: segments)
    }

    // MARK: - Headroom strip

    /// Current headroom for each selected vendor's chosen window. A bar with no
    /// percentage, or a provider we could not read, keeps a nil fraction.
    public static func currentHeadroom(
        snapshots: [QuotaSnapshot],
        filters: WidgetFilters
    ) -> [HeadroomItem] {
        let vendors = selectedVendors(snapshots: snapshots, filters: filters)
        return vendors.compactMap { vendor in
            guard let snapshot = snapshots.first(where: { $0.vendorId == vendor }) else { return nil }
            let bar: DualBarMetrics?
            if let label = filters.windowLabel {
                bar = snapshot.quotaBars.first { $0.label == label }
            } else {
                bar = snapshot.quotaBars.first
            }
            guard let bar else { return nil }
            let measured = snapshot.status.confidence == .measured
            let remaining = measured ? bar.primaryFraction.map { 1 - min(max($0, 0), 1) } : nil
            return HeadroomItem(
                vendorId: vendor,
                barLabel: bar.label,
                remainingFraction: remaining,
                resetsAt: bar.resetsAt,
                urgency: snapshot.status.urgency,
                isBlocked: bar.isBlocked,
                status: snapshot.status
            )
        }
    }

    // MARK: - Text

    public static func rangeShortTitle(_ range: HistoryPresentation.TimeRange) -> String {
        switch range {
        case .last24Hours: "24h"
        case .last7Days: "7d"
        case .last30Days: "30d"
        case .allTime: "all time"
        }
    }

    /// e.g. "All subscriptions · 24h · remaining", "Claude · WK · 7d · used".
    public static func title(for filters: WidgetFilters) -> String {
        var parts: [String] = []
        switch filters.vendors.count {
        case 0: parts.append("All subscriptions")
        case 1: parts.append(filters.vendors.first!.displayName)
        default: parts.append("\(filters.vendors.count) subscriptions")
        }
        if let label = filters.windowLabel { parts.append(label) }
        parts.append(rangeShortTitle(filters.range))
        parts.append(filters.metric.rawValue)
        return parts.joined(separator: " · ")
    }

    /// Spoken summary of the chart: each window's latest value and the
    /// average, with its sample count.
    public static func accessibilitySummary(
        series: [VendorSeries],
        average: [AveragePoint],
        filters: WidgetFilters
    ) -> String {
        guard !series.isEmpty else {
            return "No readings recorded in the \(filters.range.title.lowercased()) range"
        }
        let metricWord = filters.metric == .used ? "used" : "remaining"
        var parts = series.compactMap { s -> String? in
            guard let latest = s.latest else { return nil }
            let percent = Int((latest.value * 100).rounded())
            return "\(s.vendorId.displayName) \(s.barLabel): latest \(percent) percent \(metricWord)"
        }
        if series.count > 1, let last = average.last {
            let percent = Int((last.value * 100).rounded())
            let noun = last.sampleCount == 1 ? "window" : "windows"
            parts.append("Average of \(last.sampleCount) \(noun), not a combined quota: latest \(percent) percent \(metricWord)")
        }
        return parts.joined(separator: ". ")
    }
}
