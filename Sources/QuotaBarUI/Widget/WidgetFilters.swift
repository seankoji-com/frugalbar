import Foundation
import QuotaBarCore

// `TimeRange` is a String-backed enum; persisting the widget's filters needs it
// Codable, and the synthesised conformance encodes the raw value.
extension HistoryPresentation.TimeRange: Codable {}

/// What the desktop widget shows. Persisted as JSON.
public struct WidgetFilters: Codable, Equatable, Sendable {

    /// Which body the panel draws.
    public enum Layout: String, Codable, CaseIterable, Sendable {
        /// The story of one pool: what it has left, how fast it is going,
        /// when it comes back (owner, 23 Nov 2026). The default.
        case story
        /// Raw token consumption across providers as a stacked area. Tokens
        /// share one unit, so stacking them is meaningful, unlike quota
        /// windows. See `TokenUsagePresentation`.
        case tokens

        public var title: String {
            switch self {
            case .story: "Story"
            case .tokens: "Tokens"
            }
        }
    }

    /// The pool the story follows; nil follows the Use-now top pick.
    public var storyPoolID: String? = nil

    /// The Tokens layout's providers. Empty means every provider with a token source.
    public var vendors: Set<VendorIdentifier>
    /// The Tokens layout's range.
    public var range: HistoryPresentation.TimeRange
    public var layout: Layout

    public init(
        vendors: Set<VendorIdentifier> = [],
        range: HistoryPresentation.TimeRange = .last24Hours,
        layout: Layout = .story
    ) {
        self.vendors = vendors
        self.range = range
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case vendors, range, layout, storyPoolID
    }

    /// Tolerant decoding: a vendor removed in a later release is dropped rather
    /// than failing the whole set, and a missing or unknown field takes its
    /// default instead of discarding every other choice the user made. The
    /// retired `chart` and `overview` layouts are unknown values, so a stored
    /// choice of either opens on the story.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawVendors = (try? c.decodeIfPresent([String].self, forKey: .vendors)) ?? nil
        vendors = Set((rawVendors ?? []).compactMap(VendorIdentifier.init(rawValue:)))
        range = ((try? c.decodeIfPresent(HistoryPresentation.TimeRange.self, forKey: .range)) ?? nil) ?? .last24Hours
        layout = ((try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? nil) ?? .story
        storyPoolID = (try? c.decodeIfPresent(String.self, forKey: .storyPoolID)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vendors.map(\.rawValue).sorted(), forKey: .vendors)
        try c.encode(range, forKey: .range)
        try c.encode(layout, forKey: .layout)
        try c.encodeIfPresent(storyPoolID, forKey: .storyPoolID)
    }

    /// Reads persisted filters; anything undecodable yields the defaults.
    public static func decode(_ data: Data?) -> WidgetFilters {
        guard let data, let decoded = try? JSONDecoder().decode(WidgetFilters.self, from: data) else {
            return WidgetFilters()
        }
        return decoded
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func rangeShortTitle(_ range: HistoryPresentation.TimeRange) -> String {
        switch range {
        case .last24Hours: "24h"
        case .last7Days: "7d"
        case .last30Days: "30d"
        case .allTime: "all time"
        }
    }

    /// The Tokens header: "All subscriptions · tokens · 24h", "Claude · tokens · 7d".
    public var title: String {
        guard layout == .tokens else { return "Story" }
        let who = switch vendors.count {
        case 0: "All subscriptions"
        case 1: vendors.first!.displayName
        default: "\(vendors.count) subscriptions"
        }
        return [who, "tokens", Self.rangeShortTitle(range)].joined(separator: " · ")
    }
}
