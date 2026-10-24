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
        #expect(resumed.teams.isEmpty)
        // These are the exact options consumed by the Settings Picker, not
        // evidence of membership until the next read checks the portal.
        #expect(resumed.teamPickerOptions.map(\.id) == ["42"])
        #expect(resumed.teamPickerOptions.first?.name == "Saved selection (refresh teams for name)")
        #expect(resumedWebsite.opens == 0 && resumedWebsite.requests.isEmpty)
        guard case .usage = await resumed.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
            Issue.record("Explicit connection did not resume after restart"); return
        }
        #expect(resumedWebsite.opens == 1)
        #expect(resumedWebsite.requests == ["person@example.com|Muse Code Power Usage|42"])
        #expect(resumed.teamPickerOptions.map(\.id) == ["42"])
        #expect(resumed.teamPickerOptions.first?.name == "My team")
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

    @Test(arguments: ["not JSON", #"{"failure":"http","httpStatus":503}"#,
                     #"{"failure":"offline"}"#, #"{"failure":"timedOut"}"#,
                     #"{"email":"person@example.com"}"#])
    @MainActor func failedOrMissingTeamListKeepsPreviousMembership(failedBody: String) async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        await session.refreshTeams()
        #expect(session.teams.map(\.id) == ["42"])

        website.body = failedBody
        let result = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now)
        if case .usage = result { Issue.record("Saved membership substituted for a failed fresh read") }
        #expect(website.requests == ["||", "person@example.com|Muse Code Power Usage|42"])
        #expect(session.teams.map(\.id) == ["42"])
        #expect(session.selectedTeamID == "42")
        #expect(preferences.string(forKey: MusePortalSession.teamKey) == "42")

        // A list actually returned by the server replaces the old one, even
        // on a failed quota read, and an explicit empty list really is empty.
        website.body = #"{"failure":"tier","teams":[{"id":"43","name":"Other team"}]}"#
        await session.refreshTeams()
        #expect(session.teams.map(\.id) == ["43"])
        website.body = #"{"teams":[]}"#
        await session.refreshTeams()
        #expect(session.teams.isEmpty && session.selectedTeamID == "42")
        #expect(!session.isReadingTeams)
    }

    @Test(arguments: ["success", "malformed", "http", "cancelled"])
    @MainActor func teamRefreshOwnsItsFlagThroughCompletion(outcome: String) async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        website.holdRead = true
        let session = MusePortalSession(preferences: preferences, website: website)
        // A disabled session never starts a refresh.
        await session.refreshTeams()
        #expect(!session.isReadingTeams && website.requests.isEmpty)
        session.connect()
        let refresh = Task { await session.refreshTeams() }
        await withCheckedContinuation { website.readStarted = $0 }
        #expect(session.isReadingTeams)
        // A second sheet/click cannot start a duplicate or release this flag.
        await session.refreshTeams()
        #expect(session.isReadingTeams && website.requests == ["||"])
        if outcome == "cancelled" {
            refresh.cancel()
        } else {
            website.complete?(outcome == "success" ? body : outcome == "malformed"
                ? "not JSON" : #"{"failure":"http","httpStatus":503}"#)
        }
        await refresh.value
        #expect(!session.isReadingTeams)
        #expect(session.teams.map(\.id) == (outcome == "success" ? ["42"] : []))
        // Cleanup also permits a subsequent successful refresh.
        website.holdRead = false
        await session.refreshTeams()
        #expect(!session.isReadingTeams && website.requests.count == 2)
        #expect(session.teams.map(\.id) == ["42"])
    }

    @Test @MainActor func disconnectImmediatelyReleasesTeamRefreshAndRejectsItsLateResult() async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        website.holdRead = true
        website.holdClear = true
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        var readingAtStop: Bool?
        website.onStop = { [weak session] in readingAtStop = session?.isReadingTeams }
        let refresh = Task { await session.refreshTeams() }
        await withCheckedContinuation { website.readStarted = $0 }
        #expect(session.isReadingTeams)
        let lateCompletion = website.complete
        let disconnect = Task { await session.disconnect() }
        await withCheckedContinuation { website.clearStarted = $0 }
        #expect(readingAtStop == false)
        #expect(!session.isReadingTeams && session.isDisconnecting && !session.isEnabled)
        await session.refreshTeams()
        #expect(!session.isReadingTeams && website.requests.count == 1)
        lateCompletion?(body)
        await refresh.value
        #expect(session.teams.isEmpty && session.selectedTeamID.isEmpty)
        website.finishClear?.resume()
        await disconnect.value
        session.connect()
        guard !session.isReadingTeams else {
            Issue.record("Disconnected refresh prevented a new session's read"); return
        }
        let next = Task { await session.refreshTeams() }
        await withCheckedContinuation { website.readStarted = $0 }
        lateCompletion?(body)
        #expect(session.isReadingTeams && session.teams.isEmpty)
        website.complete?(body)
        await next.value
        #expect(!session.isReadingTeams && session.teams.map(\.id) == ["42"])
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

    @Test(arguments: ["timeout", "cancelled", "success"])
    @MainActor func navigationWaiterIsReleasedWhenReadFinishes(outcome: String) async throws {
        let suite = "MusePortalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let website = PortalWebsiteStub(body: body)
        website.isAtPortal = false
        website.holdNavigation = true
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        let first = Task { await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) }
        await withCheckedContinuation { website.navigationStarted = $0 }
        let lateCompletion = try #require(website.navigationComplete)
        if outcome == "cancelled" { first.cancel() }
        if outcome == "success" { website.finishNavigation() }
        let result = await first.value
        if outcome == "success" {
            guard case .usage = result else { Issue.record("Committed navigation lost its quota"); return }
        } else {
            guard case .failure(.timedOut) = result else { Issue.record("Navigation did not end as a timeout/cancellation"); return }
        }
        #expect(website.navigationComplete == nil)
        #expect(website.stops == 0 && website.clears == 0 && session.isEnabled)

        // A callback retained by a navigation already in flight cannot finish
        // a later read or remove the later read's registered waiter.
        website.isAtPortal = false
        let next = Task { await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) }
        await withCheckedContinuation { website.navigationStarted = $0 }
        let requestsBeforeCommit = website.requests.count
        lateCompletion(true)
        #expect(website.navigationComplete != nil)
        #expect(website.requests.count == requestsBeforeCommit)
        website.finishNavigation()
        guard case .usage = await next.value else { Issue.record("Stale callback interfered with the next read"); return }
        #expect(website.navigationComplete == nil && website.requests.count == requestsBeforeCommit + 1)
        #expect(!website.requestBeforeCommit && website.stops == 0 && website.clears == 0)
    }

    @Test @MainActor func webKitWaiterCleanupReleasesOnlyMatchingCallback() {
        // No open(): exercise the real callback storage without creating a
        // web view, touching website data or sending a network request.
        let website = MusePortalWebKit()
        let oldID = UUID(), newID = UUID()
        weak var retainedEvaluation: ClaudeMonthlyCreditEvaluation?
        do {
            let evaluation = ClaudeMonthlyCreditEvaluation()
            retainedEvaluation = evaluation
            website.waitUntilPortal(id: oldID) { _ in evaluation.finish(nil) }
        }
        #expect(retainedEvaluation != nil)
        website.cancelPortalWait(id: oldID)
        #expect(retainedEvaluation == nil)

        var completed: [UUID] = []
        website.waitUntilPortal(id: oldID) { _ in completed.append(oldID) }
        website.waitUntilPortal(id: newID) { _ in completed.append(newID) }
        website.cancelPortalWait(id: oldID)
        website.stop()
        #expect(completed == [newID])
        #expect(website.webView == nil)
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
        for (status, reason) in [(503, UnavailableReason.badResponse),
                                 (429, .rateLimited(retryAfter: nil))] {
            let text = "{\"failure\":\"http\",\"httpStatus\":\(status)}"
            guard case .failure(let actual) = try read(text) else {
                Issue.record("HTTP failure was reported as an account mismatch"); continue
            }
            #expect(actual == reason)
        }
    }

    @Test(arguments: [401, 403]) func rejectedPortalSessionRequestsPortalSignIn(status: Int) throws {
        guard case .unavailable(let message) = try read("{\"failure\":\"http\",\"httpStatus\":\(status)}") else {
            Issue.record("Rejected portal session was reported as a CLI credential failure"); return
        }
        #expect(message.contains("Sign in") && message.contains("Muse portal"))
        #expect(!message.contains("key") && !message.contains("CLI"))
        // A supplied retry instruction still wins over the sign-in remedy.
        guard case .failure(.rateLimited(let retry)) = try read("{\"failure\":\"http\",\"httpStatus\":\(status),\"retryAfter\":\"30\"}") else {
            Issue.record("Portal authentication response lost Retry-After"); return
        }
        #expect(retry == now.addingTimeInterval(30))
    }

    @Test @MainActor func abortedPortalRequestIsTimedOut() throws {
        // Exercise the actual WebKit script, with each GET aborting in turn.
        for endpoint in ["/api/auth/me", "/api/portal/teams", "/api/portal/teams/42/subscription-quota"] {
            let context = try #require(JSContext())
            context.evaluateScript(#"""
            var output = null;
            var location = {origin:'https://dev.meta.ai'};
            var AbortController = class { constructor(){this.signal={aborted:false}} abort(){this.signal.aborted=true} };
            var setTimeout = f => (f(), 1), clearTimeout = () => {};
            var email = 'person@example.com', plan = 'Muse Code Power Usage', teamID = '42';
            async function fetch(path, options) {
              if (path === abortAt && options.signal.aborted) {
                const error = new Error('aborted'); error.name = 'AbortError'; throw error;
              }
              return {ok:true,json:async()=>path === '/api/auth/me' ? {email} :
                {teams:[{team_id:teamID,team_name:'My team'}]}};
            }
            """#)
            context.setObject(endpoint, forKeyedSubscript: "abortAt" as NSString)
            context.evaluateScript("async function run() {\n" + MusePortalSession.query + "\n}\nrun().then(p=>output=p);")
            #expect(context.exception == nil)
            let text = try #require(context.objectForKeyedSubscript("output")?.toString())
            guard case .failure(.timedOut) = try read(text) else {
                Issue.record("Aborted \(endpoint) was reported as an account/plan mismatch"); continue
            }
        }
    }

    @Test @MainActor func failedPortalFetchIsOffline() async throws {
        for endpoint in ["/api/auth/me", "/api/portal/teams", "/api/portal/teams/42/subscription-quota"] {
            let context = try #require(JSContext())
            context.evaluateScript(#"""
            var output = null;
            var location = {origin:'https://dev.meta.ai'};
            var AbortController = class { constructor(){this.signal={}} };
            var setTimeout = () => 1, clearTimeout = () => {};
            var email = 'person@example.com', plan = 'Muse Code Power Usage', teamID = '42';
            async function fetch(path) {
              if (path === failAt) throw new TypeError('fixture fetch failed');
              return {ok:true,json:async()=>path === '/api/auth/me' ? {email} :
                {teams:[{team_id:teamID,team_name:'My team'}]}};
            }
            """#)
            context.setObject(endpoint, forKeyedSubscript: "failAt" as NSString)
            context.evaluateScript("async function run() {\n" + MusePortalSession.query + "\n}\nrun().then(p=>output=p);")
            #expect(context.exception == nil)
            let text = try #require(context.objectForKeyedSubscript("output")?.toString())
            // Include the session layer so Settings copy cannot blame the
            // account while the quota row correctly reports a transport error.
            let suite = "MusePortalTests.\(UUID().uuidString)"
            let preferences = try #require(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            let session = MusePortalSession(preferences: preferences, website: PortalWebsiteStub(body: text))
            session.connect()
            session.selectedTeamID = "42"
            guard case .failure(.offline) = await session.read(email: "person@example.com", plan: "Muse Code Power Usage", now: now) else {
                Issue.record("Failed \(endpoint) fetch was reported as an account/plan mismatch"); continue
            }
            #expect(session.message == "Could not reach the Muse portal. Check your connection and refresh.")
        }
        guard case .failure(.badResponse) = try read(#"{"failure":"read"}"#) else {
            Issue.record("Malformed portal response was reported as an account mismatch"); return
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
    var holdNavigation = false
    var navigationID: UUID?
    var navigationComplete: (@MainActor @Sendable (Bool) -> Void)?
    var navigationStarted: CheckedContinuation<Void, Never>?
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
    var onStop: (() -> Void)?

    init(body: String) { self.body = body }
    func open() { opens += 1 }
    func host() { hosts += 1 }
    func waitUntilPortal(id: UUID, complete: @escaping @MainActor @Sendable (Bool) -> Void) {
        waits += 1
        if isAtPortal { complete(true); return }
        if holdNavigation {
            navigationID = id
            navigationComplete = complete
            navigationStarted?.resume()
            navigationStarted = nil
            return
        }
        // open() deliberately leaves the URL unset, as on a fresh WKWebView.
        Task { @MainActor in
            await Task.yield()
            isAtPortal = navigationSucceeds
            complete(isAtPortal)
        }
    }
    func cancelPortalWait(id: UUID) {
        if navigationID == id {
            navigationID = nil
            navigationComplete = nil
        }
    }
    func finishNavigation() {
        isAtPortal = navigationSucceeds
        let complete = navigationComplete
        navigationID = nil
        navigationComplete = nil
        complete?(isAtPortal)
    }
    func stop() { stops += 1; onStop?() }
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
        readStarted = nil
        if !holdRead { complete(body) }
    }
}
