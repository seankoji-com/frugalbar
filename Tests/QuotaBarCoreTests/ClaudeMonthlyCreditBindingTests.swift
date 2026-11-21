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

    /// The account belongs to A and B, only A has a row, and billing is open
    /// for B. Matching against memberships put B's credit on A's row.
    @Test("The credit's organisation is the one its billing query names, not any membership")
    func billingOrganisationDecides() {
        var state = ClaudeMonthlyCreditSessionState()
        state.query = query(otherOrg)
        state.applyAccountRead(.account(accountUUID), query: state.query)
        let rowsA: [ClaudeMonthlyCreditBinding.Row] = [.init(accountID: "a", identity: identity(accountUUID, personalOrg))]
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: state.webIdentities, rows: rowsA) == .noMatchingAccount)

        state.query = query(personalOrg)
        // A new query needs its own account read before anything binds.
        #expect(state.webIdentities == nil)
        #expect(state.needsAccountRead(now: now))
        state.applyAccountRead(.account(accountUUID), query: state.query)
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: state.webIdentities, rows: rowsA) == .bound(accountID: "a"))
    }

    @Test("Signing out clears the account; a failed read never carries it to another query")
    func accountInvalidation() {
        var state = ClaudeMonthlyCreditSessionState()
        state.query = query(personalOrg)
        state.applyAccountRead(.account(accountUUID), query: state.query)
        #expect(state.webIdentities != nil)
        state.applyAccountRead(.unknown, query: state.query)
        #expect(state.webIdentities != nil)
        state.applyAccountRead(.signedOut, query: state.query)
        #expect(state.webIdentities == nil)

        state.applyAccountRead(.account(accountUUID), query: state.query)
        state.query = query(otherOrg)
        state.applyAccountRead(.unknown, query: state.query)
        #expect(state.webIdentities == nil)
    }
}
