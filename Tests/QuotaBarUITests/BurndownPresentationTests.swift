import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("BurndownPresentation")
struct BurndownPresentationTests {

    typealias P = BurndownPresentation

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// A 5-hour window that started 3h ago and resets in 2h.
    private var resets: Date { now.addingTimeInterval(2 * 3600) }
    private let length: TimeInterval = 5 * 3600

    private func reading(
        _ vendor: VendorIdentifier = .claude,
        label: String = "5H",
        minutesAgo: Double,
        fraction: Double?,
        resetsAt: Date?? = .none,
        windowLength: TimeInterval?? = .none,
        isBlocked: Bool = false,
        urgency: Urgency = .none,
        elapsedOnly: Bool = false
    ) -> QuotaHistoryStore.ReadingRecord {
        QuotaHistoryStore.ReadingRecord(
            vendor: vendor.rawValue,
            barLabel: label,
            measuredAt: now.addingTimeInterval(-minutesAgo * 60),
            fraction: fraction,
            isBlocked: isBlocked,
            confidence: .measured,
            urgency: urgency,
            resetsAt: resetsAt ?? resets,
            windowLength: windowLength ?? length,
            elapsedOnly: elapsedOnly
        )
    }

    /// Steady burn: 10 readings over 45 minutes, 0.40 → 0.58.
    private var burning: [QuotaHistoryStore.ReadingRecord] {
        (0..<10).map { i in
            reading(minutesAgo: Double(45 - i * 5), fraction: 0.40 + Double(i) * 0.02)
        }
    }

    // MARK: - Ideal line

