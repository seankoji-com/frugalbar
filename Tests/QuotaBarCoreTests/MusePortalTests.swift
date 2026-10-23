import Foundation
import Testing
import JavaScriptCore
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
                        body.replacingOccurrences(of: "\"email\":", with: "\"failure\":\"http\",\"email\":"),
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
                context.evaluateScript("fetch = async (p,o) => (paths.push(p), {ok:false,headers:{get:()=> '30'}});")
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
                guard case .unavailable = payload.read(email: "person@example.com", plan: "Muse Code Power Usage", teamID: "42", now: now) else {
                    Issue.record("Portal query admitted a failed or unselected scope"); continue
                }
            }
        }
    }
}
