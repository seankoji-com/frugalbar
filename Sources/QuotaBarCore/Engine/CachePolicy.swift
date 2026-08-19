import Foundation

/// Cache and timing policy for quota fetches.
public struct CachePolicy: Sendable {
    /// How long a completed fetch stays authoritative. Within this window the
    /// popover renders cached values instantly instead of refetching.
    public let cacheTTL: TimeInterval
    /// Background poll cadence.
    public let backgroundRefreshInterval: TimeInterval
    /// Hard wall-clock ceiling for a single provider's entire fetch, including
    /// credential resolution and any multi-request work.
    public let perProviderTimeout: TimeInterval

    public static let `default` = CachePolicy(
        cacheTTL: 30,                    // popover opens are instant within 30s
        backgroundRefreshInterval: 120,  // 2 minute background poll
        perProviderTimeout: 6            // > URLSession's 4s per-request budget
    )

    public init(
        cacheTTL: TimeInterval,
        backgroundRefreshInterval: TimeInterval,
        perProviderTimeout: TimeInterval = 6
    ) {
        self.cacheTTL = cacheTTL
        self.backgroundRefreshInterval = backgroundRefreshInterval
        self.perProviderTimeout = perProviderTimeout
    }
}
