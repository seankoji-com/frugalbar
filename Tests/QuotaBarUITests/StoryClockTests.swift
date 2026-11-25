import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// #221: the widget's Story follows the shared glance clock. It used to move
/// its time only on a load, so with the widget open across a published reset
/// it kept showing the ended window's "% left" as headroom until a poll
/// recorded a new attempt.
///
/// Hosts the production view (a helper-only test cannot see the wiring, #218)
/// with a fixed wall clock and an injected tick, so nothing here depends on
/// the date the suite runs or waits on a real 30-second boundary. What it
/// asserts is what the body itself derived (`ProviderStoryView.Drawn`): the
/// header's figure, the standing line and the burndown's projection.
@Suite("Widget Story follows the glance clock (#221)")
@MainActor
struct StoryClockTests {
    private struct FixtureProvider: QuotaProvider {
        let snapshot: QuotaSnapshot
        var vendorId: VendorIdentifier { snapshot.vendorId }
        var displayName: String { snapshot.displayName }
        var category: MetricCategory { snapshot.category }
        var instanceID: String { snapshot.id }
        func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
    }

    @MainActor
    private final class Capture {
        var drawn: [ProviderStoryView.Drawn] = []
    }

    private static let awaiting = "Window reset · awaiting a reading"

    private func waitFor(_ what: String, until done: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !done() {
            guard clock.now < deadline else {
                Issue.record("the hosted Story never drew \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// A week's readings rising towards the snapshot's figure, so the chart
    /// draws a recent-pace projection while the window is current.
    private func readings(for snapshot: QuotaSnapshot) throws -> [QuotaHistoryStore.ReadingRecord] {
        let wk = try #require(snapshot.quotaBars.first { $0.label == "WK" })
        return (0..<24).map { i in
            QuotaHistoryStore.ReadingRecord(vendor: snapshot.id, barLabel: "WK",
                measuredAt: GlanceFixtures.now.addingTimeInterval(-Double(23 - i) * 1800),
                fraction: 0.25 + Double(i) * 0.0045,
                isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: wk.resetsAt, windowLength: wk.windowLength, elapsedOnly: false)
        }
    }

    @Test("a reset passing while the Story is open turns it on the tick, and a later load does not undo it")
    func storyCrossesResetOnTick() async throws {
        let wallClock = GlanceFixtures.now
        let reset = wallClock.addingTimeInterval(3600)
        let claude = GlanceFixtures.snapshot("claude-story", .claude, "Claude", [
            GlanceFixtures.bar("WK", 0.35, resetsInHours: 1, windowHours: 168),
        ])
        let codex = GlanceFixtures.snapshot("codex-story", .openai, "Codex", [
            GlanceFixtures.bar("WK", 0.50, resetsInHours: 1, windowHours: 168),
        ])
        let providers = [claude, codex].map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(providerFactory: { providers },
                                                     displayPreferences: { .default }))
        await store.load()
        #expect(Set(store.snapshots.map(\.id)) == ["claude-story", "codex-story"])
        let history = try readings(for: claude) + readings(for: codex)

        let (ticks, tick) = AsyncStream<Date>.makeStream()
        defer { tick.finish() }
        let capture = Capture()
        func story(_ id: String) -> some View {
            ProviderStoryView(store: store, poolID: .constant(id), preloaded: (history, []),
                              ticks: { ticks }, clock: { wallClock },
                              drawObserver: { capture.drawn.append($0) })
                .frame(width: 360, height: 620)
        }

        let host = NSHostingView(rootView: story("claude-story"))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }

        // Opened before the reset: the window's headroom and its projection.
        try await waitFor("its first load") { capture.drawn.contains { $0.loads == 1 } }
        let opened = try #require(capture.drawn.last)
        #expect(opened.time == wallClock)
        #expect(opened.poolID == "claude-story")
        #expect(opened.standing != Self.awaiting)
        #expect(opened.heroRemaining != nil)
        #expect(opened.projects, "the fixture must draw a projection for the tick to remove")

        // A tick after the reset, with no load and no poll.
        let afterReset = reset.addingTimeInterval(1)
        tick.yield(afterReset)
        try await waitFor("the tick") { capture.drawn.last?.time == afterReset }
        let crossed = try #require(capture.drawn.last)
        #expect(crossed.loads == 1)
        #expect(crossed.standing == Self.awaiting)
        #expect(crossed.heroRemaining == nil)
        #expect(!crossed.projects)

        // Choosing another pool loads at the wall clock, which is before the
        // tick; the Story's time must not move back to it.
        host.rootView = story("codex-story")
        host.layoutSubtreeIfNeeded()
        try await waitFor("the second load") { capture.drawn.contains { $0.loads == 2 } }
        let reloaded = try #require(capture.drawn.last)
        #expect(reloaded.poolID == "codex-story")
        #expect(reloaded.time == afterReset)
        #expect(reloaded.standing == Self.awaiting)
        #expect(reloaded.heroRemaining == nil)
        #expect(!reloaded.projects)
    }

    @MainActor
    private final class WallClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class HeldRead: @unchecked Sendable {
        private let lock = NSLock()
        private var _entered = false
        var entered: Bool { lock.withLock { _entered } }
        func enter() { lock.withLock { _entered = true } }
    }

    @Test("a first history read held open across a reset cannot put the Story's time back")
    func heldFirstLoadDoesNotRewind() async throws {
        let wallClock = WallClock(GlanceFixtures.now)
        let afterReset = GlanceFixtures.now.addingTimeInterval(3600 + 1)
        let claude = GlanceFixtures.snapshot("claude-story", .claude, "Claude", [
            GlanceFixtures.bar("WK", 0.35, resetsInHours: 1, windowHours: 168),
        ])
        let history = try readings(for: claude)
        let held = HeldRead()
        let (release, releaser) = AsyncStream<Void>.makeStream()
        defer { releaser.finish() }
        let providers = [FixtureProvider(snapshot: claude)]
        let store = QuotaStore(
            manager: QuotaManager(providerFactory: { providers }, displayPreferences: { .default }),
            vendorReadingsLoader: { _, _ in
                held.enter()
                for await _ in release { break }
                return history
            })
        await store.load()

        let (ticks, tick) = AsyncStream<Date>.makeStream()
        defer { tick.finish() }
        let capture = Capture()
        func story() -> some View {
            ProviderStoryView(store: store, poolID: .constant("claude-story"),
                              ticks: { ticks }, clock: { wallClock.now },
                              drawObserver: { capture.drawn.append($0) })
                .frame(width: 360, height: 620)
        }
        let host = NSHostingView(rootView: story())
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }

        // The first load is waiting on its history read when the reset passes
        // and something redraws the Story.
        try await waitFor("its history read") { held.entered }
        wallClock.now = afterReset
        host.rootView = story()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        releaser.yield()
        try await waitFor("its first load") { capture.drawn.contains { $0.loads == 1 } }

        let times = capture.drawn.map(\.time)
        #expect(times == times.sorted(), "the Story's time went backwards: \(times)")
    }

    @Test("a late wake reports the newest boundary that has passed, not the one it slept for")
    func lateWakeReportsNewestTick() {
        let scheduled = Date(timeIntervalSinceReferenceDate: 1_000_020)
        // On time, or a hair early: the scheduled tick.
        #expect(GlanceClock.reportedTick(scheduled: scheduled, woke: scheduled.addingTimeInterval(0.004)) == scheduled)
        #expect(GlanceClock.reportedTick(scheduled: scheduled, woke: scheduled.addingTimeInterval(-0.004)) == scheduled)
        // 35 s late: the boundary at +30 s has passed, and a reset at +15 s
        // must not wait for the next one.
        #expect(GlanceClock.reportedTick(scheduled: scheduled, woke: scheduled.addingTimeInterval(35))
                == scheduled.addingTimeInterval(30))
    }
}
