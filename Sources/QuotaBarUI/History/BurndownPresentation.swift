import Foundation
import QuotaBarCore

/// Pure presentation logic for the inspector's burndown and history charts.
///
/// Every line drawn from this is either a recorded reading or arithmetic on
/// figures the vendor published. The ideal pro-rata line exists only when the
/// latest reading carries both a reset time and a window length; the
/// projection exists only when `BurnRateForecast` found a real recent pace. A
/// missing input removes the line — it is never replaced by a guess.
public enum BurndownPresentation {

    /// One recorded reading, as both used and remaining share of the window.
    public struct Point: Identifiable, Sendable, Equatable {
        public var id: String { "\(timestamp.timeIntervalSince1970)" }
        public let timestamp: Date
        public let usedFraction: Double
        public let remainingFraction: Double
        public let isBlocked: Bool
        public let urgency: Urgency

        public init(timestamp: Date, usedFraction: Double, isBlocked: Bool, urgency: Urgency) {
            let used = min(max(usedFraction, 0), 1)
            self.timestamp = timestamp
            self.usedFraction = used
            self.remainingFraction = 1 - used
            self.isBlocked = isBlocked
            self.urgency = urgency
        }
    }

    /// One unbroken stretch of one window. A reset, an outage or a long gap
    /// starts a new `Series` with the same label, so the chart never draws a
    /// line across it.
    public struct Series: Identifiable, Sendable, Equatable {
        public var id: String { "\(label)|\(points.first?.timestamp.timeIntervalSince1970 ?? 0)" }
        public let label: String
        public let points: [Point]

        public init(label: String, points: [Point]) {
            self.label = label
            self.points = points
        }
    }

    /// A vertex of a derived line (ideal or projection), as remaining share.
    public struct LinePoint: Sendable, Equatable {
        public let date: Date
        public let remainingFraction: Double

        public init(date: Date, remainingFraction: Double) {
            self.date = date
            self.remainingFraction = remainingFraction
        }
    }

    public struct Burndown: Sendable, Equatable {
        public let barLabel: String
        /// `resetsAt - windowLength`; nil unless the vendor published both.
        public let windowStart: Date?
        public let resetsAt: Date?
        /// The current window's readings, oldest first.
        public let actual: [Point]
        /// 100% at `windowStart`, 0% at `resetsAt`. Nil without both.
        public let ideal: [LinePoint]?
        /// From the latest reading at the recent pace, to exhaustion or reset,
        /// whichever comes first. Nil unless the window is measurably burning.
        public let projection: [LinePoint]?
        public let nowRemaining: Double?
        /// The reading `nowRemaining` came from.
        public let latestReading: QuotaHistoryStore.ReadingRecord?

        public init(
            barLabel: String,
            windowStart: Date?,
            resetsAt: Date?,
            actual: [Point],
            ideal: [LinePoint]?,
            projection: [LinePoint]?,
            nowRemaining: Double?,
            latestReading: QuotaHistoryStore.ReadingRecord?
        ) {
            self.barLabel = barLabel
            self.windowStart = windowStart
            self.resetsAt = resetsAt
            self.actual = actual
            self.ideal = ideal
            self.projection = projection
            self.nowRemaining = nowRemaining
            self.latestReading = latestReading
        }

        /// True when a projection runs out before the window resets.
        public var projectedExhaustion: Date? {
            guard let last = projection?.last, last.remainingFraction <= 0 else { return nil }
            return last.date
        }
    }

    // MARK: - Burndown

