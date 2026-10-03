import Foundation

/// One model as published by OpenRouter's catalog on this poll.
///
/// Prices are `Decimal`, parsed straight from the catalog's decimal strings
/// (USD per token). A `Double` would turn "0.000003" into a binary
/// approximation, and two approximations of one string compared on the next
/// poll is how a price change nobody made gets announced. `nil` means the
/// catalog published no parseable figure — never zero.
public struct CatalogEntry: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let created: Date?
    public let promptPrice: Decimal?
    public let completionPrice: Decimal?

    public init(id: String, name: String?, created: Date?, promptPrice: Decimal?, completionPrice: Decimal?) {
        self.id = id
        self.name = name
        self.created = created
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
    }
}

/// The pure half of catalog watching: diffs one fetched catalog against the
/// records stored from the previous one.
public enum CatalogDiff {

    /// Maps an OpenRouter model id to the vendor FrugalBar tracks, by prefix.
    /// Every other prefix — Meta, Mistral, DeepSeek, OpenRouter's own routers —
    /// is ignored: FrugalBar reports on the vendors it shows quotas for, and a
    /// catalog of 400-odd models would otherwise bury those under noise.
    public static func vendor(forModelId id: String) -> VendorIdentifier? {
        let prefixes: [(String, VendorIdentifier)] = [
            ("anthropic/", .claude),
            ("openai/", .openai),
            ("google/", .gemini),
            ("x-ai/", .grok),
        ]
        return prefixes.first { id.hasPrefix($0.0) }?.1
    }

    /// Ids containing ":" are OpenRouter's *variants* of a model —
    /// `:free`, `:batch`, `:thinking`, `:extended` — a different price or
    /// routing for a model already listed under its bare id. They are stored
    /// (so the record is complete) but never announced: "Claude Sonnet 5
    /// (thinking) listed" next to "Claude Sonnet 5 listed" is one release
    /// reported twice, and a variant's price is not the model's price.
    static func isVariant(_ id: String) -> Bool { id.contains(":") }

    /// Diffs `current` against `previous`.
    ///
    /// - An empty `previous` is the very first poll: every model is seeded
    ///   and nothing is announced. Without this the first launch would post a
    ///   "new model" event for each of the ~180 models from the tracked
    ///   vendors already in the catalog.
    /// - A price change needs a figure on both sides. A price appearing where
    ///   there was none, or vanishing, is recorded silently: "changed from
    ///   unknown" is not a change anyone measured.
    /// - Records carry `firstSeen` forward from `previous`; `lastSeen` is `now`.
    public static func compute(
        previous: [String: CatalogModelRecord],
        current: [CatalogEntry],
        now: Date
    ) -> (events: [AIEvent], records: [CatalogModelRecord]) {
        let isSeedRun = previous.isEmpty
        var events: [AIEvent] = []
        var records: [CatalogModelRecord] = []
        var seen: Set<String> = []

        for entry in current {
            guard let vendorId = vendor(forModelId: entry.id),
                  seen.insert(entry.id).inserted
            else { continue }
            let name = entry.name ?? entry.id
            let old = previous[entry.id]

            records.append(CatalogModelRecord(
                modelId: entry.id,
                vendorId: vendorId,
                name: name,
                createdAt: entry.created,
                promptPrice: entry.promptPrice,
                completionPrice: entry.completionPrice,
                firstSeen: old?.firstSeen ?? now,
                lastSeen: now
            ))

            guard !isSeedRun, !isVariant(entry.id) else { continue }

            if let old {
                if let event = priceChange(entry: entry, name: name, vendorId: vendorId, old: old, now: now) {
                    events.append(event)
                }
            } else {
                events.append(newModel(entry: entry, name: name, vendorId: vendorId, now: now))
            }
        }
        return (events, records)
    }

    private static func newModel(entry: CatalogEntry, name: String, vendorId: VendorIdentifier, now: Date) -> AIEvent {
        let sides = [
            entry.promptPrice.map { "Prompt \(perMillion($0))" },
            entry.completionPrice.map { "completion \(perMillion($0))" },
        ].compactMap { $0 }
        let detail: String? = sides.isEmpty
            ? nil
            : sides.joined(separator: " / ").capitalizedFirst + " per million tokens"
        return AIEvent(
            id: AIEvent.makeID(kind: .newModel, vendorId: vendorId, components: [entry.id]),
            kind: .newModel,
            vendorId: vendorId,
            title: "\(name) listed",
            detail: detail,
            occurredAt: entry.created ?? now,
            observedAt: now,
            source: .openRouterCatalog,
            url: URL(string: "https://openrouter.ai/\(entry.id)")
        )
    }

