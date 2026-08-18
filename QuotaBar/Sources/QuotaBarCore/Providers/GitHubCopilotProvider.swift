import Foundation

/// GitHub Copilot subscription provider.
/// Uses gh auth token + /copilot_internal/v2/token to probe entitlement.
/// Falls back to /user endpoint for basic plan info.
public final class GitHubCopilotProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .copilot
    public let displayName: String = "GitHub Copilot"
    public let category: MetricCategory = .aiSubscriptions

    private let token: String?

    public init(token: String? = nil) {
        self.token = token ?? CredentialStore.apiKey(for: .copilot)
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let token, !token.isEmpty else {
            return QuotaSnapshot(
                id: vendorId.rawValue,
                vendorId: vendorId,
                displayName: displayName,
                category: category,
                metric: .subscription(tierName: "Unknown", renewalDate: nil),
                status: .unauthenticated,
                resetsAt: nil,
                lastUpdated: Date(),
                auxiliaryInfo: "No GitHub token available"
            )
        }

        // Try /user for display info
        let userURL = "https://api.github.com/user"
        let headers = ["Accept": "application/vnd.github+json"]
        let (userData, _) = try await QuotaHTTP.get(url: userURL, headers: headers, key: token)
        struct GHUser: Decodable, Sendable {
            let login: String
            let plan: Plan?
            struct Plan: Decodable, Sendable {
                let name: String
            }
        }
        let user = try? JSONDecoder().decode(GHUser.self, from: userData)

        // Try /copilot_internal/v2/token for the real copilot access token
        let copilotURL = "https://api.github.com/copilot_internal/v2/token"
        let (cpData, cpHttp) = try await QuotaHTTP.get(url: copilotURL, headers: headers, key: token)

        struct CtrlToken: Decodable, Sendable {
            let token: String?
            let expires_at: Int?
            let error: String?
            let error_description: String?
        }

        let ctrl = try? JSONDecoder().decode(CtrlToken.self, from: cpData)

        let tierName: String = user?.plan?.name ?? "Individual"
        let isActive = cpHttp.statusCode == 200 && ctrl?.token != nil
        let status: ProviderStatus = {
            if cpHttp.statusCode == 401 || cpHttp.statusCode == 403 { return .unauthenticated }
            guard isActive else { return .warning }
            return .healthy
        }()

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "\(tierName)\(isActive ? " • Active" : "")", renewalDate: nil),
            status: status,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: isActive ? nil : (ctrl?.error_description ?? "Copilot token unavailable")
        )
    }
}
