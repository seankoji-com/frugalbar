import Foundation

/// GitHub REST & GraphQL rate-limit provider.
/// GET https://api.github.com/rate_limit
/// Returns `resources.core` (REST) and `resources.graphql` (GraphQL).
public final class GitHubRestProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .githubRest
    public let displayName: String = "GitHub REST API"
    public let category: MetricCategory = .developerLimits

    private let token: String?

    public init(token: String? = nil) {
        self.token = token ?? CredentialStore.apiKey(for: .githubRest)
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let url = "https://api.github.com/rate_limit"
        let headers = ["Accept": "application/vnd.github+json"]
        let (data, http) = try await QuotaHTTP.get(url: url, headers: headers, key: token)

        struct Response: Decodable, Sendable {
            struct Resources: Decodable, Sendable {
                struct Rate: Decodable, Sendable {
                    let limit: Int
                    let remaining: Int
                    let reset: Int
                }
                let core: Rate
            }
            let resources: Resources
        }

        let decoded = try JSONDecoder().decode(Response.self, from: decoded)

        let remaining = decoded.resources.core.remaining
        let limit = decoded.resources.core.limit
        let resetAt = Date(timeIntervalSince1970: TimeInterval(decoded.resources.core.reset))

        let frac = limit > 0 ? 1.0 - (Double(remaining) / Double(limit)) : 0.0
        let status: ProviderStatus = {
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthenticated }
            if frac > 0.90 { return .critical }
            if frac > 0.70 { return .warning }
            return .healthy
        }()

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .count(remaining: remaining, limit: limit, unitName: "req/hr"),
            status: status,
            resetsAt: resetAt,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}

/// GraphQL node (shares the same endpoint, just reads a different resource key)
public final class GitHubGraphQLProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .githubGraphql
    public let displayName: String = "GitHub GraphQL"
    public let category: MetricCategory = .developerLimits

    private let token: String?

    public init(token: String? = nil) {
        self.token = token ?? CredentialStore.apiKey(for: .githubGraphql)
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let url = "https://api.github.com/rate_limit"
        let headers = ["Accept": "application/vnd.github+json"]
        let (data, http) = try await QuotaHTTP.get(url: url, headers: headers, key: token)

        struct Response: Decodable, Sendable {
            struct Resources: Decodable, Sendable {
                struct Rate: Decodable, Sendable {
                    let limit: Int
                    let remaining: Int
                    let reset: Int
                }
                let graphql: Rate
            }
            let resources: Resources
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)

        let remaining = decoded.resources.graphql.remaining
        let limit = decoded.resources.graphql.limit
        let resetAt = Date(timeIntervalSince1970: TimeInterval(decoded.resources.graphql.reset))

        let frac = limit > 0 ? 1.0 - (Double(remaining) / Double(limit)) : 0.0
        let status: ProviderStatus = {
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthenticated }
            if frac > 0.90 { return .critical }
            if frac > 0.70 { return .warning }
            return .healthy
        }()

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .count(remaining: remaining, limit: limit, unitName: "pts/hr"),
            status: status,
            resetsAt: resetAt,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}
