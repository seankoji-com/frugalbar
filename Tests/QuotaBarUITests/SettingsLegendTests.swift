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
@Suite("Settings legend")
@MainActor
struct SettingsLegendTests {

    private var everyEntry: [SettingsView.LegendEntry] {
        SettingsView.statusLegend + SettingsView.windowLegend
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

    @Test("status entries use the inspector's own words, shapes and colours")
    func statusMatchesInspector() {
        let states: [MetricDetailPresentation.State] = [.healthy, .runningLow, .critical, .exhausted, .blocked]
        for state in states {
            let label = MetricDetailPresentation.headlineAndSymbol(for: state)
            let entry = SettingsView.statusLegend.first { $0.title == label.headline }
            #expect(entry?.symbol == label.symbol, "\(label.headline)")
            #expect(entry?.tint == MetricDetailModalView.color(for: state), "\(label.headline)")
        }
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
