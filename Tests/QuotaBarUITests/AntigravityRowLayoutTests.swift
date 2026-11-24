import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Antigravity row layout")
@MainActor
struct AntigravityRowLayoutTests {
    @Test("the shared pool icon contains Claude and Gemini halves with a divider")
    func sharedPoolIconHalves() throws {
        func bitmap(_ vendor: VendorIdentifier) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: VendorAvatarView(vendorId: vendor, status: .healthy, size: 28)
                .background(Theme.surface).environment(\.colorScheme, .dark))
            host.frame.size = CGSize(width: 28, height: 28)
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        let split = try bitmap(.antigravityClaude)
        let claude = try bitmap(.claude)
        let gemini = try bitmap(.gemini)
        var differentFromClaude = 0
        var differentFromGemini = 0
        var dividerPixels = 0
        for y in 0..<split.pixelsHigh {
            for x in 0..<split.pixelsWide {
                func difference(_ other: NSBitmapImageRep) throws -> CGFloat {
                    let a = try #require(split.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try #require(other.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                        + abs(a.blueComponent - b.blueComponent)
                }
                let fromClaude = try difference(claude)
                let fromGemini = try difference(gemini)
                if fromClaude > 0.1 { differentFromClaude += 1 }
                if fromGemini > 0.1 { differentFromGemini += 1 }
                let diagonal = x + y - split.pixelsWide
                if diagonal < -3 { #expect(fromClaude < 0.05) }
                if diagonal > 3 { #expect(fromGemini < 0.05) }
                if abs(diagonal) < 2 && fromClaude > 0.1 && fromGemini > 0.1 { dividerPixels += 1 }
            }
        }
        #expect(differentFromClaude > 20)
        #expect(differentFromGemini > 20)
        #expect(dividerPixels > 10)
    }

}
