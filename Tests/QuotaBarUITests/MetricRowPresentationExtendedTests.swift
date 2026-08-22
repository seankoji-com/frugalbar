import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func snapshot(
    name: String = "Vendor",
    metric: MetricType,
    status: ProviderStatus,
    resetsAt: Date? = nil,
    lastUpdated: Date = now
) -> QuotaSnapshot {
    QuotaSnapshot(
        id: name, vendorId: .githubRest, displayName: name,
        category: .developerLimits, metric: metric, status: status,
        resetsAt: resetsAt, lastUpdated: lastUpdated, auxiliaryInfo: nil
    )
}

@Suite("MetricRowPresentation — all MetricType cases")
struct MetricRowPresentationAllCases {

    // MARK: - Percentage

    @Test("percentage value label shows percentage")
    func percentageValueLabel() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .percentage(usedFraction: 0.25, displayDetails: nil),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.valueLabel == "25%")
        #expect(p.fraction == 0.25)
    }

    @Test("percentage spoken describes percent used")
    func percentageSpoken() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .percentage(usedFraction: 0.90, displayDetails: nil),
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(p.accessibilityLabel.contains("90 percent used"))
        #expect(p.accessibilityLabel.contains("critically low"))
    }

    @Test("percentage with displayDetails is unrelated to valueLabel")
    func percentageDisplayDetails() {
        // displayDetails is stored but not currently rendered in MetricRowPresentation
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .percentage(usedFraction: 0.5, displayDetails: "Details here"),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.valueLabel == "50%")
        #expect(p.accessibilityLabel.contains("50 percent used"))
    }

    // MARK: - Count

    @Test("count value label shows remaining/limit")
    func countValueLabel() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 25, limit: 100, unitName: "req/hr"),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.valueLabel == "25/100")
    }

    @Test("count spoken describes remaining of limit unit")
    func countSpoken() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 5, limit: 60, unitName: "req/min"),
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(p.accessibilityLabel.contains("5 of 60 req/min remaining"))
        #expect(p.accessibilityLabel.contains("critically low"))
    }

    @Test("count with zero remaining and full limit")
    func countExhausted() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 0, limit: 60, unitName: "req/hr"),
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(p.valueLabel == "0/60")
        #expect(p.fraction == 1.0)
        #expect(p.accessibilityLabel.contains("0 of 60 req/hr remaining"))
    }

    // MARK: - Currency

    /// Helper: produces the same .formatted(.currency()) output the code uses.
    private static func fmt(_ value: Decimal, code: String) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(2)))
    }

    @Test("currency with limit shows 'X left of Y'")
    func currencyWithLimit() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                name: "OpenRouter",
                metric: .currency(balance: 7.50, limit: 20, spent: 12.50, currencyCode: "USD"),
                status: .measured(.warning)
            ),
            now: now
        )
        #expect(p.valueLabel == "\(Self.fmt(7.50, code: "USD")) left of \(Self.fmt(20, code: "USD"))")
        // fraction = 1 - (7.50 / 20.00) = 0.625
        #expect(p.fraction == 0.625)
        #expect(p.accessibilityLabel.contains("running low"))
    }

    /// A bare dollar figure does not say whether it is money left or money
    /// spent, and the two lead to opposite decisions. The label is the fact.
    @Test("currency without limit names the spend rather than showing a bare figure")
    func currencyWithoutLimit() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                name: "OpenRouter",
                metric: .currency(balance: 12.34, limit: nil, spent: 12.34, currencyCode: "USD"),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.valueLabel == "\(Self.fmt(12.34, code: "USD")) spent")
        #expect(p.fraction == nil)
        #expect(p.isMeasured)
    }

    @Test("currency without limit or spent uses balance in value label")
    func currencyNoLimitNoSpent() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .currency(balance: 99.99, limit: nil, spent: nil, currencyCode: "USD"),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.valueLabel == Self.fmt(99.99, code: "USD"))
        #expect(p.fraction == nil)
    }

    @Test("currency with high precision decimals formats correctly")
    func currencyHighPrecision() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .currency(balance: 0.001, limit: 1, spent: 0.999, currencyCode: "USD"),
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(p.valueLabel == "\(Self.fmt(0, code: "USD")) left of \(Self.fmt(1, code: "USD"))")
        #expect(p.fraction == 0.999)
    }

    // MARK: - Subscription

    @Test("subscription value label shows tier name")
    func subscriptionValueLabel() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .subscription(tierName: "Claude Pro", renewalDate: nil),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.valueLabel == "Claude Pro")
        #expect(p.fraction == nil)
    }

    @Test("subscription spoken label includes tier name")
    func subscriptionSpoken() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .subscription(tierName: "Team", renewalDate: nil),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.accessibilityLabel.contains("Team"))
    }

    @Test("subscription with renewal date shows reset")
    func subscriptionWithRenewal() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .subscription(tierName: "Pro", renewalDate: now.addingTimeInterval(86400)),
                status: .measured(.none),
                resetsAt: now.addingTimeInterval(86400)
            ),
            now: now
        )
        #expect(p.valueLabel == "Pro")
        #expect(p.resetLabel != "—")
        #expect(p.accessibilityLabel.contains("Resets"))
    }

    // MARK: - Unavailable with various reasons

    @Test("offline shows headline and remedy")
    func offlineRow() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 0, limit: 10, unitName: "u"),
                status: .unavailable(.offline)
            ),
            now: now
        )
        #expect(p.valueLabel == "Offline")
        #expect(p.accessibilityLabel.contains("Check your connection"))
    }

    @Test("credentialRejected shows headline and remedy")
    func credentialRejectedRow() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 0, limit: 10, unitName: "u"),
                status: .unavailable(.credentialRejected)
            ),
            now: now
        )
        #expect(p.valueLabel == "Credential rejected")
        #expect(p.accessibilityLabel.contains("Check the key in Settings"))
    }

    @Test("badResponse shows headline and remedy")
    func badResponseRow() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 0, limit: 10, unitName: "u"),
                status: .unavailable(.badResponse)
            ),
            now: now
        )
        #expect(p.valueLabel == "Unexpected response")
        #expect(p.accessibilityLabel.contains("Vendor returned unexpected data"))
    }

    @Test("timedOut shows headline and remedy")
    func timedOutRow() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 0, limit: 10, unitName: "u"),
                status: .unavailable(.timedOut)
            ),
            now: now
        )
        #expect(p.valueLabel == "Timed out")
        #expect(p.accessibilityLabel.contains("Vendor slow — will retry"))
    }

    // MARK: - Reset label

    @Test("reset label shows relative time when resetsAt is set")
    func resetLabelCountdown() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 50, limit: 100, unitName: "req/hr"),
                status: .measured(.none),
                resetsAt: now.addingTimeInterval(600)
            ),
            now: now
        )
        #expect(p.resetLabel == "10m")
    }

    @Test("reset label is dash when resetsAt is nil")
    func resetLabelNil() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 50, limit: 100, unitName: "req/hr"),
                status: .measured(.none)
                // resetsAt defaults to nil
            ),
            now: now
        )
        #expect(p.resetLabel == "—")
    }
}
