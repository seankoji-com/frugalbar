import Foundation
import QuotaBarCore

/// Pure presentation logic for recorded AI-platform events: relative times,
/// day grouping, filtering, spoken labels, and the subset drawn as timeline
/// markers. No view state and no clock reads — every function takes `now`.
public enum EventsPresentation {

    /// Kinds drawn on the quota timeline. Only these say something about the
    /// allowance the chart plots; a new model or price change does not.
    public static let markerKinds: Set<AIEventKind> = [.usageReset, .usageRestored, .resetCreditGranted]

    // MARK: - Relative time

    /// Compact relative time for a row caption: "just now", "12m ago",
    /// "3h ago", "2d ago", and a short date from a week out.
    ///
    /// A timestamp in the future (clock skew, a feed dated ahead) reads as
    /// "just now" rather than a negative age.
    public static func relativeTime(
        of date: Date,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        if age < 86_400 { return "\(Int(age / 3600))h ago" }
        if age < 7 * 86_400 { return "\(Int(age / 86_400))d ago" }
        return shortDate(date, locale: locale, timeZone: timeZone)
    }

    /// The same buckets as `relativeTime`, worded for VoiceOver.
    public static func spokenRelativeTime(
        of date: Date,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let age = now.timeIntervalSince(date)
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if age < 60 { return "just now" }
        if age < 3600 { return plural(Int(age / 60), "minute") }
        if age < 86_400 { return plural(Int(age / 3600), "hour") }
        if age < 7 * 86_400 { return plural(Int(age / 86_400), "day") }
        return "on \(shortDate(date, locale: locale, timeZone: timeZone))"
    }

    static func shortDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    // MARK: - Grouping

    /// Events bucketed by the calendar day of `occurredAt`, newest day first
    /// and newest event first within a day. The calendar decides where a day
    /// starts, so callers pass the user's calendar (and tests a fixed one).
    public static func groupedByDay(
        _ events: [AIEvent],
        calendar: Calendar
    ) -> [(day: Date, events: [AIEvent])] {
        let buckets = Dictionary(grouping: events) { calendar.startOfDay(for: $0.occurredAt) }
        return buckets
            .map { day, items in
                (day: day, events: items.sorted(by: newestFirst))
            }
            .sorted { $0.day > $1.day }
    }

    /// Section heading for a day group: "Today", "Yesterday", or a date.
    public static func dayTitle(
        _ day: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter.string(from: day)
    }

    // MARK: - Filtering

    /// Events matching every filter, newest first.
    ///
    /// An empty `kinds` set matches nothing — the same contract as
    /// `QuotaHistoryStore.fetchEvents`: a filter bar with every kind unticked
    /// shows nothing, not everything. A nil `vendor` means all vendors.
    public static func filter(
        events: [AIEvent],
        kinds: Set<AIEventKind>,
        vendor: VendorIdentifier?,
        range: HistoryPresentation.TimeRange,
        now: Date
    ) -> [AIEvent] {
        let start = range.startDate(from: now)
        return events
            .filter { event in
                guard kinds.contains(event.kind) else { return false }
                if let vendor, event.vendorId != vendor { return false }
                if let start, event.occurredAt < start { return false }
                return true
            }
            .sorted(by: newestFirst)
    }

    /// One vendor's reset-type events inside the range, oldest first (chart
    /// order). Catalog and feed events say nothing about the allowance the
    /// timeline plots, so they are never markers.
    public static func markerEvents(
        _ events: [AIEvent],
        vendor: VendorIdentifier,
        range: HistoryPresentation.TimeRange,
        now: Date
    ) -> [AIEvent] {
        filter(events: events, kinds: markerKinds, vendor: vendor, range: range, now: now)
            .filter { $0.occurredAt <= now }
            .reversed()
    }

    /// "3 reset markers" / "1 reset marker"; nil when there are none, so the
    /// chart's accessibility value says nothing rather than "0 markers".
    public static func markerAccessibilitySummary(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) reset marker\(count == 1 ? "" : "s")"
    }

    // MARK: - Accessibility

    /// Full spoken description of one event row, e.g.
    /// "New model, Claude: Claude Sonnet 5.5 listed, 3 hours ago, from the
    /// OpenRouter model catalog". The detail line, when present, follows.
    public static func accessibilityLabel(
        for event: AIEvent,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let when = spokenRelativeTime(of: event.occurredAt, now: now, locale: locale, timeZone: timeZone)
        let source = lowercasedFirst(event.source.label)
        var label = "\(event.kind.title), \(event.vendorId.displayName): \(event.title), \(when), \(source)"
        if let detail = event.detail, !detail.isEmpty {
            label += ". \(detail)"
        }
        return label
    }

    /// Caption under a row title: "3h ago · From the OpenRouter model catalog".
    public static func caption(
        for event: AIEvent,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        "\(relativeTime(of: event.occurredAt, now: now, locale: locale, timeZone: timeZone)) · \(event.source.label)"
    }

    /// The event's link if it is safe to hand to the browser. Only http(s):
    /// the URL came from a third-party feed, and a `file:` or custom-scheme
    /// link should not be one click from opening.
    public static func openableURL(for event: AIEvent) -> URL? {
        guard let url = event.url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    // MARK: - Helpers

    private static func newestFirst(_ a: AIEvent, _ b: AIEvent) -> Bool {
        if a.occurredAt != b.occurredAt { return a.occurredAt > b.occurredAt }
        if a.observedAt != b.observedAt { return a.observedAt > b.observedAt }
        return a.id < b.id
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
