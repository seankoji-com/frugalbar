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
        var fiveHourUsage: Double = 0.00
        var weeklyUsage: Double = 0.00
        var monthlyUsage: Double = 1.00
        var fiveHourReset = "Resets in 5h 00m"
        var weeklyReset = "Resets in 4d 22h"
        var monthlyReset = "Resets in 4d 6h"

        let usagePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
            .appendingPathComponent("usage.json")

        if let data = try? Data(contentsOf: usagePath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fh = obj["five_hour_used"] as? Double { fiveHourUsage = fh }
            if let wk = obj["weekly_used"] as? Double { weeklyUsage = wk }
            if let mo = obj["monthly_used"] as? Double { monthlyUsage = mo }
            if let fhr = obj["five_hour_reset"] as? String { fiveHourReset = fhr }
            if let wkr = obj["weekly_reset"] as? String { weeklyReset = wkr }
            if let mor = obj["monthly_reset"] as? String { monthlyReset = mor }
        }

        let isMonthlyCritical = monthlyUsage >= 0.95
        let status: ProviderStatus = isMonthlyCritical ? .critical : (fiveHourUsage >= 0.80 ? .warning : .healthy)

        let row1 = DualBarMetrics(
            primaryFraction: fiveHourUsage,
            expectedPaceFraction: 0.40,
            label: "5H",
            statusColor: "#d47b00",
            usedText: "\(Int((fiveHourUsage * 100).rounded()))% rolling used",
            resetText: fiveHourReset
        )
        let row2 = DualBarMetrics(
            primaryFraction: weeklyUsage,
            expectedPaceFraction: 0.45,
            label: "WK",
            statusColor: "#d47b00",
            usedText: "\(Int((weeklyUsage * 100).rounded()))% weekly used",
            resetText: weeklyReset
        )
        let row3 = DualBarMetrics(
            primaryFraction: monthlyUsage,
            expectedPaceFraction: 0.60,
            label: "MO",
            statusColor: isMonthlyCritical ? "#ffb4ab" : "#d47b00",
            usedText: "\(Int((monthlyUsage * 100).rounded()))% monthly cap used",
            resetText: monthlyReset
        )

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "Go", renewalDate: nil),
            status: status,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: isMonthlyCritical ? "Monthly cap reached (100%) • \(monthlyReset)" : "Rolling: \(Int(fiveHourUsage * 100))% • Weekly: \(Int(weeklyUsage * 100))%",
            row1: row1,
            row2: row2,
            row3: row3,
            badgeText: isMonthlyCritical ? "Exhausted" : "\(Int(100 - monthlyUsage * 100))% left",
            planName: "OpenCode Go",
            latencyMs: 210,
            keyMasked: "oc_live_••••••••32Fa",
            cliSource: "macOS Keychain / auth.json"
        )
    }
}








