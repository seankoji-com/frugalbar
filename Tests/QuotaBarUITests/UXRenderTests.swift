import AppKit
import Security
import SwiftUI
import Testing
import Vision
import WebKit
@testable import QuotaBarCore
@testable import QuotaBarUI

// Opt-in offscreen renders of production views. Fixtures never enter a live store.
@Suite("UX renders", .enabled(if: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil))
@MainActor
struct UXRenderTests {
    /// Design B avatars, the single spent red across Command Code and OpenCode
    /// Go, a named Claude row carrying the linked monthly credit, and an
    /// two OpenDesign Go workspace rows.
    @Test func renderExhaustedAndNewRows() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = ClaudeAccountFixtures.now
        func bar(_ label: String, _ fraction: Double?, _ hours: Double, blocked: Bool = false) -> DualBarMetrics {
            let length: TimeInterval = label == "5H" ? QuotaWindow.fiveHours
                : label == "WK" ? QuotaWindow.week : 30 * 86400
            return DualBarMetrics(primaryFraction: fraction,
                expectedPaceFraction: DualBarMetrics.proRataPace(resetsAt: now.addingTimeInterval(hours * 3600),
                    windowLength: length, now: now), label: label,
                blockedColor: blocked ? "#ffb4ab" : nil, isBlocked: blocked,
                resetsAt: now.addingTimeInterval(hours * 3600), windowLength: length)
        }
        func snapshot(_ id: String, _ vendor: VendorIdentifier, _ plan: String?,
                      _ rows: [DualBarMetrics], name: String? = nil) -> QuotaSnapshot {
            QuotaSnapshot(id: id, vendorId: vendor, displayName: name ?? id, category: .aiSubscriptions,
                metric: .subscription(tierName: plan, renewalDate: nil), status: .measured(.none),
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: rows.first, row2: rows.dropFirst().first, row3: rows.dropFirst(2).first, planName: plan)
        }
        var primary = ClaudeAccountFixtures.snapshot(ClaudeAccountFixtures.personal, weekly: 0.42, fable: 0.18)
        primary.row1 = bar("5H", 0.12, 3)
        primary.row2 = bar("WK", 0.42, 4 * 24)
        primary.monthlyAPICredit = ClaudeMonthlyCredit(amountUSD: 200,
            nextGrantAt: now.addingTimeInterval(9 * 86400), measuredAt: now)
        let commandCode = snapshot("Command Code", .commandcode, "Pro", [bar("MO", 1, 13 * 24)])
        let workspaces = [
            snapshot("Alpha", .opencode, "OpenCode Go", [bar("WK", 1, 20, blocked: true), bar("MO", 0.50, 25 * 24)]),
            snapshot("Beta", .opencode, "OpenCode Go", [bar("5H", 0.16, 0.6), bar("WK", 0.20, 24)]),
        ]
        let openDesign = [
            snapshot(OpenDesignQuotaProvider.seriesID(workspaceID: "render-primary"), .opendesign,
                     "OpenDesign Go · Pro", [bar("5H", 0.08, 2), bar("WK", 0.31, 3 * 24)],
                     name: OpenDesignConnection.primary.displayName),
            snapshot(OpenDesignQuotaProvider.seriesID(workspaceID: "render-secondary"), .opendesign,
                     "OpenDesign Go · Pro", [bar("5H", 0.52, 1), bar("WK", 0.74, 4 * 24)],
                     name: OpenDesignConnection.secondary.displayName),
        ]
        try await save(livePopover([primary, commandCode] + workspaces + openDesign, expanded: .deepseek, now: now)
            .padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "exhausted-and-new-rows", directory: directory)
        try await save(SettingsView(store: nil, initialPane: .service(.opendesign), readsCredentials: false),
                       name: "settings-opendesign", directory: directory)
        try await save(HStack(spacing: 24) {
            VendorAvatarView(vendorId: .claude, status: .healthy, size: 28)
            VendorAvatarView(vendorId: .claude, status: .healthy, isExhausted: true,
                             exhaustedReset: "13d", showsResetOverlay: true, size: 28)
            VendorAvatarView(vendorId: .commandcode, status: .healthy, isExhausted: true,
                             showsResetOverlay: true, size: 28)
        }.padding(20).background(Theme.card), name: "exhausted-avatar", directory: directory)
    }

    @Test func renderClaudeAliasHistory() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = ClaudeAccountFixtures.now
        var account = ClaudeAccountFixtures.personal
        account.historyAliases = ["claude-account:previous-source"]
        let subject = HistoryOverviewPresentation.Subject(id: account.id, vendor: .claude,
            name: account.name, keys: account.historyKeys)
        let readings = account.historyKeys.reversed().enumerated().map { index, key in
            QuotaHistoryStore.ReadingRecord(vendor: key, barLabel: "WK",
                measuredAt: now.addingTimeInterval(index == 0 ? -1800 : 0), fraction: index == 0 ? 0.2 : 0.4,
                isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: now.addingTimeInterval(86400), windowLength: QuotaWindow.week, elapsedOnly: false)
        }
        let card = try #require(HistoryOverviewPresentation.overview(subjects: [subject], readings: readings).cards.first)
        try await save(HistoryOverviewCardView(card: card, isSelected: true, onSelect: {})
            .padding(12).frame(width: 260).background(Theme.surface),
            name: "claude-account-alias-overview", directory: directory)
    }

    @Test func renderClaudeAccountConfigurationB1() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClaudeAccountSettingsRender.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = ClaudeAccountStore.saveDiscovered(
            [ClaudeAccountFixtures.personal, ClaudeAccountFixtures.work], in: defaults)
        #expect(accounts.count == 2)
        try await save(Form {
            ClaudeAccountSettingsView(accounts: accounts, load: { ClaudeAccountStore.all(in: defaults) },
                saveNickname: { name, id in ClaudeAccountStore.setNickname(name, for: id, in: defaults) })
        }.formStyle(.grouped).frame(width: 550, height: 430),
            name: "claude-account-b1-settings", directory: directory)
        try await save(Form {
            ClaudeAccountSettingsView(accounts: [], load: nil,
                saveNickname: { _, _ in Issue.record("Fixture must not save a nickname") })
        }.formStyle(.grouped).frame(width: 550, height: 330),
            name: "claude-account-b1-settings-empty", directory: directory)
    }

    @Test func renderAgreedChatGPTLayout() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var snapshot = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro 200", renewalDate: nil),
            status: .measured(.none), resetsAt: now.addingTimeInterval(7 * 86_400),
            lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.24, label: "WK", resetsAt: now.addingTimeInterval(7 * 86_400)),
            planName: "Pro 200")
        snapshot.resetCreditsAvailable = 2
        snapshot.resetCreditExpiries = [now.addingTimeInterval(20 * 86_400),
                                        now.addingTimeInterval(21 * 86_400)]
        snapshot.apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai,
            label: "Usage credits", metric: .credits(remaining: 59_641, unitName: "credits"),
            creditGrant: OpenAICreditGrant(total: 75_000, expiresAt: now.addingTimeInterval(68 * 86_400)))]
        try await save(livePopover([snapshot], expanded: .openai, now: now)
            .padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "chatgpt-agreed-layout", directory: directory)
        snapshot.resetCreditsAvailable = 7
        snapshot.resetCreditExpiries = [now.addingTimeInterval(86_400), nil, now, now.addingTimeInterval(12 * 86_400)]
        snapshot.staleReading = StaleReading(reason: .offline, at: now)
        try await save(livePopover([snapshot], expanded: .openai, now: now)
            .padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "chatgpt-ticket-overflow-stale", directory: directory)
        try await save(Form { OpenAIAccountSettingsView(accountKey: "render-fixture") }
            .formStyle(.grouped).frame(width: 500, height: 360), name: "chatgpt-account-settings", directory: directory)
    }

    @Test func renderRestoredMuseTeamSelection() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "MusePortalRender.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: MusePortalSession.enabledKey)
        preferences.set("42", forKey: MusePortalSession.teamKey)
        let session = MusePortalSession(preferences: preferences, website: RenderPortalWebsite())
        #expect(session.teams.isEmpty && session.teamPickerOptions.map(\.id) == ["42"])
        try await save(MusePortalConnectionView(session: session), name: "muse-restored-team", directory: directory)
    }

    private final class RenderPortalWebsite: MusePortalWebsite {
        var webView: WKWebView? { nil }
        var isAtPortal: Bool { false }
        func open() { Issue.record("A render must not open the portal") }
        func host() {}
        func waitUntilPortal(id: UUID, complete: @escaping @MainActor @Sendable (Bool) -> Void) { complete(false) }
        func cancelPortalWait(id: UUID) {}
        func stop() {}
        func clear() async {}
        func evaluate(email: String, plan: String, teamID: String,
                      complete: @escaping @MainActor @Sendable (String?) -> Void) {
            Issue.record("A render must not request portal data")
            complete(nil)
        }
    }

    /// The popover as it is drawn now: Subscriptions with one group
    /// expanded, then the Wallet when anything carries a credit or balance.
    /// Fixtures render this rather than the legacy `MetricSectionView`, which
    /// the app draws only for developer limits and which omits every credit.
    private func livePopover(_ snapshots: [QuotaSnapshot], expanded: VendorIdentifier? = nil,
                             now: Date, balanceSeries: [String: [BalancePoint]] = [:]) -> some View {
        let wallet = WalletPresentation(
            snapshots: GlancePresentation(snapshots: snapshots, now: now).walletSnapshots, now: now)
        return VStack(spacing: Theme.sectionGap) {
            ProviderGridView(presentation: ProviderGridPresentation(
                snapshots: snapshots, serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now),
                expanded: expanded)
            if !wallet.rows.isEmpty {
                WalletSection(presentation: wallet, balanceSeries: balanceSeries, now: now)
            }
        }
    }

    private struct FixtureProvider: QuotaProvider {
        let snapshot: QuotaSnapshot
        var vendorId: VendorIdentifier { snapshot.vendorId }
        var displayName: String { snapshot.displayName }
        var category: MetricCategory { snapshot.category }
        var instanceID: String { snapshot.id }
        func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
    }

    @Test func renderAntigravityPools() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func snapshot(_ vendor: VendorIdentifier, name: String, weekly: Double) -> QuotaSnapshot {
            let plan = vendor == .claude ? "Max" : vendor == .openai ? "Pro" : "Google AI Pro"
            return QuotaSnapshot(id: vendor.rawValue, vendorId: vendor, displayName: name,
                category: .aiSubscriptions, metric: .subscription(tierName: plan, renewalDate: nil),
                status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: weekly, label: "WK"), planName: plan)
        }
        var claude = snapshot(.antigravityClaude, name: "AGY Claude/GPT", weekly: 0.47)
        claude.row2 = DualBarMetrics(primaryFraction: 0.05, label: "5H")
        var codex = snapshot(.openai, name: "OpenAI", weekly: 0.8)
        codex.apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai,
            label: "Usage credits", metric: .credits(remaining: Decimal(string: "60085.422977"), unitName: "credits"))]
        let rows = [claude, snapshot(.claude, name: "Claude", weekly: 0.38),
                    snapshot(.antigravityArgon, name: "AGY Argon", weekly: 0.51),
                    codex,
                    snapshot(.gemini, name: "Gemini", weekly: 0.6)]
        try await save(VStack(spacing: 12) {
            Text("Fixture · service groups, separate pools").font(.caption)
            livePopover(rows, expanded: .gemini, now: now)
        }.padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "agy-pools", directory: directory)
        let exhaustedRows = Array(rows.dropLast()) + [snapshot(.gemini, name: "Gemini", weekly: 1)]
        try await save(VStack(spacing: 12) {
            Text("Fixture · mixed exhaustion stays in its service").font(.caption)
            livePopover(exhaustedRows, expanded: .gemini, now: now)
        }.padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "agy-pools-exhausted", directory: directory)
        try await save(HStack(spacing: 16) {
            VendorAvatarView(vendorId: .antigravityClaude, status: .healthy, size: 28)
            VendorAvatarView(vendorId: .antigravityClaude, status: .healthy, isExhausted: true, size: 28)
            VendorAvatarView(vendorId: .antigravityClaude, status: .unavailable(.badResponse), size: 28)
            VendorAvatarView(vendorId: .claude, status: .healthy, size: 28)
        }.padding(12).background(Theme.surface), name: "agy-claude-icons", directory: directory)
    }

    /// The menu-bar title in each tone, and Subscriptions with stale, weak and
    /// unreadable pools.
    @Test func renderGlanceStates() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = GlanceFixtures.now
        func grid(_ snapshots: [QuotaSnapshot]) -> ProviderGridView {
            ProviderGridView(presentation: ProviderGridPresentation(
                snapshots: snapshots, serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now))
        }

        func spent(_ hours: Double?) -> QuotaSnapshot {
            GlanceFixtures.snapshot("s\(hours ?? -1)", .opencode, "Spent",
                                    [GlanceFixtures.bar("WK", 1.0, resetsInHours: hours, windowHours: 168)])
        }
        let weak = GlanceFixtures.snapshot("w", .opencode, "Low",
                                           [GlanceFixtures.bar("WK", 0.88, resetsInHours: 100, windowHours: 168)])
        var stale = GlanceFixtures.snapshot("st", .claude, "Stale",
                                            [GlanceFixtures.bar("WK", 0.1, resetsInHours: 100, windowHours: 168)])
        stale.staleReading = StaleReading(reason: .rateLimited(retryAfter: nil), at: now)
        let states: [(String, [QuotaSnapshot])] = [
            ("pick", GlanceFixtures.batch), ("weak pick", [weak]),
            ("all spent", [spent(38)]), ("none confirmed", [spent(38), stale]),
        ]
        try await save(VStack(alignment: .leading, spacing: 8) {
            ForEach(states, id: \.0) { label, snaps in
                let title = MenuBarGlance.presentation(snapshots: snaps, now: now)
                HStack(spacing: 6) {
                    Text(label).font(.caption).foregroundStyle(Theme.outline).frame(width: 100, alignment: .leading)
                    if let vendor = title.vendor {
                        VendorAvatarView(vendorId: vendor, status: .measured(.none), size: 16)
                    } else if let symbol = title.symbolName {
                        Image(systemName: symbol).foregroundStyle(Color(nsColor: MenuBarGlance.color(for: title.tone)))
                    }
                    Text(title.text).font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color(nsColor: MenuBarGlance.color(for: title.tone)))
                }
            }
            grid([stale, weak])
        }.padding(12).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "glance-states", directory: directory)

        let unreadableClaude = [
            GlanceFixtures.snapshot("claude-account:primary", .claude, "Primary", [],
                                    status: .unavailable(.rateLimited(retryAfter: nil))),
            GlanceFixtures.snapshot("claude-account:secondary", .claude, "Secondary", [],
                                    status: .unavailable(.timedOut)),
        ]
        try await save(
            grid(unreadableClaude + [weak])
                .padding(Theme.edgeMargin)
                .frame(width: PopoverRootView.popoverWidth)
                .background(Theme.surface),
            name: "popover-claude-unreadable", directory: directory)
    }

    @Test func renderProviderGrid() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let presentation = ProviderGridPresentation(
            snapshots: GlanceFixtures.batchWithWallet, serviceOrder: ProviderDisplayPreferences.defaultOrder,
            now: GlanceFixtures.now
        )
        for vendor in [nil, .deepseek, .claude] as [VendorIdentifier?] {
            try await save(ProviderGridView(presentation: presentation, expanded: vendor)
                .padding(Theme.edgeMargin)
                .frame(width: PopoverRootView.popoverWidth)
                .background(Theme.surface),
                name: vendor == .claude ? "provider-grid-claude" :
                    vendor == nil ? "provider-grid-collapsed" : "provider-grid-expanded", directory: directory)
        }
        // The popover as drawn: Gemini expanded (Argon now sits in it, each
        // row naming its route), then the Wallet.
        let now = GlanceFixtures.now
        // The ChatGPT bonus as the owner's account had it on 24 Nov 2026:
        // 62,500 credits granted 55 days ago, 37 days to expiry, 44,135 left,
        // with the grant date saved so its even-use tick draws.
        var walletBatch = GlanceFixtures.batchWithWallet
        if let i = walletBatch.firstIndex(where: { $0.vendorId == .openai }) {
            walletBatch[i].apiCredits = [APICreditEntry(
                id: "openai.api-credits", vendorId: .openai, label: "Usage credits",
                metric: .credits(remaining: 44_135, unitName: "credits"),
                creditGrant: OpenAICreditGrant(total: 62_500, expiresAt: now.addingTimeInterval(37 * 86_400),
                                               grantedAt: now.addingTimeInterval(-55 * 86_400)))]
        }
        // A second Google account with its own Gemini API credit: two pools.
        if let i = walletBatch.firstIndex(where: {
            $0.vendorId == .gemini && $0.antigravityAccount?.id == GlanceFixtures.account2.id
        }) {
            walletBatch[i].geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 14,
                                                             configuredAt: now.addingTimeInterval(-86_400))
        }
        let wallet = WalletPresentation(
            snapshots: GlancePresentation(snapshots: walletBatch, now: now).walletSnapshots, now: now)
        // A week of recorded balances for each balance line, so its trend draws.
        var series: [String: [BalancePoint]] = [:]
        for (index, id) in wallet.rows.compactMap(\.balanceSeriesID).enumerated() {
            series[id] = (0..<8).map { day in
                BalancePoint(measuredAt: now.addingTimeInterval(Double(day - 7) * 86_400),
                             value: Decimal(20 - day * (index + 1)) + Decimal(day % 3))
            }
        }
        try await save(VStack(spacing: Theme.sectionGap) {
            ProviderGridView(presentation: presentation, expanded: .claude)
            WalletSection(presentation: wallet, balanceSeries: series, now: now)
        }
        .padding(Theme.edgeMargin)
        .frame(width: PopoverRootView.popoverWidth)
        .background(Theme.surface), name: "provider-grid-gemini-wallet", directory: directory)
    }

    /// Three states v0.32.0's review checked by reading code only: the Gemini
    /// group expanded with each row naming its route, Wallet tags at full
    /// width beside their glyph-only form, and a spent Wallet credit bar.
    @Test func renderSubscriptionsWalletStates() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = GlanceFixtures.now

        // 1. Gemini expanded: account 1 read through this Mac's Google
        // sign-in (AGY), account 2 through the CLI Proxy.
        var routed = GlanceFixtures.batch
        for i in routed.indices where routed[i].vendorId == .gemini || routed[i].vendorId == .antigravityArgon {
            routed[i].cliSource = routed[i].antigravityAccount?.id == GlanceFixtures.burner.id
                ? "Google OAuth (this Mac)" : "CLI Proxy (localhost)"
        }
        let grid = ProviderGridPresentation(snapshots: routed, serviceOrder: ProviderDisplayPreferences.defaultOrder,
                                            now: now)
        let gemini = try #require(grid.groups.first { $0.id == .gemini })
        #expect(gemini.pools.map { "\($0.name) | \($0.source ?? "")" } == [
            "Account 1 | Gemini · AGY", "Account 1 | Argon · AGY",
            "Account 2 | Gemini · CLI Proxy", "Account 2 | Argon · CLI Proxy",
        ])
        try await save(ProviderGridView(presentation: grid, expanded: .gemini)
            .padding(Theme.edgeMargin)
            .frame(width: PopoverRootView.popoverWidth)
            .background(Theme.surface), name: "provider-grid-gemini-routes", directory: directory)
        // The presentation can be right while the view drops it, and the
        // offscreen accessibility tree is empty, so read the rendered pixels.
        let gridText = try renderedText("provider-grid-gemini-routes", directory: directory)
        #expect(gridText.filter { $0.contains("AGY") }.count == 2, "\(gridText)")
        #expect(gridText.filter { $0.contains("CLI Proxy") }.count == 2, "\(gridText)")

        // 2. Tags: short titles keep the word, long account names shrink the
        // tag to its glyph (pencil for configured, clock for last reading).
        var plainGemini = GlanceFixtures.snapshot("gemini", .gemini, "Gemini", plan: "Google AI Pro",
            [GlanceFixtures.bar("WK", 0.4, resetsInHours: 100, windowHours: 168)])
        plainGemini.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 25,
                                                      configuredAt: now.addingTimeInterval(-4 * 86_400))
        let longGoogle = AntigravityAccount(id: "agy-long", badge: "3", sourceLabel: "fixture",
            fallbackName: "research-burner-account@example.com", planName: "Google AI Pro")
        var longGemini = GlanceFixtures.agy(.gemini, longGoogle,
            [GlanceFixtures.bar("WK", 0.2, resetsInHours: 100, windowHours: 168)])
        longGemini.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 14,
                                                     configuredAt: now.addingTimeInterval(-86_400))
        var staleBalance = GlanceFixtures.balance("openrouter", .openrouter, "OpenRouter", Decimal(string: "8.50")!)
        staleBalance.staleReading = StaleReading(reason: .offline, at: now)
        let longClaude = ClaudeAccount(id: "claude-long", badge: "3", sourceLabel: "fixture",
                                       fallbackName: "Platform Engineering Shared Seat")
        var staleClaude = GlanceFixtures.claude(longClaude,
            [GlanceFixtures.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)])
        // Stamped with its account as `ClaudeQuotaProvider` stamps a named
        // account's entries.
        staleClaude.apiCredits = [APICreditEntry(id: longClaude.id + "|claude.extra-usage", vendorId: .claude,
            label: "Extra usage", metric: .currency(balance: 42, limit: 200, spent: nil, currencyCode: "USD"),
            poolID: "claude.extra-usage", accountID: staleClaude.id, accountName: longClaude.name)]
        staleClaude.staleReading = StaleReading(reason: .offline, at: now)
        // Names long enough to push out the tag's word but short enough to
        // stay whole beside its glyph: the case the glyph exists for.
        let midGoogle = AntigravityAccount(id: "agy-mid", badge: "4", sourceLabel: "fixture",
            fallbackName: "Research", planName: "Google AI Pro")
        var midGemini = GlanceFixtures.agy(.gemini, midGoogle,
            [GlanceFixtures.bar("WK", 0.2, resetsInHours: 100, windowHours: 168)])
        midGemini.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 14,
                                                    configuredAt: now.addingTimeInterval(-86_400))
        let midClaude = ClaudeAccount(id: "claude-mid", badge: "4", sourceLabel: "fixture", fallbackName: "Ops")
        var midStale = GlanceFixtures.claude(midClaude,
            [GlanceFixtures.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)])
        midStale.apiCredits = [APICreditEntry(id: midClaude.id + "|claude.extra-usage", vendorId: .claude,
            label: "Extra usage", metric: .currency(balance: 42, limit: 200, spent: nil, currencyCode: "USD"),
            poolID: "claude.extra-usage", accountID: midStale.id, accountName: midClaude.name)]
        midStale.staleReading = StaleReading(reason: .offline, at: now)
        let tagged = WalletPresentation(
            snapshots: [plainGemini, midGemini, longGemini, staleBalance, midStale, staleClaude], now: now)
        #expect(tagged.rows.map(\.title) == [
            "Gemini API cap", "Gemini API cap · Research", "Gemini API cap · research-burner-account@example.com",
            "OpenRouter", "Claude Extra usage · Ops", "Claude Extra usage · Platform Engineering Shared Seat",
        ])
        // No CONFIGURED tag any more (owner, 26 Nov 2026): a typed figure's line
        // is only ever drawn for itself, so only carried-over reads are tagged.
        #expect(tagged.rows.map(\.tag) == [nil, nil, nil,
                                           "last reading", "last reading", "last reading"])
        try await save(WalletSection(presentation: tagged, now: now)
            .padding(Theme.edgeMargin)
            .frame(width: PopoverRootView.popoverWidth)
            .background(Theme.surface), name: "wallet-tags", directory: directory)
        // The word is drawn only where the title leaves room for it: once
        // each. The mid-length names stay whole beside their glyphs.
        let tagText = try renderedText("wallet-tags", directory: directory)
        #expect(!tagText.contains { $0.contains("CONFIGURED") }, "\(tagText)")
        #expect(tagText.filter { $0.contains("LAST READING") }.count == 1, "\(tagText)")
        #expect(tagText.contains { $0.contains("Research") }, "\(tagText)")
        #expect(tagText.contains { $0.contains("usage · Ops") || $0.contains("usage • Ops") }, "\(tagText)")

        // 3. Spent credits: ChatGPT bonus at 0 of 62,500 (grant date saved, so
        // the tick would draw if it were not spent), the Claude promo at $0
        // of $100, and an unspent monthly grant for contrast.
        var openai = GlanceFixtures.snapshot("openai", .openai, "OpenAI", plan: "Pro",
            [GlanceFixtures.bar("WK", 0.4, resetsInHours: 100, windowHours: 168)])
        openai.apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai, label: "Usage credits",
            metric: .credits(remaining: 0, unitName: "credits"),
            creditGrant: OpenAICreditGrant(total: 62_500, expiresAt: now.addingTimeInterval(37 * 86_400),
                                           grantedAt: now.addingTimeInterval(-55 * 86_400)))]
        openai.openAIMonthlyCredit = OpenAIMonthlyCredit(
            grantUSD: 100, remainingUSD: 64, periodStart: now.addingTimeInterval(-4 * 86_400),
            periodEnd: now.addingTimeInterval(26 * 86_400), measuredAt: now)
        var claude = GlanceFixtures.snapshot("claude", .claude, "Claude", plan: "Max",
            [GlanceFixtures.bar("WK", 0.4, resetsInHours: 100, windowHours: 168)])
        claude.apiCredits = [APICreditEntry(id: "claude.promo-credit", vendorId: .claude, label: "Promo credit",
            metric: .currency(balance: 0, limit: 100, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, monthlyPeriodEnd: now.addingTimeInterval(12 * 86_400))]
        let spent = WalletPresentation(snapshots: [openai, claude], now: now)
        let spentRows = spent.rows.filter { $0.tone == .exhausted }
        #expect(spentRows.count == 2)
        for row in spentRows {
            guard case .credit(let bar) = row.meter else { Issue.record("\(row.title) has no credit bar"); continue }
            #expect(GlancePresentation.window(for: bar, now: now).isSpent)
        }
        try await save(WalletSection(presentation: spent, now: now)
            .padding(Theme.edgeMargin)
            .frame(width: PopoverRootView.popoverWidth)
            .background(Theme.surface), name: "wallet-spent-credit", directory: directory)
    }

    /// The rebuilt detail view for a synthetic Gemini account, with a
    /// recorded climb in its weekly window so the recent-pace line shows.
    @Test func renderGlanceInspector() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = GlanceFixtures.now
        var gemini = try #require(GlanceFixtures.batchWithWallet.first {
            $0.vendorId == .gemini && $0.antigravityAccount?.id == GlanceFixtures.burner.id })
        gemini.auxiliaryInfo = "Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen, Gemini 3.8 Flash"
        let wk = try #require(gemini.quotaBars.first { $0.label == "WK" })
        let readings = (0..<24).map { i in
            QuotaHistoryStore.ReadingRecord(vendor: gemini.id, barLabel: "WK",
                measuredAt: now.addingTimeInterval(-Double(23 - i) * 1800), fraction: 0.60 + Double(i) * 0.0048,
                isBlocked: false, confidence: .measured, urgency: .warning,
                resetsAt: wk.resetsAt, windowLength: wk.windowLength, elapsedOnly: false)
        }
        var inspector = MetricDetailModalView(snapshot: gemini, readingsLoader: { _, _ in readings },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        inspector.maxBody = 1_200
        try await save(inspector.frame(width: PopoverRootView.popoverWidth, height: 1_000).background(Theme.surface),
                       name: "glance-inspector", directory: directory)
    }

    /// The widget's Story layout for Gemini · Burner and for a blocked pool.
    @Test func renderWidgetStory() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = GlanceFixtures.now
        let providers = GlanceFixtures.batch.map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(providerFactory: { providers }, displayPreferences: { .default }))
        await store.load()
        let burner = try #require(GlanceFixtures.batch.first {
            $0.vendorId == .gemini && $0.antigravityAccount?.id == GlanceFixtures.burner.id })
        let wk = try #require(burner.quotaBars.first { $0.label == "WK" })
        let readings = (0..<24).map { i in
            QuotaHistoryStore.ReadingRecord(vendor: burner.id, barLabel: "WK",
                measuredAt: now.addingTimeInterval(-Double(23 - i) * 1800), fraction: 0.60 + Double(i) * 0.0048,
                isBlocked: false, confidence: .measured, urgency: .warning,
                resetsAt: wk.resetsAt, windowLength: wk.windowLength, elapsedOnly: false)
        }
        for (name, id) in [("widget-story", burner.id), ("widget-story-blocked", "opencode-go:delta")] {
            try await save(ProviderStoryView(store: store, poolID: .constant(id),
                                             preloaded: (readings, []), now: now)
                .padding(14).frame(width: 360, height: 620).background(Theme.surface),
                name: name, directory: directory)
        }
    }

    /// The Settings Keychain vault banner in each state it can show (#186), at
    /// the width of the Settings content pane (780pt window minus the 190pt
    /// sidebar and divider).
    @Test func renderSettingsVaultBanner() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(VaultStatusSnapshot, Bool)] = [
            (VaultStatusSnapshot(state: .lockedOrDenied(errSecInteractionNotAllowed)), false),
            (VaultStatusSnapshot(state: .loaded, pendingLegacySyncKeys: [SyncSecretAccount.refreshToken],
                                 legacyScanSucceeded: true), false),
            (VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: true, deferredWriteCount: 1), false),
            (VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: true, deferredWriteCount: 1), true),
            (VaultStatusSnapshot(state: .corrupt), false),
        ]
        try await save(VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
                if let presentation = SettingsVaultBannerPresentation.make(from: entry.0) {
                    SettingsVaultBannerView(presentation: presentation, isBusy: entry.1, onAction: {})
                }
            }
        }
        .padding(.bottom, 12)
        .frame(width: 589)
        .background(Color(nsColor: .windowBackgroundColor)), name: "settings-vault-banner", directory: directory)
    }

    @Test func render() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_848_000)
        func snapshot(_ vendor: VendorIdentifier, _ name: String, _ fraction: Double) -> QuotaSnapshot {
            QuotaSnapshot(id: vendor == .opencode ? "opencode.gamma" : vendor.rawValue,
                vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: "Review fixture", renewalDate: nil), status: .measured(.none),
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: fraction, expectedPaceFraction: 0.5, label: "WK",
                    usedText: "\(Int(fraction * 100))% used", resetText: "Resets in 3d",
                    resetsAt: now.addingTimeInterval(3.5 * 86400), windowLength: 7 * 86400),
                row2: DualBarMetrics(primaryFraction: 0.2, label: "5H", usedText: "20% used",
                    resetText: "Resets in 1h", resetsAt: now.addingTimeInterval(3600)))
        }
        let snapshots = [snapshot(.claude, "Claude", 0.65), snapshot(.opencode, "OpenCode Go · Gamma workspace", 0.45),
                         snapshot(.commandcode, "Command Code", 0.9)] + soleMeters(now: now) + moneyRows(now: now)
        let checkTime = Date()
        var oldReading = QuotaSnapshot(id: "muse", vendorId: .muse, displayName: "Muse",
            category: .aiSubscriptions, metric: .percentage(usedFraction: 0.95, displayDetails: nil),
            status: .measured(.critical), resetsAt: nil,
            lastUpdated: checkTime.addingTimeInterval(-16 * 3_600), auxiliaryInfo: nil)
        oldReading.staleReading = StaleReading(reason: .badResponse, at: checkTime)
        let failedCheck = SystemHealthSummary.compute(from: [oldReading])
        try await save(VStack(spacing: 12) {
            Text("Footer · checking, checked with stale figures, not checked").font(.caption)
            FooterActionsView(summary: failedCheck, isRefreshing: true,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
            FooterActionsView(summary: failedCheck, isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
            FooterActionsView(summary: .compute(from: []), isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
        }.frame(width: 384).background(Theme.surface), name: "footer-refresh-stale", directory: directory)
        var subscription = snapshot(.openai, "OpenAI", 1)
        subscription.apiCredits = creditFixtures().filter(\.extendsSubscription)
        var staleSubscription = subscription
        staleSubscription.staleReading = StaleReading(
            reason: .unsupported("OpenAI returned no usage window"), at: now)
        try await save(VStack(spacing: 12) {
            Text("Subscription credits · current and failed poll").font(.caption)
            livePopover([subscription], expanded: .openai, now: now)
            livePopover([staleSubscription], expanded: .openai, now: now)
        }.padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "subscription-credits", directory: directory)
        var claudeMonthly = snapshot(.claude, "Claude", 0.65)
        claudeMonthly.monthlyAPICredit = try ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"123.45","next_grant_at":"2027-02-15T14:49:22Z"}"#.utf8), now: Date())
        claudeMonthly.apiCredits = [APICreditEntry(id: "claude.promo-credit", vendorId: .claude,
            label: "Promo credit",
            metric: .currency(balance: 0, limit: 200, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, monthlyPeriodEnd: Date().addingTimeInterval(11 * 86_400))]
        var staleMonthly = claudeMonthly
        staleMonthly.staleReading = StaleReading(reason: .rateLimited(
            retryAfter: Date().addingTimeInterval(300)), at: Date())
        staleMonthly.monthlyAPICredit = try ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"123.45","next_grant_at":"2027-02-15T14:49:22Z"}"#.utf8), now: Date().addingTimeInterval(-600))
        staleMonthly.monthlyAPICredit?.refreshFailed = true
        try await save(VStack(spacing: 12) {
            Text("Usage credits · the entitlement is not repeated above it").font(.caption)
            livePopover([claudeMonthly, subscription], expanded: .claude, now: Date())
            livePopover([staleMonthly, staleSubscription], expanded: .claude, now: Date())
        }.padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "monthly-credit-and-openai", directory: directory)
        try await save(VStack(spacing: 12) {
            Text("Review fixtures · no live account data").font(.caption).foregroundStyle(Theme.outline)
            livePopover(snapshots, expanded: .claude, now: now, balanceSeries: balanceFixtures(now: now))
            FooterActionsView(summary: .compute(from: snapshots), isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
        }.padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "popover", directory: directory)
        try await save(MetricDetailModalView(snapshot: snapshots[1], readingsLoader: { _, _ in [] },
            eventsLoader: { _, _, _, _, _ in [] }, balanceLoader: { _, _, _, _ in [] }, onClose: {}).frame(width: 384, height: 400),
            name: "inspector-short", directory: directory)
        // The inspector's balance card, against a money row that has a month of
        // recorded history — the surface the inline strip only gestures at.
        let balanceHistory = balanceFixtures(now: now)
        var balanceInspector = MetricDetailModalView(
            snapshot: snapshots.first { $0.id == "openrouter" }!, readingsLoader: { _, _ in [] },
            eventsLoader: { _, _, _, _, _ in [] },
            balanceLoader: { id, _, _, _ in balanceHistory[id] }, onClose: {})
        balanceInspector.maxBody = 1_400
        try await save(balanceInspector.frame(width: 384, height: 1_200).background(Theme.surface),
            name: "inspector-balance", directory: directory)

        // The balance read failed for every series the snapshot publishes. The
        // card is still drawn, and says the failure: gating it on the
        // successful reads alone hid it entirely and presented the failure as
        // "this provider publishes no balance".
        var balanceUnreadable = MetricDetailModalView(
            snapshot: snapshots.first { $0.id == "openrouter" }!, readingsLoader: { _, _ in [] },
            eventsLoader: { _, _, _, _, _ in [] },
            balanceLoader: { _, _, _, _ in nil }, onClose: {})
        balanceUnreadable.maxBody = 1_000
        try await save(balanceUnreadable.frame(width: 384, height: 700).background(Theme.surface),
            name: "inspector-balance-unreadable", directory: directory)

        // The same card for a credit *count*: charted in credits, with the axis
        // labelled in credits — never converted to money.
        var creditsHost = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI", category: .aiSubscriptions,
            metric: .subscription(tierName: "Plus", renewalDate: nil), status: .measured(.none),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        creditsHost.apiCredits = [creditFixtures()[0]]
        var creditsInspector = MetricDetailModalView(
            snapshot: creditsHost, readingsLoader: { _, _ in [] },
            eventsLoader: { _, _, _, _, _ in [] },
            balanceLoader: { id, _, _, _ in balanceHistory[id] }, onClose: {})
        creditsInspector.maxBody = 1_200
        try await save(creditsInspector.frame(width: 384, height: 1_000).background(Theme.surface),
            name: "inspector-balance-credits", directory: directory)
        let history = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try await save(QuotaTimelineChart(segments: [], timeRange: .last7Days)
            .frame(width: 640, height: 240).background(Theme.card),
            name: "history-empty", directory: directory)
        try await save(EventsListView(store: history, isSampleMode: false)
            .frame(width: 640, height: 320).background(Theme.surface),
            name: "events-empty", directory: directory)
        try await save(HistoryRootView(liveStore: history, sampleStore: history).frame(width: 640, height: 460),
                 name: "history-minimum", directory: directory)
        let graphQL = QuotaSnapshot(id: "github_graphql", vendorId: .githubGraphql, displayName: "GitHub GraphQL",
            category: .developerLimits, metric: .count(remaining: 600, limit: 1000, unitName: "points"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.4, label: "GraphQL", usedText: "40% used"))
        let providers = (snapshots + [graphQL]).map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(providerFactory: { providers }, displayPreferences: { .default }))
        await store.load()
        try await save(DesktopWidgetView(store: store, filters: WidgetFilters())
            .frame(width: 320, height: 300), name: "widget-story", directory: directory)
        let unreadable = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .unavailable(.offline), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        let unreadableStore = QuotaStore(manager: QuotaManager(
            providerFactory: { [FixtureProvider(snapshot: unreadable)] }, displayPreferences: { .default }))
        await unreadableStore.load()
        try await save(DesktopWidgetView(store: unreadableStore, filters: WidgetFilters())
            .frame(width: 320, height: 240).background(Theme.surface),
            name: "widget-unreadable", directory: directory)
        let tokenChart = TokenUsagePresentation.chart(usage: .init(buckets: [
            .init(source: "codex", start: TokenUsagePresentation.window(range: .last24Hours, now: now).since.addingTimeInterval(7200),
                  tokens: 1234, records: 1)
        ], uncountedRecords: ["claude_code": 3]), filters: WidgetFilters(layout: .tokens), hidden: [],
            configured: [.claude, .openai, .gemini, .grok, .kiro], ingestion: .incomplete, now: now)
        try await save(TokenUsageChartView(chart: tokenChart, range: .last24Hours).padding(14)
            .frame(width: 320, height: 240).background(Theme.surface), name: "token-caveats", directory: directory)
    }

    /// The prepaid credit entries the API Spend & Credits card draws: a credit
    /// count (OpenAI's unit, never money), a monthly money pool with its limit
    /// as the note, and a promo credit whose expiry is a date rather than a
    /// countdown. None of them carries a bar.
    private func creditFixtures() -> [APICreditEntry] {
        [APICreditEntry(
            id: "openai.api-credits", vendorId: .openai, label: "API credits",
            metric: .credits(remaining: 62_500, unitName: "credits"),
            source: "Codex usage payload · credits.balance"),
         APICreditEntry(
            id: "claude.extra-usage", vendorId: .claude, label: "Extra usage",
            metric: .currency(balance: Decimal(string: "179.50")!,
                              limit: Decimal(string: "200.00")!, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, detail: "$200.00 monthly limit",
            source: "OAuth usage payload · extra_usage"),
         APICreditEntry(
            id: "claude.promo-credit", vendorId: .claude, label: "Promo credit",
            metric: .currency(balance: Decimal(150), limit: Decimal(200), spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, detail: "Expires 15 Nov 2026",
            source: "OAuth usage payload · iguana_necktie")]
    }

    /// The vendors whose whole row is a money figure: OpenRouter's account
    /// credit and DeepSeek's prepaid balance. Neither publishes a window, so the
    /// row has no bar — the figure is the row — and this fixture is what the
    /// rendered popover shows the inline balance sparkline against.
    private func moneyRows(now: Date) -> [QuotaSnapshot] {
        [QuotaSnapshot(id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits,
            metric: .currency(balance: Decimal(string: "179.50")!, limit: nil,
                              spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now,
            auxiliaryInfo: "Account credit balance", row1: nil, row2: nil,
            badgeText: "$179.50 credit", planName: nil, cliSource: "OPENROUTER_API_KEY",
            currencyBasis: .accountCredit),
         QuotaSnapshot(id: "deepseek", vendorId: .deepseek, displayName: "DeepSeek",
            category: .apiSpendAndCredits,
            metric: .currency(balance: Decimal(string: "42.00")!, limit: nil,
                              spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now,
            auxiliaryInfo: "Prepaid balance", row1: nil, row2: nil,
            badgeText: "$42.00", planName: nil, cliSource: "DEEPSEEK_API_KEY",
            currencyBasis: .accountCredit)]
    }

    /// A week of hourly balance readings per money series, so the inline
    /// sparkline has a real trend to draw in the render: a steady draw-down with
    /// a plateau, not a straight ramp, which a strip would only render as one
    /// unreadable diagonal.
    private func balanceFixtures(now: Date) -> [String: [BalancePoint]] {
        func series(_ id: String, from start: Decimal, to end: Decimal) -> (String, [BalancePoint]) {
            let points = (0...40).map { step -> BalancePoint in
                let t = now.addingTimeInterval(-Double(40 - step) * 4 * 3600)
                // Flat for the first third (no work), then a steady draw-down.
                let fraction = step < 14 ? 0 : Decimal(step - 14) / Decimal(26)
                return BalancePoint(measuredAt: t, value: start + (end - start) * fraction)
            }
            return (id, points)
        }
        return Dictionary(uniqueKeysWithValues: [
            series(BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")),
                   from: Decimal(string: "210.00")!, to: Decimal(string: "179.50")!),
            series(BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD")),
                   from: Decimal(string: "60.00")!, to: Decimal(string: "42.00")!),
            series(BalanceSeries.id(source: "claude.extra-usage", unit: .currency(code: "USD")),
                   from: Decimal(string: "200.00")!, to: Decimal(string: "179.50")!),
            // A credit *count* has history too, and is charted in its own unit —
            // never converted to money.
            series(BalanceSeries.id(source: "openai.api-credits", unit: .credits(name: "credits")),
                   from: Decimal(80_000), to: Decimal(62_500)),
        ])
    }

    /// The vendors that publish a single window — GitHub Copilot reports
    /// monthly only, OpenAI weekly only. Each row's one meter spans the whole
    /// grid rather than sitting in a third of the row with a faint dash either
    /// side, and this fixture is what the rendered popover shows it with. The
    /// OpenAI row also carries banked reset credits, so the ticket strip
    /// (capped, with the overflow count) is visible in the render.
    private func soleMeters(now: Date) -> [QuotaSnapshot] {
        func sole(_ vendor: VendorIdentifier, _ name: String, _ plan: String, _ token: String,
                  fraction: Double, pace: Double?, length: TimeInterval, resetsIn: TimeInterval,
                  bankedResets: Int? = nil) -> QuotaSnapshot {
            var snap = QuotaSnapshot(id: vendor.rawValue, vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: plan, renewalDate: nil), status: .measured(.none),
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(
                    primaryFraction: fraction, expectedPaceFraction: pace, label: token,
                    usedText: "\(Int(fraction * 100))% used",
                    resetText: "Resets in \(Int(resetsIn / 86_400))d",
                    resetsAt: now.addingTimeInterval(resetsIn), windowLength: length))
            snap.resetCreditsAvailable = bankedResets
            return snap
        }
        return [sole(.copilot, "GitHub Copilot", "Pro", "MO", fraction: 1.0, pace: nil,
                     length: 30 * 86_400, resetsIn: 18 * 86_400),
                sole(.openai, "OpenAI", "Plus", "WK", fraction: 0.12, pace: 0.15,
                     length: 7 * 86_400, resetsIn: 6 * 86_400, bankedResets: 7)]
    }

    // MARK: - Detail, History, Settings and workspace order

    /// Renders the surfaces this pass reworked, from fixtures only. Readings go
    /// into a throwaway database under the render directory; the workspace
    /// list and display preferences are written to the test-host preference
    /// suite (never the user's) and removed afterwards; Settings is drawn with
    /// `readsCredentials: false`, so no Keychain item is read.
    @Test func renderReworkedSurfaces() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Relative to the clock because the History window reads its ranges
        // from it; nothing here asserts a duration.
        let now = Date()
        let beta = OpenCodeGoWorkspace(id: "render-beta", name: "Go Beta")
        let alpha = OpenCodeGoWorkspace(id: "render-alpha", name: "Go Alpha")

        func bar(_ label: String, _ used: Double?, length: TimeInterval, resetsIn: TimeInterval,
                 isBlocked: Bool = false) -> DualBarMetrics {
            let reset = now.addingTimeInterval(resetsIn)
            return DualBarMetrics(
                primaryFraction: used,
                expectedPaceFraction: DualBarMetrics.proRataPace(resetsAt: reset, windowLength: length, now: now),
                label: label, isBlocked: isBlocked,
                usedText: used.map { "\(Int($0 * 100))% used" }, resetText: nil,
                resetsAt: reset, windowLength: length)
        }
        func snapshot(_ id: String, _ vendor: VendorIdentifier, _ name: String, status: ProviderStatus = .measured(.none),
                      bars: [DualBarMetrics], plan: String? = "Review fixture") -> QuotaSnapshot {
            var s = QuotaSnapshot(
                id: id, vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .percentage(usedFraction: bars.first?.primaryFraction ?? 0, displayDetails: nil),
                status: status, resetsAt: bars.first?.resetsAt, lastUpdated: now.addingTimeInterval(-90),
                auxiliaryInfo: nil,
                row1: bars.count > 0 ? bars[0] : nil, row2: bars.count > 1 ? bars[1] : nil)
            s.planName = plan
            s.cliSource = "Review fixture"
            s.latencyMs = 212
            return s
        }

        let claude = snapshot("claude", .claude, "Claude", bars: [
            bar("WK", 0.62, length: 7 * 86_400, resetsIn: 3.2 * 86_400),
            bar("5H", 0.18, length: 5 * 3600, resetsIn: 2.5 * 3600),
        ])
        // The user put Beta first; Alpha's month turns over sooner, which used
        // to pull it above Beta under the automatic sort.
        let goBeta = snapshot(beta.instanceID, .opencode, beta.name, bars: [
            bar("MO", 0.35, length: 30 * 86_400, resetsIn: 20 * 86_400),
            bar("WK", 0.4, length: 7 * 86_400, resetsIn: 4 * 86_400),
        ], plan: "Go")
        let goAlpha = snapshot(alpha.instanceID, .opencode, alpha.name, status: .measured(.critical), bars: [
            bar("MO", 0.88, length: 30 * 86_400, resetsIn: 2 * 86_400),
            bar("WK", 0.97, length: 7 * 86_400, resetsIn: 1 * 86_400, isBlocked: true),
        ], plan: "Go")
        let openai = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.credentialRejected),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-90), auxiliaryInfo: nil)
        let snapshots = [claude, goBeta, goAlpha, openai]

        // MARK: Popover, with workspaces in the user's order under the automatic sort
        let providers = [claude, goBeta, goAlpha, openai].map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(
            providerFactory: { providers },
            displayPreferences: { ProviderDisplayPreferences(ordering: .automatic) }))
        await store.load()
        #expect(store.snapshots.filter { $0.vendorId == .opencode }.map(\.id) == [beta.instanceID, alpha.instanceID])
        try await save(VStack(spacing: 12) {
            Text("Review fixtures · automatic order · workspaces in the user's order").font(.caption)
                .foregroundStyle(Theme.outline)
            livePopover(store.snapshots, expanded: .deepseek, now: Date())
            FooterActionsView(summary: store.summary, isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
        }.padding(Theme.edgeMargin).frame(width: PopoverRootView.popoverWidth).background(Theme.surface),
            name: "popover-workspaces", directory: directory)

        // MARK: Readings for the inspector and the History window
        let history = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-fixture-\(UUID().uuidString).sqlite"))
        var readings: [QuotaHistoryStore.ReadingRecord] = []
        for step in stride(from: 6 * 86_400.0, through: 1800, by: -1800) {
            let at = now.addingTimeInterval(-step)
            let t = 1 - step / (6 * 86_400)
            let wobble = 0.03 * sin(step / 7_000)
            var polled: [QuotaSnapshot] = []
            func with(_ snap: QuotaSnapshot, _ bars: [DualBarMetrics]) -> QuotaSnapshot {
                var copy = snap
                copy.row1 = bars.count > 0 ? bars[0] : nil
                copy.row2 = bars.count > 1 ? bars[1] : nil
                return copy
            }
            let fiveUsed = (step.truncatingRemainder(dividingBy: 18_000)) / 18_000 * 0.6
            polled.append(with(claude, [
                DualBarMetrics(primaryFraction: 0.08 + 0.54 * t + wobble, label: "WK",
                               resetsAt: claude.row1?.resetsAt, windowLength: 7 * 86_400),
                DualBarMetrics(primaryFraction: 0.6 - fiveUsed, label: "5H", windowLength: 5 * 3600),
            ]))
            polled.append(with(goBeta, [DualBarMetrics(primaryFraction: 0.2 + 0.15 * t, label: "MO",
                                                     resetsAt: goBeta.row1?.resetsAt, windowLength: 30 * 86_400)]))
            polled.append(with(goAlpha, [DualBarMetrics(primaryFraction: 0.55 + 0.33 * t + wobble, label: "MO",
                                                      resetsAt: goAlpha.row1?.resetsAt, windowLength: 30 * 86_400)]))
            try await history.record(polled, now: at)
        }
        // Go Beta's newest poll failed: its History card must say so rather
        // than lead with the figure from the poll before.
        try await history.record([QuotaSnapshot(
            id: beta.instanceID, vendorId: .opencode, displayName: beta.name, category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil)],
            now: now.addingTimeInterval(-60))
        readings = try await history.fetchReadings(vendor: .claude)
        let resetEvent = AIEvent(
            id: AIEvent.makeID(kind: .usageReset, vendorId: .claude, components: ["render"]),
            kind: .usageReset, vendorId: .claude, title: "5-hour window reset", detail: nil,
            occurredAt: now.addingTimeInterval(-9_000), observedAt: now.addingTimeInterval(-9_000), source: .quotaPoll)

        // MARK: Inspector
        var inspector = MetricDetailModalView(
            snapshot: claude, readingsLoader: { [readings] _, _ in readings },
            eventsLoader: { _, _, _, _, _ in [resetEvent] }, onClose: {})
        inspector.maxBody = 1_400
        try await save(inspector.frame(width: 384, height: 1_560).background(Theme.surface),
                       name: "inspector-detail", directory: directory)
        var blocked = MetricDetailModalView(
            snapshot: goAlpha, readingsLoader: { _, _ in [] }, eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        blocked.maxBody = 1_000
        try await save(blocked.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-blocked-workspace", directory: directory)
        var unreadable = MetricDetailModalView(
            snapshot: openai, readingsLoader: { _, _ in [] }, eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        unreadable.maxBody = 800
        try await save(unreadable.frame(width: 384, height: 760).background(Theme.surface),
                       name: "inspector-unreadable", directory: directory)
        // The history database could not be read: said as a failed read, not
        // as zero readings or "no events".
        var failedRead = MetricDetailModalView(
            snapshot: claude, readingsLoader: { _, _ in nil }, eventsLoader: { _, _, _, _, _ in nil }, onClose: {})
        failedRead.maxBody = 1_000
        try await save(failedRead.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-history-unreadable", directory: directory)

        // MARK: History
        let subjects = HistoryOverviewPresentation.subjects(
            order: [.claude, .opencode, .openai, .grok, .kiro], hidden: [.kiro], workspaces: [beta, alpha], claudeAccounts: [])
        try await save(
            HistoryRootView(liveStore: history, sampleStore: history,
                            subjectSource: { (subjects, ["Kiro"]) })
                .frame(width: 880, height: 1_180),
            name: "history-overview", directory: directory)
        let segments = HistoryPresentation.segments(from: HistoryPresentation.consumptionReadings(
            readings.filter { $0.measuredAt >= now.addingTimeInterval(-86_400) }))
        try await save(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .inspecting(now.addingTimeInterval(-6 * 3600))
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            name: "history-chart-readout", directory: directory)
        // Long-range sparklines, thinned exactly as the window thins them.
        for range in [HistoryPresentation.TimeRange.last30Days, .allTime] {
            let bucket = HistoryOverviewPresentation.sampleBucketSeconds(
                range: range, retention: await history.retentionInterval)
            let sampled = try await history.fetchSampledReadings(
                since: range.startDate(from: now), until: now, bucketSeconds: bucket)
            let cards = HistoryOverviewPresentation.overview(
                subjects: subjects, readings: sampled, bucketSeconds: bucket).cards
            #expect(cards.allSatisfy { $0.segments.count == 1 })
            try await save(
                HStack(spacing: 10) {
                    ForEach(cards) { HistoryOverviewCardView(card: $0, isSelected: false, onSelect: {}) }
                }
                .padding(14).frame(width: 640).background(Theme.card),
                name: "history-\(range == .allTime ? "all" : "30d")-sparkline", directory: directory)
        }

        // A real key press: the chart takes focus and the right arrow selects
        // the newest poll, with no pointer involved.
        try await saveAfterKeys(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            keys: [(48, "\t"), (124, "\u{F703}")],
            name: "history-chart-keyboard", directory: directory)
        // The control: focus alone selects nothing, so the readout above is
        // the arrow key's doing.
        try await saveAfterKeys(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            keys: [(48, "\t")],
            name: "history-chart-focus-only", directory: directory)

        let emptyHistory = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-empty-\(UUID().uuidString).sqlite"))
        try await save(
            HistoryRootView(liveStore: emptyHistory, sampleStore: emptyHistory,
                            subjectSource: { (Array(subjects.prefix(2)), ["Grok", "Kiro"]) })
                .frame(width: 880, height: 760),
            name: "history-empty-reasons", directory: directory)

        // MARK: Attempt-3 states: blocked burndown, failed polls, widget reads
        // A blocked window still reporting a percentage: no "out in", and its
        // figure is "reported remaining", not headroom.
        let blockedWeekly = (0..<6).map { i in
            QuotaHistoryStore.ReadingRecord(
                vendor: alpha.instanceID, barLabel: "WK", measuredAt: now.addingTimeInterval(-Double(6 - i) * 600),
                fraction: 0.91 + Double(i) * 0.01, isBlocked: true, confidence: .measured, urgency: .critical,
                resetsAt: goAlpha.row2?.resetsAt, windowLength: 7 * 86_400, elapsedOnly: false)
        }
        var blockedFirst = goAlpha
        blockedFirst.row1 = goAlpha.row2
        blockedFirst.row2 = nil
        var blockedBurndown = MetricDetailModalView(
            snapshot: blockedFirst, readingsLoader: { _, _ in blockedWeekly },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        blockedBurndown.maxBody = 1_000
        try await save(blockedBurndown.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-blocked-burndown", directory: directory)

        // Claude's newest poll failed: the card says so and no pace card
        // compares the figure from before it.
        let failedLatest = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-failed-latest-\(UUID().uuidString).sqlite"))
        try await failedLatest.record([claude], now: now.addingTimeInterval(-1_200))
        try await failedLatest.record([QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil)],
            now: now.addingTimeInterval(-60))
        let claudeOnly = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [], claudeAccounts: [])
        try await save(
            HistoryRootView(liveStore: failedLatest, sampleStore: failedLatest, subjectSource: { (claudeOnly, []) })
                .frame(width: 880, height: 900),
            name: "history-failed-latest", directory: directory)

        // Every poll in range failed: said as failed polls, not "no readings".
        let onlyFailed = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-only-failed-\(UUID().uuidString).sqlite"))
        try await onlyFailed.record([QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil)],
            now: now.addingTimeInterval(-60))
        try await save(
            HistoryRootView(liveStore: onlyFailed, sampleStore: onlyFailed,
                            subjectSource: { (HistoryOverviewPresentation.subjects(
                                order: [.claude, .grok], hidden: [], workspaces: [], claudeAccounts: []), []) })
                .frame(width: 880, height: 760),
            name: "history-only-failed", directory: directory)

        // A blocked figure on an overview card wears the nosign glyph.
        let blockedCard = try #require(HistoryOverviewPresentation.overview(
            subjects: HistoryOverviewPresentation.subjects(order: [.opencode], hidden: [], workspaces: [alpha], claudeAccounts: []),
            readings: blockedWeekly).cards.first)
        try await save(
            HistoryOverviewCardView(card: blockedCard, isSelected: false, onSelect: {})
                .padding(14).frame(width: 260).background(Theme.card),
            name: "history-card-blocked", directory: directory)

        // MARK: Attempt-4 states: provider-level failed polls, blocked readout
        // Measured polls, an offline poll stored under the provider's own
        // label, then recovery: every line breaks at the outage, and the
        // inspector opened during it has no current burndown.
        let outage = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-outage-\(UUID().uuidString).sqlite"))
        let offlineClaude = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        func claudeAt(_ week: Double, _ fiveHour: Double) -> QuotaSnapshot {
            var s = claude
            s.row1 = bar("WK", week, length: 7 * 86_400, resetsIn: 3.2 * 86_400)
            s.row2 = bar("5H", fiveHour, length: 5 * 3600, resetsIn: 2.5 * 3600)
            return s
        }
        for i in 0..<8 {
            try await outage.record([claudeAt(0.50 + Double(i) * 0.01, 0.20 + Double(i) * 0.03)],
                                    now: now.addingTimeInterval(-Double(16 - i) * 600))
        }
        try await outage.record([offlineClaude], now: now.addingTimeInterval(-7 * 600))
        let duringOutage = try await outage.fetchReadings(vendor: .claude)
        var failedPollInspector = MetricDetailModalView(
            snapshot: claude, readingsLoader: { _, _ in duringOutage },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        failedPollInspector.maxBody = 1_000
        try await save(failedPollInspector.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-failed-poll", directory: directory)
        // MARK: Attempt-5 states: a snapshot a later failed poll superseded,
        // and outages inside one overview bucket.
        // The inspector opened on a snapshot fetched 15 minutes ago, with an
        // offline poll recorded 10 minutes ago: the summary says the last
        // poll failed and the windows say when they are from.
        let superseded = QuotaHistoryStore(
            databaseURL: directory.appendingPathComponent("rework-superseded-\(UUID().uuidString).sqlite"))
        var stale = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.42, displayDetails: nil), status: .measured(.none),
            resetsAt: claude.resetsAt, lastUpdated: now.addingTimeInterval(-900), auxiliaryInfo: nil,
            row1: bar("WK", 0.42, length: 7 * 86_400, resetsIn: 3.2 * 86_400),
            row2: bar("5H", 0.18, length: 5 * 3600, resetsIn: 2.5 * 3600))
        stale.cliSource = "Review fixture"
        for i in 0..<4 {
            try await superseded.record([stale], now: now.addingTimeInterval(-Double(4 - i) * 300 - 600))
        }
        try await superseded.record([offlineClaude], now: now.addingTimeInterval(-600))
        let supersededReadings = try await superseded.fetchReadings(vendor: .claude)
        #expect(MetricDetailPresentation(snapshot: stale, readings: supersededReadings, now: now)
            .summary.state == .lastPollFailed(at: Date(timeIntervalSince1970:
                now.addingTimeInterval(-600).timeIntervalSince1970.rounded(.down))))
        var supersededInspector = MetricDetailModalView(
            snapshot: stale, readingsLoader: { _, _ in supersededReadings },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        supersededInspector.maxBody = 1_000
        try await save(supersededInspector.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-superseded-by-failed-poll", directory: directory)

        // A day of polls with two outages inside 12-minute buckets of the
        // 24-hour overview: two offline polls either side of a reading, then
        // a poll with no WK figure followed by a recovery. The thinned
        // sparkline breaks where the full read does.
        let bucketed = QuotaHistoryStore(
            databaseURL: directory.appendingPathComponent("rework-bucketed-\(UUID().uuidString).sqlite"))
        let bucket24 = HistoryOverviewPresentation.sampleBucketSeconds(
            range: .last24Hours, retention: await bucketed.retentionInterval)
        let start = (now.timeIntervalSince1970 / Double(bucket24)).rounded(.down) * Double(bucket24) - 20 * 3600
        var noWeekFigure = claude
        noWeekFigure.row1 = bar("WK", nil, length: 7 * 86_400, resetsIn: 3.2 * 86_400)
        for i in 0..<240 {
            let at = Date(timeIntervalSince1970: start + Double(i) * 300)
            let poll = i == 84 || i == 86 ? offlineClaude
                : i == 168 ? noWeekFigure
                : claudeAt(0.30 + Double(i) * 0.001, 0.2)
            try await bucketed.record([poll], now: at)
        }
        let bucketedFull = try await bucketed.fetchReadings(vendor: .claude)
        let bucketedSampled = try await bucketed.fetchSampledReadings(
            since: now.addingTimeInterval(-86_400), until: now, bucketSeconds: bucket24)
        let bucketedCards = HistoryOverviewPresentation.overview(
            subjects: HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [], claudeAccounts: []),
            readings: bucketedSampled, bucketSeconds: bucket24).cards
        let fullCards = HistoryOverviewPresentation.overview(
            subjects: HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [], claudeAccounts: []),
            readings: bucketedFull, bucketSeconds: bucket24).cards
        #expect(fullCards.first?.segments.count == 4)
        #expect(bucketedCards.first?.segments.count == 4)
        try await save(
            HStack(spacing: 10) {
                ForEach(bucketedCards) { HistoryOverviewCardView(card: $0, isSelected: false, onSelect: {}) }
            }
            .padding(14).frame(width: 320).background(Theme.card),
            name: "history-sparkline-outages-in-bucket", directory: directory)

        for i in 0..<6 {
            try await outage.record([claudeAt(0.60 + Double(i) * 0.01, 0.45 + Double(i) * 0.03)],
                                    now: now.addingTimeInterval(-Double(6 - i) * 600))
        }
        let acrossOutage = try await outage.fetchReadings(vendor: .claude)
        let outageSegments = HistoryPresentation.segments(from: HistoryPresentation.consumptionReadings(acrossOutage))
        #expect(outageSegments.filter { $0.barLabel == "WK" }.count == 2)
        try await save(
            QuotaTimelineChart(segments: outageSegments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            name: "history-chart-outage", directory: directory)

        // A blocked reading inspected on the chart: the readout wears the
        // nosign glyph beside "blocked", while the point keeps its square.
        let blockedSegments = HistoryPresentation.segments(from: blockedWeekly)
        try await save(
            QuotaTimelineChart(segments: blockedSegments, timeRange: .last24Hours)
                .inspecting(blockedWeekly[3].measuredAt)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            name: "history-chart-blocked-readout", directory: directory)

        // MARK: Settings
        let workspacesKey = OpenCodeGoWorkspaceStore.defaultsKey
        let savedWorkspaces = CredentialStore.preferences.data(forKey: workspacesKey)
        let savedHidden = CredentialStore.preferences.object(forKey: CredentialStore.hiddenProvidersDefaultsKey)
        defer {
            if let savedWorkspaces {
                CredentialStore.preferences.set(savedWorkspaces, forKey: workspacesKey)
            } else {
                CredentialStore.preferences.removeObject(forKey: workspacesKey)
            }
            if let savedHidden {
                CredentialStore.preferences.set(savedHidden, forKey: CredentialStore.hiddenProvidersDefaultsKey)
            } else {
                CredentialStore.preferences.removeObject(forKey: CredentialStore.hiddenProvidersDefaultsKey)
            }
        }
        #expect(CredentialStore.preferences !== UserDefaults.standard)
        OpenCodeGoWorkspaceStore.set([beta, alpha])
        CredentialStore.hiddenProviders = [.kiro]
        for (pane, name) in [
            (SettingsView.Pane.services, "services"), (.service(.opencode), "opencode"),
            (.service(.claude), "claude"), (.service(.gemini), "antigravity"), (.service(.openai), "codex"),
            (.connections, "connections"), (.notifications, "notifications"), (.display, "display"),
            (.guide, "guide"), (.data, "data"),
        ] {
            try await save(
                SettingsView(store: store, initialPane: pane, readsCredentials: false),
                name: "settings-\(name)", directory: directory)
        }
        _ = snapshots
    }

    /// Hosts `view` in a key window, delivers `keys` (virtual key code and
    /// characters) as real key-down events, then renders it.
    private func saveAfterKeys<V: View>(
        _ view: V, keys: [(UInt16, String)], name: String, directory: URL
    ) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        try await Task.sleep(for: .milliseconds(300))
        for (code, characters) in keys {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: code == 124 ? [.numericPad, .function] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }

    private func save<V: View>(_ view: V, name: String, directory: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        let accessibility = accessibilityDump(host).joined(separator: "\n")
        try accessibility.write(to: directory.appendingPathComponent("\(name)-accessibility.txt"),
                                atomically: true, encoding: .utf8)
        window.close()
    }

    /// The text lines Vision reads from a saved render, on device and offline.
    private func renderedText(_ name: String, directory: URL) throws -> [String] {
        let url = directory.appendingPathComponent("\(name).png")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: url).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Read the hosted AppKit accessibility tree, including SwiftUI's combined
    /// row labels. This artifact is separate from the screenshot and can be
    /// inspected even when the hosted runner has no Accessibility Inspector.
    private func accessibilityDump(_ object: Any, depth: Int = 0) -> [String] {
        guard depth < 16, let element = object as? NSAccessibilityProtocol else { return [] }
        let role = element.accessibilityRole()?.rawValue ?? "unknown"
        let label = element.accessibilityLabel() ?? ""
        var lines = [String(repeating: "  ", count: depth) + role + ": " + label]
        for child in element.accessibilityChildren() ?? [] {
            lines += accessibilityDump(child, depth: depth + 1)
        }
        return lines
    }
}

