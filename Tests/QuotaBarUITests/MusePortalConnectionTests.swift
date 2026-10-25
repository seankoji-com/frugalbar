import AppKit
import SwiftUI
import Testing
import WebKit
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Muse portal connection controls")
@MainActor
struct MusePortalConnectionTests {
    @Test("the production Picker displays the restored selection and its loaded-list status")
    func restoredTeamPickerDisplaysSelectedTitle() async throws {
        let suite = "MusePortalConnectionTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: MusePortalSession.enabledKey)
        preferences.set("42", forKey: MusePortalSession.teamKey)
        let website = PickerWebsite()
        let session = MusePortalSession(preferences: preferences, website: website)
        let host = NSHostingView(rootView: MusePortalConnectionView(session: session))
        host.frame.size = NSSize(width: 800, height: 660)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        try await expectSelectedTitle("Saved selection (refresh teams for name)", in: host)
        #expect(website.requests == 0)
        await session.refreshTeams()
        try await expectSelectedTitle("Saved selection (absent from loaded teams)", in: host)
        #expect(session.selectedTeamID == "42")
        website.body = #"{"teams":[{"id":"42","name":"Fixture team"}]}"#
        await session.refreshTeams()
        try await expectSelectedTitle("Fixture team", in: host)
        #expect(session.selectedTeamID == "42")
    }

    private func expectSelectedTitle(_ expected: String, in host: NSView) async throws {
        // Bounded layout turns let SwiftUI install/update the actual AppKit
        // control. Absence or a blank selection is a failure, never a skip.
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if popup(in: host)?.titleOfSelectedItem == expected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let control = try #require(popup(in: host), "Production Picker has no NSPopUpButton")
        print("MUSE_PICKER selectedIndex=\(control.indexOfSelectedItem) selectedTitle=\(control.titleOfSelectedItem ?? "<nil>")")
        #expect(control.titleOfSelectedItem == expected)
        #expect(control.indexOfSelectedItem >= 0)
    }

    private func popup(in view: NSView) -> NSPopUpButton? {
        if let control = view as? NSPopUpButton { return control }
        return view.subviews.lazy.compactMap { popup(in: $0) }.first
    }
}

@MainActor
private final class PickerWebsite: MusePortalWebsite {
    var webView: WKWebView? { nil }
    var isAtPortal: Bool { true }
    var body = #"{"teams":[]}"#
    var requests = 0
    func open() {}
    func host() {}
    func waitUntilPortal(id: UUID, complete: @escaping @MainActor @Sendable (Bool) -> Void) { complete(true) }
    func cancelPortalWait(id: UUID) {}
    func stop() {}
    func clear() async {}
    func evaluate(email: String, plan: String, teamID: String,
                  complete: @escaping @MainActor @Sendable (String?) -> Void) {
        requests += 1
        complete(body)
    }
}
