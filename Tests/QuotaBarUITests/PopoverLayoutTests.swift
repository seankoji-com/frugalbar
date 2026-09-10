import SwiftUI
import Testing
@testable import QuotaBarUI

@Suite("Popover layout")
@MainActor
struct PopoverLayoutTests {
    @Test("content height is preserved when it fits")
    func contentFits() {
        #expect(PopoverRootView.scrollHeight(contentHeight: 420, availableHeight: 800, footerHeight: 44) == 420)
    }

    @Test("content is capped below the footer and popover chrome")
    func contentIsCappedByScreen() {
        #expect(PopoverRootView.scrollHeight(contentHeight: 900, availableHeight: 500, footerHeight: 44) == 444)
    }

    @Test("content never exceeds the global ceiling")
    func contentIsCappedByMaximum() {
        #expect(PopoverRootView.scrollHeight(contentHeight: 2_000, availableHeight: 2_000, footerHeight: 44)
                == PopoverRootView.maxContentHeight)
    }

    @Test("a tiny screen never overflows the available space")
    func contentHasMinimumViewport() {
        let height = PopoverRootView.scrollHeight(contentHeight: 900, availableHeight: 100, footerHeight: 44)
        #expect(height + 44 <= 100)
    }
}
