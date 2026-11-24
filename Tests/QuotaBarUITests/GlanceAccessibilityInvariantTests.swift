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

            // Exhausted countdown badge small text (9.5pt white on Theme.errorBadge)
            ("exhausted countdown badge white text on errorBadge", hex(0xffffff), resolve(Theme.errorBadge)),
            // Blocked / exhausted inspector headline (14.5pt semibold) on tinted errorBold summary card
            ("blocked inspector headline on tinted errorBold card",
             resolve(MetricDetailModalView.headlineColor(for: .blocked, warnsEarlyRunOut: false)),
             resolve(Theme.errorBold.opacity(0.12)).over(card)),
            // Stale reset caption on expanded row surface (full opacity Theme.outline)
            ("stale reset caption (outline) on expandedRow", resolve(Theme.outline), resolve(Theme.surfaceContainerHighest.opacity(0.22)).over(card)),

            // Menu bar caveat & critical text on dark and light menu bars
            ("MenuBar caveat on dark menu bar", resolveNSColor(MenuBarGlance.color(for: .caveat), appearance: .darkAqua), card),
            ("MenuBar caveat on light menu bar (#f0f0f0)", resolveNSColor(MenuBarGlance.color(for: .caveat), appearance: .aqua), hex(0xf0f0f0)),
            ("MenuBar caveat on white menu bar", resolveNSColor(MenuBarGlance.color(for: .caveat), appearance: .aqua), hex(0xffffff)),
            ("MenuBar critical on dark menu bar", resolveNSColor(MenuBarGlance.color(for: .critical), appearance: .darkAqua), card),
            ("MenuBar critical on light menu bar (#f0f0f0)", resolveNSColor(MenuBarGlance.color(for: .critical), appearance: .aqua), hex(0xf0f0f0)),
            ("MenuBar critical on white menu bar", resolveNSColor(MenuBarGlance.color(for: .critical), appearance: .aqua), hex(0xffffff)),

            // Inspector segmented control text (selected dark text on primary pill; unselected on well)
            ("chart mode selected text on primary pill", resolve(Theme.surfaceContainerLowest), resolve(Theme.primary)),
            ("chart mode unselected text on well", resolve(Theme.onSurfaceVariant), containerLowest),

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
            ("errorBold fill on track", resolve(Theme.errorBold), track),
            ("errorBold fill on surface", resolve(Theme.errorBold), surface),
            ("errorBold fill on inspectorInnerCard", resolve(Theme.errorBold), inspectorInnerCard),
            ("primary fill on card", resolve(Theme.primary), card),
            ("primary fill on track", resolve(Theme.primary), track),
            ("pace marker (onSurface) on track", resolve(Theme.onSurface), track),
            // Over a fill the tick's knockout (Theme.surface) is its edge.
            ("pace marker knockout on healthy fill", resolve(Theme.surface), resolve(Theme.healthy)),
            ("pace marker knockout on tertiary fill", resolve(Theme.surface), resolve(Theme.tertiary)),
            ("pace marker knockout on error fill", resolve(Theme.surface), resolve(Theme.error)),
            // A spent track's stripes against their own wash, and against the
            // row (hovered included), which carries the bar's shape.
            ("spent stripes on spent wash (card)", resolve(Theme.errorBold),
             resolve(Theme.errorBold.opacity(SpentTrack.baseOpacity)).over(card)),
            ("spent stripes on spent wash (row hover)", resolve(Theme.errorBold),
             resolve(Theme.errorBold.opacity(SpentTrack.baseOpacity)).over(resolve(Theme.rowHover).over(card))),
            ("elapsed meter outline on card", resolve(Theme.primary.opacity(GlanceColors.elapsedOutlineOpacity)).over(card), card),
            ("pace marker knockout on stale healthy fill",
             resolve(Theme.surface), resolve(Theme.healthy.opacity(0.55)).over(card)),
            ("chart mode selected pill (primary) on well", resolve(Theme.primary), resolve(Theme.surfaceContainerLowest)),
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

    @Test("PopoverInspection and FooterActionsView disable motion under Reduce Motion")
    func reduceMotionDisablesInspectorAndRefreshMotion() {
        // Inspector open/close animations & scale transition
        #expect(PopoverInspection.openAnimation(reduceMotion: true) == nil)
        #expect(PopoverInspection.closeAnimation(reduceMotion: true) == nil)
        #expect(!PopoverInspection.usesScaleTransition(reduceMotion: true))
        #expect(PopoverInspection.openAnimation(reduceMotion: false) != nil)
        #expect(PopoverInspection.closeAnimation(reduceMotion: false) != nil)
        #expect(PopoverInspection.usesScaleTransition(reduceMotion: false))

        let inspection = PopoverInspection()
        inspection.snapshot = GlanceFixtures.batch.first
        #expect(inspection.snapshot != nil)
        #expect(inspection.dismiss(reduceMotion: true))
        #expect(inspection.snapshot == nil)
        #expect(!inspection.dismiss(reduceMotion: true))

        // Footer refresh icon rotation
        #expect(FooterActionsView.refreshRotationDegrees(isRefreshing: true, reduceMotion: true) == 0)
        #expect(FooterActionsView.refreshAnimation(isRefreshing: true, reduceMotion: true) == nil)
        #expect(FooterActionsView.refreshRotationDegrees(isRefreshing: true, reduceMotion: false) == 360)
        #expect(FooterActionsView.refreshAnimation(isRefreshing: true, reduceMotion: false) != nil)
    }

    @Test("Stale Wallet credit rows preserve freshness in spoken labels")
    func staleWalletCreditRowsSpeakFreshness() {
        let now = Date(timeIntervalSinceReferenceDate: 790_000_000)
        var claude = GlanceFixtures.snapshot(
            "claude-stale", .claude, "Claude", plan: "Max",
            [GlanceFixtures.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)]
        )
        claude.apiCredits = [
            APICreditEntry(
                id: "claude-stale|claude.extra-usage",
                vendorId: .claude,
                label: "Extra usage",
                metric: .currency(balance: 42, limit: 200, spent: nil, currencyCode: "USD"),
                poolID: "claude.extra-usage",
                accountID: claude.id
            )
        ]
        claude.staleReading = StaleReading(reason: .offline, at: now)

        let wallet = WalletPresentation(snapshots: [claude], now: now)
        #expect(wallet.rows.count == 1)
        #expect(wallet.rows[0].tag == "last reading")
        #expect(wallet.rows[0].spoken.localizedCaseInsensitiveContains("stale"))
        #expect(wallet.rows[0].spoken.localizedCaseInsensitiveContains("last poll failed"))
    }

    @Test("Inspector forecast verdict warns only on early run-out and preserves spoken facts")
    func inspectorForecastVerdictOnlyWarnsOnEarlyRunOutAndPreservesSpeech() throws {
        let now = Date(timeIntervalSinceReferenceDate: 790_000_000)
        // Behind pace: 20% used at 50% elapsed -> lasts until the reset (must NOT warn)
        let lastingBar = DualBarMetrics(
            primaryFraction: 0.20,
            expectedPaceFraction: 0.50,
            label: "WK",
            resetsAt: now.addingTimeInterval(84 * 3600),
            windowLength: 168 * 3600
        )
        let lastingResult = try #require(InspectorRunOut.compute(for: lastingBar, snapshotID: "c1", readings: nil, now: now))
        #expect(!lastingResult.runsOutBeforeReset)
        #expect(lastingResult.text.contains("lasts until the reset"))

        // Ahead of pace: 58% used at 28% elapsed -> runs out before reset (MUST warn)
        let earlyBar = DualBarMetrics(
            primaryFraction: 0.58,
            expectedPaceFraction: 0.28,
            label: "WK",
            resetsAt: now.addingTimeInterval(120 * 3600),
            windowLength: 168 * 3600
        )
        let earlyResult = try #require(InspectorRunOut.compute(for: earlyBar, snapshotID: "c2", readings: nil, now: now))
        #expect(earlyResult.runsOutBeforeReset)
        #expect(earlyResult.text.contains("before the reset"))

        let snap = GlanceFixtures.snapshot("c2", .claude, "Primary", plan: "Max", [earlyBar])
        let detail = MetricDetailPresentation(snapshot: snap, now: now)
        let spoken = MetricDetailModalView.summaryAccessibilityLabel(
            summary: detail.summary,
            warnsEarlyRunOut: true,
            isAheadOfPace: true,
            runOutText: earlyResult.text
        )
        #expect(spoken.contains("Primary"))
        #expect(spoken.contains("On track to run out"))
        #expect(!spoken.contains("Healthy"))
        #expect(spoken.contains("58 percent used"))
        #expect(spoken.contains("Resets in"))
        #expect(spoken.contains("before the reset"))

        // Unknown reset with rising recent history: must NOT set runsOutBeforeReset or claim "before the reset"
        let undatedBar = DualBarMetrics(primaryFraction: 0.58, label: "5H")
        let undatedReadings = (0..<4).map { i in
            QuotaHistoryStore.ReadingRecord(
                vendor: "opencode-go", barLabel: "5H",
                measuredAt: now.addingTimeInterval(-Double(30 - i * 10) * 60),
                fraction: 0.40 + Double(i) * 0.06,
                isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: nil, elapsedOnly: false
            )
        }
        let undatedResult = try #require(InspectorRunOut.compute(for: undatedBar, snapshotID: "opencode-go", readings: undatedReadings, now: now))
        #expect(!undatedResult.runsOutBeforeReset)
        #expect(!undatedResult.text.contains("before the reset"))
    }

    @Test("Collapsed group subtitle distinguishes vendor-blocked pools from exhausted ones")
    func collapsedGroupSubtitleDistinguishesBlockedFromSpent() {
        let now = Date(timeIntervalSinceReferenceDate: 790_000_000)
        let blockedBar = DualBarMetrics(
            primaryFraction: 0.40,
            label: "MO",
            isBlocked: true,
            resetsAt: now.addingTimeInterval(48 * 3600),
            windowLength: 30 * 86_400
        )
        let blockedSnap = GlanceFixtures.snapshot("opencode", .opencode, "OpenCode Go", [blockedBar])
        let exhaustedBar = DualBarMetrics(
            primaryFraction: 1.0,
            label: "WK",
            resetsAt: now.addingTimeInterval(24 * 3600),
            windowLength: 168 * 3600
        )
        let exhaustedSnap = GlanceFixtures.snapshot("claude-spent", .claude, "Secondary", [exhaustedBar])
        let grid = ProviderGridPresentation(snapshots: [blockedSnap, exhaustedSnap], serviceOrder: [.deepseek, .claude], now: now)
        #expect(grid.groups.first(where: { $0.id == .deepseek })?.subtitle == "1 blocked")
        #expect(grid.groups.first(where: { $0.id == .claude })?.subtitle == "1 spent")
    }
}
