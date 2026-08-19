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
    }
}
