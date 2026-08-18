import Foundation

/// GitHub Copilot provider.
///
/// GitHub publishes no REST endpoint that reports an individual user's own
/// Copilot premium-request quota. Every documented Copilot metrics endpoint is
/// scoped to `/orgs/{org}/...` or `/enterprises/{enterprise}/...` and requires
/// org or enterprise admin rights.
///
/// A previous revision called `/copilot_internal/v2/token`. That path is an
/// undocumented internal endpoint used by GitHub's own clients; it is not part
/// of any published API, can change without notice, and returns a live access
/// token we have no need for. It has been removed.
///
/// We validate the token against the documented `/user` endpoint and report
/// the account, but we do not claim a quota we cannot read.
public final class GitHubCopilotProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .copilot
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let resolved = await credential(injected: token, for: .copilot) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://api.github.com/user",
            headers: ["Accept": "application/vnd.github+json"],
            auth: .bearer(resolved)
        )

        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        struct GHUser: Decodable, Sendable { let login: String }
        guard let user = try? JSONDecoder().decode(GHUser.self, from: data) else {
            return unavailable(.badResponse)
        }

        return unavailable(
            .unsupported("Signed in as \(user.login) — no individual quota API")
        )
    }
}
