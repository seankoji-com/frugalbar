import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

@Suite("DualBarHelpText")
struct DualBarHelpTextTests {

    @Test("a blocked window with no reading says it is blocked")
    func blockedWithoutReading() {
        let metrics = DualBarMetrics(
            primaryFraction: nil,
            label: "5H",
            isBlocked: true
        )
        #expect(DualBarProgressView.blockedFallbackDetail(for: metrics)
            == "blocked • no reading reported")
    }

    @Test("an unmeasured not-blocked window is not labelled blocked")
    func unmeasuredNotBlocked() {
        let metrics = DualBarMetrics(
            primaryFraction: nil,
            label: "5H",
            isBlocked: false
        )
        let detail = DualBarProgressView.blockedFallbackDetail(for: metrics)
        #expect(detail == "no reading reported")
        #expect(!detail.localizedCaseInsensitiveContains("blocked"))
    }

    @Test("usedText takes precedence over the fallback wording")
    func usedTextWins() {
        let metrics = DualBarMetrics(
            primaryFraction: nil,
            label: "5H",
            isBlocked: true,
            usedText: "Rate limited"
        )
        #expect(DualBarProgressView.blockedFallbackDetail(for: metrics) == "Rate limited")
    }
}
