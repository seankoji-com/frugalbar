import Foundation

/// One notification banner's text.
public struct AIEventBanner: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Decides which newly recorded events become banners, and what they say.
///
/// Pure, so the filtering is testable without `osascript`. Delivery stays in
/// `AppMain`.
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
    /// "Outage: …", "GPT-6.2 now available in Codex"), so a single event's
    /// banner is its title, with the vendor named where the title may not.
    public static func banners(for events: [AIEvent], enabledKinds: Set<AIEventKind>, now: Date) -> [AIEventBanner] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let eligible = events.filter {
            $0.isSurfaced && enabledKinds.contains($0.kind) && $0.occurredAt >= cutoff
        }
        return AIEventKind.allCases.compactMap { kind in
            let group = eligible.filter { $0.kind == kind }
            guard let first = group.first else { return nil }
            if group.count == 1 {
                return AIEventBanner(
                    title: bannerTitle(for: first),
                    body: first.detail ?? first.source.label)
            }
            return AIEventBanner(
                title: "\(group.count) \(kind.pluralTitle)",
                body: group.map(\.title).joined(separator: "; "))
        }
    }
}

extension AIEventNotification {
    /// Status-page incident names rarely name the vendor ("Elevated errors
    /// across all models"), so outage banners lead with it.
    static func bannerTitle(for event: AIEvent) -> String {
        switch event.kind {
        case .outageStarted, .outageResolved:
            "\(event.vendorId.displayName) · \(event.title)"
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
