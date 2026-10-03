import SwiftUI
import AppKit
import QuotaBarCore

/// The History window's top-level tabs.
public enum HistoryTab: String, CaseIterable, Identifiable, Sendable {
    case timeline
    case events

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .timeline: "Timeline"
        case .events: "Events"
        }
    }
}

/// Carries a tab request into an already-open History window. `serial`
/// changes on every request, so asking again for a tab the user has since
/// navigated away from still switches back to it.
@MainActor
@Observable
public final class HistoryTabRequest {
    public private(set) var tab: HistoryTab = .timeline
    public private(set) var serial = 0

    public init() {}

    public func request(_ tab: HistoryTab) {
        self.tab = tab
        serial += 1
    }
}

/// Owns the single History and Allowance Attribution window.
@MainActor
public enum HistoryWindow {

    private static var window: NSWindow?
    private static let tabRequest = HistoryTabRequest()

    /// Shows the History window.
    ///
    /// The window builds its own `QuotaHistoryStore` for the same database the
    /// recorder writes to. That is a second SQLite connection rather than a
    /// shared one — safe under WAL, and it keeps the window independent of app
    /// lifecycle — but it does mean injected stores are not plumbed through
    /// here, so the parameters that used to exist and were never passed have
    /// been removed rather than left as a dead seam.
    public static func show(tab: HistoryTab = .timeline) {
        NSApp.activate(ignoringOtherApps: true)
        tabRequest.request(tab)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = HistoryRootView(initialTab: tab, tabRequest: tabRequest)
        let hosting = NSHostingController(rootView: rootView)
        let created = NSWindow(contentViewController: hosting)
        created.title = "Quota History & Attribution"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .visible
        created.isMovableByWindowBackground = true
        created.appearance = NSAppearance(named: .darkAqua)
        created.backgroundColor = NSColor(red: 0x0a / 255.0, green: 0x0a / 255.0, blue: 0x0b / 255.0, alpha: 1.0)
        created.isReleasedWhenClosed = false
        created.minSize = NSSize(width: 640, height: 480)
        // Wide enough for the header's tab picker beside the timeline's
        // vendor and range pickers without truncating the title.
        created.setContentSize(NSSize(width: 880, height: 560))
        created.center()

        window = created
        created.makeKeyAndOrderFront(nil)
    }
}
