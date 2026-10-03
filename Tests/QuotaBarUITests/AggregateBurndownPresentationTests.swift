import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("AggregateBurndownPresentation")
struct AggregateBurndownPresentationTests {

    typealias P = AggregateBurndownPresentation

    /// Aligned to a 300s bucket boundary (1_699_999_800 / 300 = 5_666_666),
    /// so bucket membership in the average tests is exact.
    private let now = Date(timeIntervalSince1970: 1_699_999_800)

    private func reading(
        _ vendor: VendorIdentifier = .claude,
        label: String = "5H",
        minutesAgo: Double,
        fraction: Double?,
        windowLength: TimeInterval? = 5 * 3600,
        resetsAt: Date? = nil,
        elapsedOnly: Bool = false,
        urgency: Urgency = .none
    ) -> QuotaHistoryStore.ReadingRecord {
        QuotaHistoryStore.ReadingRecord(
            vendor: vendor.rawValue,
            barLabel: label,
            measuredAt: now.addingTimeInterval(-minutesAgo * 60),
            fraction: fraction,
            isBlocked: false,
            confidence: .measured,
            urgency: urgency,
            resetsAt: resetsAt,
            windowLength: windowLength,
            elapsedOnly: elapsedOnly
        )
    }

    private func snapshot(
        _ vendor: VendorIdentifier,
        status: ProviderStatus = .healthy,
        bars: [DualBarMetrics]
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue,
            vendorId: vendor,
            displayName: vendor.displayName,
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: status,
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: nil,
            row1: bars.indices.contains(0) ? bars[0] : nil,
            row2: bars.indices.contains(1) ? bars[1] : nil,
            row3: bars.indices.contains(2) ? bars[2] : nil
        )
    }

    private var claudeSnapshot: QuotaSnapshot {
        snapshot(.claude, bars: [
            DualBarMetrics(primaryFraction: 0.2, label: "5H", windowLength: QuotaWindow.fiveHours),
            DualBarMetrics(primaryFraction: 0.4, label: "WK", windowLength: QuotaWindow.week),
        ])
    }

    // MARK: - Series selection

    @Test("defaults to each vendor's longest window by windowLength")
    func longestWindowChosen() {
        let readings = [
            reading(label: "5H", minutesAgo: 10, fraction: 0.5, windowLength: QuotaWindow.fiveHours),
            reading(label: "WK", minutesAgo: 10, fraction: 0.3, windowLength: QuotaWindow.week),
            reading(label: "WK", minutesAgo: 5, fraction: 0.32, windowLength: QuotaWindow.week),
        ]
        let series = P.series(readings: readings, snapshots: [claudeSnapshot], filters: WidgetFilters(), now: now)
        #expect(series.count == 1)
        #expect(series[0].barLabel == "WK")
        #expect(series[0].allPoints.count == 2)
    }

    @Test("falls back to the snapshot's longest quota bar when readings carry no window length")
    func fallsBackToSnapshotLabel() {
        let readings = [
            reading(label: "5H", minutesAgo: 10, fraction: 0.5, windowLength: nil),
            reading(label: "WK", minutesAgo: 10, fraction: 0.3, windowLength: nil),
        ]
        let series = P.series(readings: readings, snapshots: [claudeSnapshot], filters: WidgetFilters(), now: now)
        #expect(series.map(\.barLabel) == ["WK"])
    }

    @Test("an explicit window label overrides the longest-window default")
    func explicitLabel() {
        let readings = [
            reading(label: "5H", minutesAgo: 10, fraction: 0.5, windowLength: QuotaWindow.fiveHours),
            reading(label: "WK", minutesAgo: 10, fraction: 0.3, windowLength: QuotaWindow.week),
        ]
        let filters = WidgetFilters(windowLabel: "5H")
        let series = P.series(readings: readings, snapshots: [claudeSnapshot], filters: filters, now: now)
        #expect(series.map(\.barLabel) == ["5H"])
        #expect(series[0].allPoints.map(\.value) == [0.5])
    }

    @Test("vendor filter isolates the selected subscriptions")
    func vendorFilter() {
        let openai = snapshot(.openai, bars: [DualBarMetrics(primaryFraction: 0.1, label: "WK", windowLength: QuotaWindow.week)])
        let readings = [
            reading(.claude, label: "WK", minutesAgo: 10, fraction: 0.3, windowLength: QuotaWindow.week),
            reading(.openai, label: "WK", minutesAgo: 10, fraction: 0.6, windowLength: QuotaWindow.week),
        ]
        let all = P.series(readings: readings, snapshots: [claudeSnapshot, openai], filters: WidgetFilters(), now: now)
        #expect(Set(all.map(\.vendorId)) == [.claude, .openai])

        let onlyOpenAI = P.series(
            readings: readings, snapshots: [claudeSnapshot, openai],
            filters: WidgetFilters(vendors: [.openai]), now: now
        )
        #expect(onlyOpenAI.map(\.vendorId) == [.openai])
    }

    /// Regression: proven red by removing the `consumptionReadings` filter in
    /// `series(...)` — the billing cycle row then won the longest-window pick
    /// and charted elapsed time as usage.
    @Test("elapsed-only billing-cycle readings never become a usage series")
    func elapsedOnlyExcluded() {
        let readings = [
            reading(label: "WK", minutesAgo: 10, fraction: 0.3, windowLength: QuotaWindow.week),
            reading(label: "CYCLE", minutesAgo: 10, fraction: 0.9, windowLength: 30 * 86_400, elapsedOnly: true),
        ]
        let series = P.series(readings: readings, snapshots: [claudeSnapshot], filters: WidgetFilters(), now: now)
        #expect(series.map(\.barLabel) == ["WK"])
        #expect(series[0].allPoints.map(\.value) == [0.7])

        let forced = P.series(
            readings: readings, snapshots: [claudeSnapshot],
            filters: WidgetFilters(windowLabel: "CYCLE"), now: now
        )
        #expect(forced.isEmpty)
    }

    @Test("readings without a fraction are excluded, never drawn as 0 or 100")
    func nilFractionsExcluded() {
        let readings = [
            reading(label: "WK", minutesAgo: 30, fraction: 0.3, windowLength: QuotaWindow.week),
            reading(label: "WK", minutesAgo: 20, fraction: nil, windowLength: QuotaWindow.week),
            reading(label: "WK", minutesAgo: 10, fraction: 0.35, windowLength: QuotaWindow.week),
        ]
        let series = P.series(
            readings: readings, snapshots: [claudeSnapshot],
            filters: WidgetFilters(metric: .used), now: now
        )
        #expect(series.count == 1)
        // The outage breaks the line into two segments.
        #expect(series[0].segments.count == 2)
        #expect(series[0].allPoints.map(\.value) == [0.3, 0.35])
    }

    @Test("readings outside the range are dropped")
    func rangeFilter() {
        let readings = [
            reading(label: "WK", minutesAgo: 25 * 60, fraction: 0.1, windowLength: QuotaWindow.week),
            reading(label: "WK", minutesAgo: 60, fraction: 0.2, windowLength: QuotaWindow.week),
        ]
        let series = P.series(
            readings: readings, snapshots: [claudeSnapshot],
            filters: WidgetFilters(range: .last24Hours, metric: .used), now: now
        )
        #expect(series[0].allPoints.map(\.value) == [0.2])
    }

    // MARK: - Metric

    @Test("metric converts fractions to used or remaining")
    func metricConversion() {
        let readings = [reading(label: "WK", minutesAgo: 10, fraction: 0.25, windowLength: QuotaWindow.week)]
        let used = P.series(readings: readings, snapshots: [claudeSnapshot], filters: WidgetFilters(metric: .used), now: now)
        let remaining = P.series(readings: readings, snapshots: [claudeSnapshot], filters: WidgetFilters(metric: .remaining), now: now)
        #expect(used[0].allPoints.map(\.value) == [0.25])
        #expect(remaining[0].allPoints.map(\.value) == [0.75])
    }

    // MARK: - Average

    private func series(
        _ vendor: VendorIdentifier,
        _ points: [(minutesAgo: Double, value: Double)]
    ) -> P.VendorSeries {
        P.VendorSeries(vendorId: vendor, barLabel: "WK", segments: [
            P.SeriesSegment(points: points.map {
                P.SeriesPoint(timestamp: now.addingTimeInterval(-$0.minutesAgo * 60), value: $0.value, urgency: .none, isBlocked: false)
            })
        ])
    }

    @Test("average is the exact mean of series present in each bucket")
    func averageMeanExact() {
        let a = series(.claude, [(minutesAgo: 9, value: 0.2)])
        let b = series(.openai, [(minutesAgo: 8, value: 0.6)])
        let c = series(.gemini, [(minutesAgo: 7, value: 0.7)])
        let avg = P.average(of: [a, b, c], bucket: 300, now: now)
        #expect(avg.count == 1)
        #expect(avg[0].sampleCount == 3)
        #expect(abs(avg[0].value - 0.5) < 1e-12)
        #expect(avg[0].timestamp == now.addingTimeInterval(-600))
    }

    @Test("a bucket with one series has sampleCount 1 and that series' value")
    func averageSingleSeriesBucket() {
        let a = series(.claude, [(minutesAgo: 9, value: 0.2), (minutesAgo: 2, value: 0.3)])
        let b = series(.openai, [(minutesAgo: 9, value: 0.6)])
        let avg = P.average(of: [a, b], bucket: 300, now: now)
        #expect(avg.map(\.sampleCount) == [2, 1])
        #expect(abs(avg[1].value - 0.3) < 1e-12)
    }

    @Test("a series with several readings in a bucket counts once")
    func averageSeriesCountsOnce() {
        let a = series(.claude, [(minutesAgo: 9, value: 0.2), (minutesAgo: 8, value: 0.4)])
        let b = series(.openai, [(minutesAgo: 9, value: 0.9)])
        let avg = P.average(of: [a, b], bucket: 300, now: now)
        #expect(avg.count == 1)
        #expect(avg[0].sampleCount == 2)
        #expect(abs(avg[0].value - 0.6) < 1e-12)   // mean(0.3, 0.9)
    }

    /// A+B followed by A+C keeps the count at two and still averages a
    /// different pair of windows; the line must break there too.
    @Test("a change in which windows contribute starts a new segment, even at the same count")
    func contributorSetChangeBreaksSegment() {
        let a = series(.claude, [(minutesAgo: 14, value: 0.2), (minutesAgo: 4, value: 0.2)])
        let b = series(.openai, [(minutesAgo: 14, value: 0.6)])
        let c = series(.gemini, [(minutesAgo: 4, value: 0.8)])
        let avg = P.average(of: [a, b, c], bucket: 300, now: now)
        #expect(avg.map(\.sampleCount) == [2, 2])
        #expect(avg.map(\.segment) == [0, 1])
    }

    @Test("gaps are not filled, and a long gap starts a new segment")
    func averageGapsNotFilled() {
        let a = series(.claude, [(minutesAgo: 300, value: 0.2), (minutesAgo: 1, value: 0.4)])
        let avg = P.average(of: [a], bucket: 300, now: now)
        #expect(avg.count == 2)
        #expect(avg.map(\.segment) == [0, 1])
    }

    @Test("average label carries the sample count")
    func averageLabel() {
        let pts = [
            P.AveragePoint(timestamp: now, value: 0.5, sampleCount: 3, segment: 0),
            P.AveragePoint(timestamp: now, value: 0.5, sampleCount: 3, segment: 0),
        ]
        #expect(P.averageLabel(for: pts) == "Average (3 windows)")
        let mixed = pts + [P.AveragePoint(timestamp: now, value: 0.5, sampleCount: 1, segment: 0)]
        #expect(P.averageLabel(for: mixed) == "Average (1–3 windows)")
    }

    // MARK: - Headroom

    @Test("current headroom keeps a nil fraction nil and converts the rest to remaining")
    func headroomNilPreserved() {
        let blocked = snapshot(.opencode, status: .critical, bars: [
            DualBarMetrics(primaryFraction: nil, label: "MO", isBlocked: true, windowLength: 30 * 86_400),
        ])
        let unreadable = snapshot(.openai, status: .unavailable(.offline), bars: [
            DualBarMetrics(primaryFraction: 0.4, label: "WK", windowLength: QuotaWindow.week),
        ])
        let items = P.currentHeadroom(snapshots: [claudeSnapshot, blocked, unreadable], filters: WidgetFilters())
        let byVendor = Dictionary(uniqueKeysWithValues: items.map { ($0.vendorId, $0) })
        #expect(byVendor[.claude]?.barLabel == "WK")
        #expect(byVendor[.claude]?.remainingFraction.map { abs($0 - 0.6) < 1e-12 } == true)
        #expect(byVendor[.opencode]?.remainingFraction == nil)
        #expect(byVendor[.opencode]?.isBlocked == true)
        #expect(byVendor[.openai]?.remainingFraction == nil)
    }

    @Test("headroom honours an explicit window label and skips vendors without it")
    func headroomWindowLabel() {
        let openai = snapshot(.openai, bars: [DualBarMetrics(primaryFraction: 0.1, label: "WK", windowLength: QuotaWindow.week)])
        let items = P.currentHeadroom(snapshots: [claudeSnapshot, openai], filters: WidgetFilters(windowLabel: "5H"))
        #expect(items.map(\.vendorId) == [.claude])
        #expect(items.first?.barLabel == "5H")
    }

    @Test("available windows are listed longest first, elapsed-only rows excluded")
    func availableWindowLabels() {
        var cycle = DualBarMetrics(primaryFraction: 0.9, label: "CYC", windowLength: 365 * 86_400)
        cycle.measuresElapsedTimeOnly = true
        let devpass = snapshot(.devpass, bars: [cycle])
        #expect(P.availableWindowLabels(snapshots: [claudeSnapshot, devpass]) == ["WK", "5H"])
        #expect(P.availableVendors(snapshots: [claudeSnapshot, devpass]) == [.claude])
    }

    // MARK: - Text

    @Test("title describes the filters")
    func titleText() {
        #expect(P.title(for: WidgetFilters()) == "All subscriptions · 24h · remaining")
        #expect(P.title(for: WidgetFilters(vendors: [.claude], windowLabel: "WK", range: .last7Days, metric: .used))
                == "Claude · WK · 7d · used")
        #expect(P.title(for: WidgetFilters(vendors: [.claude, .openai], range: .last30Days))
                == "2 subscriptions · 30d · remaining")
    }

    @Test("accessibility summary names each window and labels the average honestly")
    func accessibilitySummary() {
        let a = series(.claude, [(minutesAgo: 9, value: 0.2)])
        let b = series(.openai, [(minutesAgo: 8, value: 0.6)])
        let avg = P.average(of: [a, b], bucket: 300, now: now)
        let text = P.accessibilitySummary(series: [a, b], average: avg, filters: WidgetFilters())
        #expect(text.contains("Claude WK: latest 20 percent remaining"))
        #expect(text.contains("Average of 2 windows, not a combined quota: latest 40 percent remaining"))
        #expect(P.accessibilitySummary(series: [], average: [], filters: WidgetFilters()).hasPrefix("No readings"))
    }

    // MARK: - Decimation

    @Test("decimation caps point count but keeps endpoints and urgency transitions")
    func decimation() {
        var points: [P.SeriesPoint] = (0..<1000).map {
            P.SeriesPoint(timestamp: now.addingTimeInterval(Double($0)), value: 0.5, urgency: .none, isBlocked: false)
        }
        points[501] = P.SeriesPoint(timestamp: points[501].timestamp, value: 0.95, urgency: .critical, isBlocked: false)
        let s = P.VendorSeries(vendorId: .claude, barLabel: "WK", segments: [P.SeriesSegment(points: points)])
        let thinned = P.decimated(s, maxPointsPerSeries: 100)
        let kept = thinned.allPoints
        #expect(kept.count < 120)
        #expect(kept.first == points.first)
        #expect(kept.last == points.last)
        #expect(kept.contains(points[501]))
    }

    // MARK: - Codable

    @Test("filters survive a JSON round-trip")
    func filtersRoundTrip() throws {
        let filters = WidgetFilters(vendors: [.claude, .gemini], windowLabel: "WK", range: .last7Days, metric: .used)
        let data = try #require(filters.encoded())
        #expect(WidgetFilters.decode(data) == filters)
    }

    @Test("unknown vendors and missing fields decode to defaults, not a failure")
    func filtersTolerantDecode() {
        let json = #"{"vendors":["claude","no-such-vendor"],"range":"bogus"}"#
        let decoded = WidgetFilters.decode(Data(json.utf8))
        #expect(decoded.vendors == [.claude])
        #expect(decoded.range == .last24Hours)
        #expect(decoded.metric == .remaining)
        #expect(decoded.windowLabel == nil)
        #expect(WidgetFilters.decode(nil) == WidgetFilters())
        #expect(WidgetFilters.decode(Data("not json".utf8)) == WidgetFilters())
    }
}
