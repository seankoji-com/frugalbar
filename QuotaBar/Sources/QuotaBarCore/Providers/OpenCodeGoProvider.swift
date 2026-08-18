import Foundation

/// OpenCode provider.
///
/// A previous revision called `https://api.opencode.ai/v1/usage`. No such
/// endpoint appears in OpenCode's documentation, and the hosted service
/// ("OpenCode Zen", `https://opencode.ai/zen/v1/...`) documents no usage or
/// quota endpoint either. The old code treated the resulting 404 as a
/// successful read and rendered a hardcoded "500/500 units, healthy".
///
/// Until a documented usage endpoint exists, this provider reports whether a
/// credential is present and nothing more. It performs no network call, so it
/// cannot mistake a failure for a healthy quota.
public final class OpenCodeGoProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .opencode
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard await credential(injected: apiKey, for: .opencode) != nil else {
            return unavailable(.notConfigured)
        }
        return unavailable(.unsupported("Credential found — OpenCode exposes no usage API"))
    }
}
