import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Antigravity row layout")
@MainActor
struct AntigravityRowLayoutTests {
    @Test("the shared Claude/GPT name gets room to wrap at the real row width")
    func sharedPoolTitleWraps() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func rowHeight(name: String) -> CGFloat {
            let snapshot = QuotaSnapshot(id: "antigravity_claude", vendorId: .antigravityClaude,
                displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
                status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: 0.2, label: "5H"),
                row2: DualBarMetrics(primaryFraction: 0.4, label: "WK"), planName: "Google AI Pro")
            let host = NSHostingView(rootView: MetricRowView(snapshot: snapshot)
                .frame(width: Theme.popoverWidth - 2 * Theme.edgeMargin - 2 * Theme.cardPadding))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        // Measure the production view, not a copy of its Text modifiers. The
        // previous one-line truncation gives both names the same row height.
        #expect(rowHeight(name: "AGY Claude/GPT") > rowHeight(name: "AGY Claude") + 8)
    }
}
