import Foundation

/// Antigravity subscription quota via the Google Cloud Code API. The request
/// format is derived from antigravity-usage (MIT); no executable is required.
public final class GeminiQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .gemini
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let accessToken: String?

    public init(accessToken: String? = nil) { self.accessToken = accessToken }

    private struct CodeAssist: Decodable {
        struct Project: Decodable { let id: String? }
        struct Plan: Decodable { let planType: String? }
        let cloudaicompanionProject: Project?
        let planInfo: Plan?
    }

    private struct ModelResponse: Decodable {
        struct Model: Decodable {
            struct Quota: Decodable { let remainingFraction: Double?; let resetTime: String? }
            let displayName: String?
            let label: String?
            let quotaInfo: Quota?
        }
        let models: [String: Model]?
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let resolvedToken = accessToken ?? GeminiOAuthSession.load()?.accessToken
        guard let token = resolvedToken, !token.isEmpty else {
            return unavailable(.notConfigured)
        }
        let metadata = ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
        let encoder = JSONEncoder()
        let assistBody = try encoder.encode(["metadata": metadata])
        let (assistData, assistHTTP) = try await QuotaHTTP.post(
            url: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", body: assistBody,
            headers: ["User-Agent": "antigravity"], auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: assistHTTP.statusCode) { return unavailable(reason) }
        guard let assist = try? JSONDecoder().decode(CodeAssist.self, from: assistData),
              let projectID = assist.cloudaicompanionProject?.id, !projectID.isEmpty
        else { return unavailable(.badResponse) }

        let modelBody = try encoder.encode(["project": projectID])
        let (modelsData, modelsHTTP) = try await QuotaHTTP.post(
            url: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", body: modelBody,
            headers: ["User-Agent": "antigravity"], auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: modelsHTTP.statusCode) { return unavailable(reason) }
        guard let response = try? JSONDecoder().decode(ModelResponse.self, from: modelsData),
              let models = response.models
        else { return unavailable(.badResponse) }

        let readings = models.compactMap { id, model -> (String, Double, Date)? in
            guard id.lowercased().contains("gemini"), !id.contains("2.5"),
                  let remaining = model.quotaInfo?.remainingFraction, (0...1).contains(remaining),
                  let resetText = model.quotaInfo?.resetTime, let reset = Self.parseDate(resetText)
            else { return nil }
            return (model.displayName ?? model.label ?? id, 1 - remaining, reset)
        }.sorted { $0.0 < $1.0 }
        guard let primary = readings.first else { return unavailable(.badResponse) }

        let rows = readings.prefix(3).map { Self.row(name: $0.0, used: $0.1, reset: $0.2) }
        let urgency: Urgency = primary.1 > 0.90 ? .critical : primary.1 > 0.70 ? .warning : .none
        let percent = Int((primary.1 * 100).rounded())
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: "Antigravity", renewalDate: nil),
            status: .measured(urgency), resetsAt: primary.2, lastUpdated: Date(),
            auxiliaryInfo: "Live Antigravity subscription quota", row1: rows[safe: 0],
            row2: rows[safe: 1], row3: rows[safe: 2], badgeText: "\(100 - percent)% left",
            planName: assist.planInfo?.planType ?? "Antigravity", cliSource: "Google OAuth"
        )
    }

    private static func row(name: String, used: Double, reset: Date) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: used, label: "AG", statusColor: "#3b82f6",
                       usedText: "\(name): \(Int((used * 100).rounded()))% used",
                       resetText: "Resets \(RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date()))")
    }

    private static func parseDate(_ text: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

public struct GeminiOAuthSession: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date
    static let keychainLabel = "gemini.oauth.session"

    static func load() -> GeminiOAuthSession? {
        guard let text = try? KeychainManager.shared.get(label: keychainLabel),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(GeminiOAuthSession.self, from: data)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
