import Testing
import Foundation
@testable import QuotaBarCore

@Suite("AIEventEngine")
struct AIEventEngineTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func engine(
        store: QuotaHistoryStore,
        log: FetchLog,
        tracker: @escaping @Sendable () -> String? = { nil },
        status: @escaping @Sendable () -> String? = { nil },
        tracking: @escaping @Sendable () -> Bool = { true }
    ) -> AIEventEngine {
        AIEventEngine(
            store: store,
            trackerFetcher: { t in
                log.hit("tracker:\(t.name)")
                return tracker().map { Data($0.utf8) }
            },
            statusFetcher: { page in
                log.hit("status:\(page.name)")
                return status().map { Data($0.utf8) }
            },
            modelLister: { vendor in
                log.hit("models:\(vendor.rawValue)")
                return nil
            },
            trackers: [ResetTracker(name: "claude-resets", url: URL(string: "https://example.invalid/r")!,
                                    host: "example.invalid", vendors: [.claude, .openai], format: .claudeResets)],
            statusPages: [StatusPage(name: "claude", vendorId: .claude,
                                     incidentsURL: URL(string: "https://example.invalid/s")!,
                                     pageURL: URL(string: "https://example.invalid")!,
                                     relevance: .components(["Claude Code"], includeUnscoped: true))],
            modelVendors: [.claude],
            isTrackingEnabled: tracking
        )
    }

    /// Retention must not depend on the tracking toggle: resets, restores
    /// and credits are recorded whether or not external sources are polled.
    @Test("events are pruned on the poll cadence even with tracking off")
    func pruneRunsWithTrackingOff() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let engine = engine(store: store, log: log, tracking: { false })
        let ancient = AIEvent(
            id: "old", kind: .usageReset, vendorId: .claude, title: "old", detail: nil,
            occurredAt: now.addingTimeInterval(-AIEventEngine.eventRetentionInterval - 86_400),
            observedAt: now, source: .quotaPoll)
        try await store.recordEvents([ancient])

        let fresh = await engine.pollExternalSources(now: now, vendors: [.claude])
        #expect(fresh.isEmpty)
        #expect(log.total == 0)
        let remaining = try await store.fetchEvents()
        #expect(remaining.isEmpty)
    }

    @Test("a restore that restarted the window says so in its detail")
    func restartedWindowDetail() async throws {
        let store = makeIsolatedEventStore()
        let engine = engine(store: store, log: FetchLog())
        let restore = UsageRestoredEvent(vendorId: .openai, displayName: "OpenAI", barLabel: "5H",
                                         previousFraction: 0.9, currentFraction: 0.0,
                                         resetsAt: now.addingTimeInterval(5 * 3600), windowRestarted: true)
        let events = await engine.recordPollEvents(resets: [], restores: [restore], creditGrants: [], now: now)
        #expect(events.first?.detail == "Used fell from 90% to 0% and the window restarted early; the new reset is 5 hours away")
    }

    @Test("poll-derived events are recorded once across repeated polls")
    func pollEventsDedupe() async throws {
        let store = makeIsolatedEventStore()
        let engine = engine(store: store, log: FetchLog())
        let reset = QuotaResetEvent(vendorId: .claude, displayName: "Claude", barLabel: "5H",
                                    resetsAt: now.addingTimeInterval(18_000))
        let restore = UsageRestoredEvent(vendorId: .openai, displayName: "OpenAI", barLabel: "WK",
                                         previousFraction: 0.73, currentFraction: 0.02,
                                         resetsAt: now.addingTimeInterval(4 * 86_400 + 60))
        let grant = ResetCreditGrantedEvent(vendorId: .openai, displayName: "OpenAI",
                                            previousCount: 0, currentCount: 1)

        let first = await engine.recordPollEvents(resets: [reset], restores: [restore], creditGrants: [grant], now: now)
        #expect(first.map(\.kind) == [.usageReset, .usageRestored, .resetCreditGranted])
        #expect(first[0].title == "Claude 5H window reset")
        #expect(first[1].title == "OpenAI WK usage restored")
        #expect(first[1].detail == "Used fell from 73% to 2% with 4 days left before the published reset")
        #expect(first[2].title == "OpenAI granted a usage reset credit")
        #expect(first[2].detail == "1 banked reset available — redeem in Codex to refill both windows")

        let second = await engine.recordPollEvents(resets: [reset], restores: [restore], creditGrants: [grant], now: now)
        #expect(second.isEmpty)
        #expect(try await store.fetchEvents().count == 3)
    }

    @Test("a reset without a reset time is not recorded")
    func resetWithoutTimeSkipped() async {
        let engine = engine(store: makeIsolatedEventStore(), log: FetchLog())
        let fresh = await engine.recordPollEvents(
            resets: [QuotaResetEvent(vendorId: .claude, displayName: "Claude", barLabel: "5H")],
            restores: [], creditGrants: [], now: now)
        #expect(fresh.isEmpty)
    }

    @Test("each source polls at once, then on its own cadence")
    func externalCadence() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let engine = engine(store: store, log: log,
                            tracker: { ResetTrackerWatcherTests.claudeResets },
                            status: { StatusIncidentWatcherTests.incidents })

        let first = await engine.pollExternalSources(now: now, vendors: [.claude])
        #expect(log.count("tracker:claude-resets") == 1)
        #expect(log.count("status:claude") == 1)
        #expect(log.count("models:claude") == 1)
        // History is backfilled into the log on the first poll.
        #expect(first.contains { $0.kind == .vendorReset })
        #expect(first.contains { $0.kind == .outageStarted })

        // Ten minutes on: only the status page is due again, and it records
        // nothing it already has.
        let later = now.addingTimeInterval(AIEventEngine.statusPollInterval)
        #expect(await engine.pollExternalSources(now: later, vendors: [.claude]).isEmpty)
        #expect(log.count("status:claude") == 2)
        #expect(log.count("tracker:claude-resets") == 1)

        // An hour on: the tracker is due, and re-reading it is harmless.
        let hour = now.addingTimeInterval(AIEventEngine.trackerPollInterval)
        #expect(await engine.pollExternalSources(now: hour, vendors: [.claude]).isEmpty)
        #expect(log.count("tracker:claude-resets") == 2)
    }

    @Test("an incident resolved after it was first seen records its recovery then")
    func recoveryRecordedLater() async throws {
        let store = makeIsolatedEventStore()
        let page = Box(StatusIncidentWatcherTests.openIncident)
        let engine = engine(store: store, log: FetchLog(), status: { page.value })

        let opened = await engine.pollExternalSources(now: now, vendors: [.claude])
        #expect(opened.map(\.kind) == [.outageStarted])

        page.value = StatusIncidentWatcherTests.resolvedIncident
        let resolved = await engine.pollExternalSources(
            now: now.addingTimeInterval(AIEventEngine.statusPollInterval), vendors: [.claude])
        #expect(resolved.map(\.kind) == [.outageResolved])
        #expect(resolved.first?.detail == "Resolved after 1h 30m")
    }

    /// Regression guard for the privacy toggle: off must mean no request.
    @Test("tracking off fetches nothing, and switching it on polls at once")
    func trackingOffNoFetch() async {
        let log = FetchLog()
        let enabled = Box(false)
        let engine = engine(store: makeIsolatedEventStore(), log: log,
                            tracker: { ResetTrackerWatcherTests.claudeResets },
                            tracking: { enabled.value })
        #expect(await engine.pollExternalSources(now: now, vendors: [.claude]).isEmpty)
        #expect(log.total == 0)

        enabled.value = true
        _ = await engine.pollExternalSources(now: now.addingTimeInterval(60), vendors: [.claude])
        #expect(log.count("tracker:claude-resets") == 1)
    }

    @Test("with no configured vendor nothing is fetched")
    func noVendorsNoFetch() async {
        let log = FetchLog()
        let engine = engine(store: makeIsolatedEventStore(), log: log)
        #expect(await engine.pollExternalSources(now: now, vendors: []).isEmpty)
        #expect(log.total == 0)
    }

    @Test("old events are pruned on an external poll")
    func prunesOldEvents() async throws {
        let store = makeIsolatedEventStore()
        let old = AIEvent(id: "old", kind: .vendorReset, vendorId: .claude, title: "old", detail: nil,
                          occurredAt: now.addingTimeInterval(-AIEventEngine.eventRetentionInterval - 86_400),
                          observedAt: now, source: .resetTracker(name: "claude-resets"))
        let recent = AIEvent(id: "recent", kind: .vendorReset, vendorId: .claude, title: "recent", detail: nil,
                             occurredAt: now.addingTimeInterval(-86_400), observedAt: now,
                             source: .resetTracker(name: "claude-resets"))
        try await store.recordEvents([old, recent])
        let engine = engine(store: store, log: FetchLog())
        _ = await engine.pollExternalSources(now: now, vendors: [.claude])
        #expect(try await store.fetchEvents().map(\.id) == ["recent"])
    }

    @Test("remaining time is whole units from an explicit now")
    func remainingText() {
        #expect(AIEventEngine.remaining(until: now.addingTimeInterval(4 * 86_400 + 5), now: now) == "4 days")
        #expect(AIEventEngine.remaining(until: now.addingTimeInterval(86_400), now: now) == "1 day")
        #expect(AIEventEngine.remaining(until: now.addingTimeInterval(3 * 3600 + 59), now: now) == "3 hours")
        #expect(AIEventEngine.remaining(until: now.addingTimeInterval(30), now: now) == "1 minute")
    }
}

