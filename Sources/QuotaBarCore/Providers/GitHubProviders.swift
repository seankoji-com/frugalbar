import Foundation

// MARK: - Shared /rate_limit fetch

/// `GET /rate_limit` returns REST and GraphQL allowances in one payload, so
/// fetching it twice per cycle is pure waste — and lets the two rows disagree
/// about a reset window they actually share. This coalesces them: whichever
/// provider asks first performs the call, the other reuses the result.
///
/// The window is deliberately short — it exists to merge the two providers
/// inside a single refresh, not to act as a second cache layer.
actor GitHubRateLimitFetcher {

    static let shared = GitHubRateLimitFetcher()

    struct Rate: Decodable, Sendable {
        let limit: Int
        let remaining: Int
        let reset: Int
    }
    struct Payload: Decodable, Sendable {
        struct Resources: Decodable, Sendable {
            let core: Rate
            let graphql: Rate?
        }
        let resources: Resources
    }

    private var cached: (payload: Payload, at: Date, token: String)?
    private var inFlight: [String: Task<(Payload, Date), Error>] = [:]
    private let coalesceWindow: TimeInterval = 5

    /// Returns the payload and the instant it was actually fetched, so a
    /// coalesced read is not reported as fresher than it is.
    func rateLimits(token: String) async throws -> (payload: Payload, fetchedAt: Date) {
        if let cached,
           cached.token == token,
           Date().timeIntervalSince(cached.at) < coalesceWindow {
            return (cached.payload, cached.at)
        }
        // Keyed by token: joining another token's request would hand back the
        // wrong account's limits.
        if let existing = inFlight[token] {
            let (payload, at) = try await existing.value
            return (payload, at)
        }

        let task = Task<(Payload, Date), Error> {
            let (data, http) = try await QuotaHTTP.get(
                url: "https://api.github.com/rate_limit",
                headers: ["Accept": "application/vnd.github+json"],
                auth: .bearer(token)
            )
            if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
                throw ProviderError(reason)
            }
            guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
                throw ProviderError.badResponse
            }
            return (decoded, Date())
        }
        inFlight[token] = task
        defer { if inFlight[token] == task { inFlight[token] = nil } }

        let (payload, at) = try await task.value
        cached = (payload, at, token)
        return (payload, at)
    }

    /// Test hook — drops memoised state between cases.
    func reset() {
        cached = nil
        inFlight.removeAll()
    }
}

// MARK: - Snapshot construction

private func rateLimitSnapshot(
    provider: any QuotaProvider,
    rate: GitHubRateLimitFetcher.Rate,
    gqlRate: GitHubRateLimitFetcher.Rate? = nil,
    unitName: String,
    fetchedAt: Date
) -> QuotaSnapshot {
    // An authenticated allowance is 5000; unauthenticated it is 0.
    // A zero limit is not "100% consumed", it means there is no allowance to
    // report — so treat it as unreadable rather than drawing a full red bar.
    guard rate.limit > 0 else {
        return QuotaManager.unavailableSnapshot(for: provider, reason: .credentialRejected)
    }

    let consumed = 1.0 - min(max(Double(rate.remaining) / Double(rate.limit), 0), 1)
    let urgency: Urgency = consumed > 0.90 ? .critical
                         : consumed > 0.70 ? .warning
                         : .none

    let minsRemaining = max(0, rate.reset - Int(fetchedAt.timeIntervalSince1970)) / 60
    let r1 = DualBarMetrics(
        primaryFraction: consumed,
        secondaryFraction: 0.0,
        label: "REST",
        usedText: "\(rate.remaining) / \(rate.limit) req/hr",
        resetText: minsRemaining > 0 ? "Resets in \(minsRemaining)m" : "Resets shortly"
    )

    var r2: DualBarMetrics? = nil
    var auxInfo = "REST: \(rate.remaining)/\(rate.limit)"
    if let actualGql = gqlRate {
        let gqlConsumed = 1.0 - min(max(Double(actualGql.remaining) / Double(actualGql.limit), 0), 1)
        let gqlMins = max(0, actualGql.reset - Int(fetchedAt.timeIntervalSince1970)) / 60
        r2 = DualBarMetrics(
            primaryFraction: gqlConsumed,
            secondaryFraction: 0.0,
            label: "GraphQL",
            usedText: "\(actualGql.remaining) / \(actualGql.limit) pts/hr",
            resetText: gqlMins > 0 ? "Resets in \(gqlMins)m" : "Hourly roll at :00"
        )
        auxInfo = "REST: \(rate.remaining)/\(rate.limit) • GraphQL: \(actualGql.remaining)/\(actualGql.limit)"
    }

    let name = provider.vendorId == .githubRest ? "GitHub API" : provider.displayName

    return QuotaSnapshot(
        id: provider.vendorId.rawValue,
        vendorId: provider.vendorId,
        displayName: name,
        category: provider.category,
        metric: .count(remaining: rate.remaining, limit: rate.limit, unitName: unitName),
        status: .measured(urgency),
        resetsAt: Date(timeIntervalSince1970: TimeInterval(rate.reset)),
        lastUpdated: fetchedAt,
        auxiliaryInfo: auxInfo,
        row1: r1,
        row2: r2,
        badgeText: "\(rate.remaining) left",
        planName: "GitHub API",
        cliSource: "gh auth token"
    )
}



// MARK: - REST

public final class GitHubRestProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .githubRest
    public var displayName: String { "GitHub API" }
    public let category: MetricCategory = .developerLimits

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        // Without a token GitHub still answers 200, with the anonymous 60/hr
        // allowance — a real-looking number that has nothing to do with the
        // user's account. Refuse to report it.
        guard let resolved = await credential(injected: token, for: .githubRest) else {
            return unavailable(.notConfigured)
        }
        let result = try await GitHubRateLimitFetcher.shared.rateLimits(token: resolved)
        return rateLimitSnapshot(
            provider: self,
            rate: result.payload.resources.core,
            gqlRate: result.payload.resources.graphql,
            unitName: "req/hr",
            fetchedAt: result.fetchedAt
        )
    }
}


// MARK: - GraphQL

public final class GitHubGraphQLProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .githubGraphql
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .developerLimits

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let resolved = await credential(injected: token, for: .githubGraphql) else {
            return unavailable(.notConfigured)
        }
        let result = try await GitHubRateLimitFetcher.shared.rateLimits(token: resolved)
        guard let graphql = result.payload.resources.graphql else {
            return unavailable(.badResponse)
        }
        return rateLimitSnapshot(provider: self, rate: graphql,
                                 unitName: "pts/hr", fetchedAt: result.fetchedAt)
    }
}
