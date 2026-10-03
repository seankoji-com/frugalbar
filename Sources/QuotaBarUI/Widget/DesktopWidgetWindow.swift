import SwiftUI
import AppKit
import Observation
import QuotaBarCore

/// Whether the desktop widget is on screen, observable so the gear menu's
/// checkmark follows the panel without polling.
@MainActor
@Observable
public final class DesktopWidgetVisibility {
    public static let shared = DesktopWidgetVisibility()
    public internal(set) var isVisible = false
    private init() {}
}

/// Owns the single desktop widget panel.
///
/// Not a WidgetKit widget: a WidgetKit extension has to ship as a signed
/// `.appex` inside a `.app`, and this app is a bare executable. The widget is
/// an `NSPanel` the app owns, either pinned to the desktop (on the wallpaper,
/// under the icons) or floating above windows.
///
/// Unlike `HistoryWindow`, it needs the live `QuotaStore` rather than a second
/// database connection, so `AppDelegate` calls `configure(store:)` once after
/// the store exists. `show()` before that is a no-op.
@MainActor
public enum DesktopWidgetWindow {

    private static var store: QuotaStore?
    private static var panel: NSPanel?
    private static var delegate: PanelDelegate?

    public static let defaultSize = NSSize(width: 420, height: 320)
    public static let minimumSize = NSSize(width: 340, height: 260)

    public static func configure(store: QuotaStore) {
        self.store = store
    }

    public static var isVisible: Bool { panel?.isVisible ?? false }

    public static func show() {
        guard let store else { return }
        let panel = panel ?? makePanel(store: store)
        self.panel = panel
        applyMode()
        restoreFrame(of: panel)
        panel.orderFrontRegardless()
        setVisible(true)
    }

    /// Hides without forgetting the frame. Not the same as the close button:
    /// both persist visible = false, but this one keeps the panel built.
    public static func hide() {
        panel?.orderOut(nil)
        setVisible(false)
    }

    public static func toggle() {
        isVisible ? hide() : show()
    }

    /// Applies the persisted `DesktopWidgetMode`. Safe to call before the
    /// panel exists — it is applied again on `show()`.
    public static func applyMode() {
        guard let panel else { return }
        switch CredentialStore.desktopWidgetMode {
        case .desktop:
            // One below the icon layer: on the wallpaper, under the icons,
            // beneath every ordinary window.
            // One level ABOVE the desktop icons, still far below every
            // ordinary window. Below the icons, Finder's full-screen desktop
            // layer swallowed every click: the panel could be seen but not
            // dragged, resized, closed or filtered.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .floating:
            panel.level = .floating
        }
        panel.ignoresMouseEvents = false
    }

    private static func setVisible(_ visible: Bool) {
        CredentialStore.isDesktopWidgetVisible = visible
        DesktopWidgetVisibility.shared.isVisible = visible
    }

    private static func makePanel(store: QuotaStore) -> NSPanel {
        let created = NSPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.title = "FrugalBar Usage"
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.isMovableByWindowBackground = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.appearance = NSAppearance(named: .darkAqua)
        created.backgroundColor = NSColor(red: 0x0a / 255.0, green: 0x0a / 255.0, blue: 0x0b / 255.0, alpha: 0.94)
        created.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        created.minSize = minimumSize
        created.contentViewController = NSHostingController(rootView: DesktopWidgetView(store: store))
        created.setContentSize(defaultSize)
        created.center()

        let delegate = PanelDelegate()
        created.delegate = delegate
        self.delegate = delegate
        return created
    }

    private static func restoreFrame(of panel: NSPanel) {
        guard let stored = CredentialStore.desktopWidgetFrameString else { return }
        let rect = NSRectFromString(stored)
        guard rect.width >= minimumSize.width, rect.height >= minimumSize.height else { return }
        // Only restore onto a screen that still exists; a disconnected display
        // would otherwise leave the widget somewhere it can never be seen.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        guard onScreen else { return }
        panel.setFrame(rect, display: false)
    }

    fileprivate static func persistFrame() {
        guard let panel else { return }
        CredentialStore.desktopWidgetFrameString = NSStringFromRect(panel.frame)
    }

    fileprivate static func didClose() {
        setVisible(false)
    }
}

@MainActor
private final class PanelDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        DesktopWidgetWindow.persistFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        DesktopWidgetWindow.persistFrame()
    }

    /// The title-bar close button. Quitting the app does not close windows,
    /// so a widget left open at quit comes back at launch.
    func windowWillClose(_ notification: Notification) {
        DesktopWidgetWindow.persistFrame()
        DesktopWidgetWindow.didClose()
    }
}
