import Foundation

/// Claude subscription provider.
///
/// Anthropic publishes no API that reports a Claude.ai subscription's
/// remaining 5-hour or weekly message quota. (The Anthropic API's usage and
/// cost endpoints cover API organisations, not Claude.ai subscriptions.)
/// Claude Code's `/usage` command is backed by an undocumented OAuth endpoint
/// that is not part of the public API and is not safe to depend on.
///
/// This provider therefore reports `.unavailable(.unsupported)`: the row is
/// shown, but with no bar, no percentage and no countdown, because there is
/// no measurement to display. It deliberately does not estimate.
public final class ClaudeQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .claude
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    public init() {}

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        unavailable(.unsupported("Anthropic publishes no subscription quota API"))
    }
}
