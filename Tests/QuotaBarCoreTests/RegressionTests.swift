import Testing
import Foundation
@testable import QuotaBarCore

/// One test per defect that actually shipped.
///
/// Every case here is a bug a user hit, not a hypothetical. The comment on
/// each says what the user saw, because that is the thing a future change
/// must not bring back — the assertion alone rarely conveys it.
@Suite("Regressions — defects that reached a user", .serialized)
struct RegressionTests {

    // MARK: Gemini OAuth — sign-in that failed silently three times over

    /// PKCE on top of a client-secret exchange killed every sign-in at the
    /// token step. The browser said "You may close this window" (which is
    /// printed when the *callback* arrives, before the exchange runs), no
    /// session was saved, and Settings said only "sign-in did not complete".
    @Test("the consent request carries no PKCE")
    func authorizationRequestHasNoPKCE() throws {
        let url = try #require(GeminiOAuthLogin.authorizationURL(
            clientID: "client-1", redirectURI: "http://127.0.0.1:1234/callback", state: "abc"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let names = Set(items.map(\.name))

        #expect(!names.contains("code_challenge"))
        #expect(!names.contains("code_challenge_method"))
        // Exactly the reference implementation's parameter set.
        #expect(names == ["client_id", "redirect_uri", "response_type", "scope",
                          "access_type", "prompt", "state"])
        #expect(items.first { $0.name == "access_type" }?.value == "offline")
        #expect(items.first { $0.name == "prompt" }?.value == "consent")
        #expect(items.first { $0.name == "response_type" }?.value == "code")
    }

    @Test("the code exchange carries no verifier")
    func exchangeCarriesNoVerifier() {
        let fields = GeminiOAuthLogin.exchangeFields(
            code: "code-1", redirectURI: "http://127.0.0.1:1234/callback")
        #expect(fields["code"] == "code-1")
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["redirect_uri"] == "http://127.0.0.1:1234/callback")
        #expect(fields["code_verifier"] == nil)
    }

    /// A bare `/callback` path on an ephemeral loopback port. The earlier
    /// `/oauth/callback` was not what these clients are used with.
    @Test("the redirect path matches the reference flow")
    func redirectPathMatchesReference() {
        let uri = GeminiOAuthLogin.redirectURI(port: 62_692)
        #expect(uri == "http://127.0.0.1:62692/callback")
    }

    /// Switching OAuth clients left the old session in the Keychain. Its
    /// refresh token belonged to the previous client, so the row read
    /// "Credential rejected" permanently and signing in again did not clear it.
    @Test("a session is only usable by the client that issued it")
    func sessionBelongsToItsClient() {
        let session = GeminiOAuthSession(
            accessToken: "a", refreshToken: "r",
            expiry: Date(timeIntervalSince1970: 4_000_000_000), clientID: "client-1")

        #expect(GeminiOAuthSession.isUsable(session, forClientID: "client-1"))
        #expect(!GeminiOAuthSession.isUsable(session, forClientID: "client-2"))
        #expect(!GeminiOAuthSession.isUsable(session, forClientID: nil))

        let legacy = GeminiOAuthSession(
            accessToken: "a", refreshToken: "r",
            expiry: Date(timeIntervalSince1970: 4_000_000_000), clientID: nil)
        #expect(!GeminiOAuthSession.isUsable(legacy, forClientID: "client-1"))
    }

    // MARK: Gemini quota — the window that was missing entirely

    private static let quotaSummary = #"""
    {"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2099-01-08T00:00:00Z","remainingFraction":0.28312185},
        {"bucketId":"gemini-5h","window":"5h","resetTime":"2099-01-01T00:00:00Z","remainingFraction":0.845952}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.3126108}]}]}
    """#

    /// The row showed one bar at 85% remaining while the weekly limit — the
    /// binding constraint — sat at 28% remaining and was not drawn at all.
    /// Gemini looked like the healthiest provider on the list.
    @Test("both metered windows are rendered, and the fuller one drives urgency")
    func geminiRendersBothWindows() async throws {
        let snap = try await GeminiHarness.snapshot(summary: Self.quotaSummary, assist: "{}")
        #expect(snap.bars.count == 2)
        #expect(snap.row1?.label == "5H")
        #expect(snap.row2?.label == "WK")
        #expect(snap.status == .measured(.warning))
        #expect(snap.badgeText == "28% left")
    }

    /// `currentTier` is the Code Assist licence and reads "free-tier" for
    /// almost any personal account, so a Google AI Pro subscriber was told
    /// they were on the free tier.
    @Test("the paid subscription is shown, not the Code Assist licence tier")
    func geminiShowsPaidSubscription() async throws {
        let assist = #"""
        {"currentTier":{"id":"free-tier","name":"Antigravity"},
         "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}
        """#
        let snap = try await GeminiHarness.snapshot(summary: Self.quotaSummary, assist: assist)
        #expect(snap.planName == "Google AI Pro")
    }

    /// The plan is decoration. Losing it must not cost a reading we already
    /// hold — an earlier revision made the whole provider fail when the
    /// second call did not return what it expected.
    @Test("a failed plan lookup still yields the quota")
    func geminiPlanIsBestEffort() async throws {
        let snap = try await GeminiHarness.snapshot(
            summary: Self.quotaSummary, assist: "{}", assistStatus: 500)
        #expect(snap.status.confidence == .measured)
        #expect(snap.bars.count == 2)
        #expect(snap.planName == nil)
    }

    // MARK: Copilot — a permanent "Credential rejected"

    /// OpenCode caches two tokens under `github-copilot`. `access` is the
    /// short-lived Copilot API token, which api.github.com rejects; `refresh`
    /// is the durable GitHub OAuth token. Reading the wrong one made the row
    /// read "Credential rejected" indefinitely.
    @Test("the durable GitHub token is preferred over the cached Copilot token")
    func copilotUsesTheDurableToken() {
        let blob = Data(#"""
        {"github-copilot":{"type":"oauth","refresh":"gho_durable","access":"tid=short-lived","expires":1}}
        """#.utf8)
        #expect(CredentialStore.copilotOAuthToken(from: blob) == "gho_durable")
    }

    // MARK: Fabricated data

    /// The pace marker fell back to a constant chosen by label, so a weekly
    /// bar six days into its window drew its target at 45% of the track and
    /// reported the user as comfortably ahead of pace.
    @Test("a bar with no measured pace exposes no pace at all")
    func noPaceMeansNoMarker() {
        let unpaced = DualBarMetrics(primaryFraction: 0.97, label: "WK")
        #expect(unpaced.expectedPaceFraction == nil)
        #expect(unpaced.burndownDelta == nil)
        #expect(unpaced.isAboveProrataPace == false)
    }

    /// Claude publishes its window lengths in the header names it parses, so
    /// both bars carry a real marker rather than a constant.
    @Test("Claude derives a pace marker for each of its windows")
    func claudeWindowsArePaced() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fiveHour = DualBarMetrics.proRataPace(
            resetsAt: now.addingTimeInterval(3600), windowLength: QuotaWindow.fiveHours, now: now)
        let weekly = DualBarMetrics.proRataPace(
            resetsAt: now.addingTimeInterval(24 * 3600), windowLength: QuotaWindow.week, now: now)
        #expect(abs((fiveHour ?? 0) - 0.8) < 0.000_01)
        #expect(abs((weekly ?? 0) - 6.0 / 7.0) < 0.000_01)
    }

    /// Copilot's allowance runs to a monthly reset, and months are 28–31 days.
    /// A 30-day constant drifts the marker by up to a day at exactly the point
    /// it matters — the end of the window.
    @Test("a monthly pace marker uses the real calendar month")
    func monthlyPaceUsesTheCalendar() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 1
        let march = try #require(Calendar.current.date(from: components))
        let february = try #require(DualBarMetrics.monthWindowLength(endingAt: march))
        #expect(abs(february - 28 * 24 * 3600) < 3600)

        components.month = 1
        let january = try #require(Calendar.current.date(from: components))
        let december = try #require(DualBarMetrics.monthWindowLength(endingAt: january))
        #expect(abs(december - 31 * 24 * 3600) < 3600)
    }

    // MARK: Advice — health asserted for providers never read

    private func measured(_ vendor: VendorIdentifier, used: Double, label: String,
                          pace: Double? = nil, reset: String? = nil,
                          urgency: Urgency = .none) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: .measured(urgency), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, expectedPaceFraction: pace,
                                 label: label, resetText: reset))
    }

    private func unreadable(_ vendor: VendorIdentifier, _ reason: UnavailableReason) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: reason.headline, renewalDate: nil),
            status: .unavailable(reason), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: reason.remedy)
    }

    /// The reported bug, verbatim: two providers exhausted, two unreadable,
    /// and the summary read "All Quotas Healthy & Balanced — Claude, Gemini
    /// and OpenCode have ample headroom."
    @Test("an exhausted fleet with unreadable providers never summarises as healthy")
    func exhaustedFleetIsNotHealthy() {
        let advice = QuotaAdvice.evaluate(from: [
            measured(.claude, used: 0.97, label: "WK", pace: 0.93, reset: "11 hours"),
            measured(.openai, used: 0.99, label: "WK", pace: 0.18),
            unreadable(.gemini, .notConfigured),
            unreadable(.opencode, .unsupported("No usage API")),
        ])
        #expect(advice.headline != "All Quotas Healthy & Balanced")
        #expect(!advice.message.contains("Gemini has"))
        #expect(!advice.message.contains("OpenCode has"))
    }

    /// A GitHub limit we could not read is not a limit at zero, and must not
    /// hijack the advice with a fabricated percentage.
    @Test("an unreadable GitHub limit raises no advice of its own")
    func unreadableGitHubIsSilent() {
        let github = QuotaSnapshot(
            id: "github_rest", vendorId: .githubRest, displayName: "GitHub REST",
            category: .developerLimits,
            metric: .subscription(tierName: "Credential rejected", renewalDate: nil),
            status: .unavailable(.credentialRejected), resetsAt: nil,
            lastUpdated: Date(), auxiliaryInfo: nil)
        let advice = QuotaAdvice.evaluate(from: [measured(.claude, used: 0.20, label: "5H"), github])
        #expect(!advice.headline.contains("GitHub"))
        #expect(advice.headline == "All Quotas Healthy & Balanced")
    }

    /// Routing to paid credit while an already-paid window still holds
    /// something and is hours from resetting. The 0.95 cutoff excluded a
    /// weekly window at 97% — exactly the case the rule exists for.
    @Test("a sliver left in an expiring window outranks paid credit")
    func expiringSliverBeatsCredit() {
        let advice = QuotaAdvice.evaluate(from: [
            measured(.claude, used: 0.98, label: "WK", pace: 0.95, reset: "11 hours"),
            measured(.openai, used: 1.0, label: "WK", pace: 0.20),
        ])
        #expect(advice.headline == "Spend Remaining Claude")
        #expect(advice.message.contains("2% left"))
    }

    // MARK: Preference domain — every provider "Not configured" overnight

    /// An unbundled binary keys `UserDefaults.standard` off its process name.
    /// The release installs as `frugalbar` and the SwiftPM product builds as
    /// `QuotaBar`, so enabling discovery under one name left the other
    /// reporting every provider unconfigured, with nothing on screen to say why.
    @Test("preferences resolve to one shared suite, never the process name")
    func preferencesAreShared() {
        #expect(CredentialStore.sharedSuiteName == "com.quotabar.app")
        #expect(CredentialStore.preferencesSuiteName(isTestHost: false) == "com.quotabar.app")
        #expect(CredentialStore.legacyPreferenceDomains.contains("frugalbar"))
        #expect(CredentialStore.legacyPreferenceDomains.contains("QuotaBar"))

        // Asserted behaviourally, not by identity: a write through `preferences`
        // must land in the named suite and nowhere near `.standard`, which is
        // the domain that keyed off the process name.
        let probe = "QuotaBarSuiteProbe"
        let expected = UserDefaults(
            suiteName: CredentialStore.preferencesSuiteName(isTestHost: TestHost.isActive))
        CredentialStore.preferences.set("written", forKey: probe)
        defer {
            CredentialStore.preferences.removeObject(forKey: probe)
            UserDefaults.standard.removeObject(forKey: probe)
        }
        #expect(expected?.string(forKey: probe) == "written")
        #expect(UserDefaults.standard.string(forKey: probe) == nil)
    }

    @Test("migration prefers an enabled domain but never reverses an opt-out")
    func migrationRules() {
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: [true, false]) == true)
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: [false, false]) == false)
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: []) == nil)
    }

    /// Both safety nets — no real network, no writes to the user's real
    /// preference file — key off this. It was written against XCTest, which
    /// `swift test` does not set, so neither had ever engaged.
    @Test("the test host is detected under swift-testing")
    func testHostIsDetected() {
        #expect(TestHost.isActive)
    }

    // MARK: DevPass monthly bar & Claude credential caching regressions

    /// DevPass without row1 fell into the no-denominator fallback layout,
    /// which drew a micro-progress bar and a clipped chip ("1...").
    /// A measured DevPass plan must draw a single "MO" burndown bar.
    @Test("DevPass plan usage renders as a monthly burndown bar with label MO")
    func devPassPlanRendersMonthlyBar() throws {
        let json = """
        {"label":"key","usage":"0","limit":null,"devPlan":"lite",
         "devPlanCreditsUsed":"20.00","devPlanCreditsLimit":"80.00",
         "devPlanCreditsRemaining":"60.00"}
        """
        let data = try JSONDecoder().decode(DevPassQuotaProvider.KeyData.self, from: Data(json.utf8))
        let snap = DevPassQuotaProvider.snapshot(from: data, provider: DevPassQuotaProvider(), now: Date())

        #expect(snap.status.confidence == .measured)
        #expect(snap.planName == "DevPass Lite")
        #expect(snap.bars.count == 1)
        #expect(snap.row1?.label == "MO")
        #expect(abs(try #require(snap.row1?.primaryFraction) - 0.25) < 0.0001)
        #expect(snap.row1?.usedText?.contains("20.00") == true)
        #expect(snap.row1?.usedText?.contains("80.00") == true)
    }

    /// Calling SecItemCopyMatching for "Claude Code-credentials" on every 60-second
    /// poll triggered repetitive Keychain authorization prompts.
    /// CredentialCache memoises the blob in memory until near expiry.
    @Test("Claude OAuth credentials blob is memoised within TTL")
    func claudeBlobIsMemoised() {
        let cache = CredentialStore.CredentialCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var resolveCount = 0
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"test_tok","expiresAt":1000600000}}"#.utf8)

        let first = cache.claudeBlob(now: now) {
            resolveCount += 1
            return blob
        }
        #expect(first == blob)
        #expect(resolveCount == 1)

        // Multiple rapid reads within the TTL return the cached blob without re-resolving
        for step in 1...10 {
            let subsequent = cache.claudeBlob(now: now.addingTimeInterval(Double(step * 10))) {
                resolveCount += 1
                return Data()
            }
            #expect(subsequent == blob)
            #expect(resolveCount == 1)
        }
    }
}

/// Drives the Gemini provider against canned Cloud Code responses.
///
/// `.serialized` at the suite level is not enough on its own: `URLProtocol`
/// subclasses are instantiated by `URLSession`, so the canned bodies have to
/// live in statics and concurrent suites would overwrite each other's.
private enum GeminiHarness {
    static func snapshot(summary: String, assist: String, assistStatus: Int = 200) async throws -> QuotaSnapshot {
        Proto.summary = summary
        Proto.assist = assist
        Proto.assistStatus = assistStatus
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Proto.self]
        let provider = GeminiQuotaProvider(accessToken: "token")
        return try await QuotaHTTP.$session.withValue(URLSession(configuration: config)) {
            try await provider.fetchSnapshot()
        }
    }

    final class Proto: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var summary = ""
        nonisolated(unsafe) static var assist = ""
        nonisolated(unsafe) static var assistStatus = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let isAssist = request.url?.absoluteString.contains("loadCodeAssist") == true
            let response = HTTPURLResponse(
                url: request.url!, statusCode: isAssist ? Self.assistStatus : 200,
                httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((isAssist ? Self.assist : Self.summary).utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
