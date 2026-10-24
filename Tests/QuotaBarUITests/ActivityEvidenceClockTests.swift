import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

/// C8: the controlled evidence ledger must not depend on the hour the binary
/// happens to run. Both fixture days are derived from an explicit reference
/// and must already be behind it, including on daylight-saving boundaries.
@Suite("Activity evidence clock")
struct ActivityEvidenceClockTests {

    private func reference(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("the standard fixture is a fixed instant with both days in its past")
    func standardFixtureIsFixedAndPrior() {
        let fixture = ActivityEvidenceRenderer.Fixture.standard
        #expect(fixture.referenceDate == Date(timeIntervalSince1970: 1_792_497_600))
        #expect(fixture.dayOne == Date(timeIntervalSince1970: 1_792_404_000))
        #expect(fixture.dayTwo == Date(timeIntervalSince1970: 1_792_490_400))
        #expect(fixture.dayOne < fixture.dayTwo)
        #expect(fixture.dayTwo < fixture.referenceDate)
        // Both observations are inside the production Tokens window.
        let window = TokenUsagePresentation.window(
            range: .last7Days, now: fixture.referenceDate, calendar: fixture.calendar)
        #expect(window.since <= fixture.dayOne)
        #expect(fixture.dayTwo < fixture.referenceDate)
    }

    @Test("a derived fixture keeps both days behind the reference at every local hour")
    func derivedFixtureKeepsBothDaysBehindReference() {
        for identifier in ["America/Los_Angeles", "Pacific/Auckland", "Asia/Kathmandu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            // Morning, the 10:00 boundary, midday, evening and the last minute
            // of the day — the hours the old derivation failed to account for.
            for (hour, minute) in [(0, 30), (9, 0), (10, 0), (12, 0), (23, 59)] {
                for (month, day) in [(3, 8), (11, 1), (9, 27), (4, 5)] {
                    let now = reference(2026, month, day, hour, minute, calendar: calendar)
                    let fixture = ActivityEvidenceRenderer.Fixture.around(
                        reference: now, calendar: calendar)
                    #expect(fixture.dayOne < fixture.dayTwo,
                            "\(identifier) \(month)-\(day) \(hour):\(minute)")
                    #expect(fixture.dayTwo < fixture.referenceDate,
                            "\(identifier) \(month)-\(day) \(hour):\(minute)")
                    #expect(fixture.dayOne < fixture.referenceDate)
                    // Local 10:00 on both days, however long the day was.
                    #expect(calendar.component(.hour, from: fixture.dayOne) == 10)
                    #expect(calendar.component(.hour, from: fixture.dayTwo) == 10)
                    // Both inside a seven-day window. No duration assertion:
                    // a DST day is not 24 hours.
                    let window = TokenUsagePresentation.window(
                        range: .last7Days, now: fixture.referenceDate, calendar: calendar)
                    #expect(window.since <= fixture.dayOne)
                    #expect(fixture.dayTwo < fixture.referenceDate)
                }
            }
        }
    }

    @Test("the evidence observations sit inside the reference day, not the fixture days")
    func ancillaryObservationsAreRelativeToTheReference() {
        let fixture = ActivityEvidenceRenderer.Fixture.standard
        #expect(fixture.claudeObservedAt == fixture.referenceDate.addingTimeInterval(-3600))
        #expect(fixture.openCodeObservedAt == fixture.referenceDate.addingTimeInterval(-1800))
        #expect(fixture.dayTwo < fixture.claudeObservedAt)
        #expect(fixture.dayTwo < fixture.openCodeObservedAt)
    }
}
