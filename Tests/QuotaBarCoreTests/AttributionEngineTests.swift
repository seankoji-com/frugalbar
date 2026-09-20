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
}
