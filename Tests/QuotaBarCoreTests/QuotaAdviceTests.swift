import Testing
import Foundation
@testable import QuotaBarCore

@Suite("QuotaAdvice — Smart advice & model routing")
struct QuotaAdviceTests {

    @Test("All primary quotas critical advises using OpenRouter until Claude resets")
    func allQuotasCriticalAdvisesOpenRouter() {
        let claude = QuotaSnapshot(
            id: "claude",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Claude Max", renewalDate: nil),
            status: .measured(.critical),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.95, secondaryFraction: 0.05, label: "5H", resetText: "3 hours"),
            row2: DualBarMetrics(primaryFraction: 0.90, label: "WK")
        )
        let gemini = QuotaSnapshot(
            id: "gemini",
            vendorId: .gemini,
            displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "AI Studio", renewalDate: nil),
            status: .measured(.critical),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.92, label: "5H"),
            row2: DualBarMetrics(primaryFraction: 0.88, label: "WK")
        )
        let openrouter = QuotaSnapshot(
            id: "openrouter",
            vendorId: .openrouter,
            displayName: "OpenRouter",
            category: .apiSpendAndCredits,
            metric: .currency(balance: 22.01, limit: 31.00, spent: 8.99, currencyCode: "AUD"),
            status: .measured(.none),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            badgeText: "A$22.01 left"
        )

        let advice = QuotaAdvice.evaluate(from: [claude, gemini, openrouter])
        #expect(advice.urgency == .critical)
        #expect(advice.message.contains("OpenRouter"))
        #expect(advice.message.contains("3 hours"))
        #expect(advice.suggestedAction == "Use OpenRouter Models")
    }

    @Test("Gemini resetting soon with unused allowance advises prioritizing Gemini")
    func geminiResettingSoonAdvisesUsingGemini() {
        let claude = QuotaSnapshot(
            id: "claude",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Claude Max", renewalDate: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.60, label: "5H", resetText: "4 hours")
        )
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
            row1: DualBarMetrics(primaryFraction: 0.20, label: "5H", resetText: "in 5 hours")
        )

        let advice = QuotaAdvice.evaluate(from: [claude, gemini])
        #expect(advice.headline.contains("Gemini"))
        #expect(advice.message.contains("Gemini"))
        #expect(advice.message.contains("in 5 hours"))
        #expect(advice.suggestedAction == "Use Gemini")
    }


    @Test("Claude elevated usage with Gemini headroom advises switching to Gemini")
    func claudeHighGeminiLowAdvisesSwitch() {
        let claude = QuotaSnapshot(
            id: "claude",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Claude Max", renewalDate: nil),
            status: .measured(.warning),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.80, label: "5H", resetText: "42m")
        )
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
            row1: DualBarMetrics(primaryFraction: 0.30, label: "5H")
        )

        let advice = QuotaAdvice.evaluate(from: [claude, gemini])
        #expect(advice.urgency == .critical)
        #expect(advice.headline == "Use Gemini")
        #expect(advice.message.contains("Gemini has 70% remaining"))
        #expect(advice.message.contains("Claude 5H at 80% (resets in 42m)"))
        #expect(advice.suggestedAction == "Use Gemini")
    }




    @Test("GitHub REST limit near exhaustion advises throttling or switching to GraphQL")
    func gitHubRestLimitNearExhaustion() {
        let github = QuotaSnapshot(
            id: "github_rest",
            vendorId: .githubRest,
            displayName: "GitHub REST",
            category: .developerLimits,
            metric: .count(remaining: 100, limit: 5000, unitName: "req/hr"),
            status: .measured(.critical),
            resetsAt: Date().addingTimeInterval(1800),
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.98, label: "5H", resetText: "30m")
        )

        let advice = QuotaAdvice.evaluate(from: [github])
        #expect(advice.urgency == .critical)
        #expect(advice.headline.contains("GitHub REST"))
        #expect(advice.message.contains("GraphQL"))
        #expect(advice.suggestedAction == "Throttle GitHub CLI")
    }

    @Test("All healthy providers return optimal headroom advice")
    func allHealthyProviders() {
        let claude = QuotaSnapshot(
            id: "claude",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Claude Max", renewalDate: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.60, label: "5H")
        )
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
            row1: DualBarMetrics(primaryFraction: 0.60, label: "5H")
        )

        let advice = QuotaAdvice.evaluate(from: [claude, gemini])
        #expect(advice.urgency == .none)
        #expect(advice.headline == "All Quotas Healthy & Balanced")
        #expect(advice.suggestedAction == "Optimal Headroom")
        #expect(advice.message.contains("Claude & Gemini have ample headroom"))
    }

    // MARK: - Unreadable providers are never counted as headroom

    private func subscription(
        _ vendor: VendorIdentifier,
        used: Double,
        label: String = "5H",
        urgency: Urgency = .none,
        reset: String? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: .measured(urgency), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, label: label, resetText: reset)
        )
    }

    private func unreadable(_ vendor: VendorIdentifier, _ reason: UnavailableReason) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: reason.headline, renewalDate: nil),
            status: .unavailable(reason), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: reason.remedy
        )
    }

    /// The reported bug: Claude and OpenAI nearly spent, OpenCode exhausted,
    /// Gemini wide open — and the summary read "All Quotas Healthy & Balanced,
    /// Claude, Gemini and OpenCode have ample headroom".
    @Test("a constrained fleet with one open provider routes to that provider")
    func constrainedFleetRoutesToTheOpenProvider() {
        let advice = QuotaAdvice.evaluate(from: [
            subscription(.claude, used: 0.88, label: "WK", reset: "2 days"),
            subscription(.openai, used: 0.92, label: "WK"),
            subscription(.opencode, used: 1.0, label: "MO", urgency: .critical),
            subscription(.gemini, used: 0.06, label: "AG"),
        ])
        #expect(advice.headline == "Use Gemini")
        #expect(advice.vendorId == .gemini)
        #expect(advice.urgency == .critical)
        #expect(advice.message.contains("Gemini has 94% remaining"))
        #expect(advice.message.contains("OpenAI WK at 92%"))
        #expect(advice.message.contains("Claude WK at 88% (resets in 2 days)"))
        #expect(advice.message.contains("OpenCode MO exhausted"))
    }

    /// An unreadable provider is not an empty one. The old engine defaulted a
    /// missing fraction to 0.0, which read as "plenty left".
    @Test("unreadable providers are named as unread, never as headroom")
    func unreadableProvidersAreNotHeadroom() {
        let advice = QuotaAdvice.evaluate(from: [
            subscription(.claude, used: 0.30),
            unreadable(.gemini, .notConfigured),
            unreadable(.opencode, .unsupported("No usage API")),
        ])
        #expect(advice.headline == "All Quotas Healthy & Balanced")
        #expect(advice.message.contains("Claude has ample headroom"))
        #expect(advice.message.contains("Gemini & OpenCode could not be read"))
        #expect(!advice.message.contains("Gemini has"))
    }

    /// A constrained provider with nothing to route to must not nominate an
    /// unreadable provider as the alternative.
    @Test("no readable alternative falls back to OpenRouter, not to an unread provider")
    func noReadableAlternativeFallsBack() {
        let advice = QuotaAdvice.evaluate(from: [
            subscription(.claude, used: 0.97, urgency: .critical, reset: "3 hours"),
            unreadable(.gemini, .credentialRejected),
        ])
        #expect(advice.suggestedAction == "Use OpenRouter Models")
        #expect(advice.vendorId == .openrouter)
        #expect(advice.message.contains("until Claude resets in 3 hours"))
    }

    // MARK: - Paid-for allowance is spent before metered credit

    private func constrainedWindow(
        _ vendor: VendorIdentifier,
        used: Double,
        label: String,
        pace: Double?,
        reset: String? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, expectedPaceFraction: pace,
                                 label: label, resetText: reset)
        )
    }

    /// The reported behaviour: with everything constrained but a weekly window
    /// resetting tomorrow, the advice sent the user to paid OpenRouter credit
    /// instead of the allowance they had already bought and were about to lose.
    @Test("an allowance about to reset unspent is preferred over paid credit")
    func expiringAllowanceBeatsOpenRouter() {
        let advice = QuotaAdvice.evaluate(from: [
            // 90% used, six days into a seven-day window: 10% is about to expire.
            constrainedWindow(.claude, used: 0.90, label: "WK", pace: 6.0 / 7.0, reset: "11 hours"),
            constrainedWindow(.openai, used: 0.92, label: "WK", pace: 0.30),
            constrainedWindow(.copilot, used: 1.0, label: "PREM", pace: 0.50),
        ])
        #expect(advice.headline == "Spend Remaining Claude")
        #expect(advice.vendorId == .claude)
        #expect(advice.suggestedAction == "Use Claude")
        #expect(advice.message.contains("Claude WK has 10% left"))
        #expect(advice.message.contains("resets in 11 hours"))
        #expect(!advice.message.contains("Route urgent tasks"))
        // The other constraints are still reported, not swallowed.
        #expect(advice.message.contains("OpenAI WK at 92%"))
        #expect(advice.message.contains("Copilot PREM exhausted"))
    }

    /// Early in a window there is nothing about to be lost, so the free-
    /// allowance nudge must not fire — the honest advice is still to route out.
    @Test("allowance in a window that just opened is not treated as expiring")
    func earlyWindowIsNotExpiring() {
        let advice = QuotaAdvice.evaluate(from: [
            constrainedWindow(.claude, used: 0.88, label: "WK", pace: 0.10, reset: "6 days"),
        ])
        #expect(advice.suggestedAction == "Use OpenRouter Models")
    }

    /// Without a measured pace we do not know whether the window is ending, and
    /// must not guess that it is.
    @Test("an unpaced window never claims an allowance is about to expire")
    func unpacedWindowIsNotExpiring() {
        let advice = QuotaAdvice.evaluate(from: [
            constrainedWindow(.claude, used: 0.88, label: "WK", pace: nil, reset: "soon"),
        ])
        #expect(advice.suggestedAction == "Use OpenRouter Models")
    }

    /// A genuinely spent allowance has nothing left to burn.
    @Test("a fully spent window falls through to OpenRouter")
    func spentWindowFallsThrough() {
        let advice = QuotaAdvice.evaluate(from: [
            constrainedWindow(.claude, used: 1.0, label: "WK", pace: 0.95, reset: "11 hours"),
        ])
        #expect(advice.suggestedAction == "Use OpenRouter Models")
    }

    @Test("nothing readable at all is reported as no readings, not as health")
    func nothingReadable() {
        let advice = QuotaAdvice.evaluate(from: [
            unreadable(.claude, .credentialRejected),
            unreadable(.gemini, .notConfigured),
        ])
        #expect(advice.headline == "No Quota Readings")
        #expect(advice.urgency == .none)
    }
}
