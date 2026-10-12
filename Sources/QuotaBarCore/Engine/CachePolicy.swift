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
    /// Floor between two real network fetches of the *same* vendor. A vendor
    /// fetched more recently than this interval is served its cached snapshot
    /// instead of being re-hit, so refresh cannot hammer a paid provider's API
    /// faster than the floor allows.
    ///
    /// What the floor is measured from depends on who is asking, and that
    /// distinction is load-bearing. An automatic poll measures from the last
    /// fetch of any kind; a user-initiated `forceRefresh()` measures from the
    /// last *user-initiated* fetch. Measuring both from the same instant meant
    /// an automatic fetch — the 2-minute background tick, or the load the
    /// popover runs as it opens — armed the floor that then swallowed the
    /// user's click, so pressing ⟳ within the floor issued no request at all
    /// and the reading never moved. Zero disables the floor.
    public let minPollInterval: TimeInterval

    public static let `default` = CachePolicy(
        cacheTTL: 30,                    // popover opens are instant within 30s
        backgroundRefreshInterval: 120,  // 2 minute background poll
        // Gemini and OpenRouter each issue two sequential requests, so the
        // ceiling has to clear 2 x URLSession's 4s per-request budget or a slow
        // network cancels them mid-second-call and they report nothing.
        perProviderTimeout: 10,
        // Guards paid provider APIs from repeated "force refresh"
        // clicks; a vendor the user already refreshed within the last 30s is
        // served from cache. An automatic poll does not arm this floor.
        minPollInterval: 30
    )

    /// `minPollInterval` has NO default: every construction site must state
    /// its intent explicitly. `.default` — what the running app actually uses —
    /// is the single source of the 30s floor; everywhere else passes `0` (floor
    /// disabled) or its own value. Withholding a default means a missed or
    /// careless call site fails loudly at compile time instead of silently
    /// inheriting a floor it never asked for.
    public init(
        cacheTTL: TimeInterval,
        backgroundRefreshInterval: TimeInterval,
        perProviderTimeout: TimeInterval = 10,
        minPollInterval: TimeInterval
    ) {
        self.cacheTTL = cacheTTL
        self.backgroundRefreshInterval = backgroundRefreshInterval
        self.perProviderTimeout = perProviderTimeout
        self.minPollInterval = minPollInterval
    }
}
