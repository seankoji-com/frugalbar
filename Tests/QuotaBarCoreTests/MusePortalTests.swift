import Foundation
import Testing
import JavaScriptCore
import WebKit
@testable import QuotaBarCore

@Suite("Muse portal quota")
struct MusePortalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Allowlisted schema from the portal's subscription-quota GET. These are
    // fixtures, not this user's quota; no key-mint api_key is ever recorded.
    private let body = #"""
    {"email":"person@example.com","teams":[{"id":"42","name":"My team"}],
    "subscription_quota":{"tier":"Muse Code Power Usage",
      "window_weighted_used":"200","window_weighted_limit":"1000",
      "window_resets_at":1800009000,"window_duration_secs":18000,
      "weekly_weighted_used":"3500","weekly_weighted_limit":"10000",
      "weekly_resets_at":1800259200}}
    """#

    private func read(_ body: String, email: String = "person@example.com",
                      plan: String = "Muse Code Power Usage", team: String = "42") throws -> MusePortalRead {
        try JSONDecoder().decode(MusePortalPayload.self, from: Data(body.utf8))
            .read(email: email, plan: plan, teamID: team, now: now)
    }

    @Test func publishedPairsProduceIndependentWindows() throws {
        guard case .usage(let usage) = try read(body) else {
            Issue.record("Published quota pairs were discarded"); return
        }
        let response = MuseQuotaProvider.KeyResponse(is_subs_active: true, require_payment: false,
            subs_tier_name: "Muse Code Power Usage", subs_usage: usage, user_email: nil)
        let snapshot = MuseQuotaProvider.snapshot(from: response, provider: MuseQuotaProvider(), now: now)
        #expect(snapshot.status == .measured(.none))
        #expect(snapshot.row1?.primaryFraction == 0.2)
        #expect(snapshot.row2?.primaryFraction == 0.35)
        #expect(snapshot.row1?.windowLength == 18000)
        #expect(snapshot.row1?.resetsAt == now.addingTimeInterval(9000))
        #expect(snapshot.row2?.resetsAt == now.addingTimeInterval(259200))
    }

    @Test func explicitTeamAndMatchingAccountAndPlanAreRequired() throws {
        for (email, plan, team) in [
            ("other@example.com", "Muse Code Power Usage", "42"),
            ("", "Muse Code Power Usage", "42"),
            ("person@example.com", "Other plan", "42"),
            ("person@example.com", "", "42"),
            ("person@example.com", "Muse Code Power Usage", ""),
            ("person@example.com", "Muse Code Power Usage", "43"),
            ("person@example.com", "Muse Code Power Usage", "../42"),
        ] {
            guard case .unavailable = try read(body, email: email, plan: plan, team: team) else {
                Issue.record("Mismatching or unselected scope accepted"); continue
            }
        }
        guard case .usage = try read(body, email: " PERSON@EXAMPLE.COM ") else {
            Issue.record("Email whitespace/case rejected"); return
        }
    }

    @Test func idleAndExpiredWindowsAreAbsentRatherThanZero() throws {
        for changed in [body.replacingOccurrences(of: "1800009000", with: "null"),
                        body.replacingOccurrences(of: "1800009000", with: "1799999999"),
                        body.replacingOccurrences(of: "\"200\"", with: "null"),
                        body.replacingOccurrences(of: "\"1000\"", with: "\"0\"")] {
            guard case .usage(let usage) = try read(changed) else {
                Issue.record("Valid weekly window was discarded"); continue
            }
            #expect(usage.window == nil)
            #expect(usage.weekly?.used_percent?.value == 35)
        }
        guard case .unavailable = try read(body
            .replacingOccurrences(of: "1800009000", with: "null")
            .replacingOccurrences(of: "1800259200", with: "1799999999")) else {
            Issue.record("No current windows rendered as health"); return
        }
    }

    @Test func quotedPortalResetTimesKeepTheirPublishedInstant() throws {
        guard case .usage(let usage) = try read(body.replacingOccurrences(of: "1800259200", with: "\"1800259200\"")) else {
            Issue.record("Quoted portal timestamp discarded"); return
        }
        #expect(usage.weekly?.resets_at?.date == now.addingTimeInterval(259200))
    }

    @Test func malformedAndFailedReadingsCannotProduceHealth() throws {
        for changed in [body.replacingOccurrences(of: "\"200\"", with: "\"NaN\"")
                            .replacingOccurrences(of: "\"3500\"", with: "-1"),
                        body.replacingOccurrences(of: "\"email\":", with: "\"failure\":\"read\",\"email\":"),
                        body.replacingOccurrences(of: "\"teams\":[{\"id\":\"42\",\"name\":\"My team\"}]", with: "\"teams\":[]")] {
            guard case .unavailable = try read(changed) else {
                Issue.record("Failed portal reading rendered as health"); continue
            }
        }
    }

    @Test @MainActor func testHostCannotOpenARealPortalSession() {
        let session = MusePortalSession.shared
        session.connect()
        #expect(!session.isEnabled)
        #expect(session.webView == nil)
    }

    @Test @MainActor func explicitConnectionAndTeamSurviveRestart() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        let original = MusePortalSession(preferences: preferences, website: website)
        #expect(!original.isEnabled)
        _ = await original.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now)
        #expect(website.opens == 0 && website.requests.isEmpty)
        original.connect()
        original.selectedTeamID = "42"

        let resumedWebsite = PortalWebsiteStub(body: body)
        let resumed = MusePortalSession(preferences: preferences, website: resumedWebsite)
        #expect(resumed.isEnabled)
        #expect(resumed.selectedTeamID == "42")
        guard case .usage = await resumed.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
            Issue.record("Explicit connection did not resume after restart"); return
        }
        #expect(resumedWebsite.opens == 1)
        #expect(resumedWebsite.requests == ["person@example.com|Muse Code Power Usage|42"])
        // A saved team never substitutes for a fresh identity/membership/tier check.
        for changed in [body.replacingOccurrences(of: "person@example.com", with: "other@example.com"),
                        body.replacingOccurrences(of: "\"id\":\"42\"", with: "\"id\":\"43\""),
                        body.replacingOccurrences(of: "Muse Code Power Usage", with: "Other plan")] {
            resumedWebsite.body = changed
            guard case .unavailable = await resumed.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
                Issue.record("Restored session accepted a changed account, membership or tier"); continue
            }
        }
        #expect(resumedWebsite.requests.count == 4)
    }

    @Test @MainActor func disabledOrMalformedSavedScopeCannotSelectATeam() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("42", forKey: MusePortalSession.teamKey)
        let website = PortalWebsiteStub(body: body)
        let disabled = MusePortalSession(preferences: preferences, website: website)
        #expect(!disabled.isEnabled && disabled.selectedTeamID.isEmpty)
        disabled.selectedTeamID = "42"
        #expect(disabled.selectedTeamID.isEmpty)
        preferences.set(true, forKey: MusePortalSession.enabledKey)
        preferences.set("../42", forKey: MusePortalSession.teamKey)
        let malformed = MusePortalSession(preferences: preferences, website: website)
        #expect(malformed.isEnabled && malformed.selectedTeamID.isEmpty)
        await malformed.refreshTeams()
        #expect(malformed.teams.map(\.id) == ["42"])
        #expect(malformed.selectedTeamID.isEmpty)
        _ = await malformed.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now)
        #expect(website.requests == ["||"])
    }

    @Test @MainActor func restartedReadWaitsForPortalCommit() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: MusePortalSession.enabledKey)
        preferences.set("42", forKey: MusePortalSession.teamKey)
        let website = PortalWebsiteStub(body: body)
        website.isAtPortal = false
        let session = MusePortalSession(preferences: preferences, website: website)
        guard case .usage = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
            Issue.record("Restarted read failed before the simulated portal commit"); return
        }
        #expect(website.waits == 1 && website.isAtPortal)
        #expect(website.requests.count == 1 && !website.requestBeforeCommit)
        // Closing the connection sheet returns the same view to its lifetime host.
        session.hostWebView()
        #expect(website.hosts == 1)
        await session.disconnect()
        session.hostWebView()
        #expect(website.hosts == 1)
    }

    @Test @MainActor func failedNavigationIsTransientAndCanRetry() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        website.isAtPortal = false
        website.navigationSucceeds = false
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        guard case .failure(.timedOut) = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
            Issue.record("Uncommitted navigation was reported as a lost login"); return
        }
        #expect(website.requests.isEmpty)
        website.navigationSucceeds = true
        guard case .usage = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
            Issue.record("Failed navigation prevented the next read"); return
        }
        #expect(website.waits == 2 && website.requests.count == 1)
    }

    @Test @MainActor func overlappingReadDoesNotClaimSignInWasLost() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        website.holdRead = true
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        let first = Task { await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) }
        await withCheckedContinuation { website.readStarted = $0 }
        guard case .failure(.unsupported(let message)) = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
            Issue.record("Overlapping read lost its transient outcome"); website.complete?(body); _ = await first.value; return
        }
        #expect(message.contains("in progress") && !message.contains("Sign in"))
        website.complete?(body)
        guard case .usage = await first.value else { Issue.record("Overlap invalidated the first read"); return }
        #expect(website.requests.count == 1)
    }

    @Test @MainActor func disconnectDisablesClearsAndRejectsLateResultsBeforeReconnect() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("keep", forKey: "unrelated.preference")
        let website = PortalWebsiteStub(body: body)
        website.holdRead = true
        website.holdClear = true
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        let read = Task { await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) }
        await withCheckedContinuation { website.readStarted = $0 }
        let disconnect = Task { await session.disconnect() }
        await withCheckedContinuation { website.clearStarted = $0 }
        #expect(!session.isEnabled && session.isDisconnecting && session.selectedTeamID.isEmpty)
        #expect(session.teams.isEmpty)
        #expect(website.stops == 1 && website.clears == 1)
        #expect(preferences.object(forKey: MusePortalSession.enabledKey) == nil)
        #expect(preferences.object(forKey: MusePortalSession.teamKey) == nil)
        #expect(preferences.string(forKey: "unrelated.preference") == "keep")
        let restarted = MusePortalSession(preferences: preferences, website: PortalWebsiteStub(body: body))
        #expect(!restarted.isEnabled && restarted.selectedTeamID.isEmpty)
        session.connect()
        #expect(!session.isEnabled && website.opens == 2)
        session.selectedTeamID = "42"
        #expect(session.selectedTeamID.isEmpty)
        _ = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now)
        #expect(website.requests.count == 1)
        website.complete?(body)
        guard case .failure = await read.value else {
            Issue.record("Disconnected portal read published a late quota"); return
        }
        #expect(session.teams.isEmpty)
        website.finishClear?.resume()
        await disconnect.value
        #expect(!session.isDisconnecting)
        session.connect()
        #expect(session.isEnabled && session.selectedTeamID.isEmpty)
        #expect(website.clears == 1)
    }

    @Test @MainActor func teamChangeInvalidatesAnInflightQuota() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        website.holdRead = true
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        let read = Task { await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) }
        await withCheckedContinuation { website.readStarted = $0 }
        session.selectedTeamID = "43"
        website.complete?(body)
        guard case .failure = await read.value else {
            Issue.record("Previous team's in-flight quota was accepted"); return
        }
        #expect(session.teams.isEmpty)
        #expect(MusePortalSession(preferences: preferences, website: website).selectedTeamID == "43")
    }

    @Test @MainActor func disconnectClearsWebsiteAndSavedSelection() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        await session.disconnect()
        #expect(!session.isEnabled && !session.isDisconnecting)
        #expect(session.selectedTeamID.isEmpty)
        #expect(website.stops == 1 && website.clears == 1)
        session.connect()
        #expect(session.selectedTeamID.isEmpty)
        let restarted = MusePortalSession(preferences: preferences, website: website)
        #expect(restarted.selectedTeamID.isEmpty)
    }

    @Test @MainActor func restoredConnectionStillHonoursRetryAfter() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: MusePortalSession.enabledKey)
        preferences.set("42", forKey: MusePortalSession.teamKey)
        let website = PortalWebsiteStub(body: #"{"failure":"http","retryAfter":"30"}"#)
        let session = MusePortalSession(preferences: preferences, website: website)
        if case .failure(.rateLimited(let retry)) = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) {
            #expect(retry == now.addingTimeInterval(30))
        } else {
            Issue.record("Portal HTTP failure was reported as a login failure")
        }
        website.body = body
        if case .failure(.rateLimited(let heldRetry)) = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now.addingTimeInterval(29)) {
            #expect(heldRetry == now.addingTimeInterval(30))
        } else {
            Issue.record("Retry hold was reported as a login failure")
        }
        #expect(website.requests.count == 1)
        guard case .usage = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now.addingTimeInterval(30)) else {
            Issue.record("Published Retry-After never expired"); return
        }
        #expect(website.requests.count == 2)
    }

    @Test func httpStatusIsPreservedWithoutInventingAThrottle() throws {
        for (status, reason) in [(401, UnavailableReason.credentialRejected), (503, .badResponse),
                                 (429, .rateLimited(retryAfter: nil))] {
            let text = "{\"failure\":\"http\",\"httpStatus\":\(status)}"
            guard case .failure(let actual) = try read(text) else {
                Issue.record("HTTP failure was reported as an account mismatch"); continue
            }
            #expect(actual == reason)
        }
    }

    @Test @MainActor func portalQueryUsesOnlyReadOnlyAllowlistedRequests() throws {
        for scenario in ["matching", "wrong-account", "no-selection", "failed"] {
            let context = try #require(JSContext())
            context.evaluateScript(#"""
            var paths = [], output = null, error = null;
            var location = {origin:'https://dev.meta.ai'};
            var AbortController = class { constructor(){this.signal={}} abort(){} };
            var setTimeout = () => 1, clearTimeout = () => {};
            var email = 'person@example.com', plan = 'Muse Code Power Usage', teamID = '42';
            async function fetch(path, options) {
              paths.push(path);
              if (options.method !== 'GET' || options.credentials !== 'same-origin' || options.redirect !== 'error')
                throw new Error('unsafe query');
              const payload = path === '/api/auth/me' ? {email: email, secret:'excluded'} :
                path === '/api/portal/teams' ? {teams:[{team_id:'42',team_name:'My team'}]} :
                {subscription_quota:{tier:plan,weekly_weighted_used:'35',weekly_weighted_limit:'100',
                  weekly_resets_at:1800259200,api_key:'excluded'}};
              return {ok:true,headers:{get:()=>null},json:async()=>payload};
            }
            """#)
            if scenario == "wrong-account" {
                context.evaluateScript("const originalFetch = fetch; fetch = async (p,o) => p === '/api/auth/me' ? (paths.push(p), {ok:true,json:async()=>({email:'other@example.com'})}) : originalFetch(p,o);")
            } else if scenario == "no-selection" {
                context.evaluateScript("teamID = '';")
            } else if scenario == "failed" {
                context.evaluateScript("fetch = async (p,o) => (paths.push(p), {ok:false,status:429,headers:{get:()=> '30'}});")
            }
            context.evaluateScript("async function run() {\n" + MusePortalSession.query + "\n}\nrun().then(p=>output=p).catch(e=>error=String(e));")
            #expect(context.exception == nil)
            #expect(context.objectForKeyedSubscript("error")?.isNull == true)
            let text = try #require(context.objectForKeyedSubscript("output")?.toString())
            let payload = try JSONDecoder().decode(MusePortalPayload.self, from: Data(text.utf8))
            #expect(!text.contains("api_key") && !text.contains("secret"))
            let paths = context.objectForKeyedSubscript("paths")?.toArray() as? [String]
            if scenario == "matching" {
                #expect(paths == ["/api/auth/me", "/api/portal/teams", "/api/portal/teams/42/subscription-quota"])
                guard case .usage(let usage) = payload.read(email: "person@example.com", plan: "Muse Code Power Usage", teamID: "42", now: now) else {
                    Issue.record("Actual WebKit query projection discarded published windows"); continue
                }
                #expect(usage.weekly?.used_percent?.value == 35)
            } else {
                #expect(paths?.contains(where: { $0.contains("subscription-quota") }) == false)
                let outcome = payload.read(email: "person@example.com", plan: "Muse Code Power Usage", teamID: "42", now: now)
                if scenario == "failed" {
                    #expect(payload.httpStatus == 429)
                    guard case .failure(.rateLimited(let retry)) = outcome else {
                        Issue.record("HTTP failure lost Retry-After"); continue
                    }
                    #expect(retry == now.addingTimeInterval(30))
                    continue
                }
                guard case .unavailable = outcome else {
                    Issue.record("Portal query admitted a failed or unselected scope"); continue
                }
            }
        }
    }
}

@MainActor
private final class PortalWebsiteStub: MusePortalWebsite {
    var webView: WKWebView? { nil }
    var isAtPortal = true
    var navigationSucceeds = true
    var waits = 0, hosts = 0
    var requestBeforeCommit = false
    var body: String
    var opens = 0, stops = 0, clears = 0
    var requests: [String] = []
    var holdRead = false, holdClear = false
    var complete: (@MainActor @Sendable (String?) -> Void)?
    var readStarted: CheckedContinuation<Void, Never>?
    var clearStarted: CheckedContinuation<Void, Never>?
    var finishClear: CheckedContinuation<Void, Never>?

    init(body: String) { self.body = body }
    func open() { opens += 1 }
    func host() { hosts += 1 }
    func waitUntilPortal(complete: @escaping @MainActor @Sendable (Bool) -> Void) {
        waits += 1
        if isAtPortal { complete(true); return }
        // open() deliberately leaves the URL unset, as on a fresh WKWebView.
        Task { @MainActor in
            await Task.yield()
            isAtPortal = navigationSucceeds
            complete(isAtPortal)
        }
    }
    func stop() { stops += 1 }
    func clear() async {
        clears += 1
        clearStarted?.resume()
        if holdClear { await withCheckedContinuation { finishClear = $0 } }
    }
    func evaluate(email: String, plan: String, teamID: String,
                  complete: @escaping @MainActor @Sendable (String?) -> Void) {
        requests.append("\(email)|\(plan)|\(teamID)")
        requestBeforeCommit = requestBeforeCommit || !isAtPortal
        self.complete = complete
        readStarted?.resume()
        if !holdRead { complete(body) }
    }
}
