import Testing
import Foundation
@testable import QuotaBarUI

@Suite("ResetCountdownBadge.format")
struct ResetCountdownBadgeTests {

    @Test("nil renders as an em dash")
    func nilDate() {
        #expect(ResetCountdownBadge.format(nil) == "—")
    }

    @Test("a past date reads as Now")
    func past() {
        #expect(ResetCountdownBadge.format(Date().addingTimeInterval(-60)) == "Now")
    }

    @Test("sub-minute renders in seconds")
    func seconds() {
        #expect(ResetCountdownBadge.format(Date().addingTimeInterval(30)).hasSuffix("s"))
    }

    @Test("sub-hour renders in minutes")
    func minutes() {
        #expect(ResetCountdownBadge.format(Date().addingTimeInterval(600)).hasSuffix("m"))
    }

    @Test("sub-day renders hours and minutes")
    func hours() {
        let out = ResetCountdownBadge.format(Date().addingTimeInterval(3 * 3600 + 300))
        #expect(out.contains("h"))
        #expect(out.contains("m"))
    }
}