    private static func priceChange(
        entry: CatalogEntry, name: String, vendorId: VendorIdentifier, old: CatalogModelRecord, now: Date
    ) -> AIEvent? {
        var changes: [String] = []
        if let before = old.promptPrice, let after = entry.promptPrice, before != after {
            changes.append("prompt \(perMillion(before)) → \(perMillion(after))")
        }
        if let before = old.completionPrice, let after = entry.completionPrice, before != after {
            changes.append("completion \(perMillion(before)) → \(perMillion(after))")
        }
        guard !changes.isEmpty else { return nil }

        // Keyed on the new prices, so the same change seen again (a restart,
        // a re-poll) is one event, while a later second change is another.
        let components = [
            entry.id,
            entry.promptPrice.map { "\($0)" } ?? "nil",
            entry.completionPrice.map { "\($0)" } ?? "nil",
        ]
        return AIEvent(
            id: AIEvent.makeID(kind: .priceChange, vendorId: vendorId, components: components),
            kind: .priceChange,
            vendorId: vendorId,
            title: "\(name) price changed",
            detail: changes.joined(separator: ", ").capitalizedFirst + " per M tokens",
            occurredAt: now,
            observedAt: now,
            source: .openRouterCatalog,
            url: URL(string: "https://openrouter.ai/\(entry.id)")
        )
    }

    /// USD per token → "$X.XX" per million tokens, rounded in `Decimal` so a
    /// displayed price never carries float error.
    static func perMillion(_ perToken: Decimal) -> String {
        var scaled = perToken * 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let text = formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
        return "$\(text)"
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Fetches OpenRouter's public model catalog and turns it into events.
///
/// `GET https://openrouter.ai/api/v1/models` needs no key, and it is the one
/// place every tracked vendor's models appear with a creation date and a
/// machine-readable API price — including xAI's, which publishes no feed of
/// its own.
public struct OpenRouterCatalogWatcher: Sendable {
    /// Returns the raw catalog body, or nil on any network/HTTP failure.
    public typealias Fetcher = @Sendable () async -> Data?

    public static let catalogURL = "https://openrouter.ai/api/v1/models"

    private let fetch: Fetcher

    public init(fetch: @escaping Fetcher = OpenRouterCatalogWatcher.liveFetch) {
        self.fetch = fetch
    }

    /// Fetches, diffs against the stored catalog, stores the new catalog, and
    /// returns the candidate events (not yet recorded — `AIEventEngine` does
    /// that, so deduplication has one owner).
    ///
    /// Any failure — network, status, decode, or reading the stored catalog —
    /// yields no events and leaves the stored catalog untouched. Diffing
    /// against an empty catalog because the read failed would reseed it and
    /// lose every `firstSeen`.
    public func poll(store: QuotaHistoryStore, now: Date) async -> [AIEvent] {
        guard let data = await fetch() else { return [] }
        guard let entries = Self.parse(data) else {
            NSLog("frugalbar: OpenRouter catalog returned an unparseable body; no catalog events this poll")
            return []
        }
        let previous: [String: CatalogModelRecord]
        do {
            previous = try await store.catalogModels()
        } catch {
            NSLog("frugalbar: failed to read stored model catalog: \(error)")
            return []
        }
        let diff = CatalogDiff.compute(previous: previous, current: entries, now: now)
        do {
            try await store.upsertCatalogModels(diff.records)
        } catch {
            // Without the new baseline stored, the same events would be
            // derived again next poll; recording them is still deduplicated,
            // so this costs nothing worse than a log line.
            NSLog("frugalbar: failed to store model catalog: \(error)")
        }
        return diff.events
    }

    /// The production fetch. Checks the status before handing back a body:
    /// an error page is not a catalog.
    public static func liveFetch() async -> Data? {
        guard let (data, http) = try? await QuotaHTTP.get(url: catalogURL) else {
            NSLog("frugalbar: OpenRouter catalog fetch failed")
            return nil
        }
        guard QuotaHTTP.failureReason(for: http.statusCode) == nil else {
            NSLog("frugalbar: OpenRouter catalog returned HTTP \(http.statusCode)")
            return nil
        }
        return data
    }

    private struct Response: Decodable {
        struct Model: Decodable {
            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }
            let id: String
            let name: String?
            let created: Double?
            let pricing: Pricing?
        }
        let data: [Model]
    }

    /// Decodes the catalog body. nil when the body is not a catalog at all;
    /// an individual price that does not parse becomes nil for that side.
    public static func parse(_ data: Data) -> [CatalogEntry]? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        func price(_ text: String?) -> Decimal? {
            guard let text, !text.isEmpty else { return nil }
            return Decimal(string: text, locale: posix)
        }
        return response.data.map { model in
            CatalogEntry(
                id: model.id,
                name: model.name,
                created: model.created.map { Date(timeIntervalSince1970: $0) },
                promptPrice: price(model.pricing?.prompt),
                completionPrice: price(model.pricing?.completion)
            )
        }
    }
}
