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

    @Test("every value sits under the provider and account it belongs to")
    func attribution() throws {
        let claude = try #require(wallet.entries.first { $0.vendor == .claude })
        #expect(claude.provider == "Claude Code")
        #expect(claude.account == "Primary · Max (20x)")
        #expect(claude.lines.map(\.title) == ["Console API credit", "Fable reset ticket"])

        let codex = try #require(wallet.entries.first { $0.vendor == .openai })
        #expect(codex.provider == "Codex")
        #expect(codex.lines.count == 1)
    }

    @Test("OpenRouter and DeepSeek balances are Wallet entries of their own")
    func directBalances() throws {
        let openrouter = try #require(wallet.entries.first { $0.vendor == .openrouter })
        #expect(openrouter.provider == "OpenRouter")
        #expect(openrouter.lines.map(\.figure) == ["$0.00"])
        let deepseek = try #require(wallet.entries.first { $0.vendor == .deepseek })
        #expect(deepseek.lines.first?.title == "Account credit")
    }

    @Test("the Gemini API key's credit is one configured entry, never an Antigravity account's line")
    func geminiKeyCredit() throws {
        // The configured credit is attached to every Gemini snapshot it reads
        // under; it is still one key, so one entry.
        var snapshots = GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots
        let credit = try #require(snapshots.compactMap(\.geminiAPICredit).first)
        var second = try #require(F.batch.first { $0.vendorId == .gemini && $0.antigravityAccount?.id == F.account2.id })
        second.geminiAPICredit = credit
        snapshots.append(second)
        let gemini = WalletPresentation(snapshots: snapshots, now: now).entries.filter { $0.vendor == .gemini }
        #expect(gemini.count == 1)
        let entry = try #require(gemini.first)
        #expect(entry.provider == "Gemini API")
        #expect(entry.account == "AI Studio key")
        #expect(entry.tag == "configured")
        // Its meter is time, captioned as time.
        let meter = try #require(entry.lines.first?.meter)
        #expect(meter.kind == .elapsed)
        #expect(meter.caption.hasSuffix("of the month elapsed"))
    }

    @Test("an unreadable pool carrying a credit adds no 'Not configured' line")
    func unreadablePoolIsNotABalance() throws {
        var gemini = F.snapshot("agy:gemini", .gemini, "Gemini", [], status: .unavailable(.notConfigured))
        gemini.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 14,
                                                 configuredAt: now.addingTimeInterval(-86_400))
        let w = WalletPresentation(snapshots: [gemini], now: now)
        #expect(w.entries.map(\.provider) == ["Gemini API"])
        #expect(!w.entries.flatMap(\.lines).contains { $0.figure == "Not configured" })
    }

    @Test("a balance vendor that was never configured has no entry")
    func unconfiguredBalance() {
        let unconfigured = QuotaSnapshot(id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits, metric: .currency(balance: 0, limit: nil, spent: nil, currencyCode: "USD"),
            status: .unavailable(.notConfigured), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: nil, row2: nil)
        #expect(WalletPresentation(snapshots: [unconfigured], now: now).entries.isEmpty)
    }
}
