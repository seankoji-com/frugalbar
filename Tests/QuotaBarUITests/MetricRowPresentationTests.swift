import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

@Suite("MetricRowPresentation")
struct MetricRowPresentationTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        name: String = "Vendor",
        metric: MetricType,
        status: ProviderStatus,
        resetsAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: name, vendorId: .githubRest, displayName: name,
            category: .developerLimits, metric: metric, status: status,
            resetsAt: resetsAt, lastUpdated: now, auxiliaryInfo: nil
        )
    }

    // MARK: - No denominator means no bar

    @Test("an unreadable provider draws no bar and shows the reason")
    func unavailableDrawsNoBar() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                name: "Claude",
                metric: .subscription(tierName: "No usage API", renewalDate: nil),
                status: .unavailable(.unsupported("Anthropic publishes no quota API"))
            ),
            now: now
        )
        #expect(p.fraction == nil)
        #expect(p.isMeasured == false)
        #expect(p.valueLabel == "No usage API")
        #expect(p.resetLabel == "—")
        #expect(p.accessibilityLabel.contains("Claude"))
        #expect(p.accessibilityLabel.contains("No usage API"))
    }

    @Test("a not-configured provider offers a remedy, not a number")
    func notConfigured() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 0, limit: 60, unitName: "req/hr"),
                status: .unavailable(.notConfigured)
            ),
            now: now
        )
        // Even though the placeholder metric says 0/60, an unreadable provider
        // must not render as a full red bar.
        #expect(p.fraction == nil)
        #expect(p.valueLabel == "Not configured")
        #expect(p.accessibilityLabel.contains("Add a key in Settings"))
    }

    @Test("an uncapped spend figure has no fraction")
    func uncappedCurrency() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                name: "OpenRouter",
                metric: .currency(balance: 12.34, limit: nil, spent: 12.34, currencyCode: "USD"),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(p.fraction == nil)
        #expect(p.isMeasured)
        #expect(p.valueLabel.contains("12.34"))
        #expect(p.accessibilityLabel.contains("spent"))
    }

    // MARK: - Measured readings

    @Test("a capped count reports the consumed fraction")
    func measuredCount() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 25, limit: 100, unitName: "req/hr"),
                status: .measured(.none),
                resetsAt: now.addingTimeInterval(1800)
            ),
            now: now
        )
        #expect(p.fraction == 0.75)
        #expect(p.valueLabel == "25/100")
        #expect(p.resetLabel == "30m")
        #expect(p.accessibilityLabel.contains("25 of 100 req/hr remaining"))
        #expect(p.accessibilityLabel.contains("Resets in 30 minutes"))
    }

    @Test("urgency is spoken, not just coloured")
    func urgencyIsSpoken() {
        let critical = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 2, limit: 100, unitName: "req/hr"),
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(critical.accessibilityLabel.contains("critically low"))

        let warning = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 20, limit: 100, unitName: "req/hr"),
                status: .measured(.warning)
            ),
            now: now
        )
        #expect(warning.accessibilityLabel.contains("running low"))

        let ok = MetricRowPresentation(
            snapshot: snapshot(
                metric: .count(remaining: 90, limit: 100, unitName: "req/hr"),
                status: .measured(.none)
            ),
            now: now
        )
        #expect(!ok.accessibilityLabel.contains("low"))
    }

    @Test("every row carries a non-empty spoken label")
    func alwaysHasAccessibilityLabel() {
        let cases: [ProviderStatus] = [
            .measured(.none), .measured(.warning), .measured(.critical),
            .unavailable(.notConfigured), .unavailable(.offline),
            .unavailable(.credentialRejected), .unavailable(.timedOut),
            .unavailable(.badResponse), .unavailable(.unsupported("no API")),
            .rateLimited(retryAfter: nil),
        ]
        for status in cases {
            let p = MetricRowPresentation(
                snapshot: snapshot(
                    metric: .count(remaining: 1, limit: 10, unitName: "u"),
                    status: status
                ),
                now: now
            )
            #expect(!p.accessibilityLabel.isEmpty, "empty label for \(status)")
            #expect(p.accessibilityLabel.contains("Vendor"), "label omits the provider name for \(status)")
        }
    }
}

@Suite("MenuBarPresentation")
struct MenuBarPresentationTests {

    private func snap(_ status: ProviderStatus, at date: Date = Date()) -> QuotaSnapshot {
        QuotaSnapshot(
            id: UUID().uuidString, vendorId: .githubRest, displayName: "v",
            category: .developerLimits,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: date, auxiliaryInfo: nil
        )
    }

