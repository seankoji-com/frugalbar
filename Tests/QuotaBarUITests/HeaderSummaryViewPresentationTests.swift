import Testing
import Foundation
import SwiftUI
import QuotaBarCore
@testable import QuotaBarUI

/// Tests for the pure-logic presentation mapping on SystemHealthPresentation.
///
/// These call `SystemHealthPresentation.symbol(for:)`, `.color(for:)`,
/// `.text(for:)`, and `.elapsed(since:)` directly — the same production
/// statics both the header and footer render — so a future refactor that
/// changes the mapping is caught here rather than only in a re-derived copy
/// that could silently drift from the real logic.
@Suite("HeaderSummaryView — presentation logic")
struct HeaderSummaryViewPresentationTests {
    /// Build a summary from snapshots rather than calling the internal init.
    private func summary(
        snapshots: [(status: ProviderStatus, lastUpdated: Date)]
    ) -> SystemHealthSummary {
        let snaps: [QuotaSnapshot] = snapshots.enumerated().map { i, s in
            QuotaSnapshot(
                id: "v\(i)", vendorId: VendorIdentifier.allCases[i % VendorIdentifier.allCases.count],
                displayName: "V\(i)", category: .aiSubscriptions,
                metric: .subscription(tierName: "x", renewalDate: nil),
                status: s.status,
                resetsAt: nil, lastUpdated: s.lastUpdated, auxiliaryInfo: nil
            )
        }
        return SystemHealthSummary.compute(from: snaps)
    }

    // MARK: - healthSymbol

    @Test("symbol: no readings → minus.circle")
    func symbolNoReadings() {
        let s = summary(snapshots: [
            (.unavailable(.notConfigured), Date())
        ])
        #expect(SystemHealthPresentation.symbol(for: s) == "minus.circle")
    }

    @Test("symbol: all healthy → checkmark.circle.fill")
    func symbolAllHealthy() {
        let s = summary(snapshots: [
            (.healthy, Date())
        ])
        #expect(SystemHealthPresentation.symbol(for: s) == "checkmark.circle.fill")
    }

    @Test("symbol: warning → exclamationmark.circle.fill")
    func symbolWarning() {
        let s = summary(snapshots: [
            (.warning, Date())
        ])
        #expect(SystemHealthPresentation.symbol(for: s) == "exclamationmark.circle.fill")
    }

    @Test("symbol: critical → exclamationmark.octagon.fill")
    func symbolCritical() {
        let s = summary(snapshots: [
            (.critical, Date())
        ])
        #expect(SystemHealthPresentation.symbol(for: s) == "exclamationmark.octagon.fill")
    }

    // MARK: - healthColor

    @Test("color: no readings → Theme.outline")
    func colorNoReadings() {
        let s = summary(snapshots: [
            (.unavailable(.offline), Date())
        ])
        #expect(SystemHealthPresentation.color(for: s) == Theme.outline)
    }

    @Test("color: healthy → Theme.secondary")
    func colorHealthy() {
        let s = summary(snapshots: [
            (.healthy, Date())
        ])
        #expect(SystemHealthPresentation.color(for: s) == Theme.secondary)
    }

    @Test("color: warning → Theme.tertiary")
    func colorWarning() {
        let s = summary(snapshots: [
            (.warning, Date())
        ])
        #expect(SystemHealthPresentation.color(for: s) == Theme.tertiary)
    }

    @Test("color: critical → Theme.error")
    func colorCritical() {
        let s = summary(snapshots: [
            (.critical, Date())
        ])
        #expect(SystemHealthPresentation.color(for: s) == Theme.error)
    }

    // MARK: - healthText

    @Test("text: no readings → 'No readings'")
    func textNoReadings() {
        let s = summary(snapshots: [
            (.unavailable(.notConfigured), Date()),
            (.unavailable(.offline), Date()),
        ])
        #expect(SystemHealthPresentation.text(for: s) == "No readings · 2 not readable")
    }

