import Testing
import Foundation
@testable import QuotaBarUI
import QuotaBarCore

struct MetricRowViewTests {

    @Test func row_rendersHealthyStatus() {
        let snap = makeSnapshot(vendorId: .opencode, status: .healthy, metric: .count(remaining: 80, limit: 100, unitName: "units"))
        let row = MetricRowView(snapshot: snap)
        #expect(row.snapshot.displayName == "OpenCode Go")
        #expect(row.snapshot.status == .healthy)
    }

    @Test func row_rendersUnsupportedStatus() {
        let snap = makeUnsupportedSnapshot()
        let row = MetricRowView(snapshot: snap)
        if case .unsupported = row.snapshot.status {
            #expect(true)
        } else {
            #expect(false, "expected unsupported")
        }
    }

    @Test func row_rendersCriticalStatus() {
        let snap = makeSnapshot(vendorId: .githubRest, status: .critical, metric: .count(remaining: 3, limit: 60, unitName: "req/hr"))
        let row = MetricRowView(snapshot: snap)
        #expect(row.snapshot.status == .critical)
    }

    @Test func row_rendersCurrencyMetric() {
        let metric = MetricType.currency(balance: 15.0, limit: 20.0, spent: 5.0, currencyCode: "USD")
        let snap = makeSnapshot(vendorId: .openrouter, status: .healthy, metric: metric)
        let row = MetricRowView(snapshot: snap)
        #expect(row.snapshot.vendorId == .openrouter)
        #expect(row.snapshot.metric == metric)
    }

    @Test func row_rendersNetworkError() {
        let snap = makeSnapshot(
            vendorId: .gemini,
            status: .networkError("Connection failed"),
            metric: .percentage(usedFraction: 0, displayDetails: nil)
        )
        let row = MetricRowView(snapshot: snap)
        #expect(row.snapshot.status == .networkError("Connection failed"))
    }
}

// MARK: - Helpers (no dependency on QuotaBarCoreTests)

private func makeSnapshot(vendorId: VendorIdentifier, status: ProviderStatus, metric: MetricType) -> QuotaSnapshot {
    QuotaSnapshot(
        id: vendorId.rawValue,
        vendorId: vendorId,
        displayName: vendorId.displayName,
        category: category(for: vendorId),
        metric: metric,
        status: status,
        resetsAt: nil,
        lastUpdated: Date(),
        auxiliaryInfo: nil
    )
}

private func makeUnsupportedSnapshot() -> QuotaSnapshot {
    QuotaSnapshot(
        id: "claude",
        vendorId: .claude,
        displayName: "Claude",
        category: .aiSubscriptions,
        metric: .subscription(tierName: "Claude Pro (estimated)", renewalDate: nil),
        status: .unsupported("No public quota API"),
        resetsAt: nil,
        lastUpdated: Date(),
        auxiliaryInfo: "No public quota API"
    )
}

private func category(for vendorId: VendorIdentifier) -> MetricCategory {
    switch vendorId {
    case .openrouter: return .apiSpendAndCredits
    case .githubRest, .githubGraphql: return .developerLimits
    default: return .aiSubscriptions
    }
}
