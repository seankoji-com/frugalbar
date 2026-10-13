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
    ///
    /// `usedFraction` and `remainingFraction` are bounded to 0...1 for chart
    /// geometry; `recordedFraction` is the figure as stored, for anything that
    /// reports the reading. A vendor that bills past its allowance records
    /// 1.03, and the readout must say 103%, not the 100% the line is drawn at.
    public struct Point: Identifiable, Sendable, Equatable {
        public var id: String { "\(timestamp.timeIntervalSince1970)" }
        public let timestamp: Date
        public let recordedFraction: Double
        public let usedFraction: Double
        public let remainingFraction: Double
        public let isBlocked: Bool
        public let urgency: Urgency

        public init(timestamp: Date, usedFraction: Double, isBlocked: Bool, urgency: Urgency) {
            let used = min(max(usedFraction, 0), 1)
            self.timestamp = timestamp
            self.recordedFraction = usedFraction
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

        /// True when the vendor blocked the window at the latest reading. Its
        /// remaining share is then a figure the vendor reported, not capacity
        /// the user can spend.
        public var isBlocked: Bool { latestReading?.isBlocked == true }

        /// True when a projection runs out before the window resets.
        public var projectedExhaustion: Date? {
            guard let last = projection?.last, last.remainingFraction <= 0 else { return nil }
            return last.date
        }
    }

    // MARK: - Burndown

    /// The current window of `barLabel` for one provider instance.
    ///
    /// `instanceID` is the instance's stable key (see `BurnRateForecast`), so
    /// two OpenCode Go workspaces are charted from their own readings.
    ///
    /// "Current" is the last unbroken segment under
    /// `HistoryPresentation.segments` semantics — consumption readings only,
    /// broken on a changed reset time, an expired window, a reset-sized drop
    /// or a long gap. Returns nil when the instance's newest poll did not
    /// report a fraction for that window, or when the vendor's own reset
    /// time for it has already passed (the readings describe a window that
    /// is over). `burndownAbsence` says which.
    public static func burndown(
        readings: [QuotaHistoryStore.ReadingRecord],
        instanceID: String,
        barLabel: String,
        now: Date
    ) -> Burndown? {
        let instance = readings.filter { $0.vendor == instanceID && $0.measuredAt <= now }
        let consumption = HistoryPresentation.consumptionReadings(instance)
        let records = consumption
            .filter { $0.barLabel == barLabel }
            .sorted { $0.measuredAt < $1.measuredAt }

        // The newest poll, of any label, must itself carry this window's
        // fraction. Reaching back past a trailing nil, or past a failed poll
        // recorded under the provider's own label, to an older reading would
        // present stale headroom as current and project from it — the one
        // thing a chart titled "now" must never do.
        guard let latest = HistoryPresentation.readingAtLatestPoll(readings: instance, barLabel: barLabel),
              !latest.elapsedOnly,
              let latestFraction = latest.fraction,
              let segment = HistoryPresentation.segments(from: consumption, barLabel: barLabel).last,
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

        // No projection from a blocked window: "out in 30m" beside a window
        // the vendor has already stopped reads as headroom left to burn.
        // The pace is taken from the drawn stretch only, so a projection is
        // never extrapolated from readings on the far side of an outage.
        var projection: [LinePoint]?
        let stretchStart = segment.points.first?.timestamp ?? latest.measuredAt
        if !latest.isBlocked, let forecast = BurnRateForecast.compute(
            instanceID: instanceID, barLabel: barLabel, readings: records.filter { $0.measuredAt >= stretchStart },
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
        instanceID: String,
        range: HistoryPresentation.TimeRange,
        now: Date
    ) -> [Series] {
        let start = range.startDate(from: now)
        let records = HistoryPresentation.consumptionReadings(readings).filter { record in
            record.vendor == instanceID && record.measuredAt <= now
                && (start.map { record.measuredAt >= $0 } ?? true)
        }
        return labelsLongestFirst(records).flatMap { label in
            HistoryPresentation.segments(from: records, barLabel: label).map { segment in
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

    // MARK: - Absence

    /// Why an inspector chart has nothing to draw. Each case is something the
    /// history recorded, so the chart can say why it is empty instead of
    /// calling every absence "no readings yet": a failed poll or a window
    /// that was polled without a figure is not an empty history.
    public enum Absence: Sendable, Equatable {
        /// Nothing recorded for this instance at all.
        case noReadings
        /// Readings exist, but none inside the chosen range.
        case noneInRange
        /// The newest poll could not be read.
        case lastPollFailed
        /// The newest poll answered without a figure for `label`.
        /// `isBlocked` when the vendor reported the window blocked.
        case noFigureAtLastPoll(label: String, isBlocked: Bool)
        /// The vendor's reset for `label` passed after its newest reading.
        case windowExpired(label: String)
        /// `pollCount` polls in range, none with a figure to chart.
        case polledWithoutFigures(pollCount: Int, lastPollFailed: Bool)

        public var message: String {
            switch self {
            case .noReadings:
                return "No readings yet — history accumulates as FrugalBar polls"
            case .noneInRange:
                return "No readings in this range. A longer range shows the earlier ones."
            case .lastPollFailed:
                return "The last poll could not be read, so there is no current burndown. Earlier readings are under History."
            case .noFigureAtLastPoll(let label, true):
                return "The vendor blocked \(label) and published no figure for it at the last poll, so there is no burndown to draw."
            case .noFigureAtLastPoll(let label, false):
                return "The last poll reported no figure for \(label), so there is no current burndown."
            case .windowExpired(let label):
                return "\(label) reset after its last reading. Nothing has been recorded for the new window yet."
            case .polledWithoutFigures(let count, let lastPollFailed):
                let polls = count == 1 ? "Polled once" : "Polled \(count) times"
                return "\(polls) in this range, but no poll reported a usage figure to chart."
                    + (lastPollFailed ? " The last poll could not be read." : "")
            }
        }

        /// A failure wears the warning triangle and a blocked window the
        /// shared nosign glyph; nil leaves the chart's own symbol.
        public var symbol: String? {
            switch self {
            case .lastPollFailed, .polledWithoutFigures(_, true): "exclamationmark.triangle"
            case .noFigureAtLastPoll(_, true): BlockedGlyph.symbolName
            default: nil
            }
        }
    }

    /// Why `burndown(readings:instanceID:barLabel:now:)` returned nil.
    public static func burndownAbsence(
        readings: [QuotaHistoryStore.ReadingRecord],
        instanceID: String,
        barLabel: String,
        now: Date
    ) -> Absence {
        let instance = readings.filter { $0.vendor == instanceID && $0.measuredAt <= now }
        guard let lastPoll = instance.map(\.measuredAt).max() else { return .noReadings }
        guard let latest = HistoryPresentation.readingAtLatestPoll(readings: instance, barLabel: barLabel) else {
            // The newest poll did not mention the window. Every row of it
            // unread means the read failed; otherwise it answered without it.
            let failed = instance.allSatisfy { $0.measuredAt != lastPoll || $0.confidence != .measured }
            return failed ? .lastPollFailed : .noFigureAtLastPoll(label: barLabel, isBlocked: false)
        }
        if latest.fraction == nil {
            return latest.confidence == .measured || latest.isBlocked
                ? .noFigureAtLastPoll(label: barLabel, isBlocked: latest.isBlocked)
                : .lastPollFailed
        }
        if let resetsAt = latest.resetsAt, resetsAt <= now { return .windowExpired(label: barLabel) }
        return .noFigureAtLastPoll(label: barLabel, isBlocked: latest.isBlocked)
    }

    /// Why `history(readings:instanceID:range:now:)` returned no series.
    public static func historyAbsence(
        readings: [QuotaHistoryStore.ReadingRecord],
        instanceID: String,
        range: HistoryPresentation.TimeRange,
        now: Date
    ) -> Absence {
        let instance = readings.filter { $0.vendor == instanceID && $0.measuredAt <= now }
        guard !instance.isEmpty else { return .noReadings }
        let start = range.startDate(from: now)
        let inRange = instance.filter { record in start.map { record.measuredAt >= $0 } ?? true }
        guard let lastPoll = inRange.map(\.measuredAt).max() else { return .noneInRange }
        let failed = inRange.allSatisfy { $0.measuredAt != lastPoll || $0.confidence != .measured }
        return .polledWithoutFigures(pollCount: Set(inRange.map(\.measuredAt)).count, lastPollFailed: failed)
    }

    // MARK: - Inspection

    /// The burndown's recorded readings as one inspectable segment, carrying
    /// each reading's recorded figure. The ideal and projection lines are
    /// never inspected: they are not readings.
    public static func inspectionSegments(for burndown: Burndown) -> [HistoryPresentation.TimelineSegment] {
        [inspectionSegment(label: burndown.barLabel, points: burndown.actual)]
    }

    /// The history chart's series as inspectable segments.
    public static func inspectionSegments(for series: [Series]) -> [HistoryPresentation.TimelineSegment] {
        series.map { inspectionSegment(label: $0.label, points: $0.points) }
    }

    private static func inspectionSegment(label: String, points: [Point]) -> HistoryPresentation.TimelineSegment {
        HistoryPresentation.TimelineSegment(
            vendor: "", barLabel: label, resetsAt: nil,
            points: points.map {
                HistoryPresentation.TimelinePoint(
                    timestamp: $0.timestamp, fraction: $0.recordedFraction, isBlocked: $0.isBlocked,
                    confidence: .measured, urgency: $0.urgency)
            })
    }

    // MARK: - Text

    /// e.g. "27% left · 21h 0m to reset · out in 3h 10m". Each clause
    /// appears only when its input was measured.
    ///
    /// No pace clause: the inspector's summary and window lines state the
    /// pace from `DualBarMetrics.paceMarker`, the popover's own definition.
    /// This line used to add one from `HistoryPresentation.computePace`, whose
    /// margin is wider, so one card could say "ahead of even pace" above a
    /// chart captioned "on pace".
    ///
    /// A blocked window leads with the block and calls its figure "reported":
    /// OpenCode Go still publishes a percentage for a window it has stopped,
    /// and "4% left" under it would promise capacity that is not usable.
    public static func summaryLine(for burndown: Burndown, now: Date) -> String {
        var parts: [String] = []
        if burndown.isBlocked {
            parts.append("Blocked by the vendor")
            if let remaining = burndown.nowRemaining {
                parts.append("\(percent(remaining))% reported remaining")
            }
        } else if let remaining = burndown.nowRemaining {
            parts.append("\(percent(remaining))% left")
        }
        if let resetsAt = burndown.resetsAt, resetsAt > now {
            parts.append("\(BurnRateForecast.formatDuration(resetsAt.timeIntervalSince(now))) to reset")
        }
        if let exhaustion = burndown.projectedExhaustion, exhaustion > now {
            parts.append("out in \(BurnRateForecast.formatDuration(exhaustion.timeIntervalSince(now)))")
        }
        return parts.isEmpty ? "No current reading" : parts.joined(separator: " · ")
    }

    /// Spoken description of the burndown chart.
    public static func accessibilityDescription(for burndown: Burndown, now: Date) -> String {
        var parts = ["\(burndown.barLabel) window"]
        if burndown.isBlocked {
            parts.append("blocked by the vendor")
            if let remaining = burndown.nowRemaining {
                parts.append("\(percent(remaining)) percent reported remaining")
            }
        } else if let remaining = burndown.nowRemaining {
            parts.append("\(percent(remaining)) percent remaining")
        }
        if let resetsAt = burndown.resetsAt, resetsAt > now {
            parts.append("resets in \(BurnRateForecast.formatDuration(resetsAt.timeIntervalSince(now)))")
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
                  let peak = points.max(by: { $0.recordedFraction < $1.recordedFraction })
            else { return nil }
            return "\(label): latest \(percent(latest.recordedFraction)) percent used, peak \(percent(peak.recordedFraction)) percent, \(points.count) readings"
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
    /// nil when the history was not read, or could not be: an export must
    /// not record a failed read as zero readings.
    public let readingsCount: Int?
    /// Where `readingsCount` was counted from; nil with no count.
    public let readingsSince: Date?
    public let bars: [Bar]

    public init(snapshot: QuotaSnapshot, readingsCount: Int?, readingsSince: Date? = nil) {
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
        self.readingsSince = readingsCount == nil ? nil : readingsSince
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
