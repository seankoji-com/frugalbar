import SwiftUI
import AppKit
import QuotaBarCore

/// Owns the single History and Allowance Attribution window.
@MainActor
public enum HistoryWindow {

    private static var window: NSWindow?

    /// Shows the History window.
    ///
    /// The window builds its own `QuotaHistoryStore` for the same database the
    /// recorder writes to. That is a second SQLite connection rather than a
    /// shared one — safe under WAL, and it keeps the window independent of app
    /// lifecycle — but it does mean injected stores are not plumbed through
    /// here, so the parameters that used to exist and were never passed have
    /// been removed rather than left as a dead seam.
    public static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = HistoryRootView()
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
        created.setContentSize(NSSize(width: 760, height: 560))
        created.center()

        window = created
        created.makeKeyAndOrderFront(nil)
    }
}
