import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Menu bar next limit")
struct MenuBarLimitingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ id: String, used: Double, label: String = "5H",
                          status: ProviderStatus = .measured(.warning)) -> QuotaSnapshot {
        QuotaSnapshot(id: id, vendorId: .opencode, displayName: id, category: .aiSubscriptions,
            metric: .subscription(tierName: "Go", renewalDate: nil), status: status,
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, label: label,
                resetsAt: now.addingTimeInterval(3_600)))
    }

    private func forecast(_ id: String, label: String = "5H", seconds: Double) -> BurnRateForecast {
        BurnRateForecast(instanceID: id, barLabel: label, fractionPerHour: 0.2, sampleCount: 4,
                         outcome: .limitAt(now.addingTimeInterval(seconds)))
    }

    @Test("the earliest projected limit wins over more used and untouched workspaces")
    func earliestForecastWins() {
        let snaps = [snapshot("untouched", used: 0), snapshot("nearly-full", used: 0.95), snapshot("fast", used: 0.7)]
        let details = MenuBarPresentation.limitingDetails(snapshots: snaps,
            forecasts: ["nearly-full": forecast("nearly-full", seconds: 1_800),
                        "fast": forecast("fast", seconds: 600)], now: now)
        #expect(details.displayText == "5H 30% ~10m")
        #expect(details.limitDescription?.contains("fast 5H") == true)
        #expect(details.limitDescription?.contains("at recent pace limit in 10m") == true)
        let speech = MenuBarPresentation.accessibilityDescription(for: .compute(from: snaps), recommendation: details)
        #expect(!speech.contains("resets in ~"))
    }

    @Test("without a forecast the closest live quota wins and no depletion time is invented")
    func pressureFallback() {
        let snaps = [snapshot("spent", used: 1), snapshot("unused", used: 0), snapshot("low", used: 0.95)]
        let details = MenuBarPresentation.limitingDetails(snapshots: snaps, forecasts: [:], now: now)
        #expect(details.displayText == "5H 5%")
        #expect(details.timeLeftText == nil)
        #expect(details.limitDescription?.contains("low 5H") == true)
    }

    @Test("stale, unavailable and elapsed windows cannot supply the next limit")
    func ignoresUnreadableAndElapsed() {
        var stale = snapshot("stale", used: 0.99)
        stale.staleReading = StaleReading(reason: .offline, at: now)
        let unavailable = snapshot("unavailable", used: 0.98, status: .unavailable(.offline))
        var elapsed = snapshot("elapsed", used: 0.97)
        elapsed.row1?.measuresElapsedTimeOnly = true
        let details = MenuBarPresentation.limitingDetails(
            snapshots: [stale, unavailable, elapsed, snapshot("live", used: 0.5)],
            forecasts: ["stale": forecast("stale", seconds: 60)], now: now)
        #expect(details.displayText == "5H 50%")
        #expect(details.limitDescription?.contains("live 5H") == true)
    }

    @Test("a forecast for another window or one after reset cannot win")
    func rejectsUnrelatedForecasts() {
        let snaps = [snapshot("low", used: 0.9), snapshot("other", used: 0.5)]
        for invalid in [forecast("other", label: "WK", seconds: 60), forecast("other", seconds: 7_200)] {
            let details = MenuBarPresentation.limitingDetails(snapshots: snaps, forecasts: ["other": invalid], now: now)
            #expect(details.displayText == "5H 10%")
        }
    }

    @Test("the selected window supplies the figure as well as its label")
    func selectedWindowFigures() {
        var snap = snapshot("mixed", used: 0.95)
        snap.row2 = DualBarMetrics(primaryFraction: 0.4, label: "WK", resetsAt: now.addingTimeInterval(86_400))
        let details = MenuBarPresentation.limitingDetails(snapshots: [snap],
            forecasts: ["mixed": forecast("mixed", label: "WK", seconds: 1_200)], now: now)
        #expect(details.displayText == "WK 60% ~20m")
    }

    @Test("no measured quota leaves the tray without a percentage")
    func emptyHasNoFigure() {
        let details = MenuBarPresentation.limitingDetails(snapshots: [], forecasts: [:], now: now)
        #expect(details.displayText == nil)
        #expect(details.lowestRemainingFraction == nil)
    }
}
