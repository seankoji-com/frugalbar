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
