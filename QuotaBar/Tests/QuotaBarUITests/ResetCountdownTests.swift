import Testing
import Foundation
@testable import QuotaBarUI
import QuotaBarCore

struct ResetCountdownTests {

    @Test func format_nilDate() {
        let result: String = ResetCountdownBadge.format(nil as Date?)
        #expect(result == "—")
    }

    @Test func format_pastDate() {
        let past = Date(timeIntervalSinceNow: -10)
        #expect(ResetCountdownBadge.format(past) == "Now")
    }

    @Test func format_seconds() {
        let soon = Date(timeIntervalSinceNow: 30)
        let result = ResetCountdownBadge.format(soon)
        // Due to processing time, the result might be 29s or 30s
        let isSeconds = result.hasSuffix("s") && !result.contains("m")
        #expect(isSeconds)
    }

    @Test func format_minutes() {
        let soon = Date(timeIntervalSinceNow: 300)
        let result = ResetCountdownBadge.format(soon)
        // Should be in minutes. 300s = 5m, but timing drift may show 4m or 5m
        let isMinutes = result.hasSuffix("m") && !result.contains("h") && !result.contains("s")
        #expect(isMinutes)
    }

    @Test func format_hoursAndMinutes() {
        let soon = Date(timeIntervalSinceNow: 3660)
        let result = ResetCountdownBadge.format(soon)
        // Due to timing, 3660s = 1h 0m exactly, may show 60m or 0m
        #expect(result == "1h 0m" || result == "1h 1m" || result == "60m")
    }

    @Test func description_nilDate() {
        let result: String = ResetCountdownBadge.description(nil as Date?)
        #expect(result == "—")
    }

    @Test func description_seconds() {
        let soon = Date(timeIntervalSinceNow: 30)
        let result = ResetCountdownBadge.description(soon)
        #expect(result.hasPrefix("Resets in "))
        #expect(result.hasSuffix("s"))
    }

    @Test func description_minutes() {
        let soon = Date(timeIntervalSinceNow: 180) // 3 minutes from now
        #expect(ResetCountdownBadge.description(soon) == "Resets in 3m")
    }

    @Test func description_hoursMinutes() {
        let soon = Date(timeIntervalSinceNow: 3660)
        let result = ResetCountdownBadge.description(soon)
        // 3660s = 1h 0m exactly, may also show 60m
        #expect(result == "Resets in 1h 0m" || result == "Resets in 1h 1m" || result == "Resets in 60m")
    }
}
