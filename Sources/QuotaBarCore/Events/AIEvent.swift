import Foundation

// MARK: - Event kinds

/// The kinds of AI-platform event FrugalBar records and can notify about.
///
/// Every kind is an *observation*: a window the vendor said rolled over, a
/// usage figure that fell before the vendor's own reset time, a model that
/// appeared in a catalog FrugalBar actually fetched, a price that differs from
/// the one it stored last time. Nothing here is inferred from silence, and no
/// event is ever created to fill a gap in the record. The invariant in
/// `AGENTS.md` — never synthesise a quota — extends to events: an event that
/// claims something happened when nothing was measured is the same defect.
///
/// Persisted by `rawValue`, so the names are part of the on-disk contract.
/// Renaming a case reinterprets history; add new cases instead.
public enum AIEventKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A vendor-published quota window rolled over into a fresh allowance.
    /// Produced from `QuotaResetDetector`, which judges only on the vendor's
    /// own reset time, never on a drop in the consumed fraction.
    case usageReset = "usage_reset"

    /// A consumed fraction fell substantially *before* the vendor's published
    /// reset time, and the reset time itself did not move. This is how an
    /// unscheduled allowance restore looks from the outside — OpenAI resetting
    /// Codex limits for everyone, say, or a vendor crediting an outage. The
    /// event records exactly what was measured (the two fractions and the
    /// reset that had not yet passed); it never claims to know *why*.
    case usageRestored = "usage_restored"

    /// The vendor granted a banked usage-reset credit the user can redeem —
    /// OpenAI's `rate_limit_reset_credits` for Codex/ChatGPT. Recorded when
    /// the available count rises between two polls; the count itself is a
    /// vendor-published figure, never inferred.
    case resetCreditGranted = "reset_credit_granted"

    /// A model first seen in a catalog FrugalBar polls, or announced in a
    /// vendor's own feed.
    case newModel = "new_model"

    /// A model's catalog price differs from the one FrugalBar stored on the
    /// previous poll, or a vendor's own feed carried a pricing announcement.
    case priceChange = "price_change"

    public var id: String { rawValue }

    /// Short noun for section headers and filter chips.
    public var title: String {
        switch self {
        case .usageReset:    "Usage reset"
        case .usageRestored: "Usage restored"
        case .resetCreditGranted: "Reset credit"
        case .newModel:      "New model"
        case .priceChange:   "Price change"
        }
    }

    /// SF Symbol that carries the kind without relying on colour alone.
    public var symbolName: String {
        switch self {
        case .usageReset:    "arrow.counterclockwise.circle"
        case .usageRestored: "gift.circle"
        case .resetCreditGranted: "ticket.circle"
        case .newModel:      "sparkles.rectangle.stack"
        case .priceChange:   "dollarsign.circle"
        }
    }
}

// MARK: - Event sources

/// Where an event's evidence came from. Stored as a string so a new source
/// never reinterprets old rows, and surfaced in the UI so a reader can tell a
/// vendor-published fact from a catalog observation.
public enum AIEventSource: Sendable, Equatable, Hashable, Codable {
    /// The event was derived from two consecutive quota polls of the vendor's
    /// own usage endpoint.
    case quotaPoll
    /// The event was derived from a diff of OpenRouter's public model catalog
    /// (`GET https://openrouter.ai/api/v1/models`), which lists every major
    /// vendor's models with creation dates and API prices.
    case openRouterCatalog
    /// The event was derived from an item in a vendor's own RSS/Atom feed.
    /// `name` is the feed's short identifier (e.g. `openai-news`).
    case vendorFeed(name: String)

    /// Stable on-disk representation.
    public var rawValue: String {
        switch self {
        case .quotaPoll:               "quota-poll"
        case .openRouterCatalog:       "openrouter-catalog"
        case .vendorFeed(let name):    "feed:\(name)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "quota-poll":          self = .quotaPoll
        case "openrouter-catalog":  self = .openRouterCatalog
        default:
            guard rawValue.hasPrefix("feed:") else { return nil }
            let name = String(rawValue.dropFirst("feed:".count))
            guard !name.isEmpty else { return nil }
            self = .vendorFeed(name: name)
        }
    }

