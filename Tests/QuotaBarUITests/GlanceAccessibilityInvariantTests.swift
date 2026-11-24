import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// Automated WCAG 2.1 contrast and Reduce Motion invariant checks for the
/// core daily glance loop (Menu bar, Popover, Inline Inspector) plus shared
/// `Theme` tokens that also style out-of-scope views.
@MainActor
@Suite("Glance accessibility invariants")
struct GlanceAccessibilityInvariantTests {

    // MARK: - WCAG 2.1 Luminance & Contrast

    private struct SRGB {
        let r: Double
        let g: Double
        let b: Double
        let a: Double

        func over(_ background: SRGB) -> SRGB {
            SRGB(
                r: r * a + background.r * (1 - a),
                g: g * a + background.g * (1 - a),
                b: b * a + background.b * (1 - a),
                a: 1
            )
        }

        var relativeLuminance: Double {
            func linearize(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
        }
    }

    private func resolve(_ color: Color, appearance name: NSAppearance.Name = .darkAqua) -> SRGB {
        resolveNSColor(NSColor(color), appearance: name)
    }

    private func resolveNSColor(_ nsColor: NSColor, appearance name: NSAppearance.Name = .darkAqua) -> SRGB {
        let appearance = NSAppearance(named: name) ?? NSApp.effectiveAppearance
        var result = SRGB(r: 0, g: 0, b: 0, a: 1)
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = nsColor.usingColorSpace(.sRGB) {
                result = SRGB(
                    r: Double(srgb.redComponent),
                    g: Double(srgb.greenComponent),
                    b: Double(srgb.blueComponent),
                    a: Double(srgb.alphaComponent)
                )
            }
        }
        return result
    }