    /// The current window of `barLabel` for one vendor.
    ///
    /// "Current" is the last unbroken segment under
    /// `HistoryPresentation.segments` semantics — consumption readings only,
    /// broken on a changed reset time, an expired window, a reset-sized drop
    /// or a long gap. Returns nil when that window has no reading with a
    /// fraction, or when the vendor's own reset time for it has already
    /// passed (the readings describe a window that is over).
    public static func burndown(
        readings: [QuotaHistoryStore.ReadingRecord],
        vendorId: VendorIdentifier,
        barLabel: String,
        now: Date
    ) -> Burndown? {
        let records = HistoryPresentation.consumptionReadings(readings)
            .filter { $0.vendor == vendorId.rawValue && $0.barLabel == barLabel && $0.measuredAt <= now }
            .sorted { $0.measuredAt < $1.measuredAt }

        // The newest record must itself carry a fraction. Reaching back past
        // a trailing nil to an older reading would present stale headroom as
        // current, and project from it — the one thing a chart titled "now"
        // must never do.
        guard let segment = HistoryPresentation.segments(from: records).last,
              let latest = records.last,
              let latestFraction = latest.fraction,
              segment.points.last?.timestamp == latest.measuredAt
        else { return nil }
        if let resetsAt = latest.resetsAt, resetsAt <= now { return nil }

        let actual = segment.points.map {
            Point(timestamp: $0.timestamp, usedFraction: $0.fraction, isBlocked: $0.isBlocked, urgency: $0.urgency)
        }
        let nowRemaining = 1 - min(max(latestFraction, 0), 1)

        var windowStart: Date?
        var ideal: [LinePoint]?
        if let resetsAt = latest.resetsAt, let length = latest.windowLength, length > 0 {
            let start = resetsAt.addingTimeInterval(-length)
            windowStart = start
            ideal = [
                LinePoint(date: start, remainingFraction: 1),
                LinePoint(date: resetsAt, remainingFraction: 0),
            ]
        }

        var projection: [LinePoint]?
        if let forecast = BurnRateForecast.compute(
            vendorId: vendorId, barLabel: barLabel, readings: records,
            resetsAt: latest.resetsAt, now: now
        ), forecast.fractionPerHour > 0 {
            let origin = LinePoint(date: latest.measuredAt, remainingFraction: nowRemaining)
            let perSecond = forecast.fractionPerHour / 3600
            switch forecast.outcome {
            case .notBurning:
                break
            case .limitAt(let date):
                projection = [origin, LinePoint(date: max(date, latest.measuredAt), remainingFraction: 0)]
            case .resetsFirst(let resetsAt):
                let left = nowRemaining - perSecond * resetsAt.timeIntervalSince(latest.measuredAt)
                projection = [origin, LinePoint(date: resetsAt, remainingFraction: min(max(left, 0), 1))]
            }
        }

        return Burndown(
            barLabel: barLabel,
            windowStart: windowStart,
            resetsAt: latest.resetsAt,
            actual: actual,
            ideal: ideal,
            projection: projection,
            nowRemaining: nowRemaining,
            latestReading: latest
        )
    }

    /// The x-axis domain: the vendor's window when it is known, otherwise
    /// the span of what was recorded (and projected). Nil when that span is a
    /// single instant, so the chart picks its own domain.
    public static func windowRange(for burndown: Burndown) -> ClosedRange<Date>? {
        if let start = burndown.windowStart, let end = burndown.resetsAt, start < end {
            return start...end
        }
        let dates = burndown.actual.map(\.timestamp) + (burndown.projection?.map(\.date) ?? [])
        guard let lo = dates.min(), let hi = dates.max(), lo < hi else { return nil }
        return lo...hi
    }

    // MARK: - History

    /// Used share over `range`, one `Series` per unbroken stretch of each
    /// consumption window. Windows are segmented separately: interleaving two
    /// labels through one segmentation pass would break the line at every
    /// poll. Longest window first, then by time.
    public static func history(
        readings: [QuotaHistoryStore.ReadingRecord],
        vendorId: VendorIdentifier,
        range: HistoryPresentation.TimeRange,
        now: Date
    ) -> [Series] {
        let start = range.startDate(from: now)
        let records = HistoryPresentation.consumptionReadings(readings).filter { record in
            record.vendor == vendorId.rawValue && record.measuredAt <= now
                && (start.map { record.measuredAt >= $0 } ?? true)
        }
        return labelsLongestFirst(records).flatMap { label in
            HistoryPresentation.segments(from: records.filter { $0.barLabel == label }).map { segment in
                Series(label: label, points: segment.points.map {
                    Point(timestamp: $0.timestamp, usedFraction: $0.fraction, isBlocked: $0.isBlocked, urgency: $0.urgency)
                })
            }
        }.filter { !$0.points.isEmpty }
    }