/// A mutable value a `@Sendable` test closure can read.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("AIEventNotification")
struct AIEventNotificationTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, _ kind: AIEventKind, title: String, detail: String? = "detail",
                       hoursAgo: Double = 1, source: AIEventSource = .resetTracker(name: "claude-resets"),
                       vendor: VendorIdentifier = .claude) -> AIEvent {
        AIEvent(id: id, kind: kind, vendorId: vendor, title: title, detail: detail,
                occurredAt: now.addingTimeInterval(-hoursAgo * 3600), observedAt: now,
                source: source)
    }

    @Test("one banner per kind, consolidated when several")
    func consolidates() {
        let banners = AIEventNotification.banners(
            for: [event("a", .newModel, title: "GPT-6.2 now available in Codex", source: .accountModels),
                  event("b", .newModel, title: "Claude Opus 5.5 now available in Claude", source: .accountModels),
                  event("c", .vendorReset, title: "Claude reset for everyone", detail: "Shipped Opus 5.5.")],
            enabledKinds: CredentialStore.defaultEventNotificationKinds, now: now)
        #expect(banners == [
            AIEventBanner(title: "2 new models",
                          body: "GPT-6.2 now available in Codex; Claude Opus 5.5 now available in Claude"),
            AIEventBanner(title: "Claude reset for everyone", body: "Shipped Opus 5.5."),
        ])
    }

    @Test("an outage banner names the vendor the incident title may not")
    func outageNamesVendor() {
        let banners = AIEventNotification.banners(
            for: [event("o", .outageStarted, title: "Outage: Elevated errors across all models",
                        detail: "Major impact", source: .statusPage(name: "claude"))],
            enabledKinds: [.outageStarted], now: now)
        #expect(banners == [AIEventBanner(title: "Claude · Outage: Elevated errors across all models",
                                          body: "Major impact")])
    }

    /// Regression guard: a first poll backfills months of resets and
    /// outages; none of them may arrive as a banner.
    @Test("old events, disabled kinds, usage resets and retired rows never notify")
    func filters() {
        let banners = AIEventNotification.banners(
            for: [event("old", .vendorReset, title: "old", hoursAgo: 49),
                  event("off", .outageResolved, title: "off", source: .statusPage(name: "claude")),
                  event("reset", .usageReset, title: "reset", source: .quotaPoll),
                  event("catalog", .newModel, title: "listed", source: .openRouterCatalog),
                  event("feed", .newModel, title: "news", source: .vendorFeed(name: "openai-news")),
                  event("price", .priceChange, title: "price", source: .openRouterCatalog)],
            enabledKinds: [.vendorReset, .usageReset, .newModel, .priceChange], now: now)
        #expect(banners.isEmpty)
    }

    @Test("a single event without detail falls back to its source caption")
    func fallbackBody() {
        let banners = AIEventNotification.banners(
            for: [event("a", .newModel, title: "Grok 5 now available in Grok", detail: nil,
                        source: .accountModels, vendor: .grok)],
            enabledKinds: [.newModel], now: now)
        #expect(banners == [AIEventBanner(title: "Grok 5 now available in Grok",
                                          body: "From your account's model list")])
    }
}

