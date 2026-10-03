import Foundation

/// A vendor news feed FrugalBar reads for model and pricing announcements.
public struct VendorFeed: Sendable, Equatable {
    /// Short stable identifier, persisted in `feed_item` and in the event
    /// source (`feed:<name>`). Renaming one re-announces its backlog.
    public let name: String
    public let url: URL
    public let vendorId: VendorIdentifier
    /// False for a third-party scrape of a vendor's site. Surfaced in the
    /// event's source caption so nobody mistakes it for the vendor speaking.
    public let isOfficial: Bool

    public init(name: String, url: URL, vendorId: VendorIdentifier, isOfficial: Bool) {
        self.name = name
        self.url = url
        self.vendorId = vendorId
        self.isOfficial = isOfficial
    }

    /// Every feed FrugalBar polls.
    ///
    /// - OpenAI and Google publish RSS. DeepMind's feed is served gzip;
    ///   `URLSession` decodes that transparently.
    /// - Anthropic publishes no feed. `anthropic-news` is a community scrape
    ///   of anthropic.com/news (Olshansk/rss-feeds, regenerated hourly), so it
    ///   is marked unofficial and its caption says so.
    /// - xAI has no feed at all: x.ai/news/rss.xml is a 404 and the only
    ///   third-party scrape has gone stale. Grok model news arrives through
    ///   the OpenRouter catalog (`x-ai/` ids) instead.
    public static let all: [VendorFeed] = [
        VendorFeed(
            name: "openai-news",
            url: URL(string: "https://openai.com/news/rss.xml")!,
            vendorId: .openai, isOfficial: true),
        VendorFeed(
            name: "google-ai-blog",
            url: URL(string: "https://blog.google/technology/ai/rss/")!,
            vendorId: .gemini, isOfficial: true),
        VendorFeed(
            name: "deepmind-blog",
            url: URL(string: "https://deepmind.google/blog/rss.xml")!,
            vendorId: .gemini, isOfficial: true),
        VendorFeed(
            name: "anthropic-news",
            url: URL(string: "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_news.xml")!,
            vendorId: .claude, isOfficial: false),
    ]

    public static func named(_ name: String) -> VendorFeed? {
        all.first { $0.name == name }
    }
}

/// Polls vendor feeds and turns announcement items into candidate events.
///
/// Every fetched item id is marked seen, classified or not, so an item is
/// judged exactly once however long the feed keeps serving it. On a feed's
/// first run (nothing seen yet) only items published in the last
/// `firstRunWindow` become events: a feed carries months of history, and
/// announcing all of it on first launch would bury the one release that
/// matters. Older items are still marked seen, so they never surface later.
public struct VendorFeedWatcher: Sendable {
    /// Returns the parsed items, or nil when the feed could not be fetched.
    public typealias Fetcher = @Sendable (VendorFeed) async -> [FeedItem]?

    public static let firstRunWindow: TimeInterval = 7 * 86_400

    private let feeds: [VendorFeed]
    private let fetch: Fetcher

    public init(feeds: [VendorFeed] = VendorFeed.all, fetch: @escaping Fetcher = VendorFeedWatcher.liveFetch) {
        self.feeds = feeds
        self.fetch = fetch
    }

    /// Polls every feed. One feed failing — network, status, or the store —
    /// skips that feed only.
    public func poll(store: QuotaHistoryStore, now: Date) async -> [AIEvent] {
        let pending = await prepare(store: store, now: now)
        do {
            try await pending.commit()
        } catch {
            NSLog("frugalbar: failed to mark feed items seen: \(error)")
        }
        return pending.events
    }

    /// The same as `poll`, but the seen-ids are handed back as a `commit`
    /// closure instead of written, so the caller can record the events first.
    /// See `PendingPoll` for why the order matters.
    public func prepare(store: QuotaHistoryStore, now: Date) async -> PendingPoll {
        var events: [AIEvent] = []
        var toMark: [(feed: String, ids: [String])] = []
        var fetched = false
        for feed in feeds {
            guard let items = await fetch(feed) else { continue }
            fetched = true
            let seen: Set<String>
            do {
                seen = try await store.seenFeedItemIDs(feed: feed.name)
            } catch {
                // Treating an unreadable seen-set as empty would re-announce
                // the feed's backlog; skip it this round instead.
                NSLog("frugalbar: failed to read seen items for \(feed.name): \(error)")
                continue
            }
            events += Self.events(for: feed, items: items, seen: seen, now: now)
            toMark.append((feed.name, items.map(\.id)))
        }
        let marks = toMark
        return PendingPoll(events: events, fetched: fetched) {
            for mark in marks {
                try await store.markFeedItemsSeen(feed: mark.feed, ids: mark.ids, at: now)
            }
        }
    }

    /// The pure decision: which unseen items become which events.
    static func events(for feed: VendorFeed, items: [FeedItem], seen: Set<String>, now: Date) -> [AIEvent] {
        let isFirstRun = seen.isEmpty
        let cutoff = now.addingTimeInterval(-firstRunWindow)
        var emitted: Set<String> = []
        return items.compactMap { item in
            guard !seen.contains(item.id), emitted.insert(item.id).inserted else { return nil }
            if isFirstRun {
                // An undated item cannot be shown to be recent; on the
                // first run that means it is history, not news.
                guard let published = item.published, published >= cutoff else { return nil }
            }
            guard let kind = FeedItemClassifier.classify(title: item.title, summary: item.summary) else {
                return nil
            }
            return AIEvent(
                id: AIEvent.makeID(kind: kind, vendorId: feed.vendorId, components: [item.id]),
                kind: kind,
                vendorId: feed.vendorId,
                title: item.title,
                detail: item.summary.isEmpty ? nil : truncated(item.summary),
                occurredAt: item.published ?? now,
                observedAt: now,
                source: .vendorFeed(name: feed.name),
                url: item.link
            )
        }
    }

    private static func truncated(_ text: String, limit: Int = 200) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The production fetch: status checked before parsing, so an error page
    /// is never read as an empty (and therefore "all seen") feed.
    public static func liveFetch(_ feed: VendorFeed) async -> [FeedItem]? {
        guard let (data, http) = try? await QuotaHTTP.get(url: feed.url.absoluteString) else {
            NSLog("frugalbar: feed \(feed.name) fetch failed")
            return nil
        }
        guard QuotaHTTP.failureReason(for: http.statusCode) == nil else {
            NSLog("frugalbar: feed \(feed.name) returned HTTP \(http.statusCode)")
            return nil
        }
        return FeedParser.parse(data)
    }
}
