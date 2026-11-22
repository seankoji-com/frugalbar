import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Antigravity account presentation")
@MainActor
struct AntigravityAccountPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var primary: AntigravityAccount {
        AntigravityAccount(
            id: "agy-account:primary-fixture",
            badge: "1",
            sourceLabel: "This Mac's Google OAuth session",
            fallbackName: "This Mac",
            nickname: "Personal",
            planName: "Google AI Ultra",
            isPrimary: true
        )
    }

    private var secondary: AntigravityAccount {
        AntigravityAccount(
            id: "agy-account:secondary-fixture",
            badge: "2",
            sourceLabel: "CLI Proxy (proxy.example.test) · work@example.test",
            fallbackName: "Account 2",
            nickname: "Work",
            planName: "Google AI Ultra",
            isPrimary: false
        )
    }

    private func makeSnapshot(
        account: AntigravityAccount,
        allowance: GeminiQuotaProvider.Allowance,
        fraction: Double = 0.25,
        plan: String? = "Google AI Ultra"
    ) -> QuotaSnapshot {
        let vendor: VendorIdentifier = switch allowance {
        case .gemini: .gemini
        case .claude: .antigravityClaude
        case .argon:  .antigravityArgon
        }
        var snap = QuotaSnapshot(
            id: account.poolInstanceID(for: allowance),
            vendorId: vendor,
            displayName: vendor.displayName,
            category: .aiSubscriptions,
            metric: .subscription(tierName: plan, renewalDate: nil),
            status: .measured(.none),
            resetsAt: now.addingTimeInterval(3600),
            lastUpdated: now,
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: fraction, label: "5H",
                resetsAt: now.addingTimeInterval(3600), windowLength: 18000),
            planName: plan
        )
        snap.antigravityAccount = account
        return snap
    }

    @Test("single Antigravity account preserves shared headerPlan; multiple accounts suppress headerPlan and label rows")
    func groupingHeaderPlanAndSubtitles() {
        let singleRows = [
            makeSnapshot(account: primary, allowance: .gemini),
            makeSnapshot(account: primary, allowance: .claude)
        ]
        let singleGroup = PopoverRowGrouping.groups(for: singleRows)[0]
        #expect(singleGroup.header == "Antigravity")
        #expect(singleGroup.headerPlan == "Google AI Ultra")
        #expect(singleGroup.suppressPlan)

        let multiRows = [
            makeSnapshot(account: primary, allowance: .gemini),
            makeSnapshot(account: primary, allowance: .claude),
            makeSnapshot(account: secondary, allowance: .gemini, fraction: 0.70),
            makeSnapshot(account: secondary, allowance: .claude, fraction: 0.80)
        ]
        let multiGroup = PopoverRowGrouping.groups(for: multiRows)[0]
        #expect(multiGroup.header == "Antigravity")
        #expect(multiGroup.headerPlan == nil)
        #expect(!multiGroup.suppressPlan)
        #expect(multiGroup.rowSubtitle(for: multiRows[0]) == "Personal · AI Ultra")
        #expect(multiGroup.rowSubtitle(for: multiRows[2]) == "Work · AI Ultra")
    }

    @Test("named Antigravity row accessibility label includes account badge and name")
    func accessibilityLabelIncludesAccount() {
        let snap = makeSnapshot(account: secondary, allowance: .gemini, fraction: 0.70)
        let row = MetricRowView(snapshot: snap, isGrouped: true, now: now)
        let label = row.combinedAccessibilityLabel(
            grid: WindowGridPresentation(snapshot: snap, now: now),
            presentation: MetricRowPresentation(snapshot: snap, now: now)
        )
        #expect(label.contains("Account 2"))
        #expect(label.contains("Work"))
        #expect(label.contains("Gemini"))
    }

    @Test("HistoryOverviewPresentation emits per-account subjects with legacy key continuity on primary only")
    func historySubjectsAndLegacyContinuity() {
        let subjects = HistoryOverviewPresentation.subjects(
            order: [.gemini, .antigravityClaude, .antigravityArgon],
            hidden: [],
            workspaces: [],
            claudeAccounts: [],
            antigravityAccounts: [primary, secondary]
        )
        #expect(subjects.count == 6)

        let geminiSubjects = subjects.filter { $0.vendor == .gemini }
        #expect(geminiSubjects.count == 2)
        #expect(geminiSubjects[0].name == "Gemini · Personal")
        #expect(geminiSubjects[0].keys.contains("gemini"))
        #expect(geminiSubjects[1].name == "Gemini · Work")
        #expect(!geminiSubjects[1].keys.contains("gemini"))

        let claudeSubjects = subjects.filter { $0.vendor == .antigravityClaude }
        #expect(claudeSubjects[0].keys.contains("antigravity_claude"))
        #expect(!claudeSubjects[1].keys.contains("antigravity_claude"))

        let argonSubjects = subjects.filter { $0.vendor == .antigravityArgon }
        #expect(argonSubjects[0].keys.contains("antigravity_argon"))
        #expect(!argonSubjects[1].keys.contains("antigravity_argon"))
    }
}
