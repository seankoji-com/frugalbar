import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

/// Settings computed the sentence from the billing session while the popover
/// could still be showing a cached poll, so it said "Shown under B" while the
/// credit sat under A or nowhere. "Shown under" now comes from the displayed
/// snapshots.
@Suite("Settings credit placement")
struct SettingsCreditPlacementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = ClaudeAccount(id: "claude-account:a", badge: "1", sourceLabel: "Fixture", fallbackName: "Primary")
    private let b = ClaudeAccount(id: "claude-account:b", badge: "2", sourceLabel: "Fixture", fallbackName: "Secondary")

    private func snapshot(_ account: ClaudeAccount, credit: Bool) -> QuotaSnapshot {
        var s = QuotaSnapshot(id: account.id, vendorId: .claude, displayName: account.name, category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .measured(.none),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        s.claudeAccount = account
        if credit { s.monthlyAPICredit = ClaudeMonthlyCredit(amountUSD: 200, nextGrantAt: nil, measuredAt: now) }
        return s
    }

    private var rows: [ClaudeMonthlyCreditBinding.Row] {
        [.init(accountID: a.id, identity: "ia"), .init(accountID: b.id, identity: "ib")]
    }

    @Test("Shown-under names the row the popover draws the credit under")
    func namesDisplayedRow() {
        let text = SettingsView.claudeCreditPlacement(
            snapshots: [snapshot(a, credit: true), snapshot(b, credit: false)],
            webIdentities: ["ib"], rows: rows)
        // The displayed row, and no claim about who is signed in: here the
        // web identity matches Secondary while the popover still shows Primary.
        #expect(text == "Shown under Primary.")
    }

    @Test("A binding the popover does not show yet is not described as shown")
    func boundButNotDisplayed() {
        let text = SettingsView.claudeCreditPlacement(
            snapshots: [snapshot(a, credit: false), snapshot(b, credit: false)],
            webIdentities: ["ib"], rows: rows)
        #expect(text?.contains("Shown under") == false)
        #expect(text?.contains("next refresh") == true)
    }

    @Test("Without named rows there is nothing to explain")
    func noNamedRows() {
        #expect(SettingsView.claudeCreditPlacement(snapshots: [], webIdentities: nil, rows: []) == nil)
    }
}
