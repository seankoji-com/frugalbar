import SwiftUI
import AppKit
import Foundation
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
    private let notificationObserver = QuotaNotificationObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist's LSUIElement only applies to a real .app bundle; `swift run`
        // produces a bare executable, so set the accessory policy explicitly too.
        NSApp.setActivationPolicy(.accessory)

        // Adopt a choice made under an older, process-name-keyed preference
        // domain before deciding whether this is a first launch — otherwise
        // renaming the binary reads as a fresh install.
        CredentialStore.migrateLegacyPreferences()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        self.statusItem = statusItem

        // Built once and kept. Rebuilding the hosting controller on every
        // refresh destroyed view state and re-triggered a fetch on each cycle.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        // An initial hint only. `sizingOptions` below hands sizing to SwiftUI,
        // which is what keeps a taller-than-expected card from being clipped.
        popover.contentSize = NSSize(width: PopoverRootView.popoverWidth, height: PopoverRootView.popoverHeight)
        let hostingController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        )
        hostingController.view.appearance = NSAppearance(named: .darkAqua)
        // Let the popover track the view's own height. Without this the
        // hardcoded contentSize wins and any content past it is cut off.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        self.popover = popover



        // One owner for status item redraws.
        store.onSummaryChange = { [weak self] _ in
            self?.applyStatusItemPresentation()
        }
        applyStatusItemPresentation()

        Task {
            await store.load()
            await BackgroundScheduler.shared.start(interval: 120)
            // One handler for both jobs: adding a second would make the
            // recovery check race the refresh it depends on for no reason.
            schedulerToken = await BackgroundScheduler.shared.addHandler { [weak self] in
                await self?.store.load()
                await self?.checkForQuotaRecovery()
            }
        }
    }

    /// Diffs the latest snapshots against the previous poll and delivers a
    /// notification for any critical→recovered transitions, when the user
    /// has opted in.
    ///
    /// `observe` runs on every poll regardless of the toggle, so the
    /// observer's "previous" state stays current even while notifications are
    /// off — only delivery is gated below.
    private func checkForQuotaRecovery() async {
        let events = await notificationObserver.observe(current: store.snapshots)
        guard CredentialStore.isNotificationsEnabled, !events.isEmpty else { return }
        deliverRecoveryNotification(for: events)
    }

    /// Posts one `display notification` via `osascript` for the whole batch.
    ///
    /// A poll can surface more than one vendor recovering at once; one
    /// `Process` per event would fire a burst of separate system banners for
    /// what is, from the user's point of view, a single poll result, so
    /// multiple events are consolidated into one notification.
    ///
    /// `UNUserNotificationCenter` is not an option: this app ships as a bare
    /// executable with no `.app` bundle, so `Bundle.main.bundleIdentifier` is
    /// nil and `UNUserNotificationCenter.current()` crashes the process. This
    /// mechanism needs no bundle identity and no authorization request.
    private func deliverRecoveryNotification(for events: [QuotaRecoveryEvent]) {
        let title: String
        let body: String
        if events.count == 1, let event = events.first {
            title = "\(event.displayName) quota recovered"
            body = "\(event.displayName) has headroom again."
        } else {
            title = "Quota recovered"
            let names = events.map(\.displayName).joined(separator: ", ")
            body = "\(names) have headroom again."
        }
        let script = "display notification \"\(Self.escapeForAppleScript(body))\" with title \"\(Self.escapeForAppleScript(title))\""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.standardInput = FileHandle.nullDevice
        // Best-effort: neither a launch failure nor a runtime/compile failure
        // of the AppleScript itself may crash or block the poll — but they
        // must not vanish silently either. The app has no logging infra to
        // plug into, so this uses the one channel that needs none: NSLog,
        // which lands in the unified log (`log show --predicate 'process ==
        // "frugalbar"'`) without requiring a bundle identity, matching the
        // same unbundled-executable constraint that rules out
        // UNUserNotificationCenter above. Non-zero exit status is captured
        // via `terminationHandler` (off the caller's thread, so this never
        // blocks the poll) and its stderr logged, mirroring the
        // failure-logging pattern in OpenRouterProvider.fetchModelBadges().
        task.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("frugalbar: osascript exited with status \(process.terminationStatus) delivering quota-recovery notification: \(stderrText)")
        }
        do {
            try task.run()
        } catch {
            NSLog("frugalbar: failed to launch osascript for quota-recovery notification: \(error)")
        }
    }

    /// Escapes backslashes and double quotes so an interpolated vendor name
    /// cannot break out of the AppleScript string literal it is placed in.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
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
        window.title = "FrugalBar Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }


    private func applyStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        let summary = store.summary
        let advice = store.advice
        let snapshots = store.snapshots

        let rec = MenuBarPresentation.recommendationDetails(
            advice: advice,
            snapshots: snapshots,
            summary: summary
        )

        // 1. Set MenuBar Icon to recommended vendor logo or fallback gauge
        if let vendorId = rec.vendorId, let rawImg = VendorSVGLogo.nsImage(for: vendorId) {
            let icon = NSImage(size: NSSize(width: 18, height: 18))
            icon.isTemplate = false
            icon.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            rawImg.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1.0)
            icon.unlockFocus()
            button.image = icon
            button.imagePosition = .imageLeft
        } else {
            let symbol = MenuBarPresentation.symbolName(for: summary)
            let description = MenuBarPresentation.accessibilityDescription(for: summary)
            let image: NSImage?
            if let tint = MenuBarPresentation.tint(for: summary) {
                let config = NSImage.SymbolConfiguration(paletteColors: [tint])
                image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                    .withSymbolConfiguration(config)
            } else {
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
                img?.isTemplate = true
                image = img
            }
            button.image = image
            button.imagePosition = .imageLeft
        }


        // 2. Set Attributed Title with remaining lowest quota, coloured by
        // urgency instead of always red. Deliberately the *same*
        // `MenuBarPresentation.tint` the glyph above uses: a title in a
        // different colour from the icon beside it reads as two conflicting
        // readings. nil tint means "no quota pressure" — follow the menu bar's
        // own label colour rather than forcing one.
        if let displayText = rec.displayText, !displayText.isEmpty {
            // Recommended-vendor path: colour the *recommended vendor's own*
            // reading, not the whole-summary worst urgency. A healthy
            // recommendation must stay untinted (`.labelColor`) even when some
            // other vendor is critical.
            let titleColor = rec.recommendedTint ?? .labelColor
            let attr = NSAttributedString(
                string: " " + displayText,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold),
                    .foregroundColor: titleColor
                ]
            )
            button.attributedTitle = attr
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }

        let description = MenuBarPresentation.accessibilityDescription(for: summary)
        button.toolTip = "\(description)\nRecommended: \(advice.headline)"
        button.setAccessibilityLabel(description)
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

    /// Runs before any Scene is built, and before `applicationDidFinishLaunching`
    /// fires on the `@NSApplicationDelegateAdaptor`-constructed app delegate —
    /// so a CLI invocation exits here, before the app's window/menu-bar
    /// machinery ever starts, rather than after a status item has already
    /// appeared.
    init() {
        if let exitCode = CLIArguments.handleIfPresent() {
            exit(exitCode)
        }
    }

    var body: some Scene {
        Settings { SettingsView() }
    }
}
