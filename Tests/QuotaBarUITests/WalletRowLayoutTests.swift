import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// The Wallet's own row widths (owner, 26 Nov 2026): a line with no meter had
/// its description squeezed into three lines beside a blank meter column.
@Suite("Wallet row layout")
@MainActor
struct WalletRowLayoutTests {
    /// The row the owner reported: Claude's plan is spent, so the Fable ticket
    /// falls to the Wallet, carried over (the clock glyph tag), expiring in 104
    /// days. The figure column is the batch's own — realistically wide, which is
    /// what made the description wrap.
    private var wallet: WalletPresentation {
        let now = GlanceFixtures.now
        var ticket = GlanceFixtures.claude(GlanceFixtures.primary,
            [GlanceFixtures.bar("WK", 1.0, resetsInHours: 76, windowHours: 168)])
        ticket.resetCreditGroups = [ResetCreditGroup(scope: .model("Fable"), count: 1,
            expiries: [now.addingTimeInterval(104 * 86_400)])]
        ticket.staleReading = StaleReading(reason: .offline, at: now)
        return WalletPresentation(snapshots: GlanceFixtures.batchWithWallet + [ticket], now: now)
    }

    /// The section's laid-out height at a given width. `fittingSize` reads the
    /// width from the view's own frame, so the width is applied inside it.
    private func height(at width: CGFloat) throws -> CGFloat {
        let host = NSHostingView(rootView: WalletSection(presentation: wallet, now: GlanceFixtures.now)
            .frame(width: width))
        host.frame.size = CGSize(width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("a line with no meter gives its spare column to the description")
    func ticketDescriptionTakesTheMeterColumn() throws {
        let rows = wallet.rows
        let ticket = try #require(rows.first { $0.title.contains("Fable") })
        #expect(ticket.meter == nil && ticket.balanceSeriesID == nil)

        // A title that fits needs no extra line, so the popover width and a
        // generous one lay out to the same height. With an empty meter column
        // reserved this row was 14pt taller at the popover's width — one extra
        // wrapped line.
        #expect(try height(at: PopoverRootView.popoverWidth) == height(at: 800))
    }
}
