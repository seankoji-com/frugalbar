import Foundation

/// A community tracker that records vendor usage resets after they land.
///
/// No vendor publishes its bonus resets anywhere a program can read: they are
/// announced on X by the people who run the product. These trackers keep a
/// curated, dated record of each announcement, with a link to the post. Both
/// are third-party, so every event they produce says so in its caption.
///
/// Only resets that already happened are read. Both trackers also publish
/// forecasts and "reset expected" windows; those are guesses about the future
/// and are never decoded.
public struct ResetTracker: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// claude-resets.com: `providers.<vendor>.events[]`, curated, with the
        /// post id as the event id and `meta.provisionalEventIds` naming the
        /// entries not yet verified.
        case claudeResets
        /// whenreset.dev: `events[]` with `landedAt` and the posts behind it.
        case whenReset
    }

    /// Short stable identifier, persisted in the event source
    /// (`tracker:<name>`). Renaming one changes how old rows are captioned.
    public let name: String
    public let url: URL
    /// The tracker's own page, named in captions.
    public let host: String
    /// The vendors this tracker is trusted for. One vendor, one tracker: two
    /// trackers citing different posts for the same reset would record it
    /// twice, and nothing in the payloads ties those posts together.
    public let vendors: Set<VendorIdentifier>
    public let format: Format

    public init(name: String, url: URL, host: String, vendors: Set<VendorIdentifier>, format: Format) {
        self.name = name
        self.url = url
        self.host = host
        self.vendors = vendors
        self.format = format
    }

    /// - claude-resets.com is curated by hand from @ClaudeDevs, Anthropic
    ///   staff and @thsottiaux (Codex), and marks unverified entries
    ///   provisional. It is the source for Claude and Codex.
    /// - whenreset.dev is the only tracker that records Grok resets.
    ///
    /// codex-reset.com was considered and left out: its timeline classifies
    /// posts automatically and files non-resets ("I can't really give a
    /// reset") under `type: "reset"`.
    public static let all: [ResetTracker] = [
        ResetTracker(
            name: "claude-resets",
            url: URL(string: "https://claude-resets.com/api/resets")!,
            host: "claude-resets.com",
            vendors: [.claude, .openai],
            format: .claudeResets),
        ResetTracker(
            name: "whenreset",
            url: URL(string: "https://whenreset.dev/api/resets")!,
            host: "whenreset.dev",
            vendors: [.grok],
            format: .whenReset),
    ]

    public static func named(_ name: String) -> ResetTracker? {
        all.first { $0.name == name }
    }
}

/// One reset a tracker recorded as having landed.
public struct LandedReset: Sendable, Equatable {
    /// The post that announced it. The event id is built from this, so a
    /// tracker rewording its note never records the reset twice.
    public let postId: String
    public let vendorId: VendorIdentifier
    public let landedAt: Date
    /// A banked reset (a credit the user applies later) rather than a reset
    /// applied to everyone's counters at once.
    public let isBanked: Bool
    /// Who it applied to, in the tracker's words: "all", "Max",
    /// "Pro, Max + Team", "Grok Bot users".
    public let scope: String?
    public let note: String?
    public let url: URL?
    /// The last moment a banked reset can be applied, when published.
    public let usableUntil: Date?

    public init(
        postId: String, vendorId: VendorIdentifier, landedAt: Date, isBanked: Bool,
        scope: String?, note: String?, url: URL?, usableUntil: Date?
    ) {
        self.postId = postId
        self.vendorId = vendorId
        self.landedAt = landedAt
        self.isBanked = isBanked
        self.scope = scope
        self.note = note
        self.url = url
        self.usableUntil = usableUntil
    }
}

