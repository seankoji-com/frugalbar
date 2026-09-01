import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

/// The exhausted row treatment — faded logo under a red ✗, red subtitle, red
/// window token, fully red bar — is driven entirely by these two properties,
/// so they are what the tests pin.
@Suite("MetricRowPresentation exhaustion")
struct MetricRowExhaustionTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        bars: [DualBarMetrics],
        status: ProviderStatus = .measured(.none)
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "copilot", vendorId: .copilot, displayName: "Copilot",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 1.0, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bars.count > 0 ? bars[0] : nil,
            row2: bars.count > 1 ? bars[1] : nil,
            row3: bars.count > 2 ? bars[2] : nil
        )
    }

    @Test("a fully spent window marks the row exhausted and surfaces its reset")
    func spentWindowIsExhausted() {
        let p = MetricRowPresentation(
            snapshot: snapshot(bars: [
                DualBarMetrics(
                    primaryFraction: 1.0, label: "MO",
                    resetText: "Resets on 1st of month"
                )
            ]),
            now: now
        )
        #expect(p.isExhausted)
        #expect(p.exhaustedResetText == "Resets on 1st of month")
    }

    @Test("a nearly spent window is not exhausted")
    func nearlySpentIsNotExhausted() {
        let p = MetricRowPresentation(
            snapshot: snapshot(bars: [
                DualBarMetrics(primaryFraction: 0.99, label: "WK", resetText: "3d")
            ]),
            now: now
        )
        #expect(p.isExhausted == false)
        #expect(p.exhaustedResetText == nil)
    }

    @Test("a percentage that arrives as 100 still reads as exhausted despite float residue")
    func floatResidueStillExhausted() {
        // 0.999 rather than 1.0: `>= 1` would drop a vendor that reports
        // 99.95% and rounds to 100 in its own dashboard.
        let p = MetricRowPresentation(
            snapshot: snapshot(bars: [
                DualBarMetrics(primaryFraction: 0.9995, label: "MO")
            ]),
            now: now
        )
        #expect(p.isExhausted)
    }

    @Test("only the spent window supplies the reset text, not the first bar")
    func resetTextComesFromTheSpentBar() {
        let p = MetricRowPresentation(
            snapshot: snapshot(bars: [
                DualBarMetrics(primaryFraction: 0.30, label: "5H", resetText: "2h"),
                DualBarMetrics(primaryFraction: 1.0, label: "MO", resetText: "Resets on 1st of month"),
            ]),
            now: now
        )
        #expect(p.isExhausted)
        #expect(p.exhaustedResetText == "Resets on 1st of month")
    }

    @Test("an exhausted window with no published reset offers no text to substitute")
    func noResetTextWhenVendorPublishedNone() {
        let p = MetricRowPresentation(
            snapshot: snapshot(bars: [DualBarMetrics(primaryFraction: 1.0, label: "MO")]),
            now: now
        )
        #expect(p.isExhausted)
        // The row falls back to the plan name rather than inventing a date.
        #expect(p.exhaustedResetText == nil)
    }

    @Test("a quota we could not read is not a quota we know is spent")
    func unreadableIsNotExhausted() {
        let p = MetricRowPresentation(
            snapshot: snapshot(bars: [], status: .unavailable(.notConfigured)),
            now: now
        )
        #expect(p.isExhausted == false)
        #expect(p.exhaustedResetText == nil)
    }

    @Test("exhaustion is spoken outright, not left to sound like critically low")
    func accessibilityLabelSaysExhausted() {
        let p = MetricRowPresentation(
            snapshot: snapshot(
                bars: [DualBarMetrics(primaryFraction: 1.0, label: "MO", resetText: "Resets on 1st of month")],
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(p.accessibilityLabel.contains("exhausted"))
        #expect(p.accessibilityLabel.contains("Resets on 1st of month"))
    }

    @Test("a fully rate-limited account reads as blocked, not merely critically low")
    func fullyBlockedIsExhaustedAndSpokenBlocked() {
        // Every window blocked with no percentage (OpenCodeGo's rate-limited
        // reading). There is no spent bar (nil fractions), yet the account is
        // unusable — so the row must be treated as exhausted (avatar ✗) and the
        // user must *hear* "blocked", never the "critically low" phrasing that
        // would imply it is merely low-but-usable.
        let p = MetricRowPresentation(
            snapshot: snapshot(
                bars: [
                    DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: true, resetText: "Resets in 2 hours"),
                    DualBarMetrics(primaryFraction: nil, label: "MO", isBlocked: true, resetText: "Resets on 1st of month"),
                ],
                status: .measured(.critical)
            ),
            now: now
        )
        #expect(p.isExhausted)
        // Reset text is drawn from the first blocked bar, not lost.
        #expect(p.exhaustedResetText == "Resets in 2 hours")
        #expect(p.accessibilityLabel.contains("blocked"))
        #expect(!p.accessibilityLabel.contains("critically low"))
    }
}
