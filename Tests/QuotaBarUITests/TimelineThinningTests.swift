import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

/// The long-range timeline draws a thinned copy of its readings. Thinning is
/// display-only and must never invent, average or lose what matters: every
/// drawn point is a recorded reading, the peak and a block survive, segment
/// ends survive, and a gap between segments still breaks the line.
@Suite("Timeline display thinning")
struct TimelineThinningTests {

    typealias H = HistoryPresentation
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ minute: Int, _ fraction: Double, blocked: Bool = false) -> H.TimelinePoint {
        H.TimelinePoint(timestamp: start.addingTimeInterval(Double(minute) * 60), fraction: fraction,
                        isBlocked: blocked, confidence: .measured, urgency: fraction >= 0.9 ? .critical : .none)
    }

    private func segment(_ points: [H.TimelinePoint]) -> H.TimelineSegment {
        H.TimelineSegment(vendor: "claude", barLabel: "WK", resetsAt: nil, points: points)
    }

    @Test("a long series is thinned to real readings, keeping ends, the peak and a block")
    func thinsToRealReadings() {
        // 30 days at 2-minute polls.
        var points = (0..<21_600).map { point($0 * 2, 0.2 + Double($0 % 50) / 1000) }
        points[10_000] = point(20_000, 0.97)               // the peak
        points[15_000] = point(30_000, 0.5, blocked: true) // a block, not a peak
        let original = segment(points)
        let thinned = H.thinnedForDisplay([original], buckets: 360)

        let kept = thinned[0].points
        #expect(kept.count < 800)
        #expect(kept.allSatisfy { points.contains($0) })
        #expect(kept.first == points.first)
        #expect(kept.last == points.last)
        #expect(kept.contains(points[10_000]))
        #expect(kept.contains(points[15_000]))
        #expect(thinned[0].id == original.id)
    }

    /// A blocked reading below its bucket's peak still survives: the block is
    /// the evidence, not the fraction (code review cr-01).
    @Test("a blocked reading below its bucket's peak is kept")
    func blockedBelowPeakSurvives() {
        // 1,000 minute-spaced readings, 360 buckets: minutes 3 and 4 share one.
        var points = (0..<1_000).map { point($0, 0.3) }
        points[3] = point(3, 0.55, blocked: true)
        points[4] = point(4, 0.60)
        let kept = H.thinnedForDisplay([segment(points)], buckets: 360)[0].points
        #expect(kept.contains(points[3]))
        #expect(kept.contains(points[4]))
        #expect(kept == kept.sorted { $0.timestamp < $1.timestamp })
    }

    @Test("separate segments stay separate, and a short series is untouched")
    func segmentsStaySeparate() {
        let a = segment((0..<2_000).map { point($0 * 2, 0.3) })
        let b = segment((3_000..<5_000).map { point($0 * 2, 0.4) })
        let thinned = H.thinnedForDisplay([a, b], buckets: 100)
        #expect(thinned.count == 2)
        #expect(thinned[0].points.last == a.points.last)
        #expect(thinned[1].points.first == b.points.first)

        let short = segment((0..<50).map { point($0 * 2, 0.3) })
        #expect(H.thinnedForDisplay([short], buckets: 360) == [short])
    }

    @Test("long ranges mark where a non-healthy state begins, never a healthy point")
    @MainActor
    func symbolsAtStateChanges() {
        let points = [point(0, 0.2), point(2, 0.95), point(4, 0.96), point(6, 0.5),
                      point(8, 0.5, blocked: true), point(10, 0.5, blocked: true), point(12, 0.97)]
        let seg = segment(points)
        let marked = QuotaTimelineChart.stateChangePoints(in: [seg], minSpacingDivisor: 1_000)
        let expected = [1, 4, 6].map { seg.id + "#" + points[$0].id }
        #expect(marked == Set(expected))
    }

    @Test("a state that continues into the next segment is not marked again; repeats keep their spacing")
    @MainActor
    func symbolsCarryAcrossSegments() {
        // Two segments of one window, both critical, split by a failed poll.
        let a = segment([point(0, 0.95), point(2, 0.96)])
        let b = segment([point(4, 0.97), point(6, 0.98)])
        let marked = QuotaTimelineChart.stateChangePoints(in: [a, b], minSpacingDivisor: 1_000)
        #expect(marked == [a.id + "#" + a.points[0].id])

        // Critical, healthy, critical again 2 minutes later over a 1,000-minute
        // span: the repeat is within span/150 of the first mark and is dropped.
        let c = segment([point(0, 0.95), point(1, 0.5), point(2, 0.95), point(1_000, 0.2)])
        #expect(QuotaTimelineChart.stateChangePoints(in: [c]) == [c.id + "#" + c.points[0].id])
    }

    /// Warning → critical is always marked, even right after an earlier
    /// critical mark; a step down into warning within the spacing is not
    /// (code review cr-02).
    @Test("an escalation is marked even within the spacing of an earlier, more severe mark")
    @MainActor
    func escalationAlwaysMarked() {
        let warn = { (m: Int) in H.TimelinePoint(timestamp: self.start.addingTimeInterval(Double(m) * 60), fraction: 0.75,
                                                  isBlocked: false, confidence: .measured, urgency: .warning) }
        let points = [point(0, 0.95), warn(1), point(2, 0.95), point(1_000, 0.2)]
        let seg = segment(points)
        let marked = QuotaTimelineChart.stateChangePoints(in: [seg])
        #expect(marked == Set([0, 2].map { seg.id + "#" + points[$0].id }))
    }

    @Test("nearby events share one marker and none is dropped")
    @MainActor
    func eventsCluster() {
        func event(_ minute: Int) -> AIEvent {
            let at = start.addingTimeInterval(Double(minute) * 60)
            return AIEvent(id: "e\(minute)", kind: .usageReset, vendorId: .claude, title: "Reset \(minute)",
                           detail: nil, occurredAt: at, observedAt: at, source: .quotaPoll)
        }
        let events = [event(0), event(5), event(10), event(600), event(2_000)]
        let clusters = QuotaTimelineChart.clusters(events, span: 48 * 60 * 60, slots: 48) // 1 h slots
        #expect(clusters.map(\.events.count) == [3, 1, 1])
        #expect(clusters.flatMap(\.events).count == events.count)
    }
}
