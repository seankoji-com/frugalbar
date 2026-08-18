import SwiftUI
import AppKit
import QuotaBarCore
import QuotaBarUI

/// App delegate for NSStatusItem / Popover management.
/// Used because we need full control over the status item behavior.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "QuotaBar")

        // Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient  // closes on click outside
        popover.contentViewController = NSHostingController(rootView: PopoverRootView())
        popover.delegate = self
        self.popover = popover

        // Status item click handler
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.target = self

        // Start background polling
        BackgroundScheduler.shared.start(interval: 120)
        BackgroundScheduler.shared.onRefresh = { [weak self] in
            _ = await QuotaManager.shared.refresh()
            await self?.updateStatusItem()
        }

        // Initial fetch
        Task {
            _ = await QuotaManager.shared.refresh()
            await updateStatusItem()
        }
    }

    @objc @MainActor
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh cache on open
            Task {
                _ = await QuotaManager.shared.forceRefresh()
                await updateStatusItem()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        Task { @MainActor in
            let manager = QuotaManager.shared
            let snaps = await manager.sortedSnapshots()
            let summary = SystemHealthSummary.compute(from: snaps)

            // Update menu bar icon based on worst status
            let iconName: String
            let iconColor: NSColor
            switch summary.overallStatus {
            case .healthy:
                iconName = "gauge.with.needle"
                iconColor = .secondaryLabelColor
            case .warning:
                iconName = "gauge.with.needle"
                iconColor = .systemOrange
            case .critical, .rateLimited:
                iconName = "gauge.with.needle"
                iconColor = .systemRed
            case .unauthenticated, .networkError:
                iconName = "exclamationmark.triangle.fill"
                iconColor = .systemGray
            }

            let config = NSImage.SymbolConfiguration(paletteColors: [iconColor])
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: "QuotaBar")?
                .withSymbolConfiguration(config) {
                self.statusItem?.button?.image = img
            }

            // Update popover content
            if let popover = self.popover, popover.isShown {
                popover.contentViewController = NSHostingController(rootView: PopoverRootView())
            }
        }
    }

    // NSPopoverDelegate
    nonisolated func popoverDidClose(_ notification: Notification) {
        // no-op, transient behavior handles closing
    }
}

/// SwiftUI app entry point.
/// Uses NSApplicationDelegateAdaptor for the status item / popover lifecycle.
@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
