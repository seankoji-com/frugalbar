import Foundation
import SwiftUI

/// The one display clock for the glance surfaces: the menu-bar title, the
/// popover's sections, its footer and the open inspector all re-derive on the
/// same wall-clock boundaries (every whole 30 seconds), so a published reset
/// that passes between polls takes effect on all of them on the same tick.
/// Each surface used to run its own 30-second timer from when it opened, and
/// the inspector only re-read its time on a data load, so one surface could
/// still forecast a window another already called "due".
public enum GlanceClock {
    public static let interval: TimeInterval = 30

    /// The first tick strictly after `date`.
    public static func nextTick(after date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (floor(t / interval) + 1) * interval)
    }

    /// A surface's clock never runs backwards: a load that finished after a
    /// tick already set a later time, and restoring the earlier instant put
    /// a window the popover already called "due" back on its forecast.
    public static func displayTime(current: Date, tick: Date) -> Date {
        max(current, tick)
    }

    /// The shared ticks as a sequence, for a surface that keeps its time in
    /// state (the widget's Story). Each element is the tick's own instant, so
    /// every surface describes the same moment. Ends when iteration is
    /// cancelled.
    public static func ticks() -> AsyncStream<Date> {
        AsyncStream { continuation in
            let task = Task {
                var last = Date.distantPast
                while !Task.isCancelled {
                    // Never the same tick twice, even if the sleep wakes early.
                    let tick = nextTick(after: max(Date(), last))
                    let wait = max(tick.timeIntervalSinceNow, 0.01)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { break }
                    last = tick
                    continuation.yield(tick)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A `TimelineView` schedule that draws once at `startDate` and then on every
/// `GlanceClock` tick.
public struct GlanceTickSchedule: TimelineSchedule {
    public init() {}

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var current: Date?
        return AnyIterator {
            let next = current.map(GlanceClock.nextTick(after:)) ?? startDate
            current = next
            return next
        }
    }
}

extension TimelineSchedule where Self == GlanceTickSchedule {
    /// Every `GlanceClock` tick, shared with the menu bar and the inspector.
    public static var glanceTicks: GlanceTickSchedule { GlanceTickSchedule() }
}
