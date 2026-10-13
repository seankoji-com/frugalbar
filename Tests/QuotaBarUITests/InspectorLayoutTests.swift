import Testing
@testable import QuotaBarUI

@Suite("Inspector layout")
@MainActor
struct InspectorLayoutTests {
    @Test func shortPopoverKeepsControlsVisible() {
        let height = MetricDetailModalView.scrollHeight(contentHeight: 600, availableHeight: 400,
            headerHeight: 90, footerHeight: 48)
        #expect(height == 238)
        #expect(height + 90 + 48 + 24 <= 400)
    }

    @Test func tallerHeaderReducesViewport() {
        #expect(MetricDetailModalView.scrollHeight(contentHeight: 600, availableHeight: 400,
            headerHeight: 130, footerHeight: 48) == 198)
    }

    @Test func contentFitsAndLargeWindowsRemainCapped() {
        #expect(MetricDetailModalView.scrollHeight(contentHeight: 120, availableHeight: 700,
            headerHeight: 70, footerHeight: 48) == 120)
        #expect(MetricDetailModalView.scrollHeight(contentHeight: 900, availableHeight: 900,
            headerHeight: 70, footerHeight: 48) == 480)
    }

    @Test func tinyViewportNeverBecomesNegative() {
        #expect(MetricDetailModalView.scrollHeight(contentHeight: 600, availableHeight: 100,
            headerHeight: 90, footerHeight: 48) == 0)
    }
}