    /// Caption shown under an event so the reader knows what kind of evidence
    /// stands behind it.
    public var label: String {
        switch self {
        case .quotaPoll:            "From the vendor's usage endpoint"
        case .openRouterCatalog:    "From the OpenRouter model catalog"
        case .vendorFeed(let name):
            // A third-party scrape must never read as the vendor speaking.
            VendorFeed.named(name)?.isOfficial == false
                ? "From the \(name) feed (unofficial scrape)"
                : "From the \(name) feed"
        }
    }

    // Codable through `rawValue` so the JSON form matches the SQLite form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = AIEventSource(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown AIEventSource '\(raw)'")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Event

/// One recorded AI-platform event.
///
/// `id` is the deduplication key. Two observations of the same fact — the
/// same window resetting at the same time, the same model appearing in the
/// catalog, the same feed item — produce the same `id`, and
/// `QuotaHistoryStore.recordEvents` inserts each id once. Detectors build the
/// id from the facts that define the event (see `AIEvent.makeID`), never from
/// a fresh UUID, so a restart or a repeated poll cannot re-announce it.
public struct AIEvent: Identifiable, Sendable, Equatable, Hashable, Codable {
    public let id: String
    public let kind: AIEventKind
    public let vendorId: VendorIdentifier
    /// One line, e.g. "OpenAI WK window reset" or "claude-opus-5-5 listed".
    public let title: String
    /// Optional second line carrying the measured facts, e.g.
    /// "Used fell from 73% to 2% with 4 days left before the published reset".
    public let detail: String?
    /// When the event happened, as best the evidence says. For a feed item
    /// this is its publication date; for a poll-derived event it is the poll
    /// that observed it.
    public let occurredAt: Date
    /// When FrugalBar recorded it. Always ≥ `occurredAt` for poll events; a
    /// feed item published days before FrugalBar first fetched the feed has a
    /// much later `observedAt`.
    public let observedAt: Date
    public let source: AIEventSource
    /// A link to the vendor's own page for the event, when one exists.
    public let url: URL?

    public init(
        id: String,
        kind: AIEventKind,
        vendorId: VendorIdentifier,
        title: String,
        detail: String?,
        occurredAt: Date,
        observedAt: Date,
        source: AIEventSource,
        url: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.vendorId = vendorId
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.source = source
        self.url = url
    }

    /// Builds a deterministic id from the facts that define an event.
    ///
    /// `components` must be the facts, not the prose: a reset event is keyed
    /// on vendor, bar label and the *new* reset time; a catalog event on the
    /// model id; a feed event on the item's own guid. Rewording a title must
    /// never create a second copy of the same event.
    public static func makeID(kind: AIEventKind, vendorId: VendorIdentifier, components: [String]) -> String {
        ([kind.rawValue, vendorId.rawValue] + components).joined(separator: "|")
    }
}

// MARK: - Catalog model record

/// One model as last seen in the OpenRouter catalog, persisted so the next
/// poll can be diffed against it.
///
/// Prices are kept as `Decimal` and stored as text: OpenRouter publishes them
/// as decimal strings in USD per token ("0.000003"), and a binary float would
/// round-trip a value that then looked like a price change that never
/// happened. `nil` means the catalog published no figure, never zero.
public struct CatalogModelRecord: Sendable, Equatable, Codable {
    /// OpenRouter's id, e.g. `anthropic/claude-opus-5-5`.
    public let modelId: String
    /// The FrugalBar vendor the catalog prefix maps to.
    public let vendorId: VendorIdentifier
    public let name: String
    /// The catalog's own `created` timestamp.
    public let createdAt: Date?
    /// USD per prompt token.
    public let promptPrice: Decimal?
    /// USD per completion token.
    public let completionPrice: Decimal?
    public let firstSeen: Date
    public let lastSeen: Date

    public init(
        modelId: String,
        vendorId: VendorIdentifier,
        name: String,
        createdAt: Date?,
        promptPrice: Decimal?,
        completionPrice: Decimal?,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.modelId = modelId
        self.vendorId = vendorId
        self.name = name
        self.createdAt = createdAt
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}