    @Test("text: no readings, zero unavailable → 'No readings' without unavailable count")
    func textNoReadingsNoUnavailable() {
        let s = summary(snapshots: [])
        #expect(SystemHealthPresentation.text(for: s) == "No readings")
    }

    @Test("text: all healthy → 'All quotas healthy'")
    func textAllHealthy() {
        let s = summary(snapshots: [
            (.healthy, Date()),
            (.healthy, Date()),
            (.healthy, Date()),
        ])
        #expect(SystemHealthPresentation.text(for: s) == "All quotas healthy")
    }

    @Test("text: warning → 'N running low'")
    func textWarning() {
        let s = summary(snapshots: [
            (.warning, Date()),
            (.warning, Date()),
            (.healthy, Date()),
        ])
        #expect(SystemHealthPresentation.text(for: s) == "2 running low")
    }

    @Test("text: critical → 'N critical'")
    func textCritical() {
        let s = summary(snapshots: [
            (.critical, Date()),
            (.healthy, Date()),
        ])
        #expect(SystemHealthPresentation.text(for: s) == "1 critical")
    }

    @Test("text: healthy + unavailable → appended")
    func textHealthyWithUnavailable() {
        let s = summary(snapshots: [
            (.healthy, Date()),
            (.healthy, Date()),
            (.healthy, Date()),
            (.healthy, Date()),
            (.healthy, Date()),
            (.unavailable(.notConfigured), Date()),
        ])
        #expect(SystemHealthPresentation.text(for: s) == "All quotas healthy · 1 not readable")
    }

    @Test("text: warning + unavailable → appended")
    func textWarningWithUnavailable() {
        let s = summary(snapshots: [
            (.warning, Date()),
            (.unavailable(.notConfigured), Date()),
            (.unavailable(.offline), Date()),
        ])
        #expect(SystemHealthPresentation.text(for: s) == "1 running low · 2 not readable")
    }

    // MARK: - elapsed

    /// Every elapsed case pins an explicit `now` rather than letting the
    /// helper read the clock: asserting on a duration derived from a live
    /// `Date()` makes the boundary cases ("59s", "3599s") flake whenever the
    /// machine stalls half a second between building the input and reading it.
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func ago(_ seconds: TimeInterval) -> String {
        SystemHealthPresentation.elapsed(since: Self.now.addingTimeInterval(-seconds), now: Self.now)
    }

    @Test("elapsed: 0s rounds to 0s")
    func elapsedZero() {
        #expect(ago(0) == "0s")
    }

    @Test("elapsed: 5s → '5s'")
    func elapsedSeconds() {
        #expect(ago(5) == "5s")
    }

    @Test("elapsed: 30s → '30s'")
    func elapsedThirtySeconds() {
        #expect(ago(30) == "30s")
    }

    @Test("elapsed: 59s → '59s' (still seconds)")
    func elapsedFiftyNineSeconds() {
        #expect(ago(59) == "59s")
    }

    @Test("elapsed: 60s → '1m'")
    func elapsedOneMinute() {
        #expect(ago(60) == "1m")
    }

    @Test("elapsed: 150s → '3m'")
    func elapsedMinutes() {
        #expect(ago(150) == "3m")
    }

    @Test("elapsed: 3599s → '60m' (still minutes)")
    func elapsedFiftyNineMinutes() {
        #expect(ago(3599) == "60m")
    }

    @Test("elapsed: 3600s → '1h'")
    func elapsedOneHour() {
        #expect(ago(3600) == "1h")
    }

    @Test("elapsed: 7200s → '2h'")
    func elapsedTwoHours() {
        #expect(ago(7200) == "2h")
    }

    @Test("elapsed: future date returns 0s (clamped to 0)")
    func elapsedFutureDate() {
        #expect(ago(-300) == "0s")
    }
}
