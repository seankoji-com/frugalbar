import Testing
import Foundation
@testable import QuotaBarCore

@Suite("ResetTrackerWatcher")
struct ResetTrackerWatcherTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    /// The shape claude-resets.com serves: per-vendor curated events, with
    /// limit-policy entries mixed in and unverified ids named in `meta`.
    static let claudeResets = #"""
    {"providers":{
      "claude":{"name":"Claude","events":[
        {"id":"111","date":"2027-01-10T18:35:27Z","kind":"reset","scope":"all",
         "note":"Shipped Opus 6 and reset 5-hour and weekly limits for all users.",
         "url":"https://x.com/ClaudeDevs/status/111","verification":"curated"},
        {"id":"112","date":"2027-01-11T10:00:00Z","kind":"policy",
         "note":"Raised weekly limits.","url":"https://x.com/ClaudeDevs/status/112","verification":"curated"},
        {"id":"113","date":"2027-01-12T16:44:06Z","kind":"reset","resetType":"banked",
         "usableUntil":"2027-02-10T23:59:59Z","scope":"Pro, Max + Team",
         "note":"Gave Pro, Max and Team users a banked reset.","url":"https://x.com/ClaudeDevs/status/113",
         "verification":"curated"},
        {"id":"114","date":"2027-01-14T09:00:00Z","kind":"reset","scope":"all","note":"Maybe a reset?",
         "url":"https://x.com/ClaudeDevs/status/114","verification":"curated"}
      ]},
      "codex":{"name":"Codex","events":[
        {"id":"221","date":"2027-01-13T21:18:48Z","kind":"reset","resetType":"regular",
         "note":"Reset all propagated. Enjoy.","url":"https://x.com/thsottiaux/status/221","verification":"upstream"}
      ]}
    },
    "meta":{"provisionalEventIds":["114"]}}
    """#

    /// The shape whenreset.dev serves.
    static let whenReset = #"""
    {"events":[
      {"id":"grok-331","provider":"grok","type":"reset","scope":"all",
       "scopeName":{"en":"Grok Bot users","ja":"x"},"reason":"unstated","landedAt":"2027-01-14T18:05:23.000Z",
       "sources":[{"role":"followup","postId":"332","account":"elonmusk","at":"2027-01-14T19:00:00.000Z",
                   "url":"https://x.com/elonmusk/status/332"},
                  {"role":"landed","postId":"331","account":"bot","at":"2027-01-14T18:05:23.000Z",
                   "url":"https://x.com/bot/status/331"}]},
      {"id":"grok-forecast","provider":"grok","type":"forecast","landedAt":"2027-01-20T00:00:00.000Z"},
      {"id":"codex-1","provider":"codex","type":"reset","landedAt":"2027-01-13T21:15:00.000Z",
       "sources":[{"role":"landed","postId":"221","url":"https://x.com/thsottiaux/status/221"}]}
    ]}
    """#

    private let claudeTracker = ResetTracker(
        name: "claude-resets", url: URL(string: "https://example.invalid/r")!, host: "claude-resets.com",
        vendors: [.claude, .openai], format: .claudeResets)
    private let grokTracker = ResetTracker(
        name: "whenreset", url: URL(string: "https://example.invalid/w")!, host: "whenreset.dev",
        vendors: [.grok], format: .whenReset)

    @Test("claude-resets: resets only, provisional ids skipped, codex mapped to OpenAI")
    func parsesClaudeResets() throws {
        let resets = try #require(ResetTrackerWatcher.parse(Data(Self.claudeResets.utf8), format: .claudeResets))
        #expect(Set(resets.map(\.postId)) == ["111", "113", "221"])
        let banked = try #require(resets.first { $0.postId == "113" })
        #expect(banked.isBanked)
        #expect(banked.usableUntil == ResetTrackerWatcher.parseDate("2027-02-10T23:59:59Z"))
        #expect(resets.first { $0.postId == "221" }?.vendorId == .openai)
    }

    @Test("whenreset: the landed post is the identity, and non-resets are dropped")
    func parsesWhenReset() throws {
        let resets = try #require(ResetTrackerWatcher.parse(Data(Self.whenReset.utf8), format: .whenReset))
        let grok = try #require(resets.first { $0.vendorId == .grok })
        #expect(resets.filter { $0.vendorId == .grok }.count == 1)
        #expect(grok.postId == "331")
        #expect(grok.url == URL(string: "https://x.com/bot/status/331"))
        #expect(grok.scope == "Grok Bot users")
        #expect(!grok.isBanked)
    }

    @Test("a payload of the wrong shape is a failed read, not an empty history")
    func wrongShapeIsNil() {
        #expect(ResetTrackerWatcher.parse(Data("<html>".utf8), format: .claudeResets) == nil)
        #expect(ResetTrackerWatcher.parse(Data(#"{"events":"x"}"#.utf8), format: .whenReset) == nil)
        #expect(ResetTrackerWatcher.parse(Data(#"{"providers":{}}"#.utf8), format: .claudeResets) == [])
    }

    @Test("events say who it was for, link the post, and give a banked reset's deadline")
    func eventWording() async throws {
        let watcher = ResetTrackerWatcher(trackers: [claudeTracker]) { _ in Data(Self.claudeResets.utf8) }
        let pending = await watcher.prepare(vendors: [.claude, .openai], now: now, timeZone: utc, locale: posix)
        #expect(pending.fetched)
        let byId = Dictionary(uniqueKeysWithValues: pending.events.map { ($0.id, $0) })

        let everyone = try #require(byId["vendor_reset|claude|111"])
        #expect(everyone.title == "Claude reset for everyone")
        #expect(everyone.detail == "Shipped Opus 6 and reset 5-hour and weekly limits for all users.")
        #expect(everyone.url == URL(string: "https://x.com/ClaudeDevs/status/111"))
        #expect(everyone.source == .resetTracker(name: "claude-resets"))
        #expect(everyone.occurredAt == ResetTrackerWatcher.parseDate("2027-01-10T18:35:27Z"))
        #expect(everyone.isSurfaced)

        let banked = try #require(byId["vendor_reset|claude|113"])
        #expect(banked.title == "Claude banked reset for Pro, Max + Team")
        let deadline = ResetTrackerWatcher.deadline(
            try #require(ResetTrackerWatcher.parseDate("2027-02-10T23:59:59Z")), timeZone: utc, locale: posix)
        #expect(deadline.contains("Feb 10, 2027"))
        #expect(deadline.contains("11:59"))
        #expect(banked.detail == "Gave Pro, Max and Team users a banked reset. Apply it by \(deadline).")

        #expect(byId["vendor_reset|openai|221"]?.title == "Codex reset")
    }

    @Test("resets for vendors the user does not have are not recorded or fetched")
    func vendorFiltering() async {
        let log = FetchLog()
        let watcher = ResetTrackerWatcher(trackers: [claudeTracker, grokTracker]) { tracker in
            log.hit(tracker.name)
            return Data((tracker.format == .whenReset ? Self.whenReset : Self.claudeResets).utf8)
        }
        let pending = await watcher.prepare(vendors: [.openai], now: now, timeZone: utc, locale: posix)
        #expect(log.count("whenreset") == 0)
        #expect(pending.events.map(\.vendorId) == [.openai])

        // whenreset also lists Codex, but it is trusted for Grok only, so a
        // reset is never recorded twice from two trackers.
        let grok = await watcher.prepare(vendors: [.grok, .openai], now: now, timeZone: utc, locale: posix)
        #expect(grok.events.filter { $0.vendorId == .openai }.count == 1)
        #expect(grok.events.filter { $0.vendorId == .grok }.map(\.title) == ["Grok reset for Grok Bot users"])
    }

    @Test("a tracker dated ahead of the clock is clamped to now")
    func futureClamped() {
        let reset = LandedReset(postId: "9", vendorId: .claude, landedAt: now.addingTimeInterval(3600),
                                isBanked: false, scope: nil, note: nil, url: nil, usableUntil: nil)
        let event = ResetTrackerWatcher.event(for: reset, tracker: claudeTracker, now: now)
        #expect(event.occurredAt == now)
        #expect(event.title == "Claude reset")
        #expect(event.detail == nil)
    }

    @Test("the live fetch is stubbed and treats an error status as no data")
    func liveFetch() async throws {
        let log = FetchLog()
        let ok = try await withEventStub({ request in
            log.hit(request.url?.host ?? "")
            return (200, Data(Self.claudeResets.utf8))
        }) {
            await ResetTrackerWatcher.liveFetch(self.claudeTracker)
        }
        #expect(ok != nil)
        let failed = try await withEventStub({ request in
            log.hit(request.url?.host ?? "")
            return (503, Data(Self.claudeResets.utf8))
        }) {
            await ResetTrackerWatcher.liveFetch(self.claudeTracker)
        }
        #expect(failed == nil)
        #expect(log.count("example.invalid") == 2)
    }
}
