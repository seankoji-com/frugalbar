import Testing
import Foundation
import SwiftUI
import QuotaBarCore
@testable import QuotaBarUI

/// Tests for the pure-logic derived properties in HeaderSummaryView.
///
/// The view's `healthSymbol`, `healthColor`, `healthText`, and `elapsed(_:)`
/// are private. We re-derive the same logic here as contract tests.
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
        #expect(healthSymbol(for: s) == "minus.circle")
    }

    @Test("symbol: all healthy → checkmark.circle.fill")
    func symbolAllHealthy() {
        let s = summary(snapshots: [
            (.healthy, Date())
        ])
        #expect(healthSymbol(for: s) == "checkmark.circle.fill")
    }

    @Test("symbol: warning → exclamationmark.circle.fill")
    func symbolWarning() {
        let s = summary(snapshots: [
            (.warning, Date())
        ])
        #expect(healthSymbol(for: s) == "exclamationmark.circle.fill")
    }

    @Test("symbol: critical → exclamationmark.octagon.fill")
    func symbolCritical() {
        let s = summary(snapshots: [
            (.critical, Date())
        ])
        #expect(healthSymbol(for: s) == "exclamationmark.octagon.fill")
    }

    // MARK: - healthColor

    @Test("color: no readings → secondary")
    func colorNoReadings() {
        let s = summary(snapshots: [
            (.unavailable(.offline), Date())
        ])
        #expect(healthColor(for: s) == .secondary)
    }

    @Test("color: healthy → green")
    func colorHealthy() {
        let s = summary(snapshots: [
            (.healthy, Date())
        ])
        #expect(healthColor(for: s) == .green)
    }

    @Test("color: warning → orange")
    func colorWarning() {
        let s = summary(snapshots: [
            (.warning, Date())
        ])
        #expect(healthColor(for: s) == .orange)
    }

    @Test("color: critical → red")
    func colorCritical() {
        let s = summary(snapshots: [
            (.critical, Date())
        ])
        #expect(healthColor(for: s) == .red)
    }

    // MARK: - healthText

    @Test("text: no readings → 'No readings'")
    func textNoReadings() {
        let s = summary(snapshots: [
            (.unavailable(.notConfigured), Date()),
            (.unavailable(.offline), Date()),
        ])
        #expect(healthText(for: s) == "No readings · 2 not readable")
    }

    @Test("text: no readings, zero unavailable → 'No readings' without unavailable count")
    func textNoReadingsNoUnavailable() {
        let s = summary(snapshots: [])
        #expect(healthText(for: s) == "No readings")
    }

    @Test("text: all healthy → 'All quotas healthy'")
    func textAllHealthy() {
        let s = summary(snapshots: [
            (.healthy, Date()),
            (.healthy, Date()),
            (.healthy, Date()),
        ])
        #expect(healthText(for: s) == "All quotas healthy")
    }

    @Test("text: warning → 'N running low'")
    func textWarning() {
        let s = summary(snapshots: [
            (.warning, Date()),
            (.warning, Date()),
            (.healthy, Date()),
        ])
        #expect(healthText(for: s) == "2 running low")
    }

    @Test("text: critical → 'N critical'")
    func textCritical() {
        let s = summary(snapshots: [
            (.critical, Date()),
            (.healthy, Date()),
        ])
        #expect(healthText(for: s) == "1 critical")
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
        #expect(healthText(for: s) == "All quotas healthy · 1 not readable")
    }

    @Test("text: warning + unavailable → appended")
    func textWarningWithUnavailable() {
        let s = summary(snapshots: [
            (.warning, Date()),
            (.unavailable(.notConfigured), Date()),
            (.unavailable(.offline), Date()),
        ])
        #expect(healthText(for: s) == "1 running low · 2 not readable")
    }

    // MARK: - elapsed

    @Test("elapsed: 0s rounds to 0s")
    func elapsedZero() {
        #expect(elapsed(since: Date()) == "0s")
    }

    @Test("elapsed: 5s → '5s'")
    func elapsedSeconds() {
        let d = Date().addingTimeInterval(-5)
        #expect(elapsed(since: d) == "5s")
    }

    @Test("elapsed: 30s → '30s'")
    func elapsedThirtySeconds() {
        let d = Date().addingTimeInterval(-30)
        #expect(elapsed(since: d) == "30s")
    }

    @Test("elapsed: 59s → '59s' (still seconds)")
    func elapsedFiftyNineSeconds() {
        let d = Date().addingTimeInterval(-59)
        #expect(elapsed(since: d) == "59s")
    }

    @Test("elapsed: 60s → '1m'")
    func elapsedOneMinute() {
        let d = Date().addingTimeInterval(-60)
        #expect(elapsed(since: d) == "1m")
    }

    @Test("elapsed: 150s → '3m'")
    func elapsedMinutes() {
        let d = Date().addingTimeInterval(-150)
        #expect(elapsed(since: d) == "3m")
    }

    @Test("elapsed: 3599s → '60m' (still minutes)")
    func elapsedFiftyNineMinutes() {
        let d = Date().addingTimeInterval(-3599)
        #expect(elapsed(since: d) == "60m")
    }

    @Test("elapsed: 3600s → '1h'")
    func elapsedOneHour() {
        let d = Date().addingTimeInterval(-3600)
        #expect(elapsed(since: d) == "1h")
    }

    @Test("elapsed: 7200s → '2h'")
    func elapsedTwoHours() {
        let d = Date().addingTimeInterval(-7200)
        #expect(elapsed(since: d) == "2h")
    }

    @Test("elapsed: future date returns 0s (clamped to 0)")
    func elapsedFutureDate() {
        let d = Date().addingTimeInterval(300)
        #expect(elapsed(since: d) == "0s")
    }

    // MARK: - Helpers (re-derive the same logic from HeaderSummaryView)

    private func healthSymbol(for s: SystemHealthSummary) -> String {
        guard s.hasAnyReading else { return "minus.circle" }
        switch s.worstUrgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private func healthColor(for s: SystemHealthSummary) -> Color {
        guard s.hasAnyReading else { return .secondary }
        switch s.worstUrgency {
        case .none:     return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private func healthText(for s: SystemHealthSummary) -> String {
        var parts: [String] = []
        if s.hasAnyReading {
            switch s.worstUrgency {
            case .none:     parts.append("All quotas healthy")
            case .warning:  parts.append("\(s.warningCount) running low")
            case .critical: parts.append("\(s.criticalCount) critical")
            }
        } else {
            parts.append("No readings")
        }
        if s.unavailableCount > 0 {
            parts.append("\(s.unavailableCount) not readable")
        }
        return parts.joined(separator: " · ")
    }

    private func elapsed(since date: Date) -> String {
        let interval = max(0, -date.timeIntervalSinceNow)
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        if interval < 3600 { return "\(Int((interval / 60).rounded()))m" }
        return "\(Int((interval / 3600).rounded()))h"
    }
}
