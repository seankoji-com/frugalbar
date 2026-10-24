import Foundation

/// One notification banner's text.
public struct AIEventBanner: Sendable, Equatable {
    /// The bold line macOS draws. Kept to a phrase: a two-sentence incident
    /// name set as the title filled four bold lines and pushed the banner
    /// past its body (see `subtitle`).
    public let title: String
    /// A second, quieter line. Only outage banners use it, for the incident's
    /// own published name.
    public let subtitle: String?
    public let body: String
    /// The vendor page a click should open, when the banner describes a
    /// single event that carried one. Nil on a consolidated banner: there is
    /// no one page to promise.
    public let url: URL?

    public init(title: String, subtitle: String? = nil, body: String, url: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.url = url
    }
}

/// Decides which newly recorded events become banners, and what they say.
///
/// Pure, so the filtering is testable without `osascript`. Delivery lives in
/// `QuotaBarApp/NotificationDelivery.swift`.
public enum AIEventNotification {

    /// An event older than this is recorded but never announced. A feed's
    /// first poll keeps a week of items so the log has something in it; this
    /// is what stops that week from arriving as a burst of stale banners, and
    /// what keeps a model the catalog lists months after its `created` date
    /// from being announced as news.
    public static let maximumAge: TimeInterval = 48 * 3600

    /// One banner per kind per poll, listing every title when there are
    /// several. Only surfaced events notify (`AIEvent.isSurfaced`):
    /// `.usageReset` has its own per-vendor opt-in and its own path in
    /// `AppMain`, and retired catalog and news-feed rows never notify.
    ///
    /// Titles already say what happened ("Codex reset for everyone",
    /// "GPT-6.2 now available in Codex"), so those banners keep the title as
    /// is. A status-page incident name is often a full sentence, too long for
    /// the bold line; the outage banner takes a short title and gives the
    /// incident name the subtitle.
    public static func banners(for events: [AIEvent], enabledKinds: Set<AIEventKind>, now: Date) -> [AIEventBanner] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let eligible = events.filter {
            $0.isSurfaced && enabledKinds.contains($0.kind) && $0.occurredAt >= cutoff
        }
        return AIEventKind.allCases.compactMap { kind in
            let group = eligible.filter { $0.kind == kind }
            guard let first = group.first else { return nil }
            if group.count == 1 {
                return banner(for: first)
            }
            return AIEventBanner(
                title: "\(group.count) \(kind.pluralTitle)",
                body: group.map(consolidatedTitle).joined(separator: "; "))
        }
    }
}

extension AIEventNotification {
    /// A single event's banner: the title says what happened, an outage's own
    /// name goes in the subtitle, and the body keeps the measured detail.
    static func banner(for event: AIEvent) -> AIEventBanner {
        switch event.kind {
        case .outageStarted:
            return AIEventBanner(
                title: "\(event.vendorId.displayName) outage",
                subtitle: incidentName(from: event.title),
                body: event.detail ?? event.source.label,
                url: event.url)
        case .outageResolved:
            return AIEventBanner(
                title: "\(event.vendorId.displayName) outage resolved",
                subtitle: incidentName(from: event.title),
                body: event.detail ?? event.source.label,
                url: event.url)
        default:
            return AIEventBanner(
                title: event.title,
                body: event.detail ?? event.source.label,
                url: event.url)
        }
    }

    /// The incident's own name, without the kind prefix the event title
    /// carries ("Outage: …", "Resolved: …").
    static func incidentName(from title: String) -> String {
        for prefix in ["Outage: ", "Resolved: "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    /// The line one event contributes to a consolidated banner. An outage's
    /// kind is already in that banner's title, so repeating "Outage:" on
    /// every item only lengthens the body.
    static func consolidatedTitle(for event: AIEvent) -> String {
        switch event.kind {
        case .outageStarted, .outageResolved:
            incidentName(from: event.title)
        default:
            event.title
        }
    }
}

extension AIEventKind {
    /// Lower-case plural for a consolidated banner: "3 new models".
    public var pluralTitle: String {
        switch self {
        case .usageReset:         "usage resets"
        case .usageRestored:      "usage restores"
        case .resetCreditGranted: "reset credits"
        case .newModel:           "new models"
        case .priceChange:        "price changes"
        case .vendorReset:        "vendor resets"
        case .outageStarted:      "outages"
        case .outageResolved:     "outages resolved"
        }
    }

    /// One line for the Settings toggle that controls this kind's banners.
    public var notificationCaption: String {
        switch self {
        case .usageReset:
            "A quota window rolled over at the reset time the provider published."
        case .usageRestored:
            "Usage fell sharply before the provider's published reset — an unscheduled restore."
        case .resetCreditGranted:
            "The vendor granted a banked reset credit you can redeem (OpenAI in Codex, Anthropic on claude.ai)."
        case .newModel:
            "A model became selectable on one of your subscriptions, read from that account's own model list."
        case .priceChange:
            "Retired."
        case .vendorReset:
            "Anthropic, OpenAI or xAI reset usage for everyone or granted a banked reset."
        case .outageStarted:
            "The vendor's status page reported a major or critical incident on a product you use."
        case .outageResolved:
            "The vendor's status page marked that incident resolved."
        }
    }
}
