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
/// and drives it with an injected tick, so no test waits on the wall clock.
/// The fixtures sit at `GlanceFixtures.now` (January 2027), after the wall
/// clock, so the view's own starting time and any load's `Date()` are before
/// the reset and only a tick can carry the Story past it.
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
        var reports: [(time: Date, story: ProviderStoryPresentation?)] = []
    }

    private func waitFor(_ capture: Capture, _ what: String,
                         until done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else {
                Issue.record("the hosted Story never reported \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("a reset passing while the Story is open turns it on the tick, and a later load does not undo it")
    func storyCrossesResetOnTick() async throws {
        let reset = GlanceFixtures.now.addingTimeInterval(3600)
        #expect(Date() < reset, "the fixture reset must be after the wall clock")
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

        let (ticks, tick) = AsyncStream<Date>.makeStream()
        defer { tick.finish() }
        let capture = Capture()
        func story(_ id: String) -> some View {
            ProviderStoryView(store: store, poolID: .constant(id), preloaded: ([], []),
                              ticks: { ticks },
                              timeObserver: { capture.reports.append(($0, $1)) })
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

        // Opened before the reset: the window's headroom is the story.
        try await waitFor(capture, "its first load") { !capture.reports.isEmpty }
        let opened = try #require(capture.reports.last?.story)
        #expect(opened.standing != "Window reset · awaiting a reading")
        #expect(opened.heroRemaining != nil)

        // A tick after the reset, with no load and no poll.
        let afterReset = reset.addingTimeInterval(1)
        tick.yield(afterReset)
        try await waitFor(capture, "the tick") { capture.reports.contains { $0.time == afterReset } }
        let crossed = try #require(capture.reports.last?.story)
        #expect(crossed.standing == "Window reset · awaiting a reading")
        #expect(crossed.heroRemaining == nil)

        // Choosing another pool loads at the wall clock, which is before the
        // tick; the Story's time must not move back to it.
        let reportsBefore = capture.reports.count
        host.rootView = story("codex-story")
        host.layoutSubtreeIfNeeded()
        try await waitFor(capture, "the second load") { capture.reports.count > reportsBefore }
        let reloaded = try #require(capture.reports.last)
        #expect(reloaded.time == afterReset)
        #expect(reloaded.story?.poolID == "codex-story")
        #expect(reloaded.story?.standing == "Window reset · awaiting a reading")
    }
}