    @Test("ideal runs exactly from 100% at window start to 0% at reset")
    func idealEndpointsExact() throws {
        let b = try #require(P.burndown(readings: burning, vendorId: .claude, barLabel: "5H", now: now))
        let ideal = try #require(b.ideal)
        #expect(ideal == [
            P.LinePoint(date: resets.addingTimeInterval(-length), remainingFraction: 1),
            P.LinePoint(date: resets, remainingFraction: 0),
        ])
        #expect(b.windowStart == resets.addingTimeInterval(-length))
        #expect(b.resetsAt == resets)
    }

    /// Regression: the ideal line must not be drawn from a window length
    /// nobody published. Proven red by removing the `length` binding guard in
    /// `burndown` (ideal then built from a defaulted length).
    @Test("no ideal line and no window start without a window length")
    func idealAbsentWithoutWindowLength() throws {
        let readings = burning.map {
            QuotaHistoryStore.ReadingRecord(
                vendor: $0.vendor, barLabel: $0.barLabel, measuredAt: $0.measuredAt,
                fraction: $0.fraction, isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: resets, windowLength: nil, elapsedOnly: false
            )
        }
        let b = try #require(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.ideal == nil)
        #expect(b.windowStart == nil)
        #expect(!P.summaryLine(for: b, now: now).contains("pace"))
    }

    @Test("no ideal line without a reset time")
    func idealAbsentWithoutReset() throws {
        let readings = burning.map {
            QuotaHistoryStore.ReadingRecord(
                vendor: $0.vendor, barLabel: $0.barLabel, measuredAt: $0.measuredAt,
                fraction: $0.fraction, isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: length, elapsedOnly: false
            )
        }
        let b = try #require(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.ideal == nil)
        #expect(b.resetsAt == nil)
    }

    // MARK: - Actual

    @Test("remaining is one minus used for every point and for now")
    func remainingIsComplement() throws {
        let b = try #require(P.burndown(readings: burning, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.actual.count == 10)
        for p in b.actual {
            #expect(abs(p.remainingFraction - (1 - p.usedFraction)) < 1e-12)
        }
        #expect(abs(try #require(b.nowRemaining) - 0.42) < 1e-9)
    }

    @Test("only the window after a reset-sized drop is the current one")
    func segmentsAfterResetDrop() throws {
        let readings = [
            reading(minutesAgo: 60, fraction: 0.90),
            reading(minutesAgo: 50, fraction: 0.95),
            reading(minutesAgo: 40, fraction: 0.05),
            reading(minutesAgo: 30, fraction: 0.10),
        ]
        let b = try #require(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.actual.map(\.usedFraction) == [0.05, 0.10])
    }

    @Test("blocked and urgency are carried onto points")
    func blockedCarried() throws {
        let readings = [
            reading(minutesAgo: 20, fraction: 0.8, urgency: .warning),
            reading(minutesAgo: 10, fraction: 0.95, isBlocked: true, urgency: .critical),
        ]
        let b = try #require(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.actual.map(\.isBlocked) == [false, true])
        #expect(b.actual.map(\.urgency) == [.warning, .critical])
        #expect(P.accessibilityDescription(for: b, now: now).contains("blocked"))
    }

    @Test("readings with no fraction are skipped, never drawn as 0 or 100")
    func nilFractionsSkipped() throws {
        // A trailing nil means the current reading is unavailable: no
        // burndown, rather than the older 30% revived as "70% left".
        let trailingNil = [
            reading(minutesAgo: 20, fraction: 0.3),
            reading(minutesAgo: 10, fraction: nil),
        ]
        #expect(P.burndown(readings: trailingNil, vendorId: .claude, barLabel: "5H", now: now) == nil)

        // A nil in the middle breaks the segment; the current window is what
        // follows it.
        let middleNil = [
            reading(minutesAgo: 30, fraction: 0.3),
            reading(minutesAgo: 20, fraction: nil),
            reading(minutesAgo: 10, fraction: 0.4),
        ]
        let b = try #require(P.burndown(readings: middleNil, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.actual.map(\.usedFraction) == [0.4])
        #expect(b.nowRemaining.map { abs($0 - 0.6) < 1e-9 } == true)

        let none = [reading(minutesAgo: 10, fraction: nil)]
        #expect(P.burndown(readings: none, vendorId: .claude, barLabel: "5H", now: now) == nil)
    }

    @Test("other vendors, other labels and elapsed-only rows are ignored")
    func filtersVendorLabelElapsed() throws {
        let readings = [
            reading(minutesAgo: 20, fraction: 0.3),
            reading(.openai, minutesAgo: 15, fraction: 0.9),
            reading(label: "WK", minutesAgo: 15, fraction: 0.9),
            reading(minutesAgo: 10, fraction: 0.9, elapsedOnly: true),
        ]
        let b = try #require(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.actual.map(\.usedFraction) == [0.3])
    }

    @Test("a window whose reset has passed is not the current one")
    func expiredWindowIsNil() {
        let readings = [reading(minutesAgo: 30, fraction: 0.4, resetsAt: now.addingTimeInterval(-60))]
        #expect(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now) == nil)
    }

    // MARK: - Projection

    @Test("burning with enough samples projects from the latest reading to exhaustion or reset")
    func projectionWhenBurning() throws {
        let b = try #require(P.burndown(readings: burning, vendorId: .claude, barLabel: "5H", now: now))
        let projection = try #require(b.projection)
        #expect(projection.count == 2)
        #expect(projection[0].date == now)
        #expect(abs(projection[0].remainingFraction - 0.42) < 1e-9)
        // 0.02 per 5 min = 0.24/h; 0.42 left runs out in 1.75h, before the 2h reset.
        let expected = now.addingTimeInterval(1.75 * 3600)
        #expect(abs(projection[1].date.timeIntervalSince(expected)) < 1)
        #expect(projection[1].remainingFraction == 0)
        #expect(b.projectedExhaustion != nil)
    }

    @Test("projection stops at the reset when the reset comes first")
    func projectionStopsAtReset() throws {
        let slow = (0..<10).map { i in
            reading(minutesAgo: Double(45 - i * 5), fraction: 0.40 + Double(i) * 0.002,
                    resetsAt: now.addingTimeInterval(1800))
        }
        let b = try #require(P.burndown(readings: slow, vendorId: .claude, barLabel: "5H", now: now))
        let projection = try #require(b.projection)
        #expect(projection[1].date == now.addingTimeInterval(1800))
        #expect(projection[1].remainingFraction > 0)
        #expect(b.projectedExhaustion == nil)
    }

    @Test("no projection when usage is flat")
    func projectionAbsentWhenFlat() throws {
        let flat = (0..<10).map { i in reading(minutesAgo: Double(45 - i * 5), fraction: 0.4) }
        let b = try #require(P.burndown(readings: flat, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.projection == nil)
    }

    @Test("no projection from fewer than three samples")
    func projectionAbsentTooFewSamples() throws {
        let two = [reading(minutesAgo: 30, fraction: 0.3), reading(minutesAgo: 0, fraction: 0.5)]
        let b = try #require(P.burndown(readings: two, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.projection == nil)
    }

    @Test("no projection from samples spanning under ten minutes")
    func projectionAbsentShortSpan() throws {
        let quick = (0..<5).map { i in reading(minutesAgo: Double(8 - i * 2), fraction: 0.3 + Double(i) * 0.05) }
        let b = try #require(P.burndown(readings: quick, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.projection == nil)
    }

    @Test("projection does not need a window length, only a real pace")
    func projectionWithoutWindowLength() throws {
        let readings = burning.map {
            QuotaHistoryStore.ReadingRecord(
                vendor: $0.vendor, barLabel: $0.barLabel, measuredAt: $0.measuredAt,
                fraction: $0.fraction, isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: nil, elapsedOnly: false
            )
        }
        let b = try #require(P.burndown(readings: readings, vendorId: .claude, barLabel: "5H", now: now))
        #expect(b.ideal == nil)
        #expect(b.projection != nil)
    }

    // MARK: - Window range

    @Test("window range is the vendor's window when known")
    func windowRangeKnown() throws {
        let b = try #require(P.burndown(readings: burning, vendorId: .claude, barLabel: "5H", now: now))
        #expect(P.windowRange(for: b) == resets.addingTimeInterval(-length)...resets)
    }

    @Test("window range falls back to the recorded span, extended by the projection")
    func windowRangeFallback() throws {
        let flat = (0..<4).map { i in
            reading(minutesAgo: Double(30 - i * 10), fraction: 0.4, resetsAt: .some(nil), windowLength: .some(nil))
        }
        let b = try #require(P.burndown(readings: flat, vendorId: .claude, barLabel: "5H", now: now))
        #expect(P.windowRange(for: b) == now.addingTimeInterval(-1800)...now)

        let single = [reading(minutesAgo: 5, fraction: 0.4, resetsAt: .some(nil), windowLength: .some(nil))]
        let one = try #require(P.burndown(readings: single, vendorId: .claude, barLabel: "5H", now: now))
        #expect(P.windowRange(for: one) == nil)
    }

    // MARK: - History

    @Test("history keeps only the selected range and segments each label separately")
    func historyRanges() {
        let readings = [
            reading(minutesAgo: 3 * 1440, fraction: 0.1),   // 3 days ago
            reading(minutesAgo: 60, fraction: 0.2),
            reading(label: "WK", minutesAgo: 60, fraction: 0.5, windowLength: .some(7 * 86_400)),
            reading(minutesAgo: 30, fraction: 0.3),
            reading(label: "WK", minutesAgo: 30, fraction: 0.55, windowLength: .some(7 * 86_400)),
            reading(.openai, minutesAgo: 30, fraction: 0.9),
        ]
        let day = P.history(readings: readings, vendorId: .claude, range: .last24Hours, now: now)
        #expect(day.map(\.label) == ["WK", "5H"])
        #expect(day.map { $0.points.count } == [2, 2])

        let week = P.history(readings: readings, vendorId: .claude, range: .last7Days, now: now)
        // The 3-day-old reading is separated from today's by a gap.
        let fiveHour: [P.Series] = week.filter { $0.label == "5H" }
        let fiveHourPoints: Int = fiveHour.reduce(0) { $0 + $1.points.count }
        #expect(fiveHourPoints == 3)
        #expect(fiveHour.count == 2)

        #expect(P.history(readings: [], vendorId: .claude, range: .last30Days, now: now).isEmpty)
    }

    // MARK: - Text

    @Test("summary line names remaining, reset and pace")
    func summaryLineFull() throws {
        let b = try #require(P.burndown(readings: burning, vendorId: .claude, barLabel: "5H", now: now))
        // 58% used with 60% of the window elapsed: on pace.
        #expect(P.summaryLine(for: b, now: now) == "42% left · 2h 0m to reset · on pace · out in 1h 45m")
    }

    @Test("summary line omits every clause whose input is missing")
    func summaryLineOmissions() {
        let bare = P.Burndown(
            barLabel: "5H", windowStart: nil, resetsAt: nil, actual: [],
            ideal: nil, projection: nil, nowRemaining: nil, latestReading: nil
        )
        #expect(P.summaryLine(for: bare, now: now) == "No current reading")

        let remainingOnly = P.Burndown(
            barLabel: "5H", windowStart: nil, resetsAt: nil, actual: [],
            ideal: nil, projection: nil, nowRemaining: 0.27, latestReading: nil
        )
        #expect(P.summaryLine(for: remainingOnly, now: now) == "27% left")
    }

    @Test("reset credits text appears only when published")
    func resetCreditsText() {
        #expect(P.resetCreditsText(available: nil, applicable: 1) == nil)
        #expect(P.resetCreditsText(available: 0, applicable: nil) == "0 banked")
        #expect(P.resetCreditsText(available: 2, applicable: 0) == "2 banked")
        #expect(P.resetCreditsText(available: 2, applicable: 1) == "2 banked · 1 redeemable now")
    }

    @Test("JSON export round-trips and omits absent figures")
    func exportJSON() throws {
        var snapshot = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil), status: .warning,
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.58, label: "5H", resetsAt: resets, windowLength: length),
            row2: DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true)
        )
        snapshot.resetCreditsAvailable = 2
        let export = InspectorExport(snapshot: snapshot, readingsCount: 12)
        let json = try #require(export.jsonString())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InspectorExport.self, from: Data(json.utf8))
        #expect(decoded == export)
        #expect(decoded.status == "warning")
        #expect(decoded.readingsCount == 12)
        #expect(json.contains("\"resetsAt\" : \"2023-11-15T00:13:20Z\""))
        #expect(!json.contains("latencyMs"))
        #expect(decoded.bars.first { $0.label == "WK" }?.usedFraction == nil)
    }
}
