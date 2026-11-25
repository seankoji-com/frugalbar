import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Inspector run-out line")
struct InspectorRunOutTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let length: TimeInterval = 5 * 3600
    var reset: Date { now.addingTimeInterval(2 * 3600) }

    func bar(_ used: Double, blocked: Bool = false) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: used,
                       expectedPaceFraction: DualBarMetrics.proRataPace(resetsAt: reset, windowLength: length, now: now),
                       label: "5H", isBlocked: blocked, resetsAt: reset, windowLength: length)
    }

    /// Steady burn: 10 readings over 45 minutes, 0.40 → 0.58 used.
    var burning: [QuotaHistoryStore.ReadingRecord] {
        (0..<10).map { i in
            QuotaHistoryStore.ReadingRecord(vendor: "claude", barLabel: "5H",
                measuredAt: now.addingTimeInterval(-Double(45 - i * 5) * 60), fraction: 0.40 + Double(i) * 0.02,
                isBlocked: false, confidence: .measured, urgency: .none, resetsAt: reset, windowLength: length,
                elapsedOnly: false)
        }
    }

    @Test("recent pace from history is preferred, and says so")
    func recentPaceFirst() throws {
        let text = try #require(InspectorRunOut.text(for: bar(0.58), snapshotID: "claude", readings: burning, now: now))
        #expect(text.hasPrefix("At your recent rate, runs out in"))
        #expect(text.hasSuffix("before the reset"))
    }

    @Test("without usable history, the window's average is used and named as that")
    func averageFallback() throws {
        // 0.9 used with 60% of the window gone: ahead of pace, out before the reset.
        let text = try #require(InspectorRunOut.text(for: bar(0.9), snapshotID: "claude", readings: [], now: now))
        #expect(text.hasPrefix("At this window's average rate, runs out in"))
        let slow = try #require(InspectorRunOut.text(for: bar(0.1), snapshotID: "claude", readings: nil, now: now))
        #expect(slow == "At this window's average rate, lasts until the reset")
    }

    @Test("never for a blocked or spent window, or without a published pace")
    func noProjection() {
        #expect(InspectorRunOut.text(for: bar(0.5, blocked: true), snapshotID: "claude", readings: burning, now: now) == nil)
        #expect(InspectorRunOut.text(for: bar(1.0), snapshotID: "claude", readings: burning, now: now) == nil)
        let undated = DualBarMetrics(primaryFraction: 0.5, label: "WK")
        #expect(InspectorRunOut.text(for: undated, snapshotID: "claude", readings: [], now: now) == nil)
    }

    @Test("without a published reset, recent-rate forecast never claims exhaustion before reset")
    func unknownResetNeverWarnsBeforeReset() throws {
        let undatedBar = DualBarMetrics(primaryFraction: 0.58, label: "5H")
        let undatedBurning = (0..<10).map { i in
            QuotaHistoryStore.ReadingRecord(
                vendor: "opencode-go", barLabel: "5H",
                measuredAt: now.addingTimeInterval(-Double(45 - i * 5) * 60),
                fraction: 0.40 + Double(i) * 0.02,
                isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: nil, elapsedOnly: false
            )
        }
        let result = try #require(InspectorRunOut.compute(for: undatedBar, snapshotID: "opencode-go", readings: undatedBurning, now: now))
        #expect(!result.runsOutBeforeReset)
        #expect(result.text.hasPrefix("At your recent rate, runs out in"))
        #expect(!result.text.contains("before the reset"))
        #expect(result.text.contains("no reset published"))
    }

    @Test("mismatched history reset does not warn against a revised snapshot reset")
    func mismatchedResetDoesNotContradictSummary() {
        let historyReset = now.addingTimeInterval(5 * 3600)
        let revisedReset = now.addingTimeInterval(2 * 3600)
        // History says 60%, 62%, 64% at -20m, -10m, now with a 5h reset -> projected exhaustion ~3h.
        let history = [0, 1, 2].map { i in
            QuotaHistoryStore.ReadingRecord(
                vendor: "claude", barLabel: "WK",
                measuredAt: now.addingTimeInterval(-Double(20 - i * 10) * 60),
                fraction: 0.60 + Double(i) * 0.02,
                isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: historyReset, windowLength: 168 * 3600, elapsedOnly: false
            )
        }
        // Snapshot WK bar has a revised 2h reset (earlier than the 3h projected exhaustion).
        let revisedBar = DualBarMetrics(
            primaryFraction: 0.64,
            expectedPaceFraction: DualBarMetrics.proRataPace(resetsAt: revisedReset, windowLength: 168 * 3600, now: now),
            label: "WK",
            resetsAt: revisedReset,
            windowLength: 168 * 3600
        )
        let result = InspectorRunOut.compute(for: revisedBar, snapshotID: "claude", readings: history, now: now)
        #expect(result?.runsOutBeforeReset != true)
        #expect(result?.text.contains("At your recent rate, runs out") != true)
    }

    @Test("the window lines no longer carry their own unlabelled projection")
    func windowLinesCarryNoProjection() {
        let line = MetricDetailPresentation.windowLine(bar(0.9), now: now)
        #expect(!line.detail.contains("runs out") && !line.detail.contains("burning"))
    }
}