@Suite("AI event preferences", .serialized)
struct AIEventPreferenceTests {

    @Test("tracking defaults to on and round-trips through the preferences suite")
    func trackingRoundTrip() {
        let key = CredentialStore.eventTrackingEnabledDefaultsKey
        let saved = CredentialStore.preferences.object(forKey: key)
        defer { CredentialStore.preferences.set(saved, forKey: key) }

        CredentialStore.preferences.removeObject(forKey: key)
        #expect(CredentialStore.isEventTrackingEnabled)
        CredentialStore.isEventTrackingEnabled = false
        #expect(CredentialStore.preferences.object(forKey: key) as? Bool == false)
        #expect(!CredentialStore.isEventTrackingEnabled)
        CredentialStore.isEventTrackingEnabled = true
        #expect(CredentialStore.isEventTrackingEnabled)
    }

    @Test("notification kinds default to every surfaced kind and store the opt-outs")
    func kindsRoundTrip() {
        let key = CredentialStore.eventNotificationDisabledKindsDefaultsKey
        let legacyKey = CredentialStore.eventNotificationKindsDefaultsKey
        let saved = CredentialStore.preferences.object(forKey: key)
        let savedLegacy = CredentialStore.preferences.object(forKey: legacyKey)
        defer {
            CredentialStore.preferences.set(saved, forKey: key)
            CredentialStore.preferences.set(savedLegacy, forKey: legacyKey)
        }

        CredentialStore.preferences.removeObject(forKey: key)
        CredentialStore.preferences.removeObject(forKey: legacyKey)
        #expect(CredentialStore.eventNotificationKinds == Set(AIEventKind.surfaced))

        CredentialStore.eventNotificationKinds = Set(AIEventKind.surfaced).subtracting([.outageStarted, .newModel])
        #expect(CredentialStore.preferences.stringArray(forKey: key) == ["new_model", "outage_started"])
        #expect(!CredentialStore.eventNotificationKinds.contains(.outageStarted))
        #expect(CredentialStore.eventNotificationKinds.contains(.vendorReset))

        CredentialStore.eventNotificationKinds = []
        #expect(CredentialStore.eventNotificationKinds.isEmpty)
    }

    /// The bug the opt-out list exists to prevent: someone who once unticked
    /// a box under the old opt-in list must still get the kinds added since.
    @Test("an older opt-in choice is honoured for its kinds, and newer kinds are on")
    func legacyMigration() {
        let kinds = CredentialStore.eventNotificationKinds(
            disabled: nil, legacyEnabled: ["usage_restored", "price_change", "retired"])
        #expect(kinds.contains(.usageRestored))
        #expect(!kinds.contains(.resetCreditGranted))
        #expect(!kinds.contains(.newModel))
        #expect(kinds.contains(.vendorReset))
        #expect(kinds.contains(.outageStarted))
        #expect(kinds.contains(.outageResolved))

        #expect(CredentialStore.eventNotificationKinds(disabled: nil, legacyEnabled: nil)
                == CredentialStore.defaultEventNotificationKinds)
        // The opt-out list wins over a stale opt-in list.
        #expect(CredentialStore.eventNotificationKinds(disabled: ["vendor_reset", "retired"], legacyEnabled: [])
                == CredentialStore.defaultEventNotificationKinds.subtracting([.vendorReset]))
    }
}
