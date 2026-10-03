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

    /// A model appeared in the list of models the user's own account can
    /// select (`AccountModelWatcher`). Rows recorded before that watcher
    /// existed came from the OpenRouter catalog or a vendor news feed; they
    /// stay in the log but are never surfaced (see `isSurfaced`).
    case newModel = "new_model"

    /// Retired: a catalog or news-feed price change. Nothing records it any
    /// more; the case stays so rows already on disk still decode.
    case priceChange = "price_change"

    /// A vendor reset everyone's usage (or granted a banked reset), as
    /// recorded after it landed by a community reset tracker that links the
    /// vendor's own announcement.
    case vendorReset = "vendor_reset"

    /// The vendor's official status page opened a major or critical incident
    /// on a product FrugalBar tracks.
    case outageStarted = "outage_started"

    /// The vendor's official status page marked that incident resolved.
    case outageResolved = "outage_resolved"

    public var id: String { rawValue }

    /// Short noun for section headers and filter chips.
    public var title: String {
        switch self {
        case .usageReset:    "Usage reset"
        case .usageRestored: "Usage restored"
        case .resetCreditGranted: "Reset credit"
        case .newModel:      "New model"
        case .priceChange:   "Price change"
        case .vendorReset:   "Vendor reset"
        case .outageStarted: "Outage"
        case .outageResolved: "Outage resolved"
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
        case .vendorReset:   "arrow.clockwise.heart"
        case .outageStarted: "exclamationmark.triangle"
        case .outageResolved: "checkmark.shield"
        }
    }

    /// The kinds FrugalBar still produces and shows: resets, outages, and
    /// models newly selectable on the user's own account. Scheduled window
    /// rollovers (`usageReset`) are logged and drawn on the timeline but are
    /// routine, so they never take the popover's one row or a banner here.
    public static let surfaced: [AIEventKind] = [
        .vendorReset, .usageRestored, .resetCreditGranted,
        .outageStarted, .outageResolved, .newModel,
    ]
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
    /// Retired: an item in a vendor news feed. Kept so old rows decode.
    case vendorFeed(name: String)
    /// A community reset tracker (`ResetTracker.name`).
    case resetTracker(name: String)
    /// A vendor's official status page (`StatusPage.name`).
    case statusPage(name: String)
    /// The list of models the user's own account can select, fetched with
    /// the same credential as its quota.
    case accountModels

    /// Stable on-disk representation.
    public var rawValue: String {
        switch self {
        case .quotaPoll:               "quota-poll"
        case .openRouterCatalog:       "openrouter-catalog"
        case .vendorFeed(let name):    "feed:\(name)"
        case .resetTracker(let name):  "tracker:\(name)"
        case .statusPage(let name):    "status:\(name)"
        case .accountModels:           "account-models"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "quota-poll":          self = .quotaPoll
        case "openrouter-catalog":  self = .openRouterCatalog
        case "account-models":      self = .accountModels
        default:
            let prefixed: [(String, (String) -> AIEventSource)] = [
                ("feed:", { .vendorFeed(name: $0) }),
                ("tracker:", { .resetTracker(name: $0) }),
                ("status:", { .statusPage(name: $0) }),
            ]
            for (prefix, make) in prefixed where rawValue.hasPrefix(prefix) {
                let name = String(rawValue.dropFirst(prefix.count))
                guard !name.isEmpty else { return nil }
                self = make(name)
                return
            }
            return nil
        }
    }

    /// Caption shown under an event so the reader knows what kind of evidence
    /// stands behind it.
    public var label: String {
        switch self {
        case .quotaPoll:            "From the vendor's usage endpoint"
        case .openRouterCatalog:    "From the OpenRouter model catalog"
        case .vendorFeed(let name):     "From the \(name) feed"
        case .resetTracker(let name):
            // A third-party record must never read as the vendor speaking.
            "Via \(ResetTracker.named(name)?.host ?? name) (community tracker)"
        case .statusPage(let name):
            "From \(StatusPage.named(name)?.pageURL.host() ?? name)"
        case .accountModels:            "From your account's model list"
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

    /// Whether this event is one FrugalBar shows in the popover, notifies
    /// about, and lists in the History window: a surfaced kind, and for a new
    /// model only one the user's own account can select. Catalog listings and
    /// news-feed rows recorded by earlier versions stay on disk but are not
    /// a model anyone can pick yet.
    public var isSurfaced: Bool {
        guard AIEventKind.surfaced.contains(kind) else { return false }
        if kind == .newModel { return source == .accountModels }
        return true
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
