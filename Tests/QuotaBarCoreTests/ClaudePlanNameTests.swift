import Testing
import Foundation
@testable import QuotaBarCore

/// The plan tier is published in the Claude Code credential blob and nowhere
/// else — Anthropic's rate-limit headers carry usage but not the subscription.
@Suite("Claude plan name")
struct ClaudePlanNameTests {

    private func blob(_ oauth: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    @Test("rateLimitTier carries the multiplier that subscriptionType omits", arguments: [
        ("default_claude_max_5x", "Max (5x)"),
        ("default_claude_max_20x", "Max (20x)"),
        ("default_claude_pro", "Pro"),
        ("default_claude_free", "Free"),
    ])
    func tierStrings(raw: String, expected: String) {
        #expect(CredentialStore.claudePlanName(fromRateLimitTier: raw) == expected)
    }

    @Test("an unrecognised tier string yields nothing rather than a guess")
    func unknownTierIsNil() {
        #expect(CredentialStore.claudePlanName(fromRateLimitTier: "some_new_scheme") == nil)
        #expect(CredentialStore.claudePlanName(fromRateLimitTier: "") == nil)
    }

    @Test("rateLimitTier wins over subscriptionType")
    func tierPreferredOverType() {
        // "max" alone cannot distinguish the 5x plan from the 20x one, and
        // those are materially different allowances.
        let data = blob(["subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"])
        #expect(CredentialStore.claudePlanName(from: data) == "Max (20x)")
    }

    @Test("subscriptionType is the fallback when no tier is published")
    func fallsBackToSubscriptionType() {
        #expect(CredentialStore.claudePlanName(from: blob(["subscriptionType": "pro"])) == "Pro")
    }

    @Test("an unrecognised tier falls through to subscriptionType")
    func unknownTierFallsThrough() {
        let data = blob(["subscriptionType": "max", "rateLimitTier": "wat"])
        #expect(CredentialStore.claudePlanName(from: data) == "Max")
    }

    @Test("a blob with no plan at all reports none")
    func noPlanIsNil() {
        #expect(CredentialStore.claudePlanName(from: blob(["accessToken": "x"])) == nil)
        #expect(CredentialStore.claudePlanName(from: Data("not json".utf8)) == nil)
        #expect(CredentialStore.claudePlanName(from: nil) == nil)
    }

    @Test("an empty subscriptionType is absent, not an empty subtitle")
    func emptySubscriptionTypeIsNil() {
        #expect(CredentialStore.claudePlanName(from: blob(["subscriptionType": ""])) == nil)
    }
}
