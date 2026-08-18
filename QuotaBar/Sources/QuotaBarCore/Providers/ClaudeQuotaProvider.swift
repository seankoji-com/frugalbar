import Foundation

/// Claude quota provider.
///
/// Claude Desktop manages OAuth internally and does not expose a public
/// quota/usage API endpoint. File presence of `~/.claude.json` is not a
/// valid session check, and Claude's usage limits vary by plan and model
/// (not fixed message counts), so any fabricated numbers here would be
/// actively misleading.
///
/// This provider reports `.unsupported` to show the row with a distinct
/// visual treatment — no progress bar, no percentage, no countdown —
/// rather than presenting invented data.
public final class ClaudeQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .claude
    public let displayName: String = "Claude"
    public let category: MetricCategory = .aiSubscriptions

    private static let claudeConfigPath = ".claude.json"

    public init() {}

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let reason: String
        let configDir = FileManager.default.homeDirectoryForCurrentUser
        let configURL = configDir.appendingPathComponent(Self.claudeConfigPath)
        if FileManager.default.fileExists(atPath: configURL.path) {
            reason = "No public quota API — Claude Desktop manages usage internally"
        } else {
            reason = "No ~/.claude.json session found"
        }

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "Claude Pro (estimated)", renewalDate: nil),
            status: .unsupported(reason),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: reason
        )
    }
}