    /// The regression this whole model exists to prevent: a provider with no
    /// data source must not pin the menu bar icon to a permanent error state.
    @Test("an unreadable provider does not colour the icon")
    func unreadableDoesNotDominate() {
        let summary = SystemHealthSummary.compute(from: [
            snap(.unavailable(.unsupported("no API"))),
            snap(.measured(.none)), snap(.measured(.none)), snap(.measured(.none)),
        ])
        #expect(summary.worstUrgency == .none)
        #expect(summary.unavailableCount == 1)
        #expect(MenuBarPresentation.tint(for: summary) == nil)
        #expect(MenuBarPresentation.showsUnavailableBadge(for: summary))
    }

    @Test("a critical quota is never masked by an unreadable provider")
    func criticalWins() {
        let summary = SystemHealthSummary.compute(from: [
            snap(.unavailable(.unsupported("no API"))),
            snap(.unavailable(.notConfigured)),
            snap(.measured(.critical)),
        ])
        #expect(summary.worstUrgency == .critical)
        #expect(MenuBarPresentation.tint(for: summary) == .systemRed)
        #expect(MenuBarPresentation.accessibilityDescription(for: summary).contains("critically low"))
    }

    @Test("warning tints orange")
    func warningTint() {
        let summary = SystemHealthSummary.compute(from: [snap(.measured(.warning))])
        #expect(MenuBarPresentation.tint(for: summary) == .systemOrange)
    }

    @Test("with no readings at all the icon stays untinted and says so")
    func noReadings() {
        let summary = SystemHealthSummary.compute(from: [
            snap(.unavailable(.notConfigured)), snap(.unavailable(.offline)),
        ])
        #expect(summary.hasAnyReading == false)
        #expect(MenuBarPresentation.tint(for: summary) == nil)
        #expect(MenuBarPresentation.accessibilityDescription(for: summary).contains("no readings"))
    }

    @Test("staleness reports the oldest reading, not the newest")
    func oldestReading() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 9_000)
        let summary = SystemHealthSummary.compute(from: [
            snap(.measured(.none), at: new),
            snap(.measured(.none), at: old),
        ])
        #expect(summary.oldestReading == old)
    }

    @Test("recommendationDetails extracts lowest remaining bar and time left for recommended platform")
    func recommendationDetailsExtractsLowestQuota() {
        let gemini = QuotaSnapshot(
            id: "gemini",
            vendorId: .gemini,
            displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "AI Studio", renewalDate: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.59, label: "5H", resetText: "Resets in 3h 29m"),
            row2: DualBarMetrics(primaryFraction: 0.04, label: "WK", resetText: "Refreshes in 167h 25m")
        )
        let advice = QuotaAdvice(
            headline: "Use Gemini",
            message: "Gemini high remaining.",
            vendorId: .gemini
        )
        let summary = SystemHealthSummary.compute(from: [gemini])

        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [gemini],
            summary: summary
        )

        #expect(details.vendorId == .gemini)
        #expect(details.remainingPctText == "41%")
        #expect(details.timeLeftText == "3.48hr")
        #expect(details.displayText == "41% 3.48hr")
    }

    @Test("recommendationDetails picks the healthy measured vendor over one merely first in order")
    func recommendationDetailsFallbackPrefersHealthy() {
        // Claude sorts first but is at 75% used (warning); Gemini sorts
        // second but is healthy at 10% used with no headline vendor named —
        // the fallback must recommend the one with real headroom, not
        // whichever measured vendor happens to come first.
        let claude = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Max", renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.75, label: "5H")
        )
        let gemini = QuotaSnapshot(
            id: "gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "AI Studio", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.10, label: "5H")
        )
        let advice = QuotaAdvice(headline: "All Quotas Healthy & Balanced", message: "")
        let summary = SystemHealthSummary.compute(from: [claude, gemini])

        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [claude, gemini],
            summary: summary
        )

        #expect(details.vendorId == .gemini)
    }

    @Test("formatTimeLeft parses various duration formats")
    func formatTimeLeftParsesDurations() {
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 3h 29m") == "3.48hr")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 2h 10m") == "2.17hr")
        #expect(MenuBarPresentation.formatTimeLeft("42m") == "0.70hr")
        #expect(MenuBarPresentation.formatTimeLeft("4d 6h") == "4.2d")
    }
}