/// Fetches the reset trackers and turns landed resets into events.
///
/// Stateless: an event's id is the vendor and the announcing post, so
/// re-reading a tracker's whole history every poll is harmless —
/// `recordEvents` keeps each one once. The first poll therefore backfills the
/// tracker's history into the log; `AIEventNotification.maximumAge` keeps that
/// backfill from arriving as banners.
public struct ResetTrackerWatcher: Sendable {
    /// Returns the raw payload, or nil when the tracker could not be read.
    public typealias Fetcher = @Sendable (ResetTracker) async -> Data?

    private let trackers: [ResetTracker]
    private let fetch: Fetcher

    public init(trackers: [ResetTracker] = ResetTracker.all, fetch: @escaping Fetcher = ResetTrackerWatcher.liveFetch) {
        self.trackers = trackers
        self.fetch = fetch
    }

    /// - Parameter vendors: the vendors the user actually has; a reset for a
    ///   product they do not use is not worth a line in their log.
    public func prepare(
        vendors: Set<VendorIdentifier>,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) async -> PendingPoll {
        var events: [AIEvent] = []
        var fetched = false
        for tracker in trackers where !tracker.vendors.isDisjoint(with: vendors) {
            guard let data = await fetch(tracker) else { continue }
            guard let resets = Self.parse(data, format: tracker.format) else {
                // An unreadable payload is a failed fetch, not an empty history.
                NSLog("frugalbar: reset tracker \(tracker.name) returned an unreadable payload")
                continue
            }
            fetched = true
            events += resets
                .filter { tracker.vendors.contains($0.vendorId) && vendors.contains($0.vendorId) }
                .map { Self.event(for: $0, tracker: tracker, now: now, timeZone: timeZone, locale: locale) }
        }
        return PendingPoll(events: events, fetched: fetched, commit: {})
    }

    // MARK: - Events

