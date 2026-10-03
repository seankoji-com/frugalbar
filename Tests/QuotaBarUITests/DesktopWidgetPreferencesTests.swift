import Testing
import Foundation
import AppKit
@testable import QuotaBarCore
@testable import QuotaBarUI

/// Serialized: every test here reads and writes the same preference keys.
@Suite("Desktop widget preferences", .serialized)
struct DesktopWidgetPreferencesTests {

    private let keys = [
        CredentialStore.desktopWidgetVisibleDefaultsKey,
        CredentialStore.desktopWidgetModeDefaultsKey,
        CredentialStore.desktopWidgetFrameDefaultsKey,
        CredentialStore.desktopWidgetFiltersDefaultsKey,
    ]

    private func clear() {
        for key in keys { CredentialStore.preferences.removeObject(forKey: key) }
    }

    @Test("writes land in the app's suite, not UserDefaults.standard")
    func writesGoToTheNamedSuite() {
        clear()
        defer { clear() }
        CredentialStore.isDesktopWidgetVisible = true
        #expect(CredentialStore.preferences.object(forKey: CredentialStore.desktopWidgetVisibleDefaultsKey) as? Bool == true)
        #expect(UserDefaults.standard.object(forKey: CredentialStore.desktopWidgetVisibleDefaultsKey) == nil)
    }

    @Test("visibility round-trips and defaults to hidden")
    func visibilityRoundTrip() {
        clear()
        defer { clear() }
        #expect(CredentialStore.isDesktopWidgetVisible == false)
        CredentialStore.isDesktopWidgetVisible = true
        #expect(CredentialStore.isDesktopWidgetVisible == true)
        CredentialStore.isDesktopWidgetVisible = false
        #expect(CredentialStore.isDesktopWidgetVisible == false)
    }

    @Test("mode defaults to pinned-to-desktop, round-trips, and ignores junk")
    func modeRoundTrip() {
        clear()
        defer { clear() }
        #expect(CredentialStore.desktopWidgetMode == .desktop)
        CredentialStore.desktopWidgetMode = .floating
        #expect(CredentialStore.desktopWidgetMode == .floating)
        #expect(CredentialStore.preferences.string(forKey: CredentialStore.desktopWidgetModeDefaultsKey) == "floating")
        CredentialStore.preferences.set("sideways", forKey: CredentialStore.desktopWidgetModeDefaultsKey)
        #expect(CredentialStore.desktopWidgetMode == .desktop)
    }

    @Test("frame string round-trips through NSStringFromRect")
    func frameRoundTrip() {
        clear()
        defer { clear() }
        #expect(CredentialStore.desktopWidgetFrameString == nil)
        let rect = NSRect(x: 120, y: 80, width: 420, height: 320)
        CredentialStore.desktopWidgetFrameString = NSStringFromRect(rect)
        let restored = CredentialStore.desktopWidgetFrameString.map(NSRectFromString)
        #expect(restored == rect)
    }

    @Test("filters round-trip as JSON through preferences")
    func filtersRoundTrip() {
        clear()
        defer { clear() }
        #expect(WidgetFilters.decode(CredentialStore.desktopWidgetFiltersData) == WidgetFilters())
        let filters = WidgetFilters(vendors: [.openai], windowLabel: "5H", range: .last30Days, metric: .used)
        CredentialStore.desktopWidgetFiltersData = filters.encoded()
        #expect(WidgetFilters.decode(CredentialStore.desktopWidgetFiltersData) == filters)
    }
}
