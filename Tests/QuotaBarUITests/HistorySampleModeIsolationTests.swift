import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// C10: the History view's sample state is an injected dependency, not an
/// eager read of the running user's preference.
///
/// The behavioural checks enable the sample preference in the *test host's own*
/// suite (`com.quotabar.app.tests`, never `com.quotabar.app`) and then render.
/// They are gated like `UXRenderTests` because they host offscreen AppKit
/// views, and serialized because the preference they flip is process-wide: run
/// them in a focused invocation (`--filter HistorySampleModeIsolationTests`).
@Suite(
    "History sample-mode isolation",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil))
@MainActor
struct HistorySampleModeIsolationTests {

    /// Enables the isolated preference and returns the restore step. Refuses to
    /// run outside the test host, so it can never reach the user's file.
    private func enableSamplePreference() throws -> () -> Void {
        try #require(TestHost.isActive, "refusing to touch a preference outside the test host")
        #expect(CredentialStore.preferencesSuiteName(isTestHost: true) == "com.quotabar.app.tests")
        #expect(CredentialStore.preferencesSuiteName(isTestHost: true) != CredentialStore.sharedSuiteName)

        let defaults = CredentialStore.preferences
        let key = CredentialStore.sampleModeDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        return {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func temporaryStore(_ label: String) throws -> (QuotaHistoryStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c10-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = QuotaHistoryStore(
            databaseURL: root.appendingPathComponent("history.sqlite3"), isTestHost: true)
        return (store, { try? FileManager.default.removeItem(at: root) })
    }

    @MainActor
    private final class Capture {
        var states: [HistoryRootView.ReloadedState] = []
    }

    /// Hosts the production view and waits for its own completed reload. The
    /// wait is on the view's report, not on a fixed sleep.
    private func host(
        _ store: QuotaHistoryStore,
        clock: Date,
        sampleMode: HistoryRootView.SampleModeConfiguration
    ) async throws -> [HistoryRootView.ReloadedState] {
        let subject = HistoryOverviewPresentation.Subject(
            id: VendorIdentifier.openai.rawValue, vendor: .openai,
            name: VendorIdentifier.openai.displayName)
        let capture = Capture()
        let view = HistoryRootView(
            liveStore: store, sampleStore: store, initialRange: .last7Days,
            subjectSource: { ([subject], []) }, activityStatus: nil,
            clock: { clock },
            loadObserver: { capture.states.append($0) },
            sampleMode: sampleMode)
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

        let deadline = Date().addingTimeInterval(30)
        while capture.states.isEmpty {
            guard Date() < deadline else {
                Issue.record("the hosted HistoryRootView never reported a reload")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return capture.states
    }

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test("an enabled sample preference cannot reach the controlled evidence route")
    func evidenceRouteIgnoresEnabledPreference() async throws {
        let restore = try enableSamplePreference()
        defer { restore() }
        #expect(CredentialStore.isSampleModeEnabled, "the isolated preference really is enabled")
        // Ordinary use still answers the stored preference; the evidence route
        // must not ask it.
        #expect(HistoryRootView.SampleModeConfiguration.userPreference.initial())

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Old on purpose: a route that fell back to the wall clock would not
        // find these observations, and a route that honoured the enabled
        // preference would draw sample data instead of them.
        let reference = instant("2026-03-02T12:00:00Z")
        let fixture = ActivityEvidenceRenderer.Fixture.around(reference: reference, calendar: calendar)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c10-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try await ActivityEvidenceRenderer.render(to: root, fixture: fixture)

        // The fixture store records activities only. A reading here would be
        // the sample generator's, so this is the direct "no synthetic quota"
        // assertion rather than a string match on the PNG.
        #expect(report.controlledQuotaReadings == 0,
                "the evidence route generated synthetic quota into its fixture store")
        #expect(report.openAIProjects == ["/controlled/codex-alpha", "/controlled/codex-beta"])
        #expect(report.openCodeProjects.isEmpty, "OpenCode must not be assigned to a Go workspace")
        #expect(report.attributionWindowEnd == reference)
        #expect(report.attributionWindowStart
            == HistoryPresentation.TimeRange.last7Days.startDate(from: reference))

        // Neither rendering nor the explicit dependency may write the stored
        // preference, and the explicit value must not move when it is enabled.
        let explicit = HistoryRootView.SampleModeConfiguration.explicit(false)
        #expect(explicit.initial() == false)
        explicit.persist(true)
        #expect(CredentialStore.isSampleModeEnabled,
                "the controlled route wrote the stored sample preference")
    }

    @Test("the default state still follows the stored preference")
    func defaultStateStillFollowsStoredPreference() async throws {
        let restore = try enableSamplePreference()
        defer { restore() }
        #expect(CredentialStore.isSampleModeEnabled)

        let (store, removeStore) = try temporaryStore("default")
        defer { removeStore() }
        let states = try await host(store, clock: Date(), sampleMode: .userPreference)
        #expect(states.isEmpty == false)

        // Only sample mode calls the generator into the store, so real rows here
        // prove the ordinary path still reads the preference. Without this
        // control, a route that had hard-coded sample mode off would look fixed.
        let readings = try await store.fetchReadings(since: Date.distantPast)
        #expect(readings.isEmpty == false, "the default path no longer reads the sample preference")
    }

    @Test("an explicit state is resolved once and never writes the preference")
    func explicitStateIsResolvedOnce() async throws {
        let restore = try enableSamplePreference()
        defer { restore() }

        let (store, removeStore) = try temporaryStore("explicit")
        defer { removeStore() }
        var loads = 0
        var writes = 0
        let explicit = HistoryRootView.SampleModeConfiguration(
            initial: { loads += 1; return false },
            persist: { _ in writes += 1 })

        let states = try await host(store, clock: instant("2026-01-12T12:00:00Z"), sampleMode: explicit)
        #expect(states.isEmpty == false)
        #expect(loads == 1, "the injected state must be resolved exactly once")
        #expect(writes == 0)
        // An enabled preference is still enabled and still untouched.
        #expect(CredentialStore.isSampleModeEnabled)
        #expect(try await store.fetchReadings(since: Date.distantPast).isEmpty)
    }
}

/// The dependency itself, without hosting a view or touching a preference, so
/// this part runs in every test invocation.
@Suite("Sample mode configuration")
struct SampleModeConfigurationTests {

    @Test("an explicit state is its own value and routes toggles to its writer")
    func explicitStateIsSelfContained() {
        let value = HistoryRootView.SampleModeConfiguration.explicit(false)
        #expect(value.initial() == false)
        // Flipping the control calls the injected writer, not a preference.
        value.persist(true)

        #expect(HistoryRootView.SampleModeConfiguration.explicit(true).initial())

        var written: [Bool] = []
        let spy = HistoryRootView.SampleModeConfiguration(
            initial: { true }, persist: { written.append($0) })
        spy.persist(false)
        #expect(written == [false])
    }
}