    /// Distinct labels, longest recorded window first; windows with no
    /// length sort last, alphabetically.
    static func labelsLongestFirst(_ records: [QuotaHistoryStore.ReadingRecord]) -> [String] {
        var lengths: [String: TimeInterval] = [:]
        for record in records {
            lengths[record.barLabel] = max(lengths[record.barLabel] ?? -1, record.windowLength ?? -1)
        }
        return lengths.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    // MARK: - Text

    /// e.g. "27% left · 21h 0m to reset · ahead of pace · out in 3h 10m".
    /// Each clause appears only when its input was measured.
    public static func summaryLine(for burndown: Burndown, now: Date) -> String {
        var parts: [String] = []
        if let remaining = burndown.nowRemaining {
            parts.append("\(percent(remaining))% left")
        }
        if let resetsAt = burndown.resetsAt, resetsAt > now {
            parts.append("\(BurnRateForecast.formatDuration(resetsAt.timeIntervalSince(now))) to reset")
        }
        if let pace = paceWords(for: burndown, now: now) {
            parts.append(pace)
        }
        if let exhaustion = burndown.projectedExhaustion, exhaustion > now {
            parts.append("out in \(BurnRateForecast.formatDuration(exhaustion.timeIntervalSince(now)))")
        }
        return parts.isEmpty ? "No current reading" : parts.joined(separator: " · ")
    }

    /// "ahead of pace" / "on pace" / "under pace", from
    /// `HistoryPresentation.computePace` — nil without a window length.
    static func paceWords(for burndown: Burndown, now: Date) -> String? {
        guard let reading = burndown.latestReading,
              let pace = HistoryPresentation.computePace(reading: reading, now: now)
        else { return nil }
        switch pace.status {
        case .aheadOfPace: return "ahead of pace"
        case .onPace: return "on pace"
        case .underPace: return "under pace"
        }
    }

    /// Spoken description of the burndown chart.
    public static func accessibilityDescription(for burndown: Burndown, now: Date) -> String {
        var parts = ["\(burndown.barLabel) window"]
        if let remaining = burndown.nowRemaining {
            parts.append("\(percent(remaining)) percent remaining")
        }
        if let resetsAt = burndown.resetsAt, resetsAt > now {
            parts.append("resets in \(BurnRateForecast.formatDuration(resetsAt.timeIntervalSince(now)))")
        }
        if let pace = paceWords(for: burndown, now: now) {
            parts.append(pace)
        }
        if burndown.actual.contains(where: \.isBlocked) {
            parts.append("blocked during this window")
        }
        parts.append("\(burndown.actual.count) reading\(burndown.actual.count == 1 ? "" : "s")")
        if burndown.ideal != nil {
            parts.append("ideal pace line shown")
        }
        if let exhaustion = burndown.projectedExhaustion, exhaustion > now {
            parts.append("at recent pace runs out in \(BurnRateForecast.formatDuration(exhaustion.timeIntervalSince(now)))")
        } else if burndown.projection != nil {
            parts.append("at recent pace resets before running out")
        }
        return parts.joined(separator: ", ")
    }

    /// Spoken description of the history chart.
    public static func historyAccessibilityDescription(
        series: [Series],
        range: HistoryPresentation.TimeRange
    ) -> String {
        guard !series.isEmpty else { return "No readings in the \(range.title.lowercased()) range" }
        var labels: [String] = []
        for s in series where !labels.contains(s.label) { labels.append(s.label) }
        return labels.compactMap { label -> String? in
            let points = series.filter { $0.label == label }.flatMap(\.points)
            guard let latest = points.max(by: { $0.timestamp < $1.timestamp }),
                  let peak = points.max(by: { $0.usedFraction < $1.usedFraction })
            else { return nil }
            return "\(label): latest \(percent(latest.usedFraction)) percent used, peak \(percent(peak.usedFraction)) percent, \(points.count) readings"
        }.joined(separator: ". ")
    }

    /// "2 banked", "2 banked · 1 redeemable now". Nil when the vendor
    /// publishes no reset credits at all.
    public static func resetCreditsText(available: Int?, applicable: Int?) -> String? {
        guard let available else { return nil }
        var text = "\(available) banked"
        if let applicable, applicable > 0 {
            text += " · \(applicable) redeemable now"
        }
        return text
    }

    static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}

/// What "Copy JSON" puts on the pasteboard: the inspector's measured facts,
/// with every absent figure omitted rather than written as a placeholder.
public struct InspectorExport: Codable, Equatable, Sendable {

    public struct Bar: Codable, Equatable, Sendable {
        public let label: String
        public let usedFraction: Double?
        public let isBlocked: Bool
        public let measuresElapsedTimeOnly: Bool
        public let resetsAt: Date?
        public let windowLengthSeconds: Double?
    }

    public let vendor: String
    public let displayName: String
    public let category: String
    /// "healthy", "warning", "critical" or "unavailable".
    public let status: String
    public let unavailableReason: String?
    public let plan: String?
    public let latencyMs: Int?
    public let resetCreditsAvailable: Int?
    public let resetCreditsApplicable: Int?
    public let lastUpdated: Date
    public let readingsCount: Int
    public let bars: [Bar]

    public init(snapshot: QuotaSnapshot, readingsCount: Int) {
        vendor = snapshot.vendorId.rawValue
        displayName = snapshot.displayName
        category = snapshot.category.rawValue
        switch snapshot.status {
        case .unavailable(let reason):
            status = "unavailable"
            unavailableReason = reason.headline
        case .measured(.none):
            status = "healthy"; unavailableReason = nil
        case .measured(.warning):
            status = "warning"; unavailableReason = nil
        case .measured(.critical):
            status = "critical"; unavailableReason = nil
        }
        plan = snapshot.planName
        latencyMs = snapshot.latencyMs
        resetCreditsAvailable = snapshot.resetCreditsAvailable
        resetCreditsApplicable = snapshot.resetCreditsApplicable
        lastUpdated = snapshot.lastUpdated
        self.readingsCount = readingsCount
        bars = snapshot.bars.map {
            Bar(
                label: $0.label,
                usedFraction: $0.primaryFraction,
                isBlocked: $0.isBlocked,
                measuresElapsedTimeOnly: $0.measuresElapsedTimeOnly,
                resetsAt: $0.resetsAt,
                windowLengthSeconds: $0.windowLength
            )
        }
    }

    /// Pretty-printed, sorted keys, ISO-8601 dates.
    public func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
