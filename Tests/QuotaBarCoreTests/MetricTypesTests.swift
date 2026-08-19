import Testing
import Foundation
@testable import QuotaBarCore

@Suite("consumptionFraction")
struct ConsumptionFractionTests {

    private func snapshot(_ metric: MetricType, status: ProviderStatus = .healthy) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "t", vendorId: .githubRest, displayName: "t",
            category: .developerLimits, metric: metric, status: status,
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

    @Test("count with a zero limit has no denominator, so no fraction — not a fake 0%")
    func countZeroLimit() {
        #expect(snapshot(.count(remaining: 0, limit: 0, unitName: "u")).consumptionFraction == nil)
    }

    @Test("currency inverts balance against limit (allow floating point)")
    func currency() throws {
        let m = MetricType.currency(balance: 5, limit: 20, spent: 15, currencyCode: "USD")
        let frac = try #require(snapshot(m).consumptionFraction)
        #expect(abs(frac - 0.75) < 0.001)
    }

    @Test("currency without a limit reports no consumption fraction, not zero")
    func currencyNoLimit() {
        let m = MetricType.currency(balance: 5, limit: nil, spent: nil, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == nil)
    }

    @Test("currency with a zero limit reports no consumption fraction, not a divide-by-zero")
    func currencyZeroLimit() {
        let m = MetricType.currency(balance: 5, limit: 0, spent: 5, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == nil)
    }

    @Test("subscription has no consumption dimension (nil)")
    func subscription() {
        #expect(snapshot(.subscription(tierName: "Pro", renewalDate: nil)).consumptionFraction == nil)
    }

    @Test("an unmeasured status yields nil regardless of the underlying metric")
    func unmeasuredStatusYieldsNil() {
        let m = MetricType.percentage(usedFraction: 0.9, displayDetails: nil)
        #expect(snapshot(m, status: .unavailable(.notConfigured)).consumptionFraction == nil)
        // A 429 is an absent reading, not a 90%-consumed quota. Rendering the
        // placeholder metric here is exactly the fabrication this model exists
        // to prevent.
        #expect(snapshot(m, status: .rateLimited(retryAfter: nil)).consumptionFraction == nil)
    }
}

@Suite("ProviderStatus")
struct ProviderStatusTests {

    @Test("urgency ordering")
    func urgencyOrdering() {
        #expect(Urgency.none < .warning)
        #expect(Urgency.warning < .critical)
    }

    @Test("measured urgency passes through")
    func measuredUrgency() {
        #expect(ProviderStatus.measured(.warning).urgency == .warning)
        #expect(ProviderStatus.healthy.urgency == .none)
        #expect(ProviderStatus.warning.urgency == .warning)
        #expect(ProviderStatus.critical.urgency == .critical)
    }

    @Test("unavailable never carries urgency, however severe the underlying reason")
    func unavailableHasNoUrgency() {
        #expect(ProviderStatus.unavailable(.credentialRejected).urgency == .none)
        #expect(ProviderStatus.unauthenticated.urgency == .none)
        #expect(ProviderStatus.unsupported("x").urgency == .none)
    }

    @Test("rateLimited carries no urgency — a 429 is an absent reading, not an emergency")
    func rateLimitedIsNotUrgent() {
        // A 429 on a metadata endpoint says nothing about the user's quota.
        // Treating it as critical turned the whole menu bar red on zero data.
        #expect(ProviderStatus.rateLimited(retryAfter: nil).urgency == .none)
        #expect(ProviderStatus.rateLimited(retryAfter: nil).confidence == .unavailable)
    }

    @Test("confidence: only a parsed reading counts as measured")
    func confidence() {
        #expect(ProviderStatus.healthy.confidence == .measured)
        #expect(ProviderStatus.warning.confidence == .measured)
        #expect(ProviderStatus.critical.confidence == .measured)
        #expect(ProviderStatus.rateLimited(retryAfter: nil).confidence == .unavailable)
        #expect(ProviderStatus.unauthenticated.confidence == .unavailable)
        #expect(ProviderStatus.unsupported("x").confidence == .unavailable)
    }

    @Test("unavailableReason surfaces only on .unavailable")
    func unavailableReasonAccessor() {
        #expect(ProviderStatus.unauthenticated.unavailableReason == .notConfigured)
        #expect(ProviderStatus.healthy.unavailableReason == nil)
        let retry = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ProviderStatus.rateLimited(retryAfter: retry).unavailableReason
                == .rateLimited(retryAfter: retry))
    }

    @Test("unsupported equality is by reason string")
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
