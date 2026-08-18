import Testing
import Foundation
@testable import QuotaBarCore

@Suite("consumptionFraction")
struct ConsumptionFractionTests {

    private func snapshot(_ metric: MetricType) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "t", vendorId: .githubRest, displayName: "t",
            category: .developerLimits, metric: metric, status: .healthy,
            resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil
        )
    }

    @Test("percentage passes through and clamps to 0...1")
    func percentage() {
        #expect(snapshot(.percentage(usedFraction: 0.25, displayDetails: nil)).consumptionFraction == 0.25)
        #expect(snapshot(.percentage(usedFraction: -1, displayDetails: nil)).consumptionFraction == 0.0)
        #expect(snapshot(.percentage(usedFraction: 5, displayDetails: nil)).consumptionFraction == 1.0)
    }

    @Test("count inverts remaining/limit into a consumed fraction")
    func count() {
        #expect(snapshot(.count(remaining: 25, limit: 100, unitName: "u")).consumptionFraction == 0.75)
        #expect(snapshot(.count(remaining: 100, limit: 100, unitName: "u")).consumptionFraction == 0.0)
    }

    @Test("count with a zero limit does not divide by zero")
    func countZeroLimit() {
        #expect(snapshot(.count(remaining: 0, limit: 0, unitName: "u")).consumptionFraction == 0.0)
    }

    @Test("currency inverts balance against limit")
    func currency() {
        let m = MetricType.currency(balance: 5, limit: 20, spent: 15, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == 0.75)
    }

    @Test("currency without a limit reports no consumption")
    func currencyNoLimit() {
        let m = MetricType.currency(balance: 5, limit: nil, spent: nil, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == 0.0)
    }

    @Test("subscription has no consumption dimension")
    func subscription() {
        #expect(snapshot(.subscription(tierName: "Pro", renewalDate: nil)).consumptionFraction == 0.0)
    }
}

@Suite("SystemHealthSummary")
struct SystemHealthSummaryTests {

    private func snapshot(_ id: String, _ status: ProviderStatus) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: .githubRest, displayName: id,
            category: .developerLimits,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil
        )
    }

    @Test("counts each status bucket")
    func counts() {
        let s = SystemHealthSummary.compute(from: [
            snapshot("a", .healthy),
            snapshot("b", .warning),
            snapshot("c", .critical),
            snapshot("d", .networkError("boom")),
        ])
        #expect(s.healthyCount == 1)
        #expect(s.warningCount == 1)
        #expect(s.criticalCount == 1)
        #expect(s.errorCount == 1)
        #expect(s.totalProviders == 4)
    }

    @Test("an empty set is healthy with no timestamp")
    func empty() {
        let s = SystemHealthSummary.compute(from: [])
        #expect(s.overallStatus == .healthy)
        #expect(s.totalProviders == 0)
        #expect(s.lastUpdated == nil)
    }

    @Test("warning outranks healthy")
    func worstWins() {
        let s = SystemHealthSummary.compute(from: [snapshot("a", .healthy), snapshot("b", .warning)])
        #expect(s.overallStatus == .warning)
    }
}
