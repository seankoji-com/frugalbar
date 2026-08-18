import Foundation

/// Cache policy with stale-while-revalidate semantics.
public struct CachePolicy: Sendable {
    public let cacheTTL: TimeInterval           // Time before cached entry is considered stale
    public let backgroundRefreshInterval: TimeInterval  // How often to refresh in background

    public static let `default` = CachePolicy(
        cacheTTL: 30,               // 30 seconds — fast UI update on popover open
        backgroundRefreshInterval: 120  // 2 minutes background polling
    )

    public init(cacheTTL: TimeInterval, backgroundRefreshInterval: TimeInterval) {
        self.cacheTTL = cacheTTL
        self.backgroundRefreshInterval = backgroundRefreshInterval
    }
}
