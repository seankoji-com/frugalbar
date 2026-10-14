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
        resetsAt: Date? = nil,
        row1: DualBarMetrics? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: name, vendorId: .githubRest, displayName: name,
            category: .developerLimits, metric: metric, status: status,
            resetsAt: resetsAt, lastUpdated: now, auxiliaryInfo: nil,
            row1: row1
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

    /// I27's regression: a measured provider whose window came back with *no
    /// percentage* (a nil-fraction, non-blocked `DualBarMetrics` bar) must not
    /// be rendered as a fabricated "0%"/"100%" consumption. The row has no
    /// denominator — so no bar, no percentage, and crucially not "exhausted" —
    /// even though the snapshot is a real measured one.
    @Test("a nil-fraction, non-blocked bar renders no fabricated percentage")
    func nilFractionBarRendersNoFabricatedPercent() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                name: "Gemini",
                metric: .subscription(tierName: "AI Studio", renewalDate: nil),
                status: .measured(.none),
                row1: DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: false)
            ),
            now: now
        )
        // No denominator → no bar, no computed fraction.
        #expect(p.fraction == nil)
        // Coercing the nil fraction to 1.0 would flip this to `true` and paint
        // a spent row from zero data — the exact fabrication I27 forbids.
        #expect(p.isExhausted == false)
        // The row says what it actually knows — the plan name — and nothing
        // that implies a measured percentage.
        #expect(p.valueLabel == "AI Studio")
        #expect(!p.valueLabel.contains("%"))
        #expect(!p.accessibilityLabel.contains("%"))
        #expect(!p.accessibilityLabel.lowercased().contains("percent"))
    }

    @Test("DevPass monthly plan row presentation has measured fraction and correct accessibility text")
    func devPassPlanRowPresentation() {
        let snap = QuotaSnapshot(
            id: "devpass", vendorId: .devpass, displayName: "DevPass",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.25, displayDetails: nil),
            status: .measured(.none),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: "DevPass monthly plan credits",
            row1: DualBarMetrics(primaryFraction: 0.25, label: "MO", usedText: "$20.00/80.00 credits used"),
            badgeText: "$60.00 left", planName: "DevPass Lite"
        )
        let p = MetricRowPresentation(snapshot: snap, now: now)

        #expect(p.fraction == 0.25)
        #expect(p.isMeasured == true)
        #expect(p.valueLabel == "25%")
        #expect(snap.bars.count == 1)
        #expect(snap.bars.first?.label == "MO")
        #expect(p.accessibilityLabel.contains("DevPass"))
        #expect(p.accessibilityLabel.contains("25 percent used"))
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

    // MARK: - A reading carried over from a failed poll

    /// A percentage that arrived an hour ago draws exactly like one that
    /// arrived a second ago, so the row is the only place a glance can learn
    /// that its figures are not the newest poll's. Regression: retention
    /// replaced the failed poll's snapshot wholesale, so the row said nothing
    /// and hour-old figures read as the provider's state now.
    /// Proven red by returning nil from `MetricRowPresentation.staleDisplay`.
    @Test("a stale reading is marked on the row, in words and in the spoken label")
    func staleReadingIsMarked() {
        var stale = snapshot(
            name: "Claude",
            metric: .percentage(usedFraction: 0.42, displayDetails: nil),
            status: .measured(.warning),
            row1: DualBarMetrics(primaryFraction: 0.42, label: "WK")
        )
        // Current figures carry no note at all — this is not a decoration
        // every row wears.
        let fresh = MetricRowPresentation(snapshot: stale, now: now)
        #expect(fresh.staleNote == nil)
        #expect(fresh.staleSpoken == nil)

        // Fetched at `now`; the newest poll failed ten minutes later.
        stale.staleReading = StaleReading(reason: .offline, at: now.addingTimeInterval(600))
        let shown = now.addingTimeInterval(660)
        let p = MetricRowPresentation(snapshot: stale, now: shown)

        let note = p.staleNote ?? ""
        let figuresAt = MetricDetailPresentation.clockText(now, now: shown)
        #expect(note == "Stale — last poll failed (Offline), figures from \(figuresAt)")
        // The figures' own instant, never the failed poll's: naming the poll
        // would read as "we measured this ten minutes ago", which is the bug.
        #expect(!note.contains(MetricDetailPresentation.clockText(
            now.addingTimeInterval(600), now: shown)))
        #expect(p.staleSpoken?.contains("Offline") == true)
        // Both labels, because the window grid speaks the short one — a grid
        // row that stayed silent here would be the same bug in audio.
        #expect(p.accessibilityLabel.contains("stale"))
        #expect(p.accessibilityLabelOmittingPercentage.contains("stale"))
        #expect(p.accessibilityLabel.contains(figuresAt))
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

    /// Regression: retention left a failed poll's snapshot looking exactly like
    /// a fresh one, so the footer's age was the only sign anything was wrong —
    /// and an age alone reads as a stuck clock. Proven red by dropping
    /// `staleCount` from the summary.
    @Test("a stale reading is reported without being counted as unreadable")
    func staleReadingIsReportedWithoutDemotingTheIcon() {
        var stale = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.2, displayDetails: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil)
        stale.staleReading = StaleReading(reason: .offline, at: Date())

        let summary = SystemHealthSummary.compute(from: [stale])
        #expect(summary.staleCount == 1)
        // It is still a reading: an unreadable provider must never outrank a
        // real one, and a stale provider has a real one.
        #expect(summary.unavailableCount == 0)
        #expect(summary.hasAnyReading)
        #expect(SystemHealthPresentation.symbol(for: summary) == "checkmark.circle.fill")
        #expect(SystemHealthPresentation.text(for: summary) == "All quotas healthy · 1 stale")

        // And with nothing stale, the wording is exactly what it was.
        stale.staleReading = nil
        #expect(SystemHealthPresentation.text(for: SystemHealthSummary.compute(from: [stale]))
            == "All quotas healthy")
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
        #expect(details.timeLeftText == "3h 29m")
        #expect(details.displayText == "41% 3h 29m")
        let spoken = MenuBarPresentation.accessibilityDescription(for: summary, recommendation: details)
        #expect(spoken.contains("Gemini 41% remaining"))
        #expect(spoken.contains("resets in 3h 29m"))
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

    @Test("recommended tint follows the recommended vendor, not the whole-summary worst urgency")
    func recommendedTintFollowsRecommendedVendor() {
        // The recommended (advised) vendor is healthy, while a *different*
        // vendor is critical. The summary's worst urgency is critical, but the
        // carried tint must reflect the healthy recommendation — so nil, not
        // red. This is the regression: the previous title colour re-derived
        // from the whole-summary worst urgency and painted the healthy number
        // red.
        let gemini = QuotaSnapshot(
            id: "gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "AI Studio", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.10, label: "5H")
        )
        let claude = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Max", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.99, label: "5H")
        )
        // Name the healthy vendor directly to isolate the tint logic from the
        // advisor's own selection.
        let advice = QuotaAdvice(headline: "Use Gemini", message: "", vendorId: .gemini)
        let summary = SystemHealthSummary.compute(from: [gemini, claude])
        #expect(summary.worstUrgency == .critical)

        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [gemini, claude],
            summary: summary
        )

        #expect(details.vendorId == .gemini)
        #expect(details.recommendedTint == nil)
        #expect(MenuBarPresentation.tint(for: summary) == .systemRed)
    }

    @Test("recommended tint is orange when the recommended vendor itself is under warning pressure")
    func recommendedVendorWarningTintsOrange() {
        let gemini = QuotaSnapshot(
            id: "gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "AI Studio", renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.75, label: "5H")
        )
        let advice = QuotaAdvice(headline: "Use Gemini", message: "", vendorId: .gemini)
        let summary = SystemHealthSummary.compute(from: [gemini])

        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [gemini],
            summary: summary
        )

        #expect(details.recommendedTint == .systemOrange)
    }

    @Test("recommended tint is nil when the recommended vendor is unreadable")
    func unavailableRecommendedHasNoTint() {
        let gemini = QuotaSnapshot(
            id: "gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "AI Studio", renewalDate: nil),
            status: .unavailable(.unsupported("no API")), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil
        )
        let advice = QuotaAdvice(headline: "Use Gemini", message: "", vendorId: .gemini)
        let summary = SystemHealthSummary.compute(from: [gemini])

        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [gemini],
            summary: summary
        )

        #expect(details.recommendedTint == nil)
    }

    @Test("formatTimeLeft parses various duration formats")
    func formatTimeLeftParsesDurations() {
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 3h 29m") == "3h 29m")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 2h 10m") == "2h 10m")
        #expect(MenuBarPresentation.formatTimeLeft("42m") == "42m")
        #expect(MenuBarPresentation.formatTimeLeft("4d 6h") == "4d 6h")
        #expect(MenuBarPresentation.formatTimeLeft("167h 25m") == "167h 25m")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 3 hours") == "3h")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 42 minutes") == "42m")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 4 days") == "4d")
        #expect(MenuBarPresentation.formatTimeLeft("3 hrs 29 mins") == "3h 29m")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 1 week") == "1w")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 3 weeks") == "3w")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 1 month") == "1mo")
        #expect(MenuBarPresentation.formatTimeLeft("Resets in 2 months") == "2mo")
        #expect(MenuBarPresentation.formatTimeLeft("1mo 2w") == "1mo 2w")
        #expect(MenuBarPresentation.formatTimeLeft("3m") == "3m")
        #expect(MenuBarPresentation.formatTimeLeft("3 models") == nil)
        #expect(MenuBarPresentation.formatTimeLeft("1.5 hours") == nil)
        #expect(MenuBarPresentation.formatTimeLeft(nil) == nil)
        #expect(MenuBarPresentation.formatTimeLeft("Not reported") == nil)
    }
}

