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
        // Gemini and OpenRouter each issue two sequential requests, so the
        // ceiling has to clear 2 x URLSession's 4s per-request budget or a slow
        // network cancels them mid-second-call and they report nothing.
        perProviderTimeout: 10
    )

    public init(
        cacheTTL: TimeInterval,
        backgroundRefreshInterval: TimeInterval,
        perProviderTimeout: TimeInterval = 10
    ) {
        self.cacheTTL = cacheTTL
        self.backgroundRefreshInterval = backgroundRefreshInterval
        self.perProviderTimeout = perProviderTimeout
    }
}
