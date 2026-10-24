import Foundation
import UserNotifications

/// What macOS knows about this process as a notification sender.
///
/// FrugalBar ships as a bare executable and can also run from a local `.app`
/// wrapper. Only the bundle has a notification application of its own: the
/// bare binary carries a `CFBundleIdentifier` in its embedded `__info_plist`,
/// but macOS never registers it as an app, so a banner posted through
/// `UNUserNotificationCenter` there would not be attributed to FrugalBar.
/// Delivery therefore branches on `isAppBundle` — see `NotificationDelivery`
/// in the app target.
public enum LocalNotificationIdentity {

    /// True when the running executable lives inside a `.app` bundle.
    public static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// This app's notification permission, or nil when the process has no
    /// notification identity to ask about (a bare executable) or is a test
    /// host, which must never touch the real notification centre.
    public static func authorizationStatus() async -> LocalNotificationPermission? {
        guard isAppBundle, !TestHost.isActive else { return nil }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return LocalNotificationPermission(status)
    }
}

/// `UNAuthorizationStatus`, reduced to the distinctions FrugalBar acts on.
public enum LocalNotificationPermission: Sendable, Equatable {
    case notDetermined
    /// The user refused, or turned FrugalBar off in System Settings. Banners
    /// will not appear; the notification toggles must not pretend otherwise.
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .notDetermined
        }
    }
}