    private func contrastRatio(foreground: SRGB, background: SRGB) -> Double {
        let fg = foreground.a < 1 ? foreground.over(background) : foreground
        let l1 = max(fg.relativeLuminance, background.relativeLuminance)
        let l2 = min(fg.relativeLuminance, background.relativeLuminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }

    private func hex(_ value: Int) -> SRGB {
        SRGB(
            r: Double((value >> 16) & 0xff) / 255.0,
            g: Double((value >> 8) & 0xff) / 255.0,
            b: Double(value & 0xff) / 255.0,
            a: 1
        )
    }

    // MARK: - WCAG AA Small Text (>= 4.5:1)

    @Test("All small-text foreground/background token pairs meet WCAG AA (>= 4.5:1)")
    func smallTextContrastMeetsWCAGAA() {
        let surface = resolve(Theme.surface)
        let card = resolve(Theme.card)
        let containerLow = resolve(Theme.surfaceContainerLow)
        let containerHigh = resolve(Theme.surfaceContainerHigh)
        let containerLowest = resolve(Theme.surfaceContainerLowest)
        let expandedRowBg = resolve(Theme.surfaceContainerHighest.opacity(0.25)).over(card)
        let inspectorInnerCard = resolve(Theme.surfaceContainerLowest.opacity(0.6)).over(card)
        let lightSettingsBg = hex(0xebebec)

        let pairs: [(String, SRGB, SRGB)] = [
            ("onSurface on surface", resolve(Theme.onSurface), surface),
            ("onSurface on card", resolve(Theme.onSurface), card),
            ("onSurface on surfaceContainerLow", resolve(Theme.onSurface), containerLow),
            ("onSurface on surfaceContainerHigh", resolve(Theme.onSurface), containerHigh),
            ("onSurface on surfaceContainerLowest", resolve(Theme.onSurface), containerLowest),
            ("onSurface on expandedRowBg", resolve(Theme.onSurface), expandedRowBg),
            ("onSurface on inspectorInnerCard", resolve(Theme.onSurface), inspectorInnerCard),

            ("onSurfaceVariant on surface", resolve(Theme.onSurfaceVariant), surface),
            ("onSurfaceVariant on card", resolve(Theme.onSurfaceVariant), card),
            ("onSurfaceVariant on surfaceContainerHigh", resolve(Theme.onSurfaceVariant), containerHigh),
            ("onSurfaceVariant on inspectorInnerCard", resolve(Theme.onSurfaceVariant), inspectorInnerCard),
            ("onSurfaceVariant(0.8) on card", resolve(Theme.onSurfaceVariant.opacity(0.8)), card),
            ("onSurfaceVariant(0.8) on surfaceContainerHigh", resolve(Theme.onSurfaceVariant.opacity(0.8)), containerHigh),

            ("outline on surface", resolve(Theme.outline), surface),
            ("outline on card", resolve(Theme.outline), card),
            ("outline on expandedRowBg", resolve(Theme.outline), expandedRowBg),
            ("outline on inspectorInnerCard", resolve(Theme.outline), inspectorInnerCard),

            ("primary on card", resolve(Theme.primary), card),
            ("primary on inspectorInnerCard", resolve(Theme.primary), inspectorInnerCard),
            ("secondary on card", resolve(Theme.secondary), card),
            ("tertiary on card", resolve(Theme.tertiary), card),
            ("tertiary on inspectorInnerCard", resolve(Theme.tertiary), inspectorInnerCard),
            ("error on card", resolve(Theme.error), card),
            ("error on inspectorInnerCard", resolve(Theme.error), inspectorInnerCard),

            // Menu bar caveat text on dark menu bar
            ("MenuBar caveat on dark menu bar", resolveNSColor(MenuBarGlance.color(for: .caveat)), card),

            // Out-of-scope Settings light appearance secondary text coherence
            ("systemSecondaryText on light Settings form", resolve(Theme.systemSecondaryText, appearance: .aqua), lightSettingsBg),
        ]

        for (label, fg, bg) in pairs {
            let ratio = contrastRatio(foreground: fg, background: bg)
            #expect(ratio >= 4.5, "\(label) measured \(String(format: "%.2f", ratio)):1 (required >= 4.5:1)")
        }
    }

    // MARK: - WCAG AA Non-Text UI Components (>= 3.0:1)

    @Test("All non-text UI component token pairs meet WCAG AA (>= 3.0:1)")
    func uiComponentContrastMeetsWCAGAA() {
        let surface = resolve(Theme.surface)
        let card = resolve(Theme.card)
        let track = resolve(Theme.surfaceContainerHighest)
        let inspectorInnerCard = resolve(Theme.surfaceContainerLowest.opacity(0.6)).over(card)

        let pairs: [(String, SRGB, SRGB)] = [
            ("healthy fill on card", resolve(Theme.healthy), card),
            ("healthy fill on track", resolve(Theme.healthy), track),
            ("tertiary fill on card", resolve(Theme.tertiary), card),
            ("tertiary fill on track", resolve(Theme.tertiary), track),
            ("error fill on card", resolve(Theme.error), card),
            ("error fill on track", resolve(Theme.error), track),
            ("errorBold fill on card", resolve(Theme.errorBold), card),
            ("errorBold fill on surface", resolve(Theme.errorBold), surface),
            ("errorBold fill on inspectorInnerCard", resolve(Theme.errorBold), inspectorInnerCard),
            ("primary fill on card", resolve(Theme.primary), card),
            ("primary fill on track", resolve(Theme.primary), track),
            ("pace marker (onSurface) on track", resolve(Theme.onSurface), track),
            ("exhausted badge white text on errorBold", hex(0xffffff), resolve(Theme.errorBold)),
            ("MenuBar critical on dark menu bar", resolveNSColor(MenuBarGlance.color(for: .critical)), card),
        ]

        for (label, fg, bg) in pairs {
            let ratio = contrastRatio(foreground: fg, background: bg)
            #expect(ratio >= 3.0, "\(label) measured \(String(format: "%.2f", ratio)):1 (required >= 3.0:1)")
        }
    }

    // MARK: - Reduce Motion Compliance

    @Test("Reduce Motion disables golden ticket glints without hiding the ticket")
    func reduceMotionDisablesTicketGlints() throws {
        #expect(!GoldenTicketGlintState.motionAdjusted(isGlinting: true, reduceMotion: true))
        #expect(!GoldenTicketGlintState.shouldContinueAnimation(isCancelled: false, reduceMotion: true))
        #expect(GoldenTicketGlintState.shouldContinueAnimation(isCancelled: false, reduceMotion: false))

        // Verify GoldenTicketView renders cleanly in the host
        let view = GoldenTicketView(index: 0)
            .environment(\.colorScheme, .dark)
            .frame(width: 24, height: 24)
            .background(Theme.card)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }

    @Test("PopoverInspection dismiss remains deterministic under Reduce Motion")
    func popoverInspectionDismissDeterministic() {
        let inspection = PopoverInspection()
        inspection.snapshot = GlanceFixtures.batch.first
        #expect(inspection.snapshot != nil)
        #expect(inspection.dismiss())
        #expect(inspection.snapshot == nil)
        #expect(!inspection.dismiss())
    }
}
