import Foundation
import Testing
@testable import QuotaBarCore

@Suite("AttributionEngine")
struct AttributionEngineTests {

    @Test("Project token shares are computed faithfully without coercing to quota percent")
    func tokenSharesFaithfullyComputedTest() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let windowStart = baseDate
        let windowEnd = baseDate.addingTimeInterval(3600)

        let a1 = ActivityRecord(
            source: "claude_code",
            recordId: "rec1",
            sessionId: "s1",
            projectPath: "/Users/dev/projectA",
            observedAt: baseDate.addingTimeInterval(600),
            inputTokens: 600_000,
            outputTokens: 150_000
        )
        let a2 = ActivityRecord(
            source: "codex",
            recordId: "rec2",
            sessionId: "s2",
            projectPath: "/Users/dev/projectB",
            observedAt: baseDate.addingTimeInterval(2400),
            inputTokens: 200_000,
            outputTokens: 50_000
        )

        let summary = AttributionEngine.computeAttribution(
            windowStart: windowStart,
            windowEnd: windowEnd,
            startConsumptionFraction: 0.10,
            endConsumptionFraction: 0.65,
            activities: [a1, a2],
            configuredVendors: [.claude, .openai]
        )

        #expect(summary.totalObservedTokens == 1_000_000)
        #expect(summary.consumedFractionDelta == 0.55)
        #expect(summary.projectAttributions.count == 2)

        let projA = summary.projectAttributions.first(where: { $0.projectPath == "/Users/dev/projectA" })
        let projB = summary.projectAttributions.first(where: { $0.projectPath == "/Users/dev/projectB" })

