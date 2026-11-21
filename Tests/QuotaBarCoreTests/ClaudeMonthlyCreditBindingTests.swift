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

    private func query(_ org: String) -> String {
        "/api/quirky-lollipop/link-state?organization_uuid=\(org)&include_candidates=false"
    }

    private static let linked = #"{"status":"linked","monthly_credit_usd":"200","next_grant_at":"2027-02-15T14:49:22Z"}"#

    private var rowA: [ClaudeMonthlyCreditBinding.Row] {
        [.init(accountID: "a", identity: identity(accountUUID, personalOrg))]
    }

    /// A state whose billing query names `org`, as the page's first billing
    /// fetch establishes it.
    private func state(for org: String) -> ClaudeMonthlyCreditSessionState {
        var state = ClaudeMonthlyCreditSessionState()
        state.observe(text: Self.linked, query: query(org), retryAfter: nil, now: now)
        return state
    }

    /// FrugalBar's own read: account, billing, account, as `refreshQuery`
    /// returns it.
    private func read(_ state: inout ClaudeMonthlyCreditSessionState, before: String?, after: String?,
                      billing: String = linked) {
        func who(_ uuid: String?) -> String {
            switch uuid { case nil: "null"; case "out": #"{"signedOut":true}"#; case let u?: #"{"uuid":"\#(u)"}"# }
        }
        let text = #"{"before":\#(who(before)),"after":\#(who(after)),"billing":\#(billing)}"#
        state.completeRead(text: text, query: state.query!, generation: state.generation, now: now)
    }

    @Test("A credit the page fetched on its own is unattributed until FrugalBar verifies it")
    func observedCreditIsUnverified() {
        var s = state(for: personalOrg)
        #expect(s.credit != nil)
        #expect(s.webIdentities == nil)
        #expect(s.verificationPending)
        read(&s, before: accountUUID, after: accountUUID)
        #expect(!s.verificationPending)
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: s.webIdentities, rows: rowA) == .bound(accountID: "a"))
    }

    /// The account belongs to A and B, only A has a row, and billing is open
    /// for B. Matching against memberships put B's credit on A's row.
    @Test("The credit's organisation is the one its billing query names, not any membership")
    func billingOrganisationDecides() {
        var s = state(for: otherOrg)
        read(&s, before: accountUUID, after: accountUUID)
        #expect(ClaudeMonthlyCreditBinding.resolve(webIdentities: s.webIdentities, rows: rowA) == .noMatchingAccount)
    }

    /// A's credit was observed, then B signed in to the same organisation
    /// before the account was read: separate requests let B claim A's credit.
    @Test("A sign-in change around the billing read leaves the credit unattributed")
    func swapDuringRead() {
        var s = state(for: personalOrg)
        read(&s, before: accountUUID, after: otherAccountUUID)
        #expect(s.webIdentities == nil)
        read(&s, before: nil, after: accountUUID)
        #expect(s.webIdentities == nil)
        read(&s, before: "out", after: "out")
        #expect(s.webIdentities == nil)
    }

    /// The billing refresh failed, so A's credit is still on screen.
    @Test("After a failed billing read the credit stays attributed only while the same account is verified")
    func failedBillingRead() {
        var s = state(for: personalOrg)
        read(&s, before: accountUUID, after: accountUUID)
        #expect(s.webIdentities != nil)
        read(&s, before: accountUUID, after: accountUUID, billing: #"{"_failed":true}"#)
        #expect(s.webIdentities == [identity(accountUUID, personalOrg)])
        #expect(s.credit?.refreshFailed == true)
        read(&s, before: otherAccountUUID, after: otherAccountUUID, billing: #"{"_retryAfter":""}"#)
        #expect(s.webIdentities == nil)
        // Once lost, a failed read cannot restore it: only a fresh credit can.
        read(&s, before: accountUUID, after: accountUUID, billing: #"{"_failed":true}"#)
        #expect(s.webIdentities == nil)
    }

    @Test("A billing response the page fetches itself drops an earlier verification")
    func observationDropsVerification() {
        var s = state(for: personalOrg)
        read(&s, before: accountUUID, after: accountUUID)
        s.observe(text: Self.linked, query: query(personalOrg), retryAfter: nil, now: now)
        #expect(s.webIdentities == nil)
        #expect(s.verificationPending)
    }

    /// Two named rows in one poll: one started the read, the other took the
    /// cached credit while it was pending, and the popover drew both lines.
    @Test("Rows that ask while a read is in flight all get that read's result")
    @MainActor
    func concurrentRowsShareOneRead() async {
        let shared = CoalescedRead<Int>()
        var started = 0
        // Every operation that starts is parked here and released together,
        // so a regression that runs two reads fails instead of hanging.
        var waiting: [CheckedContinuation<Void, Never>] = []
        let operation: @MainActor () async -> Int = {
            started += 1
            let mine = started
            await withCheckedContinuation { waiting.append($0) }
            return mine
        }
        async let first = shared.run(operation)
        async let second = shared.run(operation)
        // Let both callers reach the gate before the read completes.
        for _ in 0..<50 { await Task.yield() }
        waiting.forEach { $0.resume() }
        waiting = []
        let results = await [first, second]
        #expect(results == [1, 1])
        #expect(started == 1)
        // A caller after completion starts a new read.
        let later = await shared.run { 7 }
        #expect(later == 7)
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
