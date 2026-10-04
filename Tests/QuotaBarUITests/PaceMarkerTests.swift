import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

/// One definition of what a window's pace may claim; the tick, the legend, the
/// colour, the tooltip and the spoken label all read it.
@Suite("Pace marker")
struct PaceMarkerTests {

    private let reset = Date(timeIntervalSince1970: 1_900_000_000)

    private func bar(
        used: Double? = 0.3, pace: Double? = 0.5, blocked: Bool = false,
        reset hasReset: Bool = true, window: TimeInterval? = QuotaWindow.week
    ) -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: used, expectedPaceFraction: pace, label: "WK", isBlocked: blocked,
            resetsAt: hasReset ? reset : nil, windowLength: window)
    }

    // MARK: Published pace

    @Test("a pace needs the reset and a positive window length behind it")
    func needsBoth() {
        #expect(bar().evenPace == 0.5)
        #expect(bar(reset: false).evenPace == nil)
        #expect(bar(window: nil).evenPace == nil)
        #expect(bar(window: 0).evenPace == nil)
        #expect(bar(pace: nil).evenPace == nil)
        #expect(bar(reset: false).paceMarker == nil)
        #expect(bar(window: nil).paceMarker == nil)
    }

    // MARK: Marker eligibility

    @Test("the marker is drawn for an ordinary window, and clamped into the track")
    func drawn() {
        #expect(bar(pace: 0.5).paceMarker == 0.5)
        #expect(bar(used: nil, pace: 0.5).paceMarker == 0.5)      // a pace is a fact about time, not usage
    }

    @Test("no marker at either end of the track")
    func notAtTheEnds() {
        #expect(bar(pace: 0).paceMarker == nil)
        #expect(bar(pace: 1).paceMarker == nil)
        #expect(bar(pace: 1.4).paceMarker == nil)
    }

    @Test("no marker on a spent window")
    func notWhenSpent() {
        #expect(bar(used: 1.0).paceMarker == nil)
        #expect(bar(used: 0.9995).paceMarker == nil)
        #expect(bar(used: 0.99).paceMarker == 0.5)
    }

    @Test("no marker on a blocked window with no reading; one with a reading keeps it")
    func blocked() {
        #expect(bar(used: nil, blocked: true).paceMarker == nil)
        #expect(bar(used: 0.9, blocked: true).paceMarker == 0.5)
    }

    // MARK: Ahead of pace

    @Test("ahead means past the model's margin, never for a blocked window")
    func ahead() {
        #expect(bar(used: 0.30, pace: 0.10).isMeaningfullyAheadOfPace)
        #expect(!bar(used: 0.13, pace: 0.10).isMeaningfullyAheadOfPace)
        #expect(!bar(used: 0.05, pace: 0.10).isMeaningfullyAheadOfPace)
        #expect(!bar(used: 0.30, pace: 0.10, blocked: true).isMeaningfullyAheadOfPace)
        #expect(!bar(used: nil, pace: 0.10).isMeaningfullyAheadOfPace)
        // No published pace, no claim.
        #expect(!bar(used: 0.30, pace: 0.10, reset: false).isMeaningfullyAheadOfPace)
    }

    @Test("the colour, tooltip and spoken label share the model's margin")
    func oneMargin() {
        #expect(DualBarMetrics.aheadOfPaceMargin == 0.04)
        #expect(bar(used: 0.15, pace: 0.10).isAboveProrataPace == bar(used: 0.15, pace: 0.10).isMeaningfullyAheadOfPace)
    }

    // MARK: Legend

    private func snapshot(_ bars: [DualBarMetrics]) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "x", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil), status: .healthy,
            resetsAt: nil, lastUpdated: reset, auxiliaryInfo: nil,
            row1: bars.indices.contains(0) ? bars[0] : nil,
            row2: bars.indices.contains(1) ? bars[1] : nil,
            row3: bars.indices.contains(2) ? bars[2] : nil)
    }

    /// The legend names the tick, so it must not appear when no bar draws one.
    @Test("the legend shows only when some bar draws a marker")
    func legend() {
        #expect(MetricSectionView.showsPaceLegend(for: [snapshot([bar()])]))
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([])]))
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([bar(pace: nil)])]))
        // A pace is set, but every marker is suppressed.
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([bar(pace: 0)])]))
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([bar(pace: 1)])]))
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([bar(used: 1.0)])]))
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([bar(used: nil, blocked: true)])]))
        #expect(!MetricSectionView.showsPaceLegend(for: [snapshot([bar(reset: false)])]))
        // One drawn marker anywhere in the section is enough.
        #expect(MetricSectionView.showsPaceLegend(for: [snapshot([bar(used: 1.0)]), snapshot([bar()])]))
    }

    // MARK: Tooltip agrees with the colour

    @Test("the tooltip calls a window ahead only when its fill is amber")
    func tooltip() {
        func help(_ used: Double, _ pace: Double) -> String { DualBarProgressView.helpText(for: bar(used: used, pace: pace)) }
        // 6% used against 2% elapsed is green, so it must not read as overuse.
        #expect(help(0.06, 0.02).contains("close to an even pace"))
        #expect(!help(0.06, 0.02).contains("ahead"))
        #expect(help(0.30, 0.10).contains("20% ahead of an even pace"))
        #expect(help(0.10, 0.50).contains("40% behind an even pace"))
        #expect(!help(0.30, 0.10).contains("overuse"))
    }

    @Test("the tooltip makes no pace claim for a blocked, spent or unbacked window")
    func tooltipSilentCases() {
        func help(_ m: DualBarMetrics) -> String { DualBarProgressView.helpText(for: m) }
        #expect(!help(bar(used: 0.9, pace: 0.2, blocked: true)).contains("even pace"))
        #expect(!help(bar(used: 1.0, pace: 0.2)).contains("even pace"))
        #expect(!help(bar(used: 0.9, pace: 0.2, reset: false)).contains("even pace"))
    }
}
