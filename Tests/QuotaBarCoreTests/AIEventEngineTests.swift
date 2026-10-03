import Testing
import Foundation
@testable import QuotaBarCore

@Suite("AIEventEngine")
struct AIEventEngineTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let catalogV1 = #"""
    {"data":[
      {"id":"anthropic/claude-opus-5-5","name":"Claude Opus 5.5","created":1799000000,
       "pricing":{"prompt":"0.000005","completion":"0.000025"}}
    ]}
    """#

    private static let catalogV2 = #"""
    {"data":[
      {"id":"anthropic/claude-opus-5-5","name":"Claude Opus 5.5","created":1799000000,
       "pricing":{"prompt":"0.000004","completion":"0.000025"}},
      {"id":"anthropic/claude-sonnet-5-5","name":"Claude Sonnet 5.5","created":1800021000,
       "pricing":{"prompt":"0.000003","completion":"0.000015"}}
    ]}
    """#

    private func engine(
        store: QuotaHistoryStore,
        log: FetchLog,
        catalog: @escaping @Sendable () -> String? = { nil },
        tracking: @escaping @Sendable () -> Bool = { true }
    ) -> AIEventEngine {
        AIEventEngine(
            store: store,
            catalogFetcher: {
                log.hit("catalog")
                return catalog().map { Data($0.utf8) }
            },
            feedFetcher: { feed in
                log.hit(feed.name)
                return []
            },
            feeds: [VendorFeed(name: "test-feed", url: URL(string: "https://example.invalid/f")!,
                               vendorId: .openai, isOfficial: true)],
            isTrackingEnabled: tracking
        )
    }

    /// Retention must not depend on the catalog/feed toggle: resets, restores
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

        let fresh = await engine.pollExternalSources(now: now)
        #expect(fresh.isEmpty)
        #expect(log.count("catalog") == 0)
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

    @Test("external sources poll immediately, then not again until the interval passes")
    func externalCadence() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let version = Box("v1")
        let engine = engine(store: store, log: log, catalog: {
            version.value == "v1" ? Self.catalogV1 : Self.catalogV2
        })

        // First ever poll seeds the catalog and announces nothing.
        #expect(await engine.pollExternalSources(now: now).isEmpty)
        #expect(log.count("catalog") == 1)
        #expect(log.count("test-feed") == 1)

        version.value = "v2"
        #expect(await engine.pollExternalSources(now: now.addingTimeInterval(3600)).isEmpty)
        #expect(log.count("catalog") == 1)

        let later = now.addingTimeInterval(AIEventEngine.externalPollInterval)
        let fresh = await engine.pollExternalSources(now: later)
        #expect(log.count("catalog") == 2)
        #expect(Set(fresh.map(\.kind)) == [.newModel, .priceChange])
        #expect(fresh.first { $0.kind == .newModel }?.title == "Claude Sonnet 5.5 listed")

        // The same catalog again, after another interval: nothing new.
        let again = await engine.pollExternalSources(now: later.addingTimeInterval(AIEventEngine.externalPollInterval))
        #expect(again.isEmpty)
        #expect(log.count("catalog") == 3)
    }

    /// Regression guard for the privacy toggle: off must mean no request.
    @Test("tracking off fetches nothing, and switching it on polls at once")
    func trackingOffNoFetch() async {
        let log = FetchLog()
        let enabled = Box(false)
        let engine = engine(store: makeIsolatedEventStore(), log: log, catalog: { Self.catalogV1 },
                            tracking: { enabled.value })
        #expect(await engine.pollExternalSources(now: now).isEmpty)
        #expect(log.total == 0)

        enabled.value = true
        _ = await engine.pollExternalSources(now: now.addingTimeInterval(60))
        #expect(log.count("catalog") == 1)
    }

    @Test("old events are pruned on an external poll")
    func prunesOldEvents() async throws {
        let store = makeIsolatedEventStore()
        let old = AIEvent(id: "old", kind: .newModel, vendorId: .claude, title: "old", detail: nil,
                          occurredAt: now.addingTimeInterval(-AIEventEngine.eventRetentionInterval - 86_400),
                          observedAt: now, source: .openRouterCatalog)
        let recent = AIEvent(id: "recent", kind: .newModel, vendorId: .claude, title: "recent", detail: nil,
                             occurredAt: now.addingTimeInterval(-86_400), observedAt: now, source: .openRouterCatalog)
        try await store.recordEvents([old, recent])
        let engine = engine(store: store, log: FetchLog())
        _ = await engine.pollExternalSources(now: now)
        #expect(try await store.fetchEvents().map(\.id) == ["recent"])
    }

    @Test("the live catalog fetch is stubbed and treats an error status as no catalog")
    func liveCatalogFetch() async throws {
        let log = FetchLog()
        let data = try await withEventStub({ request in
            log.hit(request.url?.absoluteString ?? "")
            return (200, Data(Self.catalogV1.utf8))
        }) {
            await OpenRouterCatalogWatcher.liveFetch()
        }
        #expect(data.flatMap(OpenRouterCatalogWatcher.parse)?.count == 1)
        let failed = try await withEventStub({ request in
            log.hit(request.url?.absoluteString ?? "")
            return (503, Data(Self.catalogV1.utf8))
        }) {
            await OpenRouterCatalogWatcher.liveFetch()
        }
        #expect(failed == nil)
        #expect(log.count(OpenRouterCatalogWatcher.catalogURL) == 2)
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
                       hoursAgo: Double = 1) -> AIEvent {
        AIEvent(id: id, kind: kind, vendorId: .claude, title: title, detail: detail,
                occurredAt: now.addingTimeInterval(-hoursAgo * 3600), observedAt: now,
                source: .openRouterCatalog)
    }

    @Test("one banner per kind, consolidated when several")
    func consolidates() {
        let banners = AIEventNotification.banners(
            for: [event("a", .newModel, title: "Claude Sonnet 5.5 listed"),
                  event("b", .newModel, title: "GPT-6 listed"),
                  event("c", .priceChange, title: "GPT-6 price changed", detail: "Prompt $2.50 → $2.00 per M tokens")],
            enabledKinds: CredentialStore.defaultEventNotificationKinds, now: now)
        #expect(banners == [
            AIEventBanner(title: "2 new models", body: "Claude Sonnet 5.5 listed; GPT-6 listed"),
            AIEventBanner(title: "Price change: GPT-6 price changed", body: "Prompt $2.50 → $2.00 per M tokens"),
        ])
    }

    /// Regression guard: a first feed poll keeps a week of items; none of
    /// them may arrive as a banner.
    @Test("events older than 48 hours, disabled kinds and usage resets never notify")
    func filters() {
        let banners = AIEventNotification.banners(
            for: [event("old", .newModel, title: "old", hoursAgo: 49),
                  event("off", .priceChange, title: "off"),
                  event("reset", .usageReset, title: "reset")],
            enabledKinds: [.newModel, .usageReset], now: now)
        #expect(banners.isEmpty)
    }

    @Test("a single event without detail falls back to its source caption")
    func fallbackBody() {
        let banners = AIEventNotification.banners(
            for: [event("a", .newModel, title: "Grok 5 listed", detail: nil)],
            enabledKinds: [.newModel], now: now)
        #expect(banners == [AIEventBanner(title: "New model: Grok 5 listed", body: "From the OpenRouter model catalog")])
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

    @Test("notification kinds default when absent, store sorted raw values, and keep an empty choice")
    func kindsRoundTrip() {
        let key = CredentialStore.eventNotificationKindsDefaultsKey
        let saved = CredentialStore.preferences.object(forKey: key)
        defer { CredentialStore.preferences.set(saved, forKey: key) }

        CredentialStore.preferences.removeObject(forKey: key)
        #expect(CredentialStore.eventNotificationKinds
                == [.usageRestored, .resetCreditGranted, .newModel, .priceChange])

        CredentialStore.eventNotificationKinds = [.priceChange, .newModel]
        #expect(CredentialStore.preferences.stringArray(forKey: key) == ["new_model", "price_change"])
        #expect(CredentialStore.eventNotificationKinds == [.newModel, .priceChange])

        CredentialStore.eventNotificationKinds = []
        #expect(CredentialStore.eventNotificationKinds.isEmpty)
    }

    @Test("stored kinds decode, dropping unknown values")
    func kindsDecode() {
        #expect(CredentialStore.eventNotificationKinds(fromStored: nil) == CredentialStore.defaultEventNotificationKinds)
        #expect(CredentialStore.eventNotificationKinds(fromStored: ["new_model", "retired"]) == [.newModel])
    }
}
