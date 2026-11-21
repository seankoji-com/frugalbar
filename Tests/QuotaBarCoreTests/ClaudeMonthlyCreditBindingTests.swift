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

    @Test("The page projection decodes to identities; anything else is unknown")
    func projection() {
        let text = #"{"account":"\#(accountUUID.uppercased())","orgs":["\#(personalOrg)","not-a-uuid"]}"#
        #expect(ClaudeMonthlyCreditBinding.webIdentities(fromProjection: text) == [identity(accountUUID, personalOrg)])
        #expect(ClaudeMonthlyCreditBinding.webIdentities(fromProjection: #"{"account":null,"orgs":[]}"#) == nil)
        #expect(ClaudeMonthlyCreditBinding.webIdentities(fromProjection: "null") == nil)
        #expect(ClaudeMonthlyCreditBinding.webIdentities(fromProjection: nil) == nil)
    }
}
