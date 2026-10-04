import Testing
import SwiftUI
import QuotaBarCore
@testable import QuotaBarUI

@Suite("DualBarProgressView state colour")
struct DualBarStateColorTests {

    private let amber = Color(red: 0.96, green: 0.72, blue: 0.15)

    private func color(_ used: Double?, pace: Double? = nil, blocked: Bool = false) -> Color {
        DualBarProgressView.stateColor(for: DualBarMetrics(
            primaryFraction: used, expectedPaceFraction: pace, label: "WK", isBlocked: blocked))
    }

    /// A window barely open would otherwise turn amber at 6% used against 2%
    /// elapsed; the model's own 4-point threshold is what "ahead" means.
    @Test("slightly ahead of pace is still healthy; meaningfully ahead is amber")
    func aheadThreshold() {
        #expect(color(0.05, pace: 0.03) == Theme.healthy)
        #expect(color(0.30, pace: 0.10) == amber)
    }

    @Test("with no pace published the bar is healthy until spent")
    func noPace() {
        #expect(color(0.80) == Theme.healthy)
        #expect(color(1.0) == Theme.errorBold)
    }

    @Test("no reading is neutral, and blocked with no reading is the error tone")
    func noReading() {
        #expect(color(nil) == Theme.outline)
        #expect(color(nil, blocked: true) == Theme.errorBold)
    }

    // MARK: A blocked window is never drawn as healthy

    @Test("a blocked window wears the vendor's colour whatever its percentage and pace")
    func blockedUsesVendorColour() throws {
        let vendor = try #require(Color(hexString: "#ffb4ab"))
        for (used, pace) in [(0.05, 0.03), (0.40, nil), (0.90, 0.20)] as [(Double, Double?)] {
            let metrics = DualBarMetrics(
                primaryFraction: used, expectedPaceFraction: pace, label: "WK",
                blockedColor: "#ffb4ab", isBlocked: true)
            #expect(DualBarProgressView.stateColor(for: metrics) == vendor)
        }
    }

    /// Failure rendering as health: before this, a blocked window with a
    /// percentage and no vendor colour fell through to green.
    @Test("a blocked window with a percentage but no vendor colour is the error tone, not green")
    func blockedWithoutVendorColour() {
        #expect(color(0.40, pace: 0.50, blocked: true) == Theme.errorBold)
        #expect(color(0.05, blocked: true) == Theme.errorBold)
        #expect(color(0.40, pace: 0.50, blocked: true) != Theme.healthy)
    }
}
