import Foundation
import QuotaBarCore

/// Offscreen and presentation fixtures only. Never installed in a live store.
enum ClaudeAccountFixtures {
    static let now = Date(timeIntervalSince1970: 1_794_614_400)
    static let personal = ClaudeAccount(id: "claude-account:fixture-personal", badge: "1",
        sourceLabel: "This Mac · Claude Code", fallbackName: "This Mac", nickname: "Personal", planName: "Max")
    static let work = ClaudeAccount(id: "claude-account:fixture-work", badge: "2",
        sourceLabel: "CLI Proxy · Account 2", fallbackName: "Account 2", nickname: "Work", planName: "Max")

    static func snapshot(_ account: ClaudeAccount, weekly: Double, fable: Double,
                         measuredAt: Date? = nil) -> QuotaSnapshot {
        let reset = now.addingTimeInterval(2 * 86_400)
        var snapshot = QuotaSnapshot(id: account.id, vendorId: .claude, displayName: account.name,
            category: .aiSubscriptions, metric: .subscription(tierName: "Max", renewalDate: nil),
            status: .measured(.none), resetsAt: reset, lastUpdated: measuredAt ?? now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: weekly == 0.61 ? 0.82 : 0.18,
                expectedPaceFraction: 0.66, label: "5H", resetsAt: now.addingTimeInterval(6_120),
                windowLength: QuotaWindow.fiveHours),
            row2: DualBarMetrics(primaryFraction: weekly, expectedPaceFraction: 0.71,
                label: "WK", resetsAt: reset, windowLength: QuotaWindow.week), planName: account.planName)
        snapshot.claudeAccount = account
        snapshot.scopedBars = [DualBarMetrics(primaryFraction: fable, label: "Fable",
            resetsAt: reset, windowLength: QuotaWindow.week)]
        let isPersonal = account.id == personal.id
        snapshot.resetCreditsAvailable = isPersonal ? 2 : 3
        snapshot.resetCreditGroups = [
            ResetCreditGroup(scope: .plan, count: isPersonal ? 1 : 2,
                expiries: (isPersonal ? [20.0] : [35.0, 45.0]).map { now.addingTimeInterval($0 * 86_400) }),
            ResetCreditGroup(scope: .model("Fable"), count: 1,
                expiries: [now.addingTimeInterval((isPersonal ? 119 : 90) * 86_400)])
        ]
        return snapshot
    }

    static var both: [QuotaSnapshot] {
        [snapshot(personal, weekly: 0.61, fable: 0.35), snapshot(work, weekly: 0.27, fable: 0.12)]
    }

    static var unavailable: QuotaSnapshot {
        var snapshot = QuotaSnapshot(id: work.id, vendorId: .claude, displayName: work.name,
            category: .aiSubscriptions, metric: .subscription(tierName: "", renewalDate: nil),
            status: .unavailable(.offline), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        snapshot.claudeAccount = work
        return snapshot
    }

    static var stale: QuotaSnapshot {
        var snapshot = snapshot(work, weekly: 0.27, fable: 0.12, measuredAt: now.addingTimeInterval(-3_600))
        snapshot.staleReading = StaleReading(reason: .offline, at: now)
        return snapshot
    }
}
