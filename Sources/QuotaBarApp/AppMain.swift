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
    private let historyStore: QuotaHistoryStore
    private let activityEngine: ActivityIngestionEngine
    private let store: QuotaStore
    private let eventEngine: AIEventEngine
    /// Sync to phone & watch. nil in a build with no sync client, which then
    /// never contacts Google and shows no sync setting.
    private let sync: SyncController?

    override init() {
        let hStore = QuotaHistoryStore()
        let aEngine = ActivityIngestionEngine(store: hStore)
        self.historyStore = hStore
        self.activityEngine = aEngine
        self.eventEngine = AIEventEngine(store: hStore)
        self.store = QuotaStore(
            manager: QuotaManager.shared,
            historyRecorder: { snapshots in
                // Recording is a small insert and stays on the refresh path, so a
                // reading is never lost. Both errors used to be discarded with
                // `try?`, which meant a history database that stopped accepting
                // writes looked exactly like one with nothing to record.
                do {
                    try await hStore.record(snapshots)
                    await MainActor.run {
                        NotificationCenter.default.post(name: .frugalbarHistoryDidRecord, object: nil)
                    }
                } catch {
                    NSLog("frugalbar: failed to record quota history: \(error)")
                }

                // Ingestion walks every CLI transcript and a multi-gigabyte
                // database, so it runs separately. It used to run inline, where
                // QuotaStore held `isRefreshing` for its whole duration and
                // silently dropped any refresh the user asked for meanwhile.
                Task.detached(priority: .utility) {
                    do {
                        _ = try await aEngine.ingestAll()
                    } catch {
                        NSLog("frugalbar: activity ingestion failed: \(error)")
                    }
                }
            },
            readingsLoader: { since in
                do {
                    return try await hStore.fetchReadings(since: since)
                } catch {
                    NSLog("frugalbar: failed to read quota history for forecast: \(error)")
                    return []
                }
            },
            // nil, not empty, on a failed read: the inspector says it could
            // not read the history rather than "0 readings" or "no events".
            vendorReadingsLoader: { vendor, since in
                do {
                    return try await hStore.fetchReadings(vendor: vendor, since: since)
                } catch {
                    NSLog("frugalbar: failed to read quota history for \(vendor.rawValue): \(error)")
                    return nil
                }
            },
            eventsLoader: { vendor, instanceId, kinds, since, limit in
                do {
                    return try await hStore.fetchEvents(
                        vendor: vendor, instanceID: instanceId, kinds: kinds, since: since, limit: limit)
                } catch {
                    NSLog("frugalbar: failed to read AI events: \(error)")
                    return nil
                }
            },
            tokenUsageLoader: { since, until, bucketSeconds, anchor in
                do {
                    return try await hStore.fetchTokenUsage(
                        since: since, until: until, bucketSeconds: bucketSeconds, anchor: anchor)
                } catch {
                    // nil, not an empty usage: the widget says it could not
                    // read the history rather than drawing "no activity".
                    NSLog("frugalbar: failed to read token usage: \(error)")
                    return nil
                }
            },
            // nil, not empty, on a failed read: the inspector says it could not
            // read the balance rather than drawing an empty history.
            balanceSeriesLoader: { since, until, bucketSeconds, seriesIds in
                do {
                    return try await hStore.fetchBalanceSeries(
                        since: since, until: until, bucketSeconds: bucketSeconds, seriesIds: seriesIds)
                } catch {
                    NSLog("frugalbar: failed to read balance history: \(error)")
                    return nil
                }
            },
            activityStatusLoader: { await aEngine.status() }
        )
        // Seven days of surfaced events, the window the export reads.
        self.sync = SyncController.makeIfAvailable(eventsLoader: {
            do {
                return try await hStore.fetchEvents(
                    kinds: Set(AIEventKind.surfaced), since: Date().addingTimeInterval(-SnapshotExporter.eventHorizon))
            } catch {
                return []
            }
        })
        super.init()
    }
    private var schedulerToken: UUID?
    private var providerPreferencesObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let notificationObserver = QuotaNotificationObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the accessory policy explicit for bare and wrapped executables.
        NSApp.setActivationPolicy(.accessory)

        let activity = activityEngine
        HistoryWindow.activityStatusLoader = { await activity.status() }

        // Adopt a choice made under an older, process-name-keyed preference
        // domain before deciding whether this is a first launch — otherwise
        // renaming the binary reads as a fresh install.
        CredentialStore.migrateLegacyPreferences()

        // The banner identity and (when a banner kind is on) the one-time
        // macOS permission prompt. No-op outside an app bundle.
        NotificationDelivery.prepare()

        // Seed the legacy OpenCode Go workspace once, on a first run. Kept off
        // the fetch path (`resolved()` reads without writing) so a poll never
        // writes preferences or posts the refresh such a write triggers.
        OpenCodeGoWorkspaceStore.persistLegacyIfNeeded()

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
                onOpenSettings: { [weak self] in self?.openSettings() },
                availableHeightProvider: { [weak statusItem] in
                    statusItem?.button?.window?.screen?.visibleFrame.height
                        ?? NSScreen.main?.visibleFrame.height
                }
            )
        )
        hostingController.view.appearance = NSAppearance(named: .darkAqua)
        // Let the popover track the view's own height. Without this the
        // hardcoded contentSize wins and any content past it is cut off.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        self.popover = popover

        // A clicked banner with no link of its own opens this popover; see
        // `NotificationPresenter.didReceive`.
        NotificationPresenter.activateHandler = { [weak self] in
            self?.presentPopoverFromNotification()
        }



        // One owner for status item redraws.
        store.onSummaryChange = { [weak self] _ in
            self?.applyStatusItemPresentation()
        }
        applyStatusItemPresentation()
        DesktopWidgetWindow.configure(store: store)

        // A change in Preferences → Providers takes effect now rather than on
        // the next two-minute poll. Captures `store`, not `self`.
        providerPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .frugalbarProviderPreferencesDidChange, object: nil, queue: .main
        ) { [store] _ in
            Task { @MainActor in await store.applyProviderPreferences() }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [store] _ in
            // Use the automatic path so the vendor's Retry-After still holds.
            Task { @MainActor in await store.load() }
        }

        // Capture `store` rather than `self`: an implicit strong `self` here
        // makes the handler's `[weak self]` meaningless (and is an error under
        // Swift 6.4 with warnings-as-errors).
        // Resumes an unfinished Stop and publishes off the poll path; it does
        // nothing until the owner turns sync on.
        sync?.start()

        Task { [weak self, store] in
            await store.load()
            self?.sync?.submit(snapshots: store.snapshots)
            if CredentialStore.isDesktopWidgetVisible { DesktopWidgetWindow.show() }
            await BackgroundScheduler.shared.start(interval: 120)
            // One handler for both jobs: adding a second would make the
            // recovery check race the refresh it depends on for no reason.
            let token = await BackgroundScheduler.shared.addHandler { [weak self] in
                await self?.store.load()
                // Hands the poll to sync and returns; the upload runs elsewhere.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sync?.submit(snapshots: self.store.snapshots)
                }
                await self?.checkForQuotaTransitions()
            }
            self?.schedulerToken = token
        }
    }

    /// Diffs the latest snapshots against the previous poll and delivers a
    /// notification for any critical→recovered transitions, when the user
    /// has opted in, and for window resets on providers the user opted in.
    ///
    /// `observeTransitions` runs on every poll regardless of the toggles, so
    /// the observer's "previous" state stays current even while notifications
    /// are off — only delivery is gated below.
    private func checkForQuotaTransitions() async {
        let now = Date()
        let transitions = await notificationObserver.observeTransitions(current: store.snapshots, now: now)
        if CredentialStore.isNotificationsEnabled, !transitions.recoveries.isEmpty {
            deliverRecoveryNotification(for: transitions.recoveries)
        }
        let optedIn = CredentialStore.resetAlertVendors
        let resets = transitions.resets.filter { optedIn.contains($0.vendorId) }
        if !resets.isEmpty {
            deliverResetNotification(for: resets)
        }
        await recordAIEvents(transitions, now: now)
    }

    /// Records every poll-derived event (resets for all vendors, not just the
    /// opted-in ones — the log is a record, the banner is the opt-in), then
    /// the external sources when due, and notifies on what was actually new.
    private func recordAIEvents(_ transitions: QuotaTransitions, now: Date) async {
        var fresh = await eventEngine.recordPollEvents(
            resets: transitions.resets,
            restores: transitions.restores,
            creditGrants: transitions.creditGrants,
            now: now
        )
        fresh += await eventEngine.pollExternalSources(now: now, vendors: store.configuredVendors)
        guard !fresh.isEmpty else { return }
        await store.reloadRecentEvents()
        let banners = AIEventNotification.banners(
            for: fresh, enabledKinds: CredentialStore.eventNotificationKinds, now: now)
        for banner in banners {
            NotificationDelivery.post(banner)
        }
    }

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
        NotificationDelivery.post(AIEventBanner(title: title, body: body))
    }

    /// One banner per poll, however many windows reset in it.
    private func deliverResetNotification(for events: [QuotaResetEvent]) {
        let title: String
        let body: String
        if events.count == 1, let event = events.first {
            title = "\(event.displayName) \(event.barLabel) window reset"
            body = "\(event.displayName)'s \(event.barLabel) allowance has started a new window."
        } else {
            title = "Quota windows reset"
            let names = events.map { "\($0.displayName) \($0.barLabel)" }.joined(separator: ", ")
            body = "New windows started: \(names)."
        }
        NotificationDelivery.post(AIEventBanner(title: title, body: body))
    }

    /// A banner's click lands here when it has no link of its own. FrugalBar
    /// owns no window, so activating the app alone would show nothing.
    private func presentPopoverFromNotification() {
        NSApp.activate(ignoringOtherApps: true)
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.load() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
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

        // Sized by the view, which fixes its own frame; a fixed content rect
        // used to clip it. The store lets each provider show what the last
        // poll made of it.
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, sync: sync)))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "FrugalBar Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }


    private func applyStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        let summary = store.summary
        let snapshots = store.snapshots

        let rec = MenuBarPresentation.limitingDetails(
            snapshots: snapshots,
            forecasts: store.forecasts,
            now: Date()
        )

        // Show the vendor whose quota needs attention, or the fallback gauge.
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
            let description = MenuBarPresentation.accessibilityDescription(for: summary, recommendation: rec)
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

        let description = MenuBarPresentation.accessibilityDescription(for: summary, recommendation: rec)
        button.toolTip = description
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
