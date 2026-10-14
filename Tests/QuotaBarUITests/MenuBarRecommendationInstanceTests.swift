import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

/// A vendor that serves several instances under one id (OpenCode Go workspaces)
/// must have the *recommended* instance's figures in the menu bar, not the
/// first instance that happens to carry the vendor id.
///
/// The bug this covers: `QuotaAdvice` carried only a `VendorIdentifier`, and
/// `MenuBarPresentation.recommendationDetails` resolved the snapshot with the
/// first `vendorId` match. With three OpenCode Go workspaces — Alpha blocked
/// and spent, Beta mid-window, Gamma untouched — the advice card named Gamma
/// ("Gamma has 100% remaining") while the menu bar read Alpha's "0% 4d".
@Suite("Menu bar recommendation resolves the advised instance")
struct MenuBarRecommendationInstanceTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func bar(
        _ label: String,
        used: Double,
        window: TimeInterval?,
        resetsIn hours: Double?,
        blocked: Bool = false
    ) -> DualBarMetrics {
        var metrics = DualBarMetrics(
            primaryFraction: used,
            label: label,
            isBlocked: blocked,
            resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
            windowLength: window
        )
        // The vendor's own full-unit wording, which is what the compact menu
        // bar form parses; a bare "0d" for a five-hour reset would prove
        // nothing.
        metrics.resetText = hours.map {
            $0 < 24 ? "Resets in \(Int($0)) hours" : "Resets in \(Int($0 / 24)) days"
        }
        return metrics
    }

    private func instance(
        _ name: String,
        id: String,
        urgency: Urgency,
        rows: [DualBarMetrics]
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: .opencode, displayName: name,
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Go", renewalDate: nil),
            status: .measured(urgency), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: rows.count > 0 ? rows[0] : nil,
            row2: rows.count > 1 ? rows[1] : nil,
            row3: rows.count > 2 ? rows[2] : nil
        )
    }

    /// Alpha: weekly window blocked at 100% used, resetting in 4 days — what
    /// the menu bar used to show, because Alpha is first in canonical order.
    private var alpha: QuotaSnapshot {
        instance("Alpha", id: "opencode-go-alpha", urgency: .critical, rows: [
            bar("WK", used: 1.0, window: QuotaWindow.week, resetsIn: 96, blocked: true),
        ])
    }

    /// Beta: half of its monthly window used.
    private var beta: QuotaSnapshot {
        instance("Beta", id: "opencode-go-beta", urgency: .none, rows: [
            bar("MO", used: 0.5, window: 30 * 86_400, resetsIn: 480),
        ])
    }

    /// Gamma: every window untouched. Three windows at 100% remaining; the
    /// soonest reset is the five-hour one, which is the actionable answer.
    private var gamma: QuotaSnapshot {
        instance("Gamma", id: "opencode-go-gamma", urgency: .none, rows: [
            bar("5H", used: 0.0, window: QuotaWindow.fiveHours, resetsIn: 5),
            bar("WK", used: 0.0, window: QuotaWindow.week, resetsIn: 144),
            bar("MO", used: 0.0, window: 30 * 86_400, resetsIn: 480),
        ])
    }

    private var snapshots: [QuotaSnapshot] { [alpha, beta, gamma] }

    @Test("the menu bar reads the advised workspace's figures, not the first with that vendor id")
    func recommendedWorkspaceFigures() {
        let advice = QuotaAdvice.evaluate(from: snapshots, now: now)
        #expect(advice.headline == "Use Gamma")
        #expect(advice.vendorId == .opencode)

        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: snapshots,
            summary: SystemHealthSummary.compute(from: snapshots)
        )

        // Alpha's blocked weekly window would read "0% 4d" — the bug.
        #expect(details.displayText == "100% 5h")
        #expect(details.remainingPctText == "100%")
        #expect(details.timeLeftText == "5h")
        #expect(details.vendorId == .opencode)
    }

    @Test("ties on remaining share are broken by the earliest reset")
    func tiesPreferEarliestReset() {
        // One vendor, two untouched windows: both read 100% remaining, and
        // `bars` puts the weekly one first. The row must answer with the
        // soonest reset, not with whichever window happens to be drawn first.
        let grok = QuotaSnapshot(
            id: "grok", vendorId: .grok, displayName: "Grok",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "SuperGrok", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("WK", used: 0.0, window: QuotaWindow.week, resetsIn: 144),
            row2: bar("5H", used: 0.0, window: QuotaWindow.fiveHours, resetsIn: 5)
        )
        let advice = QuotaAdvice(headline: "Use Grok", message: "", vendorId: .grok)
        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [grok],
            summary: SystemHealthSummary.compute(from: [grok])
        )
        #expect(details.displayText == "100% 5h")
    }

    @Test("advice that names no instance still falls back to the vendor's first match")
    func vendorFallbackWithoutInstance() {
        // The fallback path is deliberately kept: an advice built by hand, or
        // recorded before the instance id existed, must still resolve.
        let advice = QuotaAdvice(headline: "Use OpenCode", message: "", vendorId: .opencode)
        let details = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: [beta, gamma],
            summary: SystemHealthSummary.compute(from: [beta, gamma])
        )
        #expect(details.vendorId == .opencode)
        // Beta's monthly window is half used: the first vendor match, not the
        // untouched Gamma.
        #expect(details.displayText == "50% 20d")
    }
}
