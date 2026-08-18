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

    @Test("currency inverts balance against limit (allow floating point)")
    func currency() {
        let m = MetricType.currency(balance: 5, limit: 20, spent: 15, currencyCode: "USD")
        let frac = snapshot(m).consumptionFraction ?? 0
        #expect(abs(frac - 0.75) < 0.001)
    }

    @Test("currency without a limit reports no consumption")
    func currencyNoLimit() {
        let m = MetricType.currency(balance: 5, limit: nil, spent: nil, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == 0.0)
    }

    @Test("subscription has no consumption dimension (nil)")
    func subscription() {
        #expect(snapshot(.subscription(tierName: "Pro", renewalDate: nil)).consumptionFraction == nil)
    }
}

@Suite("ProviderStatus")
struct ProviderStatusTests {

    @Test("severity order")
    func severity() {
        #expect(ProviderStatus.healthy.severity == 0)
        #expect(ProviderStatus.warning.severity == 1)
        #expect(ProviderStatus.critical.severity == 2)
        #expect(ProviderStatus.unauthenticated.severity == 3)
        #expect(ProviderStatus.unsupported("x").severity == 3)
        #expect(ProviderStatus.rateLimited(retryAfter: nil).severity == 3)
        #expect(ProviderStatus.networkError("x").severity == 3)
    }

    @Test("unsupported equality by reason")
    func unsupportedEquality() {
        #expect(ProviderStatus.unsupported("a") == ProviderStatus.unsupported("a"))
        #expect(ProviderStatus.unsupported("a") != ProviderStatus.unsupported("b"))
    }
}

@Suite("VendorIdentifier")
struct VendorIdentifierTests {

    @Test("7 known vendors")
    func allCases() {
        #expect(VendorIdentifier.allCases.count == 7)
    }

    @Test("all display names are non-empty")
    func displayNames() {
        for v in VendorIdentifier.allCases {
            #expect(!v.displayName.isEmpty)
        }
    }
}
