import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("EventsPresentation")
struct EventsPresentationTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let enUS = Locale(identifier: "en_US")

    private func event(
        _ id: String,
        kind: AIEventKind = .newModel,
        vendor: VendorIdentifier = .claude,
        title: String = "Event",
        detail: String? = nil,
        occurredAt: Date,
        observedAt: Date? = nil,
        source: AIEventSource = .quotaPoll,
        url: URL? = nil
    ) -> AIEvent {
        AIEvent(
            id: id, kind: kind, vendorId: vendor, title: title, detail: detail,
            occurredAt: occurredAt, observedAt: observedAt ?? occurredAt,
            source: source, url: url
        )
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    // MARK: - relativeTime

    @Test("relativeTime buckets switch exactly at minute, hour, day and week boundaries")
    func relativeTimeBoundaries() {
        func rel(_ age: TimeInterval) -> String {
            EventsPresentation.relativeTime(of: now.addingTimeInterval(-age), now: now, locale: enUS, timeZone: utc)
        }
        #expect(rel(0) == "just now")
        #expect(rel(59) == "just now")
        #expect(rel(60) == "1m ago")
        #expect(rel(12 * 60 + 30) == "12m ago")
        #expect(rel(3599) == "59m ago")
        #expect(rel(3600) == "1h ago")
        #expect(rel(3 * 3600 + 59) == "3h ago")
        #expect(rel(86_399) == "23h ago")
        #expect(rel(86_400) == "1d ago")
        #expect(rel(2 * 86_400) == "2d ago")
        #expect(rel(7 * 86_400 - 1) == "6d ago")
        // A week or more out falls back to a short date in the given zone.
        let old = rel(7 * 86_400)
        #expect(old == EventsPresentation.shortDate(now.addingTimeInterval(-7 * 86_400), locale: enUS, timeZone: utc))
        #expect(!old.contains("ago"))
    }

    @Test("a future timestamp reads as just now, never a negative age")
    func futureIsJustNow() {
        let text = EventsPresentation.relativeTime(of: now.addingTimeInterval(3600), now: now, locale: enUS, timeZone: utc)
        #expect(text == "just now")
    }

    // MARK: - groupedByDay

    @Test("groupedByDay orders days newest first and events newest first within a day")
    func groupedByDayOrdering() {
        let cal = calendar("UTC")
        let day0 = cal.startOfDay(for: now)
        let a = event("a", occurredAt: day0.addingTimeInterval(3600))
        let b = event("b", occurredAt: day0.addingTimeInterval(7200))
        let c = event("c", occurredAt: day0.addingTimeInterval(-3600))   // previous day
        let d = event("d", occurredAt: day0.addingTimeInterval(-3 * 86_400))

        let groups = EventsPresentation.groupedByDay([c, a, d, b], calendar: cal)
        #expect(groups.map(\.day) == [day0, day0.addingTimeInterval(-86_400), day0.addingTimeInterval(-3 * 86_400)])
        #expect(groups.map { $0.events.map(\.id) } == [["b", "a"], ["c"], ["d"]])
    }

    @Test("groupedByDay splits on the calendar's own midnight, not UTC's")
    func groupedByDayUsesCalendarTimeZone() {
        // 13:30 UTC and 14:30 UTC straddle midnight in Sydney (UTC+10 in
        // winter): 23:30 one day, 00:30 the next.
        let sydney = calendar("Australia/Sydney")
        var utcComponents = DateComponents()
        utcComponents.year = 2026; utcComponents.month = 7; utcComponents.day = 1
        utcComponents.hour = 13; utcComponents.minute = 30
        let before = calendar("UTC").date(from: utcComponents)!
        let after = before.addingTimeInterval(3600)

        let events = [event("before", occurredAt: before), event("after", occurredAt: after)]

        let local = EventsPresentation.groupedByDay(events, calendar: sydney)
        #expect(local.count == 2)
        #expect(local.map { $0.events.map(\.id) } == [["after"], ["before"]])

        let inUTC = EventsPresentation.groupedByDay(events, calendar: calendar("UTC"))
        #expect(inUTC.count == 1)
    }

    @Test("groupedByDay of nothing is nothing")
    func groupedByDayEmpty() {
        #expect(EventsPresentation.groupedByDay([], calendar: calendar("UTC")).isEmpty)
    }

    // MARK: - filter

    private var mixed: [AIEvent] {
        [
            event("claude-new", kind: .newModel, vendor: .claude, occurredAt: now.addingTimeInterval(-3600)),
            event("openai-reset", kind: .usageReset, vendor: .openai, occurredAt: now.addingTimeInterval(-2 * 86_400)),
            event("openai-price", kind: .priceChange, vendor: .openai, occurredAt: now.addingTimeInterval(-10 * 86_400)),
        ]
    }

    // Regression guard, proven red→green: with `guard kinds.contains(...)`
    // mutated to `guard kinds.isEmpty || kinds.contains(...)` this test fails.
    @Test("an empty kind set matches nothing, mirroring the store's contract")
    func filterEmptyKindsMatchesNothing() {
        let result = EventsPresentation.filter(events: mixed, kinds: [], vendor: nil, range: .allTime, now: now)
        #expect(result.isEmpty)
    }

    @Test("a nil vendor keeps every vendor; a vendor narrows to it")
    func filterVendor() {
        let all = Set(AIEventKind.allCases)
        let everyone = EventsPresentation.filter(events: mixed, kinds: all, vendor: nil, range: .allTime, now: now)
        #expect(everyone.map(\.id) == ["claude-new", "openai-reset", "openai-price"])

        let openai = EventsPresentation.filter(events: mixed, kinds: all, vendor: .openai, range: .allTime, now: now)
        #expect(openai.map(\.id) == ["openai-reset", "openai-price"])
    }

    @Test("the time range excludes events before its start")
    func filterRange() {
        let all = Set(AIEventKind.allCases)
        #expect(EventsPresentation.filter(events: mixed, kinds: all, vendor: nil, range: .last24Hours, now: now).map(\.id) == ["claude-new"])
        #expect(EventsPresentation.filter(events: mixed, kinds: all, vendor: nil, range: .last7Days, now: now).map(\.id) == ["claude-new", "openai-reset"])
        #expect(EventsPresentation.filter(events: mixed, kinds: all, vendor: nil, range: .last30Days, now: now).count == 3)
    }

    @Test("kinds narrow the result")
    func filterKinds() {
        let result = EventsPresentation.filter(events: mixed, kinds: [.usageReset], vendor: nil, range: .allTime, now: now)
        #expect(result.map(\.id) == ["openai-reset"])
    }

    // MARK: - markerEvents

    @Test("markerEvents keeps only this vendor's reset, restore and credit events, oldest first")
    func markerEventsKinds() {
        let events = [
            event("reset", kind: .usageReset, vendor: .openai, occurredAt: now.addingTimeInterval(-3600)),
            event("restored", kind: .usageRestored, vendor: .openai, occurredAt: now.addingTimeInterval(-7200)),
            event("credit", kind: .resetCreditGranted, vendor: .openai, occurredAt: now.addingTimeInterval(-10_800)),
            event("model", kind: .newModel, vendor: .openai, occurredAt: now.addingTimeInterval(-600)),
            event("price", kind: .priceChange, vendor: .openai, occurredAt: now.addingTimeInterval(-600)),
            event("other-vendor", kind: .usageReset, vendor: .claude, occurredAt: now.addingTimeInterval(-600)),
            event("too-old", kind: .usageReset, vendor: .openai, occurredAt: now.addingTimeInterval(-2 * 86_400)),
        ]
        let markers = EventsPresentation.markerEvents(events, vendor: .openai, range: .last24Hours, now: now)
        #expect(markers.map(\.id) == ["credit", "restored", "reset"])
        #expect(EventsPresentation.markerKinds == [.usageReset, .usageRestored, .resetCreditGranted])
    }

    @Test("marker accessibility summary pluralises and says nothing for zero")
    func markerSummary() {
        #expect(EventsPresentation.markerAccessibilitySummary(count: 0) == nil)
        #expect(EventsPresentation.markerAccessibilitySummary(count: 1) == "1 reset marker")
        #expect(EventsPresentation.markerAccessibilitySummary(count: 3) == "3 reset markers")
    }

    // MARK: - accessibility & caption

    @Test("accessibility label names kind, vendor, title, spoken age and source")
    func accessibilityLabelWording() {
        let e = event(
            "x", kind: .newModel, vendor: .claude, title: "Claude Sonnet 5.5 listed",
            occurredAt: now.addingTimeInterval(-3 * 3600), source: .openRouterCatalog
        )
        #expect(EventsPresentation.accessibilityLabel(for: e, now: now, locale: enUS, timeZone: utc)
                == "New model, Claude: Claude Sonnet 5.5 listed, 3 hours ago, from the OpenRouter model catalog")
    }

    @Test("accessibility label appends the measured detail and uses singular units")
    func accessibilityLabelDetail() {
        let e = event(
            "y", kind: .usageRestored, vendor: .openai, title: "Codex WK restored",
            detail: "Used fell from 73% to 2%",
            occurredAt: now.addingTimeInterval(-60), source: .quotaPoll
        )
        let label = EventsPresentation.accessibilityLabel(for: e, now: now, locale: enUS, timeZone: utc)
        #expect(label == "Usage restored, \(VendorIdentifier.openai.displayName): Codex WK restored, 1 minute ago, from the vendor's usage endpoint. Used fell from 73% to 2%")
    }

    @Test("caption joins compact age and source label")
    func caption() {
        let e = event("z", occurredAt: now.addingTimeInterval(-2 * 86_400), source: .vendorFeed(name: "openai-news"))
        #expect(EventsPresentation.caption(for: e, now: now, locale: enUS, timeZone: utc) == "2d ago · From the openai-news feed")
    }

    @Test("only http and https links are openable")
    func openableURL() {
        let https = event("a", occurredAt: now, url: URL(string: "https://openai.com/news/x"))
        let file = event("b", occurredAt: now, url: URL(string: "file:///etc/passwd"))
        let none = event("c", occurredAt: now)
        #expect(EventsPresentation.openableURL(for: https)?.absoluteString == "https://openai.com/news/x")
        #expect(EventsPresentation.openableURL(for: file) == nil)
        #expect(EventsPresentation.openableURL(for: none) == nil)
    }

    @Test("day titles say Today and Yesterday in the calendar's zone")
    func dayTitles() {
        let cal = calendar("UTC")
        let today = cal.startOfDay(for: now)
        #expect(EventsPresentation.dayTitle(today, now: now, calendar: cal, locale: enUS) == "Today")
        #expect(EventsPresentation.dayTitle(today.addingTimeInterval(-86_400), now: now, calendar: cal, locale: enUS) == "Yesterday")
        #expect(!["Today", "Yesterday"].contains(EventsPresentation.dayTitle(today.addingTimeInterval(-3 * 86_400), now: now, calendar: cal, locale: enUS)))
    }
}
