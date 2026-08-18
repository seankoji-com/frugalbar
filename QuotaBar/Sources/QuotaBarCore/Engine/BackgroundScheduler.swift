import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Power-aware background scheduler using NSBackgroundActivityScheduler.
/// Manages periodic refresh of quota data without wasting battery.
public final class BackgroundScheduler: @unchecked Sendable {

    public static let shared = BackgroundScheduler()

    private var timer: DispatchSourceTimer?
    private var activity: Any?  // NSBackgroundActivityScheduler reference
    private let queue = DispatchQueue(label: "com.quotabar.scheduler", qos: .background)

    public var onRefresh: (@Sendable () async -> Void)?

    private init() {}

    /// Start with a given interval in seconds. Uses NSBackgroundActivityScheduler
    /// on macOS 15+ when available, falling back to DispatchSourceTimer.
    public func start(interval: TimeInterval = 120) {
        stop()

        #if canImport(AppKit)
        if #available(macOS 15, *) {
            let scheduler = NSBackgroundActivityScheduler(identifier: "com.quotabar.refresh")
            scheduler.repeats = true
            scheduler.interval = interval
            scheduler.tolerance = interval * 0.2  // 20% tolerance for power coalescing
            scheduler.schedule { [weak self] completion in
                Task { [weak self] in
                    await self?.onRefresh?()
                    completion(.finished)
                }
            }
            self.activity = scheduler
            return
        }
        #endif

        // Fallback: DispatchSourceTimer
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(Int(interval * 0.2)))
        t.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.onRefresh?()
            }
        }
        t.resume()
        self.timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        #if canImport(AppKit)
        if let act = activity as? NSBackgroundActivityScheduler {
            act.invalidate()
        }
        #endif
        activity = nil
    }

    deinit {
        stop()
    }
}
