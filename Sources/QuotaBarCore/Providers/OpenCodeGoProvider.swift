import Foundation

/// OpenCode provider.
///
/// Reports active OpenCode Go subscription when credentials are present in the
/// Keychain or CLI config (~/.local/share/opencode/auth.json).
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
        let usagePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
            .appendingPathComponent("usage.json")

        guard let data = try? Data(contentsOf: usagePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return unavailable(.unsupported("OpenCode has not written usage data")) }

        func usage(_ key: String) -> Double? {
            guard let value = obj[key] as? Double, (0...1).contains(value) else { return nil }
            return value
        }
        let fiveHourUsage = usage("five_hour_used")
        let weeklyUsage = usage("weekly_used")
        let monthlyUsage = usage("monthly_used")
        guard fiveHourUsage != nil || weeklyUsage != nil || monthlyUsage != nil else {
            return unavailable(.badResponse)
        }
        let urgency: Urgency = (monthlyUsage ?? 0) >= 0.95 ? .critical
            : (fiveHourUsage ?? 0) >= 0.80 || (weeklyUsage ?? 0) >= 0.80 ? .warning : .none

        func row(_ fraction: Double?, _ label: String, _ resetKey: String) -> DualBarMetrics? {
            guard let fraction else { return nil }
            let percent = Int((fraction * 100).rounded())
            return DualBarMetrics(primaryFraction: fraction, label: label, statusColor: "#d47b00",
                                  usedText: "\(percent)% used", resetText: obj[resetKey] as? String)
        }

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "Go", renewalDate: nil),
            status: .measured(urgency),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: "Usage read from local OpenCode telemetry",
            row1: row(fiveHourUsage, "5H", "five_hour_reset"),
            row2: row(weeklyUsage, "WK", "weekly_reset"),
            row3: row(monthlyUsage, "MO", "monthly_reset"),
            badgeText: monthlyUsage.map { "\(Int(((1 - $0) * 100).rounded()))% left" },
            planName: "OpenCode Go",
            keyMasked: nil,
            cliSource: "macOS Keychain / auth.json"
        )
    }
}







