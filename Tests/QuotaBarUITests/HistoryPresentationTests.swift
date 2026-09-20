import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("HistoryPresentation")
struct HistoryPresentationTests {

    private func makeRecord(
        vendor: String = "claude",
        barLabel: String = "5H",
        measuredAt: Date,
        fraction: Double?,
        resetsAt: Date? = nil,
        windowLength: TimeInterval? = 5 * 3600
    ) -> QuotaHistoryStore.ReadingRecord {
        QuotaHistoryStore.ReadingRecord(
            vendor: vendor,
            barLabel: barLabel,
            measuredAt: measuredAt,
            fraction: fraction,
            isBlocked: false,
            confidence: .measured,
            urgency: .none,
            resetsAt: resetsAt,
            windowLength: windowLength,
            elapsedOnly: false
        )
    }

    // MARK: - Segmentation Tests

    @Test("contiguous readings in the same window form a single segment")
    func contiguousReadingsFormSingleSegment() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = base.addingTimeInterval(5 * 3600)

        let readings = [
            makeRecord(measuredAt: base, fraction: 0.1, resetsAt: resets),
            makeRecord(measuredAt: base.addingTimeInterval(300), fraction: 0.2, resetsAt: resets),
            makeRecord(measuredAt: base.addingTimeInterval(600), fraction: 0.3, resetsAt: resets)
        ]

        let segments = HistoryPresentation.segments(from: readings)
        #expect(segments.count == 1)
        #expect(segments[0].points.count == 3)
        #expect(segments[0].points.map(\.fraction) == [0.1, 0.2, 0.3])
    }

    @Test("window reset breaks lines rather than connecting them across the reset")
    func windowResetBreaksSegments() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstResets = base.addingTimeInterval(5 * 3600)
        let secondResets = base.addingTimeInterval(10 * 3600)

        let readings = [
            // Window 1: 0.8 consumed right before reset
            makeRecord(measuredAt: base.addingTimeInterval(4 * 3600), fraction: 0.8, resetsAt: firstResets),
            makeRecord(measuredAt: base.addingTimeInterval(4.5 * 3600), fraction: 0.9, resetsAt: firstResets),
            // Window 2 starts after reset with fresh headroom (0.05 consumed)
            makeRecord(measuredAt: base.addingTimeInterval(5.1 * 3600), fraction: 0.05, resetsAt: secondResets),
            makeRecord(measuredAt: base.addingTimeInterval(5.5 * 3600), fraction: 0.15, resetsAt: secondResets)
        ]

        let segments = HistoryPresentation.segments(from: readings)
        #expect(segments.count == 2)
        #expect(segments[0].points.count == 2)
        #expect(segments[0].points.map(\.fraction) == [0.8, 0.9])
        #expect(segments[1].points.count == 2)
        #expect(segments[1].points.map(\.fraction) == [0.05, 0.15])
    }

    @Test("large gap breaks segment into separate lines")
    func largeGapBreaksSegment() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let readings = [
            makeRecord(measuredAt: base, fraction: 0.2),
            // 5 hours later (exceeds default 2-hour maxGap)
            makeRecord(measuredAt: base.addingTimeInterval(5 * 3600), fraction: 0.3)
        ]

        let segments = HistoryPresentation.segments(from: readings, maxGap: 7200)
        #expect(segments.count == 2)
        #expect(segments[0].points.count == 1)
        #expect(segments[1].points.count == 1)
    }

    @Test("sudden negative drop breaks line as an inferred reset")
    func negativeDropBreaksLine() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let readings = [
            makeRecord(measuredAt: base, fraction: 0.85),
            // 10 minutes later, drops to 0.10 without resetsAt change
            makeRecord(measuredAt: base.addingTimeInterval(600), fraction: 0.10)
        ]

        let segments = HistoryPresentation.segments(from: readings)
        #expect(segments.count == 2)
        #expect(segments[0].points.first?.fraction == 0.85)
        #expect(segments[1].points.first?.fraction == 0.10)
    }

    @Test("nil fraction reading ends segment and is omitted from plotted points")
    func nilFractionBreaksSegment() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let readings = [
            makeRecord(measuredAt: base, fraction: 0.3),
            makeRecord(measuredAt: base.addingTimeInterval(300), fraction: nil), // outage / unavailable
            makeRecord(measuredAt: base.addingTimeInterval(600), fraction: 0.4)
        ]

        let segments = HistoryPresentation.segments(from: readings)
        #expect(segments.count == 2)
        #expect(segments[0].points.count == 1)
        #expect(segments[1].points.count == 1)
    }

    // MARK: - Pace Comparison Tests

    @Test("ahead of pace detected when consumed significantly exceeds elapsed")
    func aheadOfPaceDetectedTest() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowLength: TimeInterval = 10 * 3600 // 10h total
        let resetsAt = now.addingTimeInterval(8 * 3600) // 2h elapsed (20%)
        let reading = makeRecord(
            measuredAt: now,
            fraction: 0.70, // 70% consumed with only 20% elapsed -> delta +50%
            resetsAt: resetsAt,
            windowLength: windowLength
        )

        let pace = HistoryPresentation.computePace(reading: reading, now: now)
        let resolved = try#require(pace)
        #expect(resolved.status == .aheadOfPace)
        #expect(resolved.paceDelta > 0.45)
    }

    @Test("under pace (frugal) detected when elapsed exceeds consumed")
    func underPaceDetectedTest() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowLength: TimeInterval = 10 * 3600 // 10h total
        let resetsAt = now.addingTimeInterval(2 * 3600) // 8h elapsed (80%)
        let reading = makeRecord(
            measuredAt: now,
            fraction: 0.20, // 20% consumed with 80% elapsed -> delta -60%
            resetsAt: resetsAt,
            windowLength: windowLength
        )

        let pace = HistoryPresentation.computePace(reading: reading, now: now)
        let resolved = try#require(pace)
        #expect(resolved.status == .underPace)
        #expect(resolved.paceDelta < -0.50)
    }

    @Test("missing window metadata returns nil pace")
    func missingWindowMetadataReturnsNil() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = makeRecord(
            measuredAt: now,
            fraction: 0.50,
            resetsAt: nil, // no resetsAt
            windowLength: nil
        )

        let pace = HistoryPresentation.computePace(reading: reading, now: now)
        #expect(pace == nil)
    }

    // MARK: - Time Range Tests

    @Test("time ranges compute correct start dates")
    func timeRangesComputeStartDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(HistoryPresentation.TimeRange.allTime.startDate(from: now) == nil)

        let start24 = HistoryPresentation.TimeRange.last24Hours.startDate(from: now)
        #expect(start24 == now.addingTimeInterval(-24 * 3600))

        let start7 = HistoryPresentation.TimeRange.last7Days.startDate(from: now)
        #expect(start7 == now.addingTimeInterval(-7 * 86_400))
    }
}
