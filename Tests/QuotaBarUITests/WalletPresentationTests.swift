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

    @Test("one line per credit, each naming its provider and any named account, with no group headers")
    func singleLines() {
        #expect(wallet.rows.map(\.title) == [
            "Claude Console · Primary", "Gemini API · Account 1", "ChatGPT bonus", "ChatGPT API",
            "OpenRouter", "DeepSeek",
        ])
    }

    @Test("ChatGPT has two credit lines: its bonus credit count and its monthly API credit")
    func chatGPTCredits() throws {
        let bonus = try #require(wallet.rows.first { $0.title == "ChatGPT bonus" })
        #expect(bonus.figure == "60,085 credits")
        let api = try #require(wallet.rows.first { $0.title == "ChatGPT API" })
        #expect(api.figure == "$100.00/mo")
    }

    @Test("a credit with an expiry draws a provider-style bar; the even-use tick only where its period is published")
    func creditMeters() throws {
        // ChatGPT's monthly API credit publishes its period: bar and tick.
        guard case .credit(let api)? = wallet.rows.first(where: { $0.title == "ChatGPT API" })?.meter else {
            Issue.record("ChatGPT API has no credit bar"); return
        }
        #expect(abs((api.primaryFraction ?? 0) - 0.96) < 0.001)
        let pace = try #require(api.paceMarker)
        // Even use over the calendar month ending at the cycle end (OpenAI
        // publishes no cycle start; `OpenAIMonthlyCredit.entry`).
        let end = now.addingTimeInterval(26 * 86_400)
        let month = try #require(DualBarMetrics.monthWindowLength(endingAt: end))
        #expect(abs(pace - (1 - end.timeIntervalSince(now) / month)) < 0.001)
        #expect(GlancePresentation.window(for: api, now: now).isAheadOfPace)
        // The bonus credits publish an expiry but no start: a bar to the
        // expiry, no tick.
        guard case .credit(let bonus)? = wallet.rows.first(where: { $0.title == "ChatGPT bonus" })?.meter else {
            Issue.record("ChatGPT bonus has no credit bar"); return
        }
        #expect(abs((bonus.primaryFraction ?? 0) - (75_000 - 60_085) / 75_000) < 0.001)
        #expect(bonus.resetsAt == now.addingTimeInterval(38 * 86_400))
        #expect(bonus.paceMarker == nil)
    }

    @Test("a confirmed grant date gives the bonus bar its even-use tick over the grant's own period")
    func bonusGrantDate() throws {
        // The owner's grant: 62,500 credits, granted 30 Sep 2026, expiring at
        // the end of 31 Dec 2026, read on 24 Nov with 44,135 left.
        var snapshots = F.batchWithWallet
        let i = try #require(snapshots.firstIndex { $0.vendorId == .openai })
        let start = now.addingTimeInterval(-55 * 86_400)
        let end = now.addingTimeInterval(37 * 86_400)
        snapshots[i].apiCredits = [APICreditEntry(
            id: "openai.api-credits", vendorId: .openai, label: "Usage credits",
            metric: .credits(remaining: 44_135, unitName: "credits"),
            creditGrant: OpenAICreditGrant(total: 62_500, expiresAt: end, grantedAt: start))]
        let rows = WalletPresentation(snapshots: snapshots, now: now).rows
        guard case .credit(let bonus)? = rows.first(where: { $0.title == "ChatGPT bonus" })?.meter else {
            Issue.record("ChatGPT bonus has no credit bar"); return
        }
        #expect(abs((bonus.primaryFraction ?? 0) - (62_500 - 44_135) / 62_500) < 0.001)
        // 55 of the grant's 92 days have passed.
        let pace = try #require(bonus.paceMarker)
        #expect(abs(pace - 55.0 / 92.0) < 0.001)
        // Well short of even use: a lot is at risk of expiring unspent.
        #expect(bonus.paceStanding == .behind)
    }

    @Test("a time-only credit draws an elapsed-month meter, never a spend bar")
    func elapsedMeters() throws {
        for title in ["Claude Console · Primary", "Gemini API · Account 1"] {
            let row = try #require(wallet.rows.first { $0.title == title })
            guard case .elapsed(let fraction, let countdown)? = row.meter else {
                Issue.record("\(title) has no elapsed meter"); continue
            }
            #expect(fraction > 0 && fraction < 1)
            #expect(countdown != nil)
        }
    }

    @Test("each balance names its recorded series so its trend draws; credits with a bar do not")
    func balanceTrends() throws {
        let snapshots = GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots
        for vendor in [VendorIdentifier.openrouter, .deepseek] {
            let snapshot = try #require(snapshots.first { $0.vendorId == vendor })
            let row = try #require(wallet.rows.first { $0.vendor == vendor })
            let id = try #require(BalanceSeries.of(snapshot)?.id)
            #expect(row.balanceSeriesID == id)
            #expect(row.meter == nil)
        }
    }

    @Test("a Fable ticket is not in the Wallet: it sits beside the Fable line in Subscriptions")
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
        #expect(w.rows.contains { $0.title == "Claude plan reset ticket · Primary" && $0.figure == "20d remaining" })
    }

    @Test("a model ticket with no model line to sit beside stays in the Wallet")
    func unmatchedModelTicket() throws {
        var snapshot = try #require(F.batchWithWallet.first { $0.claudeAccount?.id == F.primary.id })
        snapshot.scopedBars = []   // no Fable line in Providers
        let w = WalletPresentation(snapshots: [snapshot], now: now)
        #expect(w.rows.contains { $0.title == "Claude Fable reset ticket · Primary" })
    }

    @Test("a named account is in the title; a vendor's single account is not named")
    func accountInTitle() throws {
        #expect(wallet.rows.contains { $0.title == "Claude Console · Primary" })
        let chatGPT = wallet.rows.filter { $0.vendor == .openai }
        #expect(!chatGPT.isEmpty)
        #expect(chatGPT.allSatisfy { !$0.title.contains("·") })
    }

    @Test("a named account's credit names the account once, as the provider stamps it on the entry")
    func namedAccountCreditNamedOnce() throws {
        // `ClaudeQuotaProvider` gives a named account's entries its
        // `accountName`; the Wallet already names the account from the
        // snapshot, so taking the entry's own title as well printed
        // "Claude · Primary Extra usage · Primary".
        var claude = F.claude(F.primary, [F.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)])
        claude.apiCredits = [APICreditEntry(id: F.primary.id + "|claude.extra-usage", vendorId: .claude,
            label: "Extra usage", metric: .currency(balance: 42, limit: nil, spent: nil, currencyCode: "USD"),
            poolID: "claude.extra-usage", accountID: claude.id, accountName: F.primary.name)]
        let rows = WalletPresentation(snapshots: [claude], now: now).rows
        #expect(rows.map(\.title) == ["Claude Extra usage · Primary"])
    }

    @Test("each Google account's Gemini API credit is its own configured line, named for the account")
    func geminiCreditPerAccount() throws {
        // main and burner each bill to their own Cloud Billing account
        // (owner, 24 Nov 2026): two pools, two lines.
        var snapshots = GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots
        var second = try #require(F.batch.first { $0.vendorId == .gemini && $0.antigravityAccount?.id == F.account2.id })
        second.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 14,
                                                 configuredAt: now.addingTimeInterval(-86_400))
        snapshots.append(second)
        let rows = WalletPresentation(snapshots: snapshots, now: now).rows.filter { $0.title.hasPrefix("Gemini API") }
        #expect(rows.map(\.title) == ["Gemini API · Account 1", "Gemini API · Account 2"])
        #expect(rows.map(\.figure) == ["A$25.00/mo", "A$14.00/mo"])
        #expect(rows.allSatisfy { $0.tag == "configured" })
    }

    @Test("one account's credit is one line however many of its routes carry it")
    func geminiCreditOncePerAccount() throws {
        var snapshots = GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots
        // The same account read through a second route carries the credit too.
        snapshots.append(try #require(snapshots.first { $0.geminiAPICredit != nil }))
        let rows = WalletPresentation(snapshots: snapshots, now: now).rows.filter { $0.title.hasPrefix("Gemini API") }
        #expect(rows.map(\.title) == ["Gemini API · Account 1"])
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

    @Test("OpenRouter and DeepSeek's own credit are Wallet lines, never Subscriptions rows, overdrawn or empty")
    func directBalancesLiveInTheWallet() throws {
        // The figures from the owner's popover on 24 Nov 2026: DeepSeek's
        // API credit overdrawn by a cent, OpenRouter at zero.
        var snapshots = F.batch.filter { $0.vendorId != .deepseek && $0.vendorId != .openrouter }
        snapshots.append(F.balance("deepseek", .deepseek, "DeepSeek", Decimal(string: "-0.01")!))
        snapshots.append(F.balance("openrouter", .openrouter, "OpenRouter", 0))

        let grid = ProviderGridPresentation(snapshots: snapshots,
                                            serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
        #expect(!grid.groups.contains { $0.id == .openrouter })
        #expect(!grid.groups.flatMap(\.pools).contains { $0.id == "deepseek" || $0.id == "openrouter" })

        let rows = WalletPresentation(snapshots: GlancePresentation(snapshots: snapshots, now: now).walletSnapshots,
                                      now: now).rows
        let deepSeek = try #require(rows.first { $0.id == "deepseek#balance" })
        #expect(deepSeek.title == "DeepSeek")
        #expect(deepSeek.figure == "-$0.01")
        #expect(deepSeek.tone == .negative)
        let openRouter = try #require(rows.first { $0.id == "openrouter#balance" })
        #expect(openRouter.figure == "$0.00")
        #expect(openRouter.tone == .normal)
    }

    @Test("a balance that could not be read is still a Wallet line, saying why, and in Subscriptions nowhere")
    func unreadableBalanceStaysVisible() throws {
        // The placeholder `QuotaManager.unavailableSnapshot` builds before a
        // first good poll: no balance, so its metric is not currency.
        let failed = QuotaSnapshot(id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits,
            metric: .subscription(tierName: UnavailableReason.offline.headline, renewalDate: nil),
            status: .unavailable(.offline), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        let snapshots = F.batch.filter { $0.vendorId != .openrouter } + [failed]
        let grid = ProviderGridPresentation(snapshots: snapshots,
                                            serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
        #expect(!grid.groups.flatMap(\.pools).contains { $0.id == "openrouter" })
        let rows = WalletPresentation(snapshots: GlancePresentation(snapshots: snapshots, now: now).walletSnapshots,
                                      now: now).rows
        let line = try #require(rows.first { $0.id == "openrouter#balance" })
        #expect(line.figure == UnavailableReason.offline.headline)
        #expect(line.tone == .unknown)
    }

    @Test("every Wallet line opens the inspector of the snapshot it came from")
    func linesOpenTheirSnapshot() throws {
        let snapshots = GlancePresentation(snapshots: F.batchWithWallet, now: now).walletSnapshots
        let rows = WalletPresentation(snapshots: snapshots, now: now).rows
        #expect(!rows.isEmpty)
        for row in rows {
            let source = try #require(snapshots.first { $0.id == row.snapshotID }, "\(row.title)")
            #expect(source.vendorId == row.vendor, "\(row.title)")
        }
        // The Console credit opens its Claude account's inspector.
        let console = try #require(rows.first { $0.title == "Claude Console · Primary" })
        #expect(snapshots.first { $0.id == console.snapshotID }?.claudeAccount?.id == F.primary.id)
    }

    @Test("a credit read on its own says LAST READING from its own read, not the quota poll's")
    func creditFreshnessIsItsOwn() throws {
        var snapshots = F.batchWithWallet
        let ai = try #require(snapshots.firstIndex { $0.vendorId == .openai })
        let claude = try #require(snapshots.firstIndex { $0.claudeAccount?.id == F.primary.id })
        func tags(_ batch: [QuotaSnapshot]) -> [String: String?] {
            let rows = WalletPresentation(snapshots: GlancePresentation(snapshots: batch, now: now).walletSnapshots,
                                          now: now).rows
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.tag) })
        }
        // Quota polls failed; both credits' own reads are fresh: no tag.
        snapshots[ai].staleReading = StaleReading(reason: .offline, at: now)
        snapshots[claude].staleReading = StaleReading(reason: .offline, at: now)
        var t = tags(snapshots)
        #expect(t["ChatGPT API"] == .some(nil))
        #expect(t["Claude Console · Primary"] == .some(nil))
        // The bonus credit rides the quota poll, so it is stale with it.
        #expect(t["ChatGPT bonus"] == .some("last reading"))

        // Quota fresh; the credits' own reads failed: tagged.
        snapshots[ai].staleReading = nil
        snapshots[claude].staleReading = nil
        snapshots[ai].openAIMonthlyCredit?.refreshFailed = true
        snapshots[claude].monthlyAPICredit?.refreshFailed = true
        t = tags(snapshots)
        #expect(t["ChatGPT API"] == .some("last reading"))
        #expect(t["Claude Console · Primary"] == .some("last reading"))
        #expect(t["ChatGPT bonus"] == .some(nil))
    }
}
