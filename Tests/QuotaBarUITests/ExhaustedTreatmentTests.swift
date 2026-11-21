import Testing
import Foundation
import SwiftUI
import AppKit
import QuotaBarCore
@testable import QuotaBarUI

/// An exhausted or blocked row draws one red: the deep `Theme.errorBold`.
/// OpenCode Go once passed its own pale `#ffb4ab` (`Theme.error`, a text
/// coral) as the blocked tint, so its workspaces rendered pink-hatched beside
/// Command Code's deep red. The avatar's exhausted treatment (design B) keeps
/// the logo recognisable in greyscale and carries the state in a red ring and
/// a top-left countdown tag, rather than fading the logo under the countdown.
@Suite("Exhausted treatment")
@MainActor
struct ExhaustedTreatmentTests {

    @Test("A blocked window is the spent red whatever tint the vendor suggested")
    func blockedWindowIgnoresVendorTint() {
        let tinted = DualBarMetrics(primaryFraction: 0.4, label: "WK", blockedColor: "#ffb4ab", isBlocked: true)
        let untinted = DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: true)
        let spent = DualBarMetrics(primaryFraction: 1, label: "MO")
        #expect(DualBarProgressView.stateColor(for: tinted) == Theme.errorBold)
        #expect(DualBarProgressView.stateColor(for: untinted) == Theme.errorBold)
        #expect(DualBarProgressView.stateColor(for: spent) == Theme.errorBold)
    }

    @Test("Exhausted rows use the spent red for text; critically low rows keep the coral")
    func exhaustedTextIsSpentRed() {
        #expect(MetricRowView.exhaustedTextColor == Theme.errorBold)
        #expect(MetricRowView.urgencyColor(urgency: .critical, isExhausted: true) == Theme.errorBold)
        #expect(MetricRowView.urgencyColor(urgency: .critical, isExhausted: false) == Theme.error)
        #expect(MetricDetailModalView.color(for: .exhausted) == Theme.errorBold)
        #expect(MetricDetailModalView.color(for: .blocked) == Theme.errorBold)
    }

    @Test("The exhausted avatar keeps a greyscale logo and a red ring and tag")
    func avatarDesignB() {
        let exhausted = VendorAvatarView.Overlay.exhausted(reset: "13d")
        let treatment = VendorAvatarView.logoTreatment(for: exhausted)
        #expect(treatment.saturation == 0)
        #expect(treatment.opacity == 0.55)
        #expect(VendorAvatarView.Overlay.exhaustedTint == Theme.errorBold)
        #expect(VendorAvatarView.Overlay.strikeTint == Theme.errorBold)
        #expect(VendorAvatarView.ExhaustedStyle.ringWidth == 1.5)
        #expect(VendorAvatarView.ExhaustedStyle.ringInset == -3)
        // Top-left, so the tag never reaches into the name column.
        #expect(VendorAvatarView.ExhaustedStyle.badgeOffset.width < 0)
        #expect(VendorAvatarView.ExhaustedStyle.badgeOffset.height < 0)
        #expect(VendorAvatarView.ExhaustedStyle.badgeBorderColor == Theme.card)
        // The inspector and widget keep the struck-through mark at full colour.
        #expect(VendorAvatarView.logoTreatment(for: .struckThrough) == (0.40, 1))
        #expect(VendorAvatarView.logoTreatment(for: .none) == (1, 1))
    }

    /// SwiftUI's `.saturation(0)` left the logo in colour in an offscreen
    /// capture, so the greyscale is baked into the image itself.
    @Test("The exhausted logo image carries no colour but keeps its shape")
    func greyscaleLogo() throws {
        let logo = try #require(VendorSVGLogo.nsImage(for: .claude))
        let grey = try #require(VendorAvatarView.greyscale(logo, size: 28))
        let bitmap = try #require(grey.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map(NSBitmapImageRep.init(cgImage:)))
        var opaque = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                opaque += 1
                #expect(abs(c.redComponent - c.greenComponent) < 0.02 && abs(c.greenComponent - c.blueComponent) < 0.02)
            }
        }
        // The mark is still there, and the transparent margin stayed transparent.
        #expect(opaque > 10)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1 < 0.5)
    }

    @Test("The exhausted avatar keeps its frame, so the workspace connector lines up")
    func avatarFrameUnchanged() {
        let plain = NSHostingView(rootView: VendorAvatarView(vendorId: .opencode, status: .healthy, size: 28))
        let exhausted = NSHostingView(rootView: VendorAvatarView(
            vendorId: .opencode, status: .healthy, isExhausted: true,
            exhaustedReset: "20h", showsResetOverlay: true, size: 28))
        #expect(plain.fittingSize == exhausted.fittingSize)
        #expect(exhausted.fittingSize == CGSize(width: 28, height: 28))
    }
}