        #expect(projA?.tokenCount == 750_000)
        #expect(projA?.tokenShare == 0.75)
        #expect(projB?.tokenCount == 250_000)
        #expect(projB?.tokenShare == 0.25)
        #expect(summary.hasConcurrentSessions == false)
        #expect(!summary.caveats.contains(.concurrentSessionsDetected))
        #expect(!summary.caveats.contains(.unmonitoredToolsConfigured))
    }

    @Test("Concurrent sessions in close succession trigger concurrency caveat")
    func concurrencyCaveatTest() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let windowStart = baseDate
        let windowEnd = baseDate.addingTimeInterval(3600)

        let a1 = ActivityRecord(
            source: "claude_code",
            recordId: "rec1",
            sessionId: "s1",
            projectPath: "/Users/dev/projectA",
            observedAt: baseDate.addingTimeInterval(100),
            inputTokens: 10_000,
            outputTokens: 2_000
        )
        let a2 = ActivityRecord(
            source: "codex",
            recordId: "rec2",
            sessionId: "s2",
            projectPath: "/Users/dev/projectB",
            observedAt: baseDate.addingTimeInterval(120), // 20s later, distinct session
            inputTokens: 20_000,
            outputTokens: 4_000
        )

        let summary = AttributionEngine.computeAttribution(
            windowStart: windowStart,
            windowEnd: windowEnd,
            startConsumptionFraction: 0.20,
            endConsumptionFraction: 0.30,
            activities: [a1, a2]
        )

        #expect(summary.hasConcurrentSessions == true)
        #expect(summary.caveats.contains(.concurrentSessionsDetected))
    }

    @Test("Unmonitored vendors trigger unmonitored tools caveat")
    func unmonitoredVendorsCaveatTest() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let summary = AttributionEngine.computeAttribution(
            windowStart: baseDate,
            windowEnd: baseDate.addingTimeInterval(3600),
            startConsumptionFraction: 0.20,
            endConsumptionFraction: 0.30,
            activities: [],
            configuredVendors: [.claude, .grok]
        )

        #expect(summary.unmonitoredVendors.contains(.grok))
        #expect(summary.caveats.contains(.unmonitoredToolsConfigured))
    }

    @Test("Nil consumption fraction preserves nil delta")
    func nilConsumptionFractionPreservedTest() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let summary = AttributionEngine.computeAttribution(
            windowStart: baseDate,
            windowEnd: baseDate.addingTimeInterval(3600),
            startConsumptionFraction: nil,
            endConsumptionFraction: 0.50,
            activities: []
        )

        #expect(summary.consumedFractionDelta == nil)
    }

    // MARK: - Bar-label scoping

    private func reading(_ label: String, _ fraction: Double?, at offset: TimeInterval) -> QuotaHistoryStore.ReadingRecord {
        QuotaHistoryStore.ReadingRecord(
            vendor: "claude",
            barLabel: label,
            measuredAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            fraction: fraction,
            isBlocked: false,
            confidence: .measured,
            urgency: .none,
            resetsAt: nil,
            windowLength: label == "5H" ? 5 * 3600 : 7 * 24 * 3600,
            elapsedOnly: false
        )
    }

    @Test("consumption endpoints never span two bar labels")
    func endpointsAreScopedToOneBar() {
        // The 5H window burns 0.20 -> 0.95; the weekly barely moves. Reading the
        // endpoints off the unfiltered list used to subtract the weekly figure
        // from the 5-hour one and report 0.00 consumed.
        let readings = [
            reading("5H", 0.20, at: 0),
            reading("WK", 0.10, at: 0),
            reading("5H", 0.95, at: 3600),
            reading("WK", 0.15, at: 3600)
        ]

        let fiveHour = AttributionEngine.consumptionEndpoints(readings: readings, barLabel: "5H")
        #expect(fiveHour.start == 0.20)
        #expect(fiveHour.end == 0.95)

        let week = AttributionEngine.consumptionEndpoints(readings: readings, barLabel: "WK")
        #expect(week.start == 0.10)
        #expect(week.end == 0.15)
    }

    @Test("a bar with no measured reading yields nil endpoints, never a borrowed or zeroed one")
    func absentBarYieldsNilEndpoints() {
        let readings = [reading("5H", 0.20, at: 0), reading("WK", nil, at: 0)]

        let absent = AttributionEngine.consumptionEndpoints(readings: readings, barLabel: "WK")
        #expect(absent.start == nil)
        #expect(absent.end == nil)

        let summary = AttributionEngine.computeAttribution(
            windowStart: Date(timeIntervalSince1970: 1_800_000_000),
            windowEnd: Date(timeIntervalSince1970: 1_800_000_000 + 3600),
            barLabel: "WK",
            startConsumptionFraction: absent.start,
            endConsumptionFraction: absent.end,
            activities: []
        )
        #expect(summary.consumedFractionDelta == nil)
    }

    @Test("the preferred bar is the longest window on the most recent reading")
    func preferredBarIsTheLongestRecentWindow() {
        let readings = [
            reading("5H", 0.20, at: 0),
            reading("WK", 0.10, at: 0),
            reading("5H", 0.95, at: 3600),
            reading("WK", 0.15, at: 3600)
        ]
        #expect(AttributionEngine.preferredBarLabel(readings: readings) == "WK")

        // And nil when nothing has been measured at all.
        #expect(AttributionEngine.preferredBarLabel(readings: [reading("5H", nil, at: 0)]) == nil)
    }

    // MARK: - Partial token breakdowns

    @Test("a record with no total is excluded from shares and reported, not counted as zero")
    func recordsWithoutTotalsAreReportedNotZeroed() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let known = ActivityRecord(
            source: "claude_code", recordId: "k1", sessionId: "s1",
            projectPath: "/Users/dev/known",
            observedAt: baseDate.addingTimeInterval(60),
            totalTokens: 1_000
        )
        let unknown = ActivityRecord(
            source: "claude_code", recordId: "u1", sessionId: "s2",
            projectPath: "/Users/dev/unknown",
            observedAt: baseDate.addingTimeInterval(120)
        )

        let summary = AttributionEngine.computeAttribution(
            windowStart: baseDate,
            windowEnd: baseDate.addingTimeInterval(3600),
            startConsumptionFraction: 0.1,
            endConsumptionFraction: 0.2,
            activities: [known, unknown]
        )

        #expect(summary.totalObservedTokens == 1_000)
        #expect(summary.recordsWithoutTokenTotals == 1)
        #expect(summary.caveats.contains(.partialTokenBreakdowns))
        // The unknown record still counts as a session; it just contributes no
        // token mass, because zero is not what it reported.
        #expect(summary.projectAttributions.map(\.projectPath).sorted() == ["/Users/dev/known"])
    }

    @Test("unrecorded external activity is always flagged")
    func unrecordedActivityAlwaysFlagged() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = AttributionEngine.computeAttribution(
            windowStart: baseDate,
            windowEnd: baseDate.addingTimeInterval(3600),
            startConsumptionFraction: 0.1,
            endConsumptionFraction: 0.2,
            activities: []
        )
        #expect(summary.caveats.contains(.unrecordedExternalActivityPossible))
    }

    @Test("only vendors with a local activity source are considered monitored")
    func localSourceMappingIsExplicit() {
        #expect(AttributionEngine.localSourceIdentifiers(for: .claude) == ["claude_code"])
        #expect(AttributionEngine.localSourceIdentifiers(for: .openai) == ["codex"])
        #expect(AttributionEngine.localSourceIdentifiers(for: .opencode) == ["opencode"])
        // No adapter speaks for these, so an activity breakdown must not be
        // presented as an explanation for their allowance.
        #expect(AttributionEngine.localSourceIdentifiers(for: .grok).isEmpty)
        #expect(AttributionEngine.localSourceIdentifiers(for: .kiro).isEmpty)
        #expect(AttributionEngine.localSourceIdentifiers(for: .gemini).isEmpty)
    }
}
