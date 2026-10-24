import AppKit
import Foundation
import QuotaBarCore
import UserNotifications

/// Posts FrugalBar's notification banners.
///
/// A `.app` posts through `UNUserNotificationCenter`, so macOS draws the
/// banner as FrugalBar's own: its name, its icon, and a click that opens the
/// event it describes. The bare `frugalbar` executable has no notification
/// application, so it keeps the `osascript` delivery that has always worked
/// there — at the cost of macOS attributing the banner to Script Editor.
@MainActor
enum NotificationDelivery {

    /// `userInfo` key carrying the event page a click should open.
    nonisolated static let linkKey = "frugalbar.event.url"

    /// Installs the delegate and asks for permission once, when the user has
    /// any kind of banner switched on. Asking at launch keeps the system
    /// prompt away from the moment an outage is being announced.
    static func prepare() {
        guard LocalNotificationIdentity.isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationPresenter.shared
        guard anyBannerEnabled else { return }
        requestAuthorizationIfNeeded()
    }

    /// Nonisolated on purpose: `getNotificationSettings` calls its completion
    /// on its own queue, and a closure formed in this main-actor type inherited
    /// the actor in the release build, trapping in `dispatch_assert_queue`
    /// before the body ran.
    nonisolated private static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Already refused (or turned off in System Settings): macOS will
            // not prompt again, and asking would only log a misleading error.
            guard settings.authorizationStatus != .denied else {
                NSLog("frugalbar: notifications are turned off for FrugalBar in System Settings")
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    NSLog("frugalbar: notification authorization failed: \(error)")
                } else if !granted {
                    NSLog("frugalbar: notifications are turned off for FrugalBar in System Settings")
                }
            }
        }
    }

    static func post(_ banner: AIEventBanner) {
        guard LocalNotificationIdentity.isAppBundle else {
            postViaAppleScript(banner)
            return
        }
        postBundled(banner)
    }

    /// Also nonisolated: every completion below runs off the main queue, so
    /// none of them may carry this type's actor isolation.
    nonisolated private static func postBundled(_ banner: AIEventBanner) {
        // `requestAuthorization` is idempotent: once the user has answered,
        // the completion arrives at once with the stored answer. Building the
        // content inside the completion keeps the non-Sendable notification
        // types from being captured across the boundary.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                NSLog("frugalbar: notification request failed: \(error)")
                fallBackUnlessDenied(banner)
                return
            }
            guard granted else {
                fallBackUnlessDenied(banner)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = banner.title
            if let subtitle = banner.subtitle, !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.body = banner.body
            if let url = banner.url, isWebLink(url) {
                content.userInfo[linkKey] = url.absoluteString
            }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("frugalbar: failed to deliver notification: \(error)")
                }
            }
        }
    }

    /// The AppleScript path is the bare binary's delivery, not a way around a
    /// refusal. A system that cannot authorize this app (still
    /// `.notDetermined`) keeps it; an explicit `.denied` does not.
    nonisolated private static func fallBackUnlessDenied(_ banner: AIEventBanner) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus != .denied else { return }
            Task { @MainActor in postViaAppleScript(banner) }
        }
    }

    /// Whether the user has asked for any banner at all. Event kinds default
    /// to every surfaced kind, so this is true for a default install; it
    /// becomes false only when every notification toggle is off, and then no
    /// permission prompt appears until one is switched on.
    private static var anyBannerEnabled: Bool {
        CredentialStore.isNotificationsEnabled
            || !CredentialStore.resetAlertVendors.isEmpty
            || (CredentialStore.isEventTrackingEnabled
                && !CredentialStore.eventNotificationKinds.isEmpty)
    }

    nonisolated private static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Bare executable

    /// `osascript` `display notification`, for the bare binary macOS has no
    /// notification identity for. The escaping keeps an interpolated vendor
    /// name or incident title from breaking out of the AppleScript string
    /// literal it is placed in.
    private static func postViaAppleScript(_ banner: AIEventBanner) {
        var script = "display notification \"\(escapeForAppleScript(banner.body))\" "
            + "with title \"\(escapeForAppleScript(banner.title))\""
        if let subtitle = banner.subtitle, !subtitle.isEmpty {
            script += " subtitle \"\(escapeForAppleScript(subtitle))\""
        }

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
        // blocks the poll) and its stderr logged.
        task.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("frugalbar: osascript exited with status \(process.terminationStatus) delivering notification: \(stderrText)")
        }
        do {
            try task.run()
        } catch {
            NSLog("frugalbar: failed to launch osascript for notification: \(error)")
        }
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Receives what the user does with a banner.
///
/// `@unchecked Sendable`: the only stored state is the shared instance, and
/// its handler is isolated to the main actor.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    /// Shown when a banner without a link is clicked: FrugalBar owns no
    /// window, so activating it alone would look like nothing happened.
    @MainActor static var activateHandler: (() -> Void)?

    /// A banner must still appear while FrugalBar is frontmost (Preferences
    /// or the popover open). Without this, macOS suppresses it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Clicking a banner opens the incident or model it describes. Banners
    /// that consolidate several events, or describe a quota transition, have
    /// no one page to open, so they show the popover instead.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[NotificationDelivery.linkKey] as? String
        await MainActor.run {
            if let raw, let url = URL(string: raw),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            } else if let handler = NotificationPresenter.activateHandler {
                handler()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
