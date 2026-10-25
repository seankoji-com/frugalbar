import Foundation
import Testing
@testable import QuotaBarCore

@Suite("ChatGPT account details")
struct OpenAIAccountPreferencesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("grant and Pro detail are account-bound, never global quota defaults")
    func accountBinding() throws {
        let key = try #require(OpenAIAccountPreferences.accountKey(for: "fixture-account"))
        let grant = try #require(OpenAICreditGrant(total: 75_000, expiresAt: now.addingTimeInterval(100)))
        let saved = OpenAIAccountPreferences(proTier: .pro200, creditGrant: grant)
        let provider = OpenAIQuotaProvider(accountPreferences: { $0 == key ? saved : nil })
        let response = OpenAIQuotaProvider.Response(plan_type: "pro",
            rate_limit: .init(primary_window: .init(used_percent: 24, limit_window_seconds: 604_800)),
            credits: .init(has_credits: true, balance: "59641.125"))
        let matched = provider.makeSnapshot(response: response, accountPlan: nil,
            accountID: "fixture-account", cliSource: "fixture", now: now)
        #expect(matched.planName == "Pro 200")
        #expect(matched.openAIAccountKey == key)
        #expect(matched.apiCredits.first?.creditGrant == grant)
        #expect(matched.apiCredits.first?.metric == .credits(remaining: Decimal(string: "59641.125"), unitName: "credits"))
        for id: String? in [nil, "", "another-account"] {
            let other = provider.makeSnapshot(response: response, accountPlan: nil,
                accountID: id, cliSource: "fixture", now: now)
            #expect(other.planName == "Pro")
            #expect(other.apiCredits.first?.creditGrant == nil)
            #expect(other.consumptionFraction == matched.consumptionFraction)
            #expect(other.quotaBars == matched.quotaBars)
            #expect(other.status == matched.status)
        }
        #expect(OpenAIAccountPreferences.accountKey(for: "  ") == nil)
        #expect(!key.contains("fixture-account"))
    }

    @Test("the vendor's changed plan beats a saved refinement")
    func changedPlan() {
        let settings = OpenAIAccountPreferences(proTier: .pro200)
        #expect(settings.planName(reported: "pro") == "Pro 200")
        #expect(settings.planName(reported: "PRO") == "Pro 200")
        #expect(settings.planName(reported: "plus") == "Plus")
        #expect(settings.planName(reported: "pro_100") == "Pro_100")
        #expect(settings.planName(reported: nil) == nil)
        #expect(OpenAIAccountPreferences().planName(reported: "pro") == "Pro")
    }

    @Test("saved details round-trip without affecting another account")
    func persistence() throws {
        let suite = "OpenAIAccountPreferencesTests.\(UUID().uuidString)"
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let grant = try #require(OpenAICreditGrant(total: Decimal(string: "75000.125")!, expiresAt: now))
        let value = OpenAIAccountPreferences(proTier: .pro200, creditGrant: grant)
        OpenAIAccountPreferences.save(value, accountKey: "one", preferences: prefs)
        OpenAIAccountPreferences.save(.init(proTier: .pro100), accountKey: "two", preferences: prefs)
        #expect(OpenAIAccountPreferences.load(accountKey: "one", preferences: prefs) == value)
        #expect(OpenAIAccountPreferences.load(accountKey: "two", preferences: prefs)?.proTier == .pro100)
        OpenAIAccountPreferences.save(nil, accountKey: "two", preferences: prefs)
        #expect(OpenAIAccountPreferences.load(accountKey: "two", preferences: prefs) == nil)
        #expect(OpenAIAccountPreferences.load(accountKey: "one", preferences: prefs) == value)
        prefs.set(["one": Data(#"{"creditGrant":{"total":0}}"#.utf8)], forKey: OpenAIAccountPreferences.defaultsKey)
        #expect(OpenAIAccountPreferences.load(accountKey: "one", preferences: prefs) == nil)
    }

    @Test("invalid allowances are rejected and absent balances are never invented")
    func invalidGrantAndBalance() throws {
        for text in ["0", "-1", "75000oops", "inf", "NaN", "", "1,000"] {
            #expect(OpenAICreditGrant.parseTotal(text) == nil)
        }
        #expect(OpenAICreditGrant.parseTotal("75000.125") == Decimal(string: "75000.125"))
        #expect(OpenAICreditGrant(total: 0) == nil)
        #expect(OpenAICreditGrant(total: -1) == nil)
        #expect(OpenAICreditGrant(total: .nan) == nil)
        let grant = try #require(OpenAICreditGrant(total: 75_000))
        #expect(OpenAIQuotaProvider.apiCredits(from: nil, grant: grant).isEmpty)
        #expect(OpenAIQuotaProvider.apiCredits(from: .init(has_credits: true, balance: "oops"), grant: grant).isEmpty)
        let unlimited = OpenAIQuotaProvider.apiCredits(from: .init(unlimited: true), grant: grant)
        #expect(unlimited.first?.creditGrant == nil)
    }

    @Test("billing cycle rebuilds preserve account, grant and per-ticket expiries")
    func cycleRebuild() throws {
        var snapshot = OpenAIQuotaProvider(accountPreferences: { _ in nil }).makeSnapshot(
            response: .init(plan_type: "pro", rate_limit: .init(primary_window: .init(used_percent: 24)),
                credits: .init(balance: "59641")), accountPlan: nil, accountID: "fixture-account",
            resetCreditExpiries: [now, nil], cliSource: "fixture", now: now)
        snapshot.resetCreditsAvailable = 2
        let attached = QuotaManager.attachingCycleRow(to: snapshot, cycle: .init(anchorDate: now), now: now)
        let removed = QuotaManager.removingStaleCycleRow(from: attached)
        for result in [attached, removed] {
            #expect(result.openAIAccountKey == snapshot.openAIAccountKey)
            #expect(result.resetCreditExpiries == [now, nil])
            #expect(result.apiCredits == snapshot.apiCredits)
        }
    }
}
