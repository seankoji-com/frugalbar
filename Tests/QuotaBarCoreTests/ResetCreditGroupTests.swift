import Foundation
import Testing
@testable import QuotaBarCore

/// Banked reset tickets are split by the allowance they reset. The vendor's
/// own grant id/label names a Fable reset; everything else is the plan-wide
/// ticket, and the split is never inferred from the ticket order.
@Suite("Reset credit scopes")
struct ResetCreditGroupTests {

    private func grant(
        id: String?, label: String? = nil, left: Int?, endsAt: String? = nil,
        clears: [String]? = nil
    ) -> ClaudeOAuthUsageResponse.ResetGrant {
        ClaudeOAuthUsageResponse.ResetGrant(
            id: id, label: label, resetsLeft: left, resetsTotal: left,
            clears: clears, usableNow: true, endsAt: endsAt)
    }

    @Test("a grant id names its model first; clears then label are fallbacks")
    func scopeClassification() {
        // The live payload: one general reset and three Fable launch grants.
        // The Fable grants also clear `seven_day_overage_included`, a shared
        // plan window, but their ids name the model explicitly.
        #expect(grant(id: "full-reset-2611",
                      label: "One full limit reset (November 2026)", left: 1,
                      clears: ["seven_day", "seven_day_overage_included"])
            .creditScope == .plan)
        #expect(grant(id: "launch-2610-fable",
                      label: "New model launch: one Fable reset for Max", left: 1,
                      clears: ["seven_day_overage_included"])
            .creditScope == .model("Fable"))
        #expect(grant(id: "launch-2610-fable-12mo",
                      label: "New model launch: one more Fable reset", left: 1,
                      clears: ["seven_day_overage_included"])
            .creditScope == .model("Fable"))
        // A general id with a label that merely mentions Fable stays general.
        #expect(grant(id: "full-reset-x",
                      label: "One full limit reset, including Fable", left: 1,
                      clears: ["seven_day"]).creditScope == .plan)
        #expect(grant(id: "general", left: 1,
                      clears: ["seven_day_fable"]).creditScope == .model("Fable"))
        #expect(grant(id: "general", left: 1,
                      clears: ["five_hour"]).creditScope == .plan)
        #expect(grant(id: nil, label: "Fable weekly reset", left: 1)
            .creditScope == .model("Fable"))
    }

    @Test("grant order never moves a ticket between General and Fable")
    func orderDoesNotMoveScopes() {
        let groups = ClaudeQuotaProvider.resetCreditGroups(from: [
            grant(id: "fable-c", left: 1, endsAt: "2026-11-23T00:00:00Z"),
            grant(id: "general", left: 1, endsAt: "2026-11-20T00:00:00Z"),
            grant(id: "fable-a", left: 1, endsAt: "2026-11-21T00:00:00Z"),
            grant(id: "fable-b", left: 1, endsAt: "2026-11-22T00:00:00Z"),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].scope == .plan)
        #expect(groups[0].count == 1)
        #expect(groups[1].scope == .model("Fable"))
        #expect(groups[1].count == 3)
    }

    @Test("one general ticket and three Fable tickets split into the two rows")
    func oneGeneralThreeFable() {
        let groups = ClaudeQuotaProvider.resetCreditGroups(from: [
            grant(id: "general", left: 1, endsAt: "2026-11-20T00:00:00Z"),
            grant(id: "fable-a", left: 1, endsAt: "2026-11-21T00:00:00Z"),
            grant(id: "fable-b", left: 1, endsAt: "2026-11-22T00:00:00Z"),
            grant(id: "fable-c", left: 1, endsAt: "2026-11-23T00:00:00Z"),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].scope == .plan)
        #expect(groups[0].count == 1)
        #expect(groups[1].scope == .model("Fable"))
        #expect(groups[1].count == 3)
        #expect(groups[1].expiries.count == 3)
    }

    @Test("a repeated grant expands to one ticket per resets_left")
    func repeatedGrantExpands() {
        let groups = ClaudeQuotaProvider.resetCreditGroups(from: [
            grant(id: "fable", left: 3, endsAt: "2026-11-21T00:00:00Z")
        ])
        #expect(groups.first?.scope == .model("Fable"))
        #expect(groups.first?.count == 3)
        #expect(groups.first?.expiries == Array(repeating: ISO8601DateFormatter()
            .date(from: "2026-11-21T00:00:00Z"), count: 3))
    }

    @Test("a grant missing its count yields no split at all")
    func missingCountYieldsNoGroups() {
        #expect(ClaudeQuotaProvider.resetCreditGroups(from: [
            grant(id: "general", left: 1),
            grant(id: "fable", left: nil),
        ]).isEmpty)
    }

    @Test("groups keep earliest expiry first and unknown expiries last")
    func expiryOrder() {
        let groups = ClaudeQuotaProvider.resetCreditGroups(from: [
            grant(id: "fable-late", left: 1, endsAt: nil),
            grant(id: "fable-last", left: 1, endsAt: "2026-12-01T00:00:00Z"),
            grant(id: "fable-first", left: 1, endsAt: "2026-11-21T00:00:00Z"),
        ])
        let expiries = try? #require(groups.first?.expiries)
        #expect(expiries?.count == 3)
        #expect(expiries?[0] == ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z"))
        #expect(expiries?[1] == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        #expect(expiries?[2] == nil)
    }
}
