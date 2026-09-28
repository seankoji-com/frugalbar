import Testing
import Foundation
@testable import QuotaBarCore

@Suite("BurnRateForecast")
struct BurnRateForecastTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(
        _ vendor: VendorIdentifier = .claude,
        label: String = "5H",
        minutesAgo: Double,
        fraction: Double?,
        confidence: Confidence = .measured,
        elapsedOnly: Bool = false
    ) -> QuotaHistoryStore.ReadingRecord {
        QuotaHistoryStore.ReadingRecord(
            vendor: vendor.rawValue, barLabel: label,
            measuredAt: now.addingTimeInterval(-minutesAgo * 60),
            fraction: fraction, isBlocked: false, confidence: confidence,
            urgency: .none, resetsAt: nil, windowLength: QuotaWindow.fiveHours,
            elapsedOnly: elapsedOnly)
    }

    /// 10% of the window per 30 minutes, ending at 50% now: 20%/h, limit in 2.5h.
    private var steadyBurn: [QuotaHistoryStore.ReadingRecord] {
        [reading(minutesAgo: 30, fraction: 0.40),
         reading(minutesAgo: 15, fraction: 0.45),
         reading(minutesAgo: 0, fraction: 0.50)]
    }

    @Test("a steady burn projects the limit from the recent slope")
    func steadyBurnProjectsLimit() throws {
        let f = try #require(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: steadyBurn, resetsAt: nil, now: now))
        #expect(abs(f.fractionPerHour - 0.2) < 1e-9)
        #expect(f.sampleCount == 3)
        guard case .limitAt(let date) = f.outcome else {
            Issue.record("expected .limitAt, got \(f.outcome)"); return
        }
        #expect(abs(date.timeIntervalSince(now) - 2.5 * 3600) < 1)
        #expect(f.summary(now: now) == "Recent pace: 5H limit in 2h 30m")
    }

    @Test("a reset before the projected limit reports resetsFirst")
    func resetBeforeLimit() throws {
        let resetsAt = now.addingTimeInterval(3600)
        let f = try #require(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: steadyBurn, resetsAt: resetsAt, now: now))
        #expect(f.outcome == .resetsFirst(resetsAt: resetsAt))
        #expect(f.summary(now: now) == "Recent pace: 5H resets before limit")
    }

    @Test("flat usage is notBurning and renders no line")
    func flatUsage() throws {
        let readings = [reading(minutesAgo: 30, fraction: 0.4),
                        reading(minutesAgo: 15, fraction: 0.4),
                        reading(minutesAgo: 0, fraction: 0.4)]
        let f = try #require(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: readings, resetsAt: nil, now: now))
        #expect(f.outcome == .notBurning)
        #expect(f.summary(now: now) == nil)
    }

    @Test("too few samples or too short a span yields no forecast")
    func insufficientHistory() {
        let two = Array(steadyBurn.dropFirst())
        #expect(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: two, resetsAt: nil, now: now) == nil)
        let short = [reading(minutesAgo: 4, fraction: 0.40),
                     reading(minutesAgo: 2, fraction: 0.45),
                     reading(minutesAgo: 0, fraction: 0.50)]
        #expect(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: short, resetsAt: nil, now: now) == nil)
    }

    @Test("unmeasured, nil-fraction, elapsed-only and other-window readings are ignored")
    func onlyMeasuredReadingsCount() {
        let noise = [reading(minutesAgo: 20, fraction: 0.9, confidence: .unavailable),
                     reading(minutesAgo: 10, fraction: nil),
                     reading(minutesAgo: 5, fraction: 0.1, elapsedOnly: true),
                     reading(label: "WK", minutesAgo: 25, fraction: 0.2),
                     reading(.openai, minutesAgo: 25, fraction: 0.2)]
        // Only two usable readings for claude/5H: not enough for a trend.
        let readings = noise + [reading(minutesAgo: 30, fraction: 0.4), reading(minutesAgo: 0, fraction: 0.5)]
        #expect(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: readings, resetsAt: nil, now: now) == nil)
    }

    @Test("readings older than the lookback are excluded")
    func lookbackRespected() {
        let old = [reading(minutesAgo: 120, fraction: 0.1),
                   reading(minutesAgo: 90, fraction: 0.2),
                   reading(minutesAgo: 0, fraction: 0.5)]
        #expect(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: old, resetsAt: nil, now: now) == nil)
    }

    @Test("a window reset inside the lookback never reads as negative consumption")
    func resetDropStartsNewSegment() throws {
        let readings = [reading(minutesAgo: 55, fraction: 0.95),
                        reading(minutesAgo: 50, fraction: 0.98),
                        reading(minutesAgo: 40, fraction: 0.00),
                        reading(minutesAgo: 20, fraction: 0.10),
                        reading(minutesAgo: 0, fraction: 0.20)]
        let f = try #require(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: readings, resetsAt: nil, now: now))
        #expect(f.sampleCount == 3)
        #expect(abs(f.fractionPerHour - 0.3) < 1e-9)
    }

    @Test("an exhausted window has nothing left to forecast")
    func exhaustedWindow() {
        let readings = [reading(minutesAgo: 30, fraction: 0.9),
                        reading(minutesAgo: 15, fraction: 0.95),
                        reading(minutesAgo: 0, fraction: 1.0)]
        #expect(BurnRateForecast.compute(
            vendorId: .claude, barLabel: "5H", readings: readings, resetsAt: nil, now: now) == nil)
    }

    private func claudeSnapshot(measured: Bool) -> QuotaSnapshot {
        var snap = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: measured ? .measured(.none) : .unavailable(.notConfigured),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        snap.row1 = DualBarMetrics(primaryFraction: 0.5, label: "5H", measuresElapsedTimeOnly: false,
                                   resetsAt: nil, windowLength: QuotaWindow.fiveHours)
        snap.row2 = DualBarMetrics(primaryFraction: 0.4, label: "WK", measuresElapsedTimeOnly: false,
                                   resetsAt: nil, windowLength: QuotaWindow.fiveHours)
        return snap
    }

    @Test("binding picks the window that runs out soonest, and none for unavailable providers")
    func bindingChoosesSoonestLimit() throws {
        // 5H at 20%/h from 50% (2.5h); WK at 60%/h from 40% (1h).
        let readings = steadyBurn + [reading(label: "WK", minutesAgo: 30, fraction: 0.10),
                                     reading(label: "WK", minutesAgo: 15, fraction: 0.25),
                                     reading(label: "WK", minutesAgo: 0, fraction: 0.40)]
        let f = try #require(BurnRateForecast.binding(
            for: claudeSnapshot(measured: true), readings: readings, now: now))
        #expect(f.barLabel == "WK")
        #expect(BurnRateForecast.binding(
            for: claudeSnapshot(measured: false), readings: readings, now: now) == nil)
    }

    @Test("durations format to the nearest minute")
    func durationFormatting() {
        #expect(BurnRateForecast.formatDuration(10) == "1m")
        #expect(BurnRateForecast.formatDuration(45 * 60) == "45m")
        #expect(BurnRateForecast.formatDuration(80 * 60) == "1h 20m")
        #expect(BurnRateForecast.formatDuration(51 * 3600) == "2d 3h")
    }
}
