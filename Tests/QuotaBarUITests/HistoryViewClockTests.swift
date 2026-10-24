import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// C9: the hosted production `HistoryRootView` must query and present the
/// window its injected instant names, not the wall clock.
///
/// Gated like `UXRenderTests` because it hosts offscreen AppKit views. The
/// fixture is deliberately old (January 2026) so a view that fell back to
/// `Date()` would need `now` to be within seven days of it to pass; the same
/// data is then rendered again under a reference that excludes it, proving the
/// window follows the injected value rather than the host's calendar.
@Suite("History view clock", .enabled(if: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil))
@MainActor
struct HistoryViewClockTests {

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func completeStatus() -> ActivityIngestionEngine.Status {
        ActivityIngestionEngine.Status(
            hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false,
            sources: [ActivitySourceStatus(
                source: "codex", recordsObserved: 1, lastPassComplete: true)])
    }

    @MainActor
    private final class Capture {
        var states: [HistoryRootView.ReloadedState] = []
    }

    /// Hosts the production view with an explicit clock and waits for the view's
    /// own reload report. No fixed sleep decides whether the query finished.
    private func hostedState(
        store: QuotaHistoryStore, clock: Date
    ) async throws -> HistoryRootView.ReloadedState {
        let subject = HistoryOverviewPresentation.Subject(
            id: VendorIdentifier.openai.rawValue, vendor: .openai,
            name: VendorIdentifier.openai.displayName)
        let status = completeStatus()
        let capture = Capture()
        let view = HistoryRootView(
            liveStore: store, sampleStore: store, initialRange: .last7Days,
            subjectSource: { ([subject], []) }, activityStatus: { status },
            clock: { clock },
            loadObserver: { capture.states.append($0) })
            .frame(width: 880, height: 820)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }

        let deadline = Date().addingTimeInterval(10)
        while capture.states.isEmpty {
            guard Date() < deadline else {
                Issue.record("the hosted HistoryRootView never reported a reload")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(capture.states.last)
    }

    @Test("an old fixture draws its attribution when the view is given its reference")
    func oldFixtureIsDrawnUnderItsReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c9-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaHistoryStore(
            databaseURL: root.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let reference = instant("2026-01-12T12:00:00Z")
        let observation = instant("2026-01-11T10:00:00Z")
        try await store.recordActivities([ActivityRecord(
            source: "codex", recordId: "c9-old", sessionId: "c9-session",
            projectPath: "/controlled/c9-old", observedAt: observation,
            inputTokens: 700_000, outputTokens: 300_000, totalTokens: 1_000_000)])

        let state = try await hostedState(store: store, clock: reference)
        print("C9_STATE reference=\(state.referenceDate.timeIntervalSince1970) windowStart=\(state.windowStart!.timeIntervalSince1970) wall=\(Date().timeIntervalSince1970) projects=\(state.attribution?.projectAttributions.map(\.projectPath) ?? [])")

        // The window the view itself used is the injected one.
        #expect(state.referenceDate == reference)
        #expect(state.windowStart == HistoryPresentation.TimeRange.last7Days.startDate(from: reference))
        #expect(state.attribution?.windowStart == state.windowStart)
        #expect(state.attribution?.windowEnd == reference)
        #expect(state.failed == false)
        // The project inside that window was actually attributed by the view.
        #expect(state.attribution?.projectAttributions.map(\.projectPath) == ["/controlled/c9-old"])
    }

    @Test("the same data is excluded under a later reference, so the window is injected")
    func laterReferenceMovesTheWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c9-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaHistoryStore(
            databaseURL: root.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let observation = instant("2026-01-11T10:00:00Z")
        try await store.recordActivities([ActivityRecord(
            source: "codex", recordId: "c9-late", sessionId: "c9-session",
            projectPath: "/controlled/c9-old", observedAt: observation,
            inputTokens: 700_000, outputTokens: 300_000, totalTokens: 1_000_000)])

        let later = instant("2026-03-01T12:00:00Z")
        let state = try await hostedState(store: store, clock: later)
        print("C9_LATE reference=\(state.referenceDate.timeIntervalSince1970) windowStart=\(state.windowStart!.timeIntervalSince1970) projects=\(state.attribution?.projectAttributions.map(\.projectPath) ?? [])")

        #expect(state.referenceDate == later)
        #expect(state.windowStart == HistoryPresentation.TimeRange.last7Days.startDate(from: later))
        #expect(state.attribution?.windowStart == state.windowStart)
        #expect(state.attribution?.windowEnd == later)
        #expect(state.attribution?.projectAttributions.isEmpty == true)
    }
}
