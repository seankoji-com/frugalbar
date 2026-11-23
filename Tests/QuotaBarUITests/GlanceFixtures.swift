import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

/// Synthetic mixed-provider readings for the popover and widget tests.
enum GlanceFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func bar(_ label: String, _ used: Double?, resetsInHours: Double?, windowHours: Double?,
                    blocked: Bool = false, role: AllowanceRole = .plan) -> DualBarMetrics {
        let reset = resetsInHours.map { now.addingTimeInterval($0 * 3600) }
        let length = windowHours.map { $0 * 3600 }
        let pace = length.flatMap { DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now) }
        return DualBarMetrics(primaryFraction: used, expectedPaceFraction: pace, label: label,
                              isBlocked: blocked, allowanceRole: role, resetsAt: reset, windowLength: length)
    }

    static func snapshot(_ id: String, _ vendor: VendorIdentifier, _ name: String, plan: String? = nil,
                         _ bars: [DualBarMetrics], badge: String? = nil,
                         urgency: Urgency = .none, status: ProviderStatus? = nil,
                         category: MetricCategory = .aiSubscriptions) -> QuotaSnapshot {
        var snap = QuotaSnapshot(id: id, vendorId: vendor, displayName: name, category: category,
            metric: .subscription(tierName: plan, renewalDate: nil), status: status ?? .measured(urgency),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bars.indices.contains(0) ? bars[0] : nil,
            row2: bars.indices.contains(1) ? bars[1] : nil,
            badgeText: badge, planName: plan)
        snap.row3 = bars.indices.contains(2) ? bars[2] : nil
        return snap
    }

    static let burner = AntigravityAccount(id: "agy-burner", badge: "1", sourceLabel: "fixture",
        fallbackName: "Account 1", planName: "Google AI Pro")
    static let account2 = AntigravityAccount(id: "agy-account-2", badge: "2", sourceLabel: "fixture",
                                             fallbackName: "Account 2", planName: "Google AI Pro")
    static let primary = ClaudeAccount(id: "claude-primary", badge: "1", sourceLabel: "fixture",
                                       fallbackName: "Primary", planName: "Max (20x)")
    static let secondary = ClaudeAccount(id: "claude-secondary", badge: "2", sourceLabel: "fixture",
                                         fallbackName: "Secondary")

    static func agy(_ vendor: VendorIdentifier, _ account: AntigravityAccount,
                    _ bars: [DualBarMetrics]) -> QuotaSnapshot {
        var snap = snapshot("\(account.id):\(vendor.rawValue)", vendor, vendor.displayName,
                            plan: "Google AI Pro", bars)
        snap.antigravityAccount = account
        return snap
    }

    static func claude(_ account: ClaudeAccount, _ bars: [DualBarMetrics]) -> QuotaSnapshot {
        var snap = snapshot("claude-account:\(account.id)", .claude, account.name, plan: account.planName, bars)
        snap.claudeAccount = account
        return snap
    }

    /// Synthetic credit and balance entries used by the same renders.
    static var batchWithWallet: [QuotaSnapshot] {
        var all = batch
        if let i = all.firstIndex(where: { $0.claudeAccount?.id == primary.id }) {
            all[i].resetCreditsAvailable = 1
            // Synthetic, labelled: a linked Console credit, to show its owner grouping.
            all[i].monthlyAPICredit = try? ClaudeMonthlyCredit.decode(Data(
                #"{"status":"linked","monthly_credit_usd":"200","next_grant_at":"2027-02-11T00:00:00Z"}"#.utf8),
                now: now)
            all[i].resetCreditGroups = [ResetCreditGroup(scope: .model("Fable"), count: 1,
                                                         expiries: [now.addingTimeInterval(107 * 86_400)])]
        }
        if let i = all.firstIndex(where: { $0.vendorId == .gemini && $0.antigravityAccount?.id == burner.id }) {
            all[i].geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 25,
                                                     configuredAt: now.addingTimeInterval(-4 * 86_400))
        }
        if let i = all.firstIndex(where: { $0.vendorId == .openai }) {
            all[i].apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai, label: "Usage credits",
                metric: .credits(remaining: Decimal(string: "1234.5"), unitName: "credits"))]
        }
        all.append(balance("openrouter", .openrouter, "OpenRouter", 0))
        all.append(balance("deepseek", .deepseek, "DeepSeek", Decimal(string: "12.34")!))
        return all
    }

    static func balance(_ id: String, _ vendor: VendorIdentifier, _ name: String, _ value: Decimal) -> QuotaSnapshot {
        QuotaSnapshot(id: id, vendorId: vendor, displayName: name, category: .apiSpendAndCredits,
            metric: .currency(balance: value, limit: nil, spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: "Account credit",
            row1: nil, row2: nil)
    }

    /// The batch, in the popover's saved service order.
    static var batch: [QuotaSnapshot] {
        [
            claude(primary, [bar("WK", 0.61, resetsInHours: 132, windowHours: 168)]),
            claude(secondary, [bar("5H", 0.0, resetsInHours: nil, windowHours: 5),
                               bar("WK", 1.0, resetsInHours: 76, windowHours: 168)]),
            agy(.gemini, burner, [bar("5H", 0.008, resetsInHours: 4.2, windowHours: 5),
                                  bar("WK", 0.73, resetsInHours: 120, windowHours: 168)]),
            agy(.antigravityClaude, burner, [bar("WK", 1.0, resetsInHours: 55.2, windowHours: 168)]),
            agy(.antigravityArgon, burner, [bar("WK", 1.0, resetsInHours: 121.5, windowHours: 168)]),
            agy(.gemini, account2, [bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
                                    bar("WK", 0.53, resetsInHours: 148, windowHours: 168)]),
            agy(.antigravityClaude, account2, [bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
                                               bar("WK", 0.02, resetsInHours: 164, windowHours: 168)]),
            agy(.antigravityArgon, account2, [bar("WK", 0.008, resetsInHours: 144, windowHours: 168)]),
            snapshot("opencode-go:alpha", .opencode, "Alpha", plan: "OpenCode Go", [
                bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
                bar("WK", 0.0, resetsInHours: 159, windowHours: 168),
                bar("MO", 1.0, resetsInHours: 406, windowHours: 720, blocked: true)], badge: "Blocked", urgency: .critical),
            snapshot("opencode-go:legacy", .opencode, "Beta", plan: "OpenCode Go", [
                bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
                bar("WK", 0.0, resetsInHours: 159, windowHours: 168),
                bar("MO", 1.0, resetsInHours: 409, windowHours: 720, blocked: true)], badge: "Blocked", urgency: .critical),
            snapshot("opencode-go:gamma", .opencode, "Gamma", plan: "OpenCode Go", [
                bar("5H", 0.0, resetsInHours: 0.05, windowHours: 5),
                bar("WK", 0.0, resetsInHours: 159, windowHours: 168),
                bar("MO", 0.13, resetsInHours: 696, windowHours: 720)]),
            snapshot("opencode-go:delta", .opencode, "Delta", plan: "OpenCode Go Plus", [
                bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
                bar("WK", 0.0, resetsInHours: 159, windowHours: 168),
                bar("MO", 1.0, resetsInHours: 39.2, windowHours: 744, blocked: true)], badge: "Blocked", urgency: .critical),
            snapshot("opencode-go:workspace5", .opencode, "Workspace 5", plan: "OpenCode Go", [
                bar("5H", 0.08, resetsInHours: 2.5, windowHours: 5),
                bar("WK", 0.15, resetsInHours: 159, windowHours: 168),
                bar("MO", 0.78, resetsInHours: 504, windowHours: 720)]),
            snapshot("openai", .openai, "OpenAI", plan: "Pro",
                     [bar("WK", 1.0, resetsInHours: 44.4, windowHours: 168)], urgency: .critical),
            snapshot("opendesign:ws", .opendesign, "OpenDesign", [
                bar("5H", 0.0, resetsInHours: 1.8, windowHours: 5),
                bar("WK", 1.0, resetsInHours: 125.2, windowHours: 168)], urgency: .critical),
            snapshot("commandcode", .commandcode, "Command Code", plan: "GOAT", [
                bar("5H", 0.0, resetsInHours: nil, windowHours: 5),
                bar("WK", 0.0, resetsInHours: nil, windowHours: 168),
                bar("MO", 1.0, resetsInHours: 288, windowHours: 720)], urgency: .critical),
        ]
    }
}
