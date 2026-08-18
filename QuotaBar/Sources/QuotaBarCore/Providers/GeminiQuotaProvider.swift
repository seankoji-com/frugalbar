import Foundation

/// Gemini (Google AI Studio) provider.
///
/// Google publishes no endpoint that reports per-key quota or usage for the
/// Generative Language API. Model-catalogue contents reflect availability, not
/// entitlement or consumption, so they cannot be used to infer either.
///
/// What we *can* do honestly is validate the key. A successful `models` call
/// proves the credential works; it tells us nothing about remaining quota. So
/// this provider reports a validated-but-unmeasurable state rather than a
/// number.
///
/// The key is sent in the `x-goog-api-key` header, which is what Google's own
/// documentation uses. It is never placed in the query string, where it would
/// leak into proxy logs, error descriptions and crash reports.
public final class GeminiQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .gemini
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .gemini) else {
            return unavailable(.notConfigured)
        }

        let (_, http) = try await QuotaHTTP.get(
            url: "https://generativelanguage.googleapis.com/v1beta/models",
            auth: .header(name: "x-goog-api-key", value: key)
        )

        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        // Key is valid. Google exposes no consumption figure, so we say so
        // rather than inventing one.
        return unavailable(.unsupported("Key valid — Google exposes no usage API"))
    }
}
