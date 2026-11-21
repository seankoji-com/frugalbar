import Foundation
import Testing
@testable import QuotaBarCore

/// With multi-account discovery every Claude row is a named account, and named
/// rows never read or attached the linked Console organisation's monthly
/// credit, so the line vanished for everyone with discovered accounts. The
/// credit now binds to the one row whose OAuth identity (account and
/// organisation UUIDs) matches the account signed in to the billing page.
@Suite("Claude monthly credit binding")
struct ClaudeMonthlyCreditBindingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let accountUUID = "11111111-1111-4111-8111-111111111111"
    private let personalOrg = "22222222-2222-4222-8222-222222222222"
    private let otherAccountUUID = "33333333-3333-4333-8333-333333333333"
    private let otherOrg = "44444444-4444-4444-8444-444444444444"

    private func identity(_ account: String, _ org: String) -> String {
        ClaudeAccount.instanceID(identity: "account|\(account)|\(org)")
    }

    private func account(_ id: String) -> ClaudeAccount {
        ClaudeAccount(id: id, badge: "1", sourceLabel: "Fixture", fallbackName: id)
    }

    private func credit(signedInAs account: String, orgs: [String]) -> ClaudeMonthlyCredit {
        var credit = ClaudeMonthlyCredit(amountUSD: 200, nextGrantAt: nil, measuredAt: now)
        credit.webIdentities = ClaudeMonthlyCreditBinding.webIdentities(accountUUID: account, organizationUUIDs: orgs)
        return credit
    }

    private func rows() -> [ClaudeMonthlyCreditBinding.Row] {
        [.init(accountID: "primary", identity: identity(accountUUID, personalOrg)),
         .init(accountID: "secondary", identity: identity(otherAccountUUID, otherOrg))]
    }

    private func snapshot(for id: String, credit: ClaudeMonthlyCredit?) async throws -> QuotaSnapshot {
        let provider = ClaudeAccountQuotaProvider(account: account(id), routes: [], failure: .notConfigured,
            backoff: ClaudeProxyBackoff(), grants: ClaudeGrantSchedule(),
            creditRows: rows(), monthlyCredit: { _ in credit })
        return try await provider.fetchSnapshot(now: now)
    }

    @Test("A named row whose identity matches the signed-in web account draws the credit")
    func matchingRowGetsCredit() async throws {
        let linked = credit(signedInAs: accountUUID, orgs: [personalOrg, otherOrg])
        let primary = try await snapshot(for: "primary", credit: linked)
        let secondary = try await snapshot(for: "secondary", credit: linked)
        #expect(primary.monthlyAPICredit?.amountUSD == 200)
        #expect(secondary.monthlyAPICredit == nil)
    }

    @Test("No match, no identity, or two matching rows attaches the credit nowhere")
    func unboundCreditGoesNowhere() async throws {
        let stranger = credit(signedInAs: "55555555-5555-4555-8555-555555555555", orgs: [personalOrg])
        #expect(try await snapshot(for: "primary", credit: stranger).monthlyAPICredit == nil)
        #expect(try await snapshot(for: "secondary", credit: stranger).monthlyAPICredit == nil)

        let unknown = ClaudeMonthlyCredit(amountUSD: 200, nextGrantAt: nil, measuredAt: now)
        #expect(try await snapshot(for: "primary", credit: unknown).monthlyAPICredit == nil)

        let both = ClaudeMonthlyCreditBinding.resolve(
            webIdentities: [identity(accountUUID, personalOrg), identity(otherAccountUUID, otherOrg)], rows: rows())
        #expect(both == .ambiguous)
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: nil, rows: rows()) == .webAccountUnknown)
        #expect(ClaudeMonthlyCreditBinding.resolve(
            webIdentities: stranger.webIdentities, rows: rows()) == .noMatchingAccount)
    }

    @Test("A row without a verified identity never receives the credit")
    func unverifiedRow() {
        let rows: [ClaudeMonthlyCreditBinding.Row] = [.init(accountID: "unverified", identity: nil)]
        #expect(ClaudeMonthlyCreditBinding.resolve(
            webIdentities: credit(signedInAs: accountUUID, orgs: [personalOrg]).webIdentities,
            rows: rows) == .noMatchingAccount)
    }

    @Test("The account projection decodes; 401/403 is signed out; anything else is unknown")
    func projection() {
        #expect(ClaudeMonthlyCreditBinding.webAccount(fromProjection: #"{"status":200,"account":"\#(accountUUID)"}"#)
            == .account(accountUUID))
        #expect(ClaudeMonthlyCreditBinding.webAccount(fromProjection: #"{"status":401}"#) == .signedOut)
        #expect(ClaudeMonthlyCreditBinding.webAccount(fromProjection: #"{"status":403}"#) == .signedOut)
        #expect(ClaudeMonthlyCreditBinding.webAccount(fromProjection: #"{"status":200,"account":"nope"}"#) == .unknown)
        #expect(ClaudeMonthlyCreditBinding.webAccount(fromProjection: #"{"status":500}"#) == .unknown)
        #expect(ClaudeMonthlyCreditBinding.webAccount(fromProjection: nil) == .unknown)
    }

    private func query(_ org: String) -> String {
        "/api/quirky-lollipop/link-state?organization_uuid=\(org)&include_candidates=false"
    }

    private static let linked = #"{"status":"linked","monthly_credit_usd":"200","next_grant_at":"2027-02-15T14:49:22Z"}"#

    /// One billing observation for `org`, as the page's observer reports it.
    private func observe(_ state: inout ClaudeMonthlyCreditSessionState, _ org: String) {
        state.observe(text: Self.linked, query: query(org), retryAfter: nil, now: now)
    }

    private var rowA: [ClaudeMonthlyCreditBinding.Row] {
        [.init(accountID: "a", identity: identity(accountUUID, personalOrg))]
    }

    /// The account belongs to A and B, only A has a row, and billing is open
    /// for B. Matching against memberships put B's credit on A's row.
    @Test("The credit's organisation is the one its billing query names, not any membership")
    func billingOrganisationDecides() {
        var state = ClaudeMonthlyCreditSessionState()
        observe(&state, otherOrg)
        state.applyAccountRead(.account(accountUUID), forVersion: state.creditVersion)
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: state.webIdentities, rows: rowA) == .noMatchingAccount)

        observe(&state, personalOrg)
        // A new observation needs its own account read before anything binds.
        #expect(state.webIdentities == nil)
        #expect(state.needsAccountRead(now: now))
        state.applyAccountRead(.account(accountUUID), forVersion: state.creditVersion)
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: state.webIdentities, rows: rowA) == .bound(accountID: "a"))
    }

    /// A signs out and B signs in to the same organisation: the billing query
    /// is unchanged, so a query-keyed account let B's credit wear A's identity.
    @Test("A sign-in swap in the same organisation never binds the new credit to the old account")
    func sameOrganisationSwap() {
        var state = ClaudeMonthlyCreditSessionState()
        observe(&state, personalOrg)
        state.applyAccountRead(.account(accountUUID), forVersion: state.creditVersion)
        #expect(state.webIdentities == [identity(accountUUID, personalOrg)])

        // B's billing response arrives through the observer.
        observe(&state, personalOrg)
        #expect(state.webIdentities == nil)
        state.applyAccountRead(.account(otherAccountUUID), forVersion: state.creditVersion)
        #expect(state.webIdentities == [identity(otherAccountUUID, personalOrg)])
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: state.webIdentities, rows: rowA) == .noMatchingAccount)
    }

    /// The billing refresh failed, so A's credit is still on screen, and the
    /// account read now answers B.
    @Test("An account that changes under an unchanged credit unbinds it")
    func accountChangesUnderCredit() {
        var state = ClaudeMonthlyCreditSessionState()
        observe(&state, personalOrg)
        let version = state.creditVersion
        state.applyAccountRead(.account(accountUUID), forVersion: version)
        state.observe(text: #"{"_failed":true}"#, query: query(personalOrg), retryAfter: nil, now: now)
        #expect(state.creditVersion == version)
        state.applyAccountRead(.account(otherAccountUUID), forVersion: version)
        #expect(state.webIdentities == nil)
        // It stays unbound until the credit itself is observed again.
        #expect(!state.needsAccountRead(now: now.addingTimeInterval(600)))
    }

    @Test("Signing out unbinds the credit; a failed read keeps an established account")
    func accountInvalidation() {
        var state = ClaudeMonthlyCreditSessionState()
        observe(&state, personalOrg)
        state.applyAccountRead(.account(accountUUID), forVersion: state.creditVersion)
        state.applyAccountRead(.unknown, forVersion: state.creditVersion)
        #expect(state.webIdentities != nil)
        state.applyAccountRead(.signedOut, forVersion: state.creditVersion)
        #expect(state.webIdentities == nil)
        // Whoever signs in next did not publish this credit.
        state.applyAccountRead(.account(otherAccountUUID), forVersion: state.creditVersion)
        #expect(state.webIdentities == nil)
        // A read for an older observation is ignored.
        observe(&state, personalOrg)
        state.applyAccountRead(.account(accountUUID), forVersion: state.creditVersion - 1)
        #expect(state.webIdentities == nil)
    }

    @Test("A stalled billing read does not hold the row past its bound")
    func boundedCreditWait() async {
        let started = ContinuousClock.now
        let credit = await ClaudeAccountQuotaProvider.bounded({ _ in
            try? await Task.sleep(for: .seconds(30))
            return ClaudeMonthlyCredit(amountUSD: 1, nextGrantAt: nil, measuredAt: Date())
        }, now: now, limit: .milliseconds(50))
        #expect(credit == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
        let quick = await ClaudeAccountQuotaProvider.bounded({ _ in
            ClaudeMonthlyCredit(amountUSD: 2, nextGrantAt: nil, measuredAt: Date())
        }, now: now, limit: .seconds(5))
        #expect(quick?.amountUSD == 2)
    }
}
