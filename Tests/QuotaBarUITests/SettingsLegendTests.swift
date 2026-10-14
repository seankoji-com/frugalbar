import Testing
import Foundation
import SwiftUI
import AppKit
import QuotaBarCore
@testable import QuotaBarUI

/// Settings' "Reading the popover" legend once defined Healthy, Running low and
/// Critically low as below 70%, past 70% and past 90% of a window. OpenCode Go,
/// Copilot, Kiro and others warn at 80% and 95%, and OpenRouter and DeepSeek
/// warn on an absolute credit balance with no window at all, so the legend
/// contradicted the providers it explained. It also described provider status
/// and window colours as one scale, when a bar's colour follows pace instead.
/// Then it called the inspector's shapes "the shape beside each provider",
/// when the popover's logo draws no checkmark, strikes an exhausted logo
/// through rather than badging it, and badges a blocked window by the
/// provider's level.
@Suite("Settings legend")
@MainActor
struct SettingsLegendTests {

    private func snapshot(status: ProviderStatus, bars: [DualBarMetrics] = []) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "opencode", vendorId: .opencode, displayName: "Go Alpha", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.4, displayDetails: nil), status: status, resetsAt: nil,
            lastUpdated: Date(timeIntervalSinceReferenceDate: 0), auxiliaryInfo: nil,
            row1: bars.first, row2: bars.dropFirst().first)
    }

    private var everyEntry: [SettingsView.LegendEntry] {
        SettingsView.popoverLegend + SettingsView.detailLegend + SettingsView.windowLegend
    }

    /// No universal threshold, percentage or amount: each provider sets its
    /// own, so any single figure is wrong for some of them.
    @Test("the legend quotes no threshold")
    func noFigures() {
        for entry in everyEntry {
            let text = entry.title + " " + entry.detail
            let hasDigit = text.contains { $0.isNumber }
            #expect(!hasDigit, "\(entry.title): \(entry.detail)")
            #expect(!text.contains("%"), "\(entry.title): \(entry.detail)")
            #expect(!text.contains("$"), "\(entry.title): \(entry.detail)")
        }
    }

    @Test("every legend symbol exists, so no entry loses its shape")
    func symbolsResolve() {
        for entry in everyEntry {
            #expect(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil, "\(entry.symbol)")
        }
    }

    @Test("usage-details entries use the inspector's own words, shapes and colours")
    func detailMatchesInspector() {
        let states: [MetricDetailPresentation.State] = [.healthy, .runningLow, .critical, .exhausted, .blocked]
        for state in states {
            let label = MetricDetailPresentation.headlineAndSymbol(for: state)
            let entry = SettingsView.detailLegend.first { $0.title == label.headline }
            #expect(entry?.symbol == label.symbol, "\(label.headline)")
            #expect(entry?.tint == MetricDetailModalView.color(for: state), "\(label.headline)")
        }
        // The two no-reading states, by the shape the inspector leads with.
        let failed = MetricDetailPresentation.summary(
            for: snapshot(status: .healthy), failedPollAt: Date(timeIntervalSinceReferenceDate: 60),
            now: Date(timeIntervalSinceReferenceDate: 120))
        let unread = MetricDetailPresentation.summary(
            for: snapshot(status: .unavailable(.notConfigured)), now: Date(timeIntervalSinceReferenceDate: 0))
        for summary in [failed, unread] {
            let entry = SettingsView.detailLegend.first { $0.symbol == summary.symbol }
            #expect(entry != nil, "\(summary.headline)")
            #expect(entry?.tint == MetricDetailModalView.color(for: summary.state), "\(summary.headline)")
        }
    }

    /// Each popover entry against what `VendorAvatarView` draws for a row in
    /// that state, worked out here from `StatusIndicatorDot`'s own rules and
    /// `MetricRowPresentation.isExhausted`, not from the legend's helper.
    @Test("popover entries show the mark the row's logo draws")
    func popoverMatchesAvatar() {
        func entry(_ title: String) -> SettingsView.LegendEntry? {
            SettingsView.popoverLegend.first { $0.title == title }
        }
        func badge(_ status: ProviderStatus) -> (String, Color) {
            (StatusIndicatorDot.symbol(for: status), StatusIndicatorDot.tint(for: status))
        }

        // Healthy draws no badge, so the legend must not show its checkmark.
        #expect(!StatusIndicatorDot.shouldShowIndicator(for: .healthy))
        #expect(entry("No mark")?.symbol == SettingsView.noMarkSymbol)
        #expect(!SettingsView.popoverLegend.contains { $0.symbol == StatusIndicatorDot.symbol(for: .healthy) })

        for (title, status) in [("Running low", ProviderStatus.warning),
                                ("Critically low", .critical),
                                ("Could not be read", .unavailable(.notConfigured))] {
            #expect(StatusIndicatorDot.shouldShowIndicator(for: status))
            #expect(entry(title)?.symbol == badge(status).0, "\(title)")
            #expect(entry(title)?.tint == badge(status).1, "\(title)")
        }

        // A spent window and an account blocked without a figure both strike
        // the logo through, whatever the status, and draw no badge.
        let spent = MetricRowPresentation(snapshot: snapshot(status: .critical, bars: [
            DualBarMetrics(primaryFraction: 1, label: "WK")]))
        let cutOff = MetricRowPresentation(snapshot: snapshot(status: .critical, bars: [
            DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true)]))
        #expect(spent.isExhausted && cutOff.isExhausted)
        for status in [ProviderStatus.healthy, .warning, .critical] {
            #expect(VendorAvatarView.overlay(status: status, isExhausted: true) == .struckThrough)
        }
        #expect(entry("Logo struck through")?.symbol == "xmark")
        #expect(entry("Logo struck through")?.tint == Theme.error)

        // A blocked window that still reports a figure is badged by the
        // provider's level (OpenCode Go goes critical), not by a blocked
        // sign: that is the difference the usage-details footer names.
        let blocked = snapshot(status: .critical, bars: [
            DualBarMetrics(primaryFraction: 0.4, label: "WK", isBlocked: true)])
        #expect(!MetricRowPresentation(snapshot: blocked).isExhausted)
        #expect(VendorAvatarView.overlay(status: blocked.status, isExhausted: false)
                == .badge(symbol: entry("Critically low")?.symbol ?? "", tint: entry("Critically low")?.tint ?? .clear))
        #expect(!SettingsView.popoverLegend.contains { $0.symbol == BlockedGlyph.symbolName })
        #expect(MetricDetailPresentation.summary(for: blocked, now: Date(timeIntervalSinceReferenceDate: 0)).state == .blocked)
    }

    /// The bar draws a coloured fill, the blocked sign, a dash for an
    /// unpublished column and an upright tick. Any other glyph in this section
    /// (a status badge's octagon, a triangle for the tick) would be a shape
    /// no bar carries.
    @Test("window entries use only shapes a bar's cell draws")
    func windowShapes() {
        let drawn: Set<String> = [SettingsView.fillSymbol, BlockedGlyph.symbolName, "minus", SettingsView.tickSymbol]
        for entry in SettingsView.windowLegend {
            #expect(drawn.contains(entry.symbol), "\(entry.title): \(entry.symbol)")
        }
        let statusShapes = Set((SettingsView.popoverLegend + SettingsView.detailLegend).map(\.symbol))
            .subtracting([BlockedGlyph.symbolName])
        #expect(Set(SettingsView.windowLegend.map(\.symbol)).isDisjoint(with: statusShapes))
    }

    /// Each sample must land in the branch its entry names, or the legend
    /// would show two swatches of one colour under different meanings.
    @Test("each window swatch is the colour a bar in that state is drawn")
    func windowSwatches() {
        let onPace = SettingsView.LegendSample.onPace
        let ahead = SettingsView.LegendSample.aheadOfPace
        let spent = SettingsView.LegendSample.spent
        #expect(onPace.paceMarker != nil && !onPace.isMeaningfullyAheadOfPace)
        #expect(ahead.isMeaningfullyAheadOfPace)
        #expect((spent.primaryFraction ?? 0) >= QuotaSnapshot.exhaustionThreshold)
        #expect(SettingsView.LegendSample.blocked.isBlocked)

        let colours = [onPace, ahead, spent].map(DualBarProgressView.stateColor(for:))
        #expect(Set(colours.map(\.description)).count == 3)
        #expect(colours[0] == Theme.healthy)
    }

    /// The footer's claim that a bar can stay green while its provider runs
    /// low: a window far past any provider's warning level, at an even pace,
    /// is drawn in the healthy colour.
    @Test("a full window at an even pace is drawn green")
    func colourFollowsPaceNotLevel() {
        let bar = DualBarMetrics(
            primaryFraction: 0.97, expectedPaceFraction: 0.96, label: "WK",
            resetsAt: Date(timeIntervalSinceReferenceDate: 0), windowLength: QuotaWindow.week)
        #expect(DualBarProgressView.stateColor(for: bar) == Theme.healthy)
    }
}
