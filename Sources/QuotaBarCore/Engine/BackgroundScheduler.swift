import Foundation

/// Periodic refresh driver.
///
/// Deliberately a `DispatchSourceTimer` rather than `NSBackgroundActivityScheduler`:
/// that API is for opportunistic, deferrable maintenance work, and treats its
/// `interval` as a lower bound the system may extend substantially on battery
/// or under thermal pressure. For a 2-minute quota poll that produces silently
/// stale readings with no signal to the user.
///
/// State is actor-isolated. The previous revision was a `@unchecked Sendable`
/// class whose `timer`, `activity` and `onRefresh` were mutated from the main
/// thread, the timer queue and the UI layer with nothing serialising them.
public actor BackgroundScheduler {

    public static let shared = BackgroundScheduler()

    private var timer: DispatchSourceTimer?
    private var handlers: [UUID: @Sendable () async -> Void] = [:]
    private var isRefreshing = false
    private let queue = DispatchQueue(label: "com.quotabar.scheduler", qos: .utility)

    /// Guards against a hung refresh wedging the scheduler permanently.
    private let refreshWatchdog: TimeInterval = 60

    init() {}

    /// Registers a refresh observer and returns a token to deregister with.
    ///
    /// This is additive rather than a single settable closure: the previous
    /// revision exposed one `var onRefresh`, and both the AppDelegate and the
    /// popover assigned to it — so opening the popover silently replaced the
    /// handler that updated the menu bar icon, and the icon stopped updating
    /// for the rest of the session.
    @discardableResult
    public func addHandler(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    public func removeHandler(_ token: UUID) {
        handlers.removeValue(forKey: token)
    }

    public func start(interval: TimeInterval = 120) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Jitter the first fire so a fleet of installs does not synchronise
        // into a retry storm against a vendor recovering from an outage.
        let jitter = Double.random(in: 0...(interval * 0.1))
        timer.schedule(
            deadline: .now() + interval + jitter,
            repeating: interval,
            leeway: .seconds(Int(interval * 0.2))   // power-friendly coalescing
        )
        timer.setEventHandler { [weak self] in
            Task { await self?.fire() }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func fire() async {
        // Skip rather than pile up if the previous cycle is still running.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let current = Array(handlers.values)
        for handler in current {
            // A handler that never returns must not wedge the scheduler.
            _ = await withDeadline(seconds: refreshWatchdog) {
                await handler()
            }
        }
    }
}
