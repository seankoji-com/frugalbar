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
    /// several. `.usageReset` is excluded: its banner has its own per-vendor
    /// opt-in and its own path in `AppMain`.
    public static func banners(for events: [AIEvent], enabledKinds: Set<AIEventKind>, now: Date) -> [AIEventBanner] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let eligible = events.filter {
            $0.kind != .usageReset && enabledKinds.contains($0.kind) && $0.occurredAt >= cutoff
        }
        return AIEventKind.allCases.compactMap { kind in
            let group = eligible.filter { $0.kind == kind }
            guard let first = group.first else { return nil }
            if group.count == 1 {
                return AIEventBanner(
                    title: "\(kind.title): \(first.title)",
                    body: first.detail ?? first.source.label)
            }
            return AIEventBanner(
                title: "\(group.count) \(kind.pluralTitle)",
                body: group.map(\.title).joined(separator: "; "))
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
            "OpenAI granted a banked reset credit you can redeem in Codex."
        case .newModel:
            "A Claude, GPT, Gemini or Grok model appeared in the OpenRouter catalog or a vendor feed."
        case .priceChange:
            "A tracked model's OpenRouter price changed, or a vendor feed announced pricing."
        }
    }
}
