import SwiftUI
import AppKit
import QuotaBarCore
import QuotaBarUI

/// Status item + popover lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    /// Single source of truth, shared by the popover and the status item, so
    /// neither has to rebuild the other to see new data.
    private let store = QuotaStore()
    private var schedulerToken: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist's LSUIElement only applies to a real .app bundle; `swift run`
        // produces a bare executable, so set the accessory policy explicitly too.
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        self.statusItem = statusItem

        // Built once and kept. Rebuilding the hosting controller on every
        // refresh destroyed view state and re-triggered a fetch on each cycle.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        )
        self.popover = popover

        // One owner for status item redraws.
        store.onSummaryChange = { [weak self] _ in
            self?.applyStatusItemPresentation()
        }
        applyStatusItemPresentation()

        Task {
            await store.load()
            await BackgroundScheduler.shared.start(interval: 120)
            schedulerToken = await BackgroundScheduler.shared.addHandler { [weak self] in
                await self?.store.load()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let token = schedulerToken
        Task {
            await BackgroundScheduler.shared.stop()
            if let token { await BackgroundScheduler.shared.removeHandler(token) }
        }
    }

    func openSettings() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaBar Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func applyStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        let summary = store.summary

        let symbol = MenuBarPresentation.symbolName(for: summary)
        let description = MenuBarPresentation.accessibilityDescription(for: summary)

        let image: NSImage?
        if let tint = MenuBarPresentation.tint(for: summary) {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(config)
        } else {
            // No tint: render as a template so the icon follows the menu bar
            // appearance (light/dark, reduced contrast) like a good citizen.
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            img?.isTemplate = true
            image = img
        }

        button.image = image
        button.toolTip = description
        button.setAccessibilityLabel(description)

        // Unreadable providers are a decoration, never a replacement icon.
        // The unavailable badge is reported via the accessibility label and
        // tooltip rather than a text suffix, which caused width jitter on a
        // variableLength status item as providers toggled between states.
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Show immediately with cached values, then update in place.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.load() }
    }
}

/// SwiftUI app entry point.
@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { SettingsView() }
    }
}
