import Testing
import Foundation
@testable import QuotaBarCore

struct SystemHealthSummaryTests {

    @Test func summary_emptyInput() {
        let summary = SystemHealthSummary.compute(from: [])
        #expect(summary.overallStatus == .healthy)
        #expect(summary.healthyCount == 0)
        #expect(summary.totalProviders == 0)
        #expect(summary.lastUpdated == nil)
    }

    @Test func summary_allHealthy() {
        let snaps = [
            QuotaSnapshot.mock(vendorId: .opencode, status: .healthy),
            QuotaSnapshot.mock(vendorId: .gemini, status: .healthy),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.overallStatus == .healthy)
        #expect(summary.healthyCount == 2)
        #expect(summary.errorCount == 0)
        #expect(summary.totalProviders == 2)
    }

    @Test func summary_warningTakesPriority() {
        let snaps = [
            QuotaSnapshot.mock(vendorId: .opencode, status: .healthy),
            QuotaSnapshot.mock(vendorId: .gemini, status: .warning),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.overallStatus == .warning)
        #expect(summary.warningCount == 1)
    }

    @Test func summary_criticalTakesPriority() {
        let snaps = [
            QuotaSnapshot.mock(vendorId: .opencode, status: .healthy),
            QuotaSnapshot.mock(vendorId: .gemini, status: .warning),
            QuotaSnapshot.mock(vendorId: .claude, status: .critical),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.overallStatus == .critical)
        #expect(summary.criticalCount == 1)
    }

    @Test func summary_errorCounts() {
        let snaps = [
            QuotaSnapshot.mock(vendorId: .opencode, status: .unauthenticated),
            QuotaSnapshot.mock(vendorId: .claude, status: .unsupported("no API")),
            QuotaSnapshot.mock(vendorId: .gemini, status: .networkError("timeout")),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        #expect(summary.errorCount == 3)
        #expect(summary.totalProviders == 3)
    }

    @Test func summary_mixedStatus() {
        let snaps = [
            QuotaSnapshot.mock(vendorId: .opencode, status: .healthy),
            QuotaSnapshot.mock(vendorId: .gemini, status: .warning),
            QuotaSnapshot.mock(vendorId: .claude, status: .unsupported("no API")),
            QuotaSnapshot.mock(vendorId: .copilot, status: .critical),
        ]
        let summary = SystemHealthSummary.compute(from: snaps)
        // .unsupported has severity 3, .critical has severity 2 — unsupported wins
        #expect(summary.overallStatus.severity == 3)
        #expect(summary.healthyCount == 1)
        #expect(summary.warningCount == 1)
        #expect(summary.errorCount == 1)
        #expect(summary.totalProviders == 4)
    }
}
