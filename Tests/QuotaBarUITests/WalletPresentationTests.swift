import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Wallet")
struct WalletPresentationTests {
    typealias F = GlanceFixtures
    let now = GlanceFixtures.now

    var wallet: WalletPresentation {
        WalletPresentation(snapshots: GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots,
                           now: now)
    }

    @Test("one line per credit, each naming its provider, with no group headers")
    func singleLines() {
        #expect(wallet.rows.map(\.title) == [
            "Claude Console", "Gemini API", "ChatGPT bonus", "ChatGPT API",
            "OpenRouter", "DeepSeek",
        ])
    }

    @Test("ChatGPT has two credit lines: its bonus credit count and its monthly API credit")
    func chatGPTCredits() throws {
        let bonus = try #require(wallet.rows.first { $0.title == "ChatGPT bonus" })
        #expect(bonus.figure == "60,085 credits")
        #expect(bonus.context?.contains("20% used") == true)
        let api = try #require(wallet.rows.first { $0.title == "ChatGPT API" })
        #expect(api.figure == "$100.00/mo")
        #expect(api.context?.contains("96% used") == true)
    }

    @Test("a credit with an expiry draws a usage bar; the even-use tick only where its period is published")
    func usageBars() throws {
        // ChatGPT's monthly API credit publishes its period: bar and tick.
        let api = try #require(wallet.rows.first { $0.title == "ChatGPT API" }?.usage)
        #expect(abs(api.used - 0.96) < 0.001)
        let pace = try #require(api.evenPace)
        // Even use over the calendar month ending at the cycle end (OpenAI
        // publishes no cycle start; `OpenAIMonthlyCredit.entry`).
        let end = now.addingTimeInterval(26 * 86_400)
        let month = try #require(DualBarMetrics.monthWindowLength(endingAt: end))
        #expect(abs(pace - (1 - end.timeIntervalSince(now) / month)) < 0.001)
        #expect(api.aheadOfPace)
        // The bonus credits publish an expiry but no start: a bar, no tick.
        let bonus = try #require(wallet.rows.first { $0.title == "ChatGPT bonus" }?.usage)
        #expect(abs(bonus.used - (75_000 - 60_085) / 75_000) < 0.001)
        #expect(bonus.evenPace == nil)
        // Time-only credits (Console, configured Gemini) have no usage bar.
        #expect(wallet.rows.first { $0.title == "Claude Console" }?.usage == nil)
        #expect(wallet.rows.first { $0.title == "Gemini API" }?.usage == nil)
    }

    @Test("a Fable ticket is not in the Wallet: it sits beside the Fable line in Providers")
    func modelTicketsLeaveTheWallet() throws {
        // No ticket line at all: the fixture's only ticket is Fable's, and a
        // leak could carry any label, so count ticket lines rather than names.
        #expect(!wallet.rows.contains { $0.symbol == "ticket.fill" })
        // A plan-wide ticket still has its line.
        var snapshots = F.batchWithWallet
        let i = try #require(snapshots.firstIndex { $0.claudeAccount?.id == F.primary.id })
        snapshots[i].resetCreditGroups.append(ResetCreditGroup(scope: .plan, count: 1,
                                                               expiries: [now.addingTimeInterval(20 * 86_400)]))
        snapshots[i].resetCreditsAvailable = 2
        let w = WalletPresentation(snapshots: snapshots, now: now)
        #expect(w.rows.contains { $0.title == "Claude plan reset ticket" && $0.figure == "20d remaining" })
    }

    @Test("a model ticket with no model line to sit beside stays in the Wallet")
    func unmatchedModelTicket() throws {
        var snapshot = try #require(F.batchWithWallet.first { $0.claudeAccount?.id == F.primary.id })
        snapshot.scopedBars = []   // no Fable line in Providers
        let w = WalletPresentation(snapshots: [snapshot], now: now)
        #expect(w.rows.contains { $0.title == "Claude Fable reset ticket" })
    }

    @Test("an account is named only when its provider has more than one")
    func accountContext() throws {
        let claude = try #require(wallet.rows.first { $0.title == "Claude Console" })
        #expect(claude.context?.hasPrefix("Primary") == true)
        let chatGPT = try #require(wallet.rows.first { $0.title == "ChatGPT API" })
        #expect(chatGPT.context?.hasPrefix("96%") == true)
    }

    @Test("the Gemini API key's credit is one configured line, never an Antigravity account's")
    func geminiKeyCredit() throws {
        var snapshots = GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots
        let credit = try #require(snapshots.compactMap(\.geminiAPICredit).first)
        var second = try #require(F.batch.first { $0.vendorId == .gemini && $0.antigravityAccount?.id == F.account2.id })
        second.geminiAPICredit = credit
        snapshots.append(second)
        let rows = WalletPresentation(snapshots: snapshots, now: now).rows.filter { $0.title == "Gemini API" }
        #expect(rows.count == 1)
        #expect(rows.first?.context?.hasPrefix("configured") == true)
        #expect(rows.first?.context?.contains("of month") == true)
    }

    @Test("an unreadable pool carrying a credit adds no 'Not configured' line")
    func unreadablePoolIsNotABalance() {
        var gemini = F.snapshot("agy:gemini", .gemini, "Gemini", [], status: .unavailable(.notConfigured))
        gemini.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 14,
                                                 configuredAt: now.addingTimeInterval(-86_400))
        let w = WalletPresentation(snapshots: [gemini], now: now)
        #expect(w.rows.map(\.title) == ["Gemini API"])
        #expect(!w.rows.contains { $0.figure == "Not configured" })
    }

    @Test("a balance vendor that was never configured has no line")
    func unconfiguredBalance() {
        let unconfigured = QuotaSnapshot(id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits, metric: .currency(balance: 0, limit: nil, spent: nil, currencyCode: "USD"),
            status: .unavailable(.notConfigured), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: nil, row2: nil)
        #expect(WalletPresentation(snapshots: [unconfigured], now: now).rows.isEmpty)
    }
}