// MARK: - Issue #128 accounting evidence

extension UXRenderTests {
    /// The app-executable seam. `Sources/QuotaBarApp/AppMain.swift` activates
    /// it after the CLI early exits; this test keeps the seam itself honest and
    /// renders its controlled views through the test host.
    @Test func renderActivityEvidenceSeam() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        let directory = root.appendingPathComponent("release-seam", isDirectory: true)
        let report = try await ActivityEvidenceRenderer.render(to: directory)
        let fixture = ActivityEvidenceRenderer.Fixture.standard
        #expect(report.chartTotalTokens == 1_100_177)
        #expect(report.openAIProjects == ["/controlled/codex-alpha", "/controlled/codex-beta"])
        #expect(report.openCodeProjects.isEmpty)
        #expect(report.openCodeUnattributedMessage.contains("not attributed"))
        // The attributed projects above come from the hosted views' own reload
        // reports; those views must have queried the fixture's window.
        #expect(report.attributionWindowEnd == fixture.referenceDate)
        #expect(report.attributionWindowStart
            == HistoryPresentation.TimeRange.last7Days.startDate(from: fixture.referenceDate))
    }

    /// Controlled, sanitized ledger: a real Codex rollout shape with a model
    /// change and a resumed day, a Claude row, and an OpenCode row whose only
    /// published billing identity is `litellm` (never a Go workspace). Renders
    /// the production Tokens chart and History attribution card.
    @Test func renderActivityAccountingEvidence() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("frugalbar-128-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // The same fixed clock the production evidence route uses: both days
        // are behind the reference, so a morning run cannot omit day two.
        let evidence = ActivityEvidenceRenderer.Fixture.standard
        let now = evidence.referenceDate
        let calendar = evidence.calendar
        let dayOne = evidence.dayOne
        let dayTwo = evidence.dayTwo
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let codexDir = fixtureRoot.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let rollout = """
        {"type":"session_meta","timestamp":"\(iso.string(from: dayOne.addingTimeInterval(-60)))","payload":{"session_id":"fixture-session","cwd":"/controlled/codex-alpha","model_provider":"openai","creator_account_id":"fixture-account"}}
        {"type":"turn_context","timestamp":"\(iso.string(from: dayOne.addingTimeInterval(-30)))","payload":{"model":"gpt-6.1-sol","cwd":"/controlled/codex-alpha"}}
        {"type":"token_usage_record","timestamp":"\(iso.string(from: dayOne))","payload":{"session_id":"fixture-session","thread_id":"fixture-session","response_id":"fixture-day-one","turn_id":"fixture-turn-one","usage":{"input_tokens":700000,"cached_input_tokens":650000,"cache_write_input_tokens":0,"output_tokens":300000,"reasoning_output_tokens":0,"total_tokens":1000000},"thread_token_usage":{"input_tokens":700000,"output_tokens":300000,"total_tokens":1000000}}}
        {"type":"turn_context","timestamp":"\(iso.string(from: dayTwo.addingTimeInterval(-30)))","payload":{"model":"gpt-5.6-luna","cwd":"/controlled/codex-beta"}}
        {"type":"token_usage_record","timestamp":"\(iso.string(from: dayTwo))","payload":{"session_id":"fixture-session","thread_id":"fixture-session","response_id":"fixture-day-two","turn_id":"fixture-turn-two","usage":{"input_tokens":70000,"cached_input_tokens":65000,"cache_write_input_tokens":0,"output_tokens":30000,"reasoning_output_tokens":0,"total_tokens":100000},"thread_token_usage":{"input_tokens":770000,"output_tokens":330000,"total_tokens":1100000}}}
        """
        try rollout.write(to: codexDir.appendingPathComponent("rollout-fixture.jsonl"), atomically: true, encoding: .utf8)

        let store = QuotaHistoryStore(
            databaseURL: fixtureRoot.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: codexDir)])
        _ = try await engine.ingestAll()

        // Claude: 10 input + 20 output + 5 cache read + 15 cache write = 50.
        // OpenCode: published total 127, billed through litellm, no workspace.
        try await store.recordActivities([
            ActivityRecord(
                source: "claude_code", recordId: "fixture-claude", sessionId: "fixture-claude-session",
                projectPath: "/controlled/claude", gitBranch: "main", model: "claude-sonnet",
                observedAt: evidence.claudeObservedAt,
                inputTokens: 10, outputTokens: 20, cacheReadTokens: 5, cacheWriteTokens: 15),
            ActivityRecord(
                source: "opencode", recordId: "fixture-opencode", sessionId: "fixture-opencode-session",
                projectPath: "/controlled/opencode", model: "gpt-5.6-luna",
                observedAt: evidence.openCodeObservedAt,
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 5, cacheWriteTokens: 2,
                totalTokens: 127, publishedProvider: "litellm"),
        ])

        let statuses = [
            ActivitySourceStatus(source: "codex", lastScanAt: now, lastSuccessfulScanAt: now,
                                 malformedRecords: 1, incompleteRecords: 0, recordsObserved: 2, lastPassComplete: true),
            ActivitySourceStatus(source: "claude_code", lastScanAt: now, lastSuccessfulScanAt: now,
                                 recordsObserved: 1, lastPassComplete: true),
            ActivitySourceStatus(source: "opencode", lastScanAt: now, lastSuccessfulScanAt: now,
                                 recordsObserved: 1, lastPassComplete: true),
        ]
        let status = ActivityIngestionEngine.Status(
            hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false, sources: statuses)

        let window = TokenUsagePresentation.window(range: .last7Days, now: now, calendar: calendar)
        let usage = try await store.fetchTokenUsage(
            since: window.since, until: now,
            bucketSeconds: TokenUsagePresentation.bucketSeconds(for: .last7Days), anchor: window.anchor)
        let chart = TokenUsagePresentation.chart(
            usage: usage, filters: WidgetFilters(range: .last7Days, layout: .tokens), hidden: [],
            configured: [.claude, .openai, .opencode], ingestion: .complete, now: now,
            calendar: calendar, sources: statuses)
        #expect(chart.totalTokens == 1_100_177)
        #expect(chart.layers.map(\.vendorId) == [.claude, .openai, .opencode])
        #expect(chart.hasSessionTotals == false)
        #expect(chart.sourceNotes.contains { $0.contains("Codex: 1 malformed record") })
        try await save(
            VStack(spacing: 8) {
                Text("Controlled ledger · Codex request rows across two days and mixed models; OpenCode billed through litellm, not a Go workspace")
                    .font(.caption).foregroundStyle(Theme.outline)
                TokenUsageChartView(chart: chart, range: .last7Days)
            }.padding(14).frame(width: 420, height: 300).background(Theme.surface),
            name: "activity-tokens-ledger", directory: directory)

        let openAI = HistoryOverviewPresentation.Subject(
            id: VendorIdentifier.openai.rawValue, vendor: .openai, name: VendorIdentifier.openai.displayName)
        let openCode = HistoryOverviewPresentation.Subject(
            id: "opencode.fixture-workspace", vendor: .opencode, name: "OpenCode Go · Fixture workspace")
        let statusLoader: @Sendable () async -> ActivityIngestionEngine.Status? = { status }

        try await save(
            HistoryRootView(
                liveStore: store, sampleStore: store, initialRange: .last7Days,
                subjectSource: { ([openAI], []) }, activityStatus: statusLoader,
                clock: { now })
                .frame(width: 880, height: 820),
            name: "activity-attribution-openai", directory: directory)

        // The OpenCode card must not turn tool activity into this workspace's
        // usage: the only published billing identity is `litellm`, not a
        // workspace.
        try await save(
            HistoryRootView(
                liveStore: store, sampleStore: store, initialRange: .last7Days,
                subjectSource: { ([openCode], []) }, activityStatus: statusLoader,
                clock: { now })
                .frame(width: 880, height: 820),
            name: "activity-attribution-opencode", directory: directory)
    }
}
