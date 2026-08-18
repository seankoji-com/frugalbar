import Testing
import Foundation
@testable import QuotaBarCore

private func snapshot(
    vendor: VendorIdentifier,
    status: ProviderStatus,
    lastUpdated: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> QuotaSnapshot {
    QuotaSnapshot(
        id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
        category: .aiSubscriptions,
        metric: .subscription(tierName: "x", renewalDate: nil),
        status: status,
        resetsAt: nil, lastUpdated: lastUpdated, auxiliaryInfo: nil
    )
}

struct SystemHealthSummaryTests {

    @Test func summary_emptyInput() {
        let summary = SystemHealthSummary.compute(from: [])
        #expect(summary.worstUrgency == .none)
        #expect(summary.healthyCount == 0)
        #expect(summary.unavailableCount == 0)
        #expect(summary.totalProviders == 0)
        #expect(summary.oldestReading == nil)
        #expect(summary.hasAnyReading == false)
    }

    @Test("6 measured-healthy plus 1 unavailable never inflates worstUrgency")
    func summary_healthyProvidersPlusOneUnavailable() {
        var snaps = (0..<6).map { i in
            snapshot(vendor: VendorIdentifier.allCases[i % VendorIdentifier.allCases.count], status: .healthy)
        }
        snaps.append(snapshot(vendor: .claude, status: .unavailable(.notConfigured)))

        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.worstUrgency == .none)
        #expect(summary.unavailableCount == 1)
        #expect(summary.healthyCount == 6)
        #expect(summary.totalProviders == 7)
        #expect(summary.hasAnyReading == true)
    }

    @Test("a critical provider alongside an unavailable one yields worstUrgency critical")
    func summary_criticalWithUnavailable() {
        let snaps = [
            snapshot(vendor: .claude, status: .critical),
            snapshot(vendor: .gemini, status: .unavailable(.offline)),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.worstUrgency == .critical)
        #expect(summary.criticalCount == 1)
        #expect(summary.unavailableCount == 1)
    }

    @Test("warning takes priority over healthy but not over critical")
    func summary_warningVsCritical() {
        let mixed = SystemHealthSummary.compute(from: [
            snapshot(vendor: .claude, status: .healthy),
            snapshot(vendor: .gemini, status: .warning),
        ])
        #expect(mixed.worstUrgency == .warning)

        let withCritical = SystemHealthSummary.compute(from: [
            snapshot(vendor: .claude, status: .healthy),
            snapshot(vendor: .gemini, status: .warning),
            snapshot(vendor: .opencode, status: .critical),
        ])
        #expect(withCritical.worstUrgency == .critical)
    }

    @Test("a rateLimited provider counts as critical urgency, not unavailable")
    func summary_rateLimitedCountsAsCritical() {
        let summary = SystemHealthSummary.compute(from: [
            snapshot(vendor: .openrouter, status: .rateLimited(retryAfter: nil)),
        ])
        #expect(summary.worstUrgency == .critical)
        #expect(summary.criticalCount == 1)
        #expect(summary.unavailableCount == 0)
    }

    @Test("oldestReading picks the oldest timestamp, not the newest or the last one seen")
    func summary_oldestReadingPicksOldest() {
        let oldest = Date(timeIntervalSince1970: 1_000)
        let middle = Date(timeIntervalSince1970: 2_000)
        let newest = Date(timeIntervalSince1970: 3_000)

        // Deliberately ordered so the newest is last and the oldest is in the
        // middle — a naive "keep the last one" or "keep the first one"
        // implementation would get this wrong.
        let snaps = [
            snapshot(vendor: .claude, status: .healthy, lastUpdated: middle),
            snapshot(vendor: .gemini, status: .healthy, lastUpdated: oldest),
            snapshot(vendor: .opencode, status: .healthy, lastUpdated: newest),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.oldestReading == oldest)
    }

    @Test("hasAnyReading is false when every provider is unavailable")
    func summary_hasAnyReadingFalseWhenAllUnavailable() {
        let summary = SystemHealthSummary.compute(from: [
            snapshot(vendor: .claude, status: .unauthenticated),
            snapshot(vendor: .gemini, status: .unsupported("no API")),
        ])
        #expect(summary.hasAnyReading == false)
        #expect(summary.unavailableCount == 2)
    }
}
