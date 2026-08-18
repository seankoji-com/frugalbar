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
    private var inFlight: Task<Payload, Error>?
    private let coalesceWindow: TimeInterval = 5

    func rateLimits(token: String) async throws -> Payload {
        if let cached,
           cached.token == token,
           Date().timeIntervalSince(cached.at) < coalesceWindow {
            return cached.payload
        }
        if let inFlight { return try await inFlight.value }

        let task = Task<Payload, Error> {
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
            return decoded
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }

        let payload = try await task.value
        cached = (payload, Date(), token)
        return payload
    }

    /// Test hook — drops memoised state between cases.
    func reset() {
        cached = nil
        inFlight = nil
    }
}

// MARK: - Snapshot construction

private func rateLimitSnapshot(
    provider: any QuotaProvider,
    rate: GitHubRateLimitFetcher.Rate,
    unitName: String
) -> QuotaSnapshot {
    // An authenticated GraphQL allowance is 5000; unauthenticated it is 0.
    // A zero limit is not "100% consumed", it means there is no allowance to
    // report — so treat it as unreadable rather than drawing a full red bar.
    guard rate.limit > 0 else {
        return QuotaManager.unavailableSnapshot(for: provider, reason: .credentialRejected)
    }

    let consumed = 1.0 - min(max(Double(rate.remaining) / Double(rate.limit), 0), 1)
    let urgency: Urgency = consumed > 0.90 ? .critical
                         : consumed > 0.70 ? .warning
                         : .none

    return QuotaSnapshot(
        id: provider.vendorId.rawValue,
        vendorId: provider.vendorId,
        displayName: provider.displayName,
        category: provider.category,
        metric: .count(remaining: rate.remaining, limit: rate.limit, unitName: unitName),
        status: .measured(urgency),
        resetsAt: Date(timeIntervalSince1970: TimeInterval(rate.reset)),
        lastUpdated: Date(),
        auxiliaryInfo: nil
    )
}

// MARK: - REST

public final class GitHubRestProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .githubRest
    public var displayName: String { vendorId.displayName }
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
        let payload = try await GitHubRateLimitFetcher.shared.rateLimits(token: resolved)
        return rateLimitSnapshot(provider: self, rate: payload.resources.core, unitName: "req/hr")
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
        let payload = try await GitHubRateLimitFetcher.shared.rateLimits(token: resolved)
        guard let graphql = payload.resources.graphql else {
            return unavailable(.badResponse)
        }
        return rateLimitSnapshot(provider: self, rate: graphql, unitName: "pts/hr")
    }
}