    static func event(
        for reset: LandedReset,
        tracker: ResetTracker,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> AIEvent {
        var detail = reset.note.map { truncated($0) } ?? ""
        if reset.isBanked, let until = reset.usableUntil {
            // With the time, in the user's zone: the vendor's own wording is
            // often a date in its zone ("until October 22"), and a bare local
            // date one day later would read as a contradiction.
            let apply = "Apply it by \(Self.deadline(until, timeZone: timeZone, locale: locale))."
            detail = detail.isEmpty ? apply : "\(detail) \(apply)"
        }
        return AIEvent(
            id: AIEvent.makeID(kind: .vendorReset, vendorId: reset.vendorId, components: [reset.postId]),
            kind: .vendorReset,
            vendorId: reset.vendorId,
            title: title(for: reset),
            detail: detail.isEmpty ? nil : detail,
            // Never in the future: a tracker dated ahead of our clock must not
            // sort above everything else as "just now" for days.
            occurredAt: min(reset.landedAt, now),
            observedAt: now,
            source: .resetTracker(name: tracker.name),
            url: reset.url
        )
    }

    /// "Codex reset for everyone", "Claude banked reset for Pro, Max + Team".
    static func title(for reset: LandedReset) -> String {
        let product: String
        switch reset.vendorId {
        case .openai: product = "Codex"
        default:      product = reset.vendorId.displayName
        }
        let kind = reset.isBanked ? "banked reset" : "reset"
        return "\(product) \(kind)\(audience(reset.scope))"
    }

    private static func audience(_ scope: String?) -> String {
        let trimmed = scope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed.lowercased() {
        case "", "unknown": return ""
        case "all":         return " for everyone"
        case "paid":        return " for paid plans"
        default:            return " for \(trimmed)"
        }
    }

    static func deadline(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private static func truncated(_ text: String, limit: Int = 200) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Parsing

    /// nil when the payload is not the expected shape at all. A payload that
    /// decodes but lists nothing is an empty array, which is an answer.
    static func parse(_ data: Data, format: ResetTracker.Format) -> [LandedReset]? {
        switch format {
        case .claudeResets: parseClaudeResets(data)
        case .whenReset:    parseWhenReset(data)
        }
    }

    private struct ClaudeResetsPayload: Decodable {
        struct Provider: Decodable { let events: [Entry]? }
        struct Entry: Decodable {
            let id: String?
            let date: String?
            let kind: String?
            let scope: String?
            let note: String?
            let url: String?
            let resetType: String?
            let usableUntil: String?
        }
        struct Meta: Decodable { let provisionalEventIds: [String]? }
        let providers: [String: Provider]
        let meta: Meta?
    }

    static func parseClaudeResets(_ data: Data) -> [LandedReset]? {
        guard let payload = try? JSONDecoder().decode(ClaudeResetsPayload.self, from: data) else { return nil }
        let provisional = Set(payload.meta?.provisionalEventIds ?? [])
        var resets: [LandedReset] = []
        for (key, provider) in payload.providers {
            let vendor: VendorIdentifier
            switch key {
            case "claude": vendor = .claude
            case "codex":  vendor = .openai
            default:       continue
            }
            for entry in provider.events ?? [] {
                // "policy" entries are limit changes, not resets.
                guard entry.kind == "reset",
                      let id = entry.id?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                      !provisional.contains(id),
                      let landed = entry.date.flatMap(parseDate)
                else { continue }
                resets.append(LandedReset(
                    postId: id,
                    vendorId: vendor,
                    landedAt: landed,
                    isBanked: entry.resetType == "banked",
                    scope: entry.scope,
                    note: entry.note,
                    url: entry.url.flatMap(URL.init(string:)),
                    usableUntil: entry.usableUntil.flatMap(parseDate)
                ))
            }
        }
        return resets
    }

    private struct WhenResetPayload: Decodable {
        struct Localized: Decodable { let en: String? }
        struct Post: Decodable {
            let role: String?
            let postId: String?
            let url: String?
        }
        struct Entry: Decodable {
            let id: String?
            let provider: String?
            let type: String?
            let scope: String?
            let scopeName: Localized?
            let reasonNote: Localized?
            let landedAt: String?
            let sources: [Post]?
        }
        let events: [Entry]
    }

    static func parseWhenReset(_ data: Data) -> [LandedReset]? {
        guard let payload = try? JSONDecoder().decode(WhenResetPayload.self, from: data) else { return nil }
        return payload.events.compactMap { entry -> LandedReset? in
            let vendor: VendorIdentifier
            switch entry.provider {
            case "grok":   vendor = .grok
            case "claude": vendor = .claude
            case "codex":  vendor = .openai
            default:       return nil
            }
            // "card" is a banked reset; anything else is not a reset at all.
            guard entry.type == "reset" || entry.type == "card",
                  let landed = entry.landedAt.flatMap(parseDate)
            else { return nil }
            let post = entry.sources?.first { $0.role == "landed" } ?? entry.sources?.first
            guard let postId = post?.postId ?? entry.id, !postId.isEmpty else { return nil }
            return LandedReset(
                postId: postId,
                vendorId: vendor,
                landedAt: landed,
                isBanked: entry.type == "card",
                scope: entry.scopeName?.en ?? entry.scope,
                note: entry.reasonNote?.en,
                url: post?.url.flatMap(URL.init(string:)),
                usableUntil: nil
            )
        }
    }

    /// ISO 8601, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// The production fetch: status checked before the body is handed on, so
    /// an error page is never parsed as an empty history.
    public static func liveFetch(_ tracker: ResetTracker) async -> Data? {
        guard let (data, http) = try? await QuotaHTTP.get(
            url: tracker.url.absoluteString, headers: ["Accept": "application/json"])
        else {
            NSLog("frugalbar: reset tracker \(tracker.name) fetch failed")
            return nil
        }
        guard QuotaHTTP.failureReason(for: http.statusCode) == nil else {
            NSLog("frugalbar: reset tracker \(tracker.name) returned HTTP \(http.statusCode)")
            return nil
        }
        return data
    }
}
