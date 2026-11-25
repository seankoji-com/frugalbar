import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Provider quota grid")
struct ProviderGridPresentationTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    @Test("Claude pools share a row and DeepSeek API credit stays outside the averages")
    func groupingAndCounts() throws {
        let grid = presentation(Fixtures.batchWithWallet)
        let claude = try #require(grid.groups.first { $0.id == .claude })
        #expect(claude.pools.map(\.name) == ["Primary", "Secondary", "Account 1", "Account 2"])
        guard case .average(let amount, 4, 4) = claude.summary(for: .weekly) else {
            Issue.record("Expected all four pools in the Claude weekly average")
            return
        }
        #expect(abs(amount - 0.3425) < 0.0001)
        // Secondary's spent week hides its 5H column from its row, so the
        // group's 5H averages only the 5H figure a row actually draws.
        #expect(claude.summary(for: .fiveHour) == .average(remaining: 1, reported: 1, count: 4))
        #expect(claude.summary(for: .monthly) == nil)

        let deepSeek = try #require(grid.groups.first { $0.id == .deepseek })
        #expect(deepSeek.pools.count == 7)
        // Direct balances live in the Wallet only (24 Nov 2026).
        #expect(!deepSeek.pools.contains { ProviderGridPresentation.isDirectBalance($0.snapshot) })
        #expect(!grid.groups.contains { $0.id == .openrouter })
        #expect(grid.groups.allSatisfy {
            ![.opencode, .commandcode, .opendesign, .antigravityClaude, .antigravityArgon].contains($0.id)
        })
        guard case .average(_, let measured, let poolCount) = deepSeek.summary(for: .monthly) else {
            Issue.record("Expected the DeepSeek monthly average")
            return
        }
        // The three blocked OpenCode workspaces' reported figures are not
        // headroom, so they are not averaged; they still count toward the
        // pools, and the cell's "3/7" coverage says so.
        #expect(measured == 3 && poolCount == 7)
    }

    @Test("all confirmed spent uses the first window reset, and stale or missing readings cannot exhaust the group")
    func allSpentRollup() throws {
        let snapshots = [3.0, 1.0, 2.0, 4.0].enumerated().map { index, hours in
            Fixtures.snapshot("claude-account:\(index)", .claude, "Account \(index)", [
                Fixtures.bar("5H", 1, resetsInHours: hours, windowHours: 5)
            ])
        }
        let full = try #require(presentation(snapshots).groups.first)
        #expect(full.allSpent)
        #expect(full.nextReturn == now.addingTimeInterval(3600))
        #expect(full.summary(for: .fiveHour) == .spent(
            reset: now.addingTimeInterval(3600), allMeasuredExhausted: true, includesBlocked: false
        ))

        var partial = snapshots
        partial[0].staleReading = .init(reason: .offline, at: now)
        let missing = Fixtures.snapshot("claude-account:missing", .claude, "Missing", [],
                                        status: .unavailable(.offline))
        let mixed = try #require(presentation(partial + [missing]).groups.first)
        #expect(!mixed.allSpent)
        #expect(mixed.pools.last?.state == .unreadable)
        #expect(mixed.subtitle?.contains("1 stale") == true)
        #expect(mixed.summary(for: .fiveHour) == .average(remaining: 0, reported: 3, count: 5))
    }

    @Test("measured monthly and weekly take the lane, while simultaneous 5H and WK stay visible")
    func spanningWindows() throws {
        let rows = try #require(presentation(Fixtures.batch).groups.first { $0.id == .deepseek }).pools
        #expect(rows.first { $0.name == "Alpha" }?.spanningColumn == .monthly)
        #expect(rows.first { $0.snapshot.vendorId == .opendesign }?.spanningColumn == .weekly)
        #expect(presentation(Fixtures.batch).groups.first { $0.id == .openai }?.pools.first?.spanningColumn == .weekly)

        let multi = Fixtures.snapshot("opencode-go:multi", .opencode, "Multiple windows", [
            Fixtures.bar("5H", 1, resetsInHours: 1, windowHours: 5),
            Fixtures.bar("WK", 1, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 0.1, resetsInHours: 500, windowHours: 720),
        ])
        let simultaneous = try #require(presentation([multi]).groups.first?.pools.first)
        #expect(simultaneous.spanningColumn == nil)
        #expect(Set(simultaneous.displayWindows.keys) == Set(WindowColumn.allCases))

        let blocked = Fixtures.snapshot("opencode-go:blocked", .opencode, "No figure", [
            Fixtures.bar("MO", nil, resetsInHours: 400, windowHours: 720, blocked: true),
        ])
        let unreadable = try #require(presentation([blocked]).groups.first?.pools.first)
        #expect(unreadable.spanningColumn == nil)
        #expect(unreadable.windows[.monthly]?.remaining == nil)
        #expect(unreadable.windows[.monthly]?.isSpent == true)
    }

    @Test("nonstandard exhausted plans keep their measurement, and blocked rollups retain their status")
    func exceptionalWindows() throws {
        let daily = Fixtures.snapshot("grok", .grok, "Grok", [
            Fixtures.bar("1D", 1, resetsInHours: 2, windowHours: 24)
        ])
        let pool = try #require(presentation([daily]).groups.first?.pools.first)
        #expect(pool.state == .spent)
        #expect(pool.windows.isEmpty)
        #expect(pool.nonstandardPlanBar?.label == "1D")
        #expect(pool.nonstandardPlanBar?.isBlocked == false)

        let blocked = Fixtures.snapshot("opencode-go:a", .opencode, "Blocked", [
            Fixtures.bar("WK", 1, resetsInHours: 12, windowHours: 168, blocked: true)
        ])
        let exhausted = Fixtures.snapshot("opencode-go:b", .opencode, "Spent", [
            Fixtures.bar("WK", 1, resetsInHours: 18, windowHours: 168)
        ])
        let group = try #require(presentation([blocked, exhausted]).groups.first)
        #expect(group.summary(for: .weekly) == .spent(
            reset: now.addingTimeInterval(12 * 3600), allMeasuredExhausted: true, includesBlocked: true
        ))
    }

    @Test("Argon sits in the Gemini group, and each Antigravity row names its model and the route that read it")
    func argonUnderGeminiWithRoutes() throws {
        func account(_ id: String, _ name: String, _ source: String) -> AntigravityAccount {
            AntigravityAccount(id: id, badge: "", sourceLabel: source, fallbackName: name)
        }
        let main = account("agy-main", "main", "This Mac's Google OAuth session")
        let burner = account("agy-burner", "burner", "CLI Proxy (proxy.example)")
        var argonMain = Fixtures.agy(.antigravityArgon, main, [Fixtures.bar("WK", 0.2, resetsInHours: 50, windowHours: 168)])
        argonMain.antigravityAccount = main
        let argonBurner = Fixtures.agy(.antigravityArgon, burner,
                                       [Fixtures.bar("WK", 0.2, resetsInHours: 50, windowHours: 168)])
        // The reading's own route wins over the account's list of routes: an
        // account reachable both ways that was read through the proxy says so.
        let both = account("agy-both", "both", "CLI Proxy (proxy.example) · This Mac's Google OAuth session")
        var geminiBurner = Fixtures.agy(.gemini, both, [Fixtures.bar("WK", 0.4, resetsInHours: 50, windowHours: 168)])
        geminiBurner.cliSource = "CLI Proxy (proxy.example)"

        let grid = presentation([argonMain, argonBurner, geminiBurner])
        #expect(grid.groups.map(\.id) == [.gemini])
        let gemini = try #require(grid.groups.first)
        #expect(gemini.title == "Gemini")
        #expect(gemini.pools.map(\.source) == ["Argon · AGY", "Argon · CLI Proxy", "Gemini · CLI Proxy"])
    }

    private func presentation(_ snapshots: [QuotaSnapshot]) -> ProviderGridPresentation {
        ProviderGridPresentation(snapshots: snapshots, serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
    }
}
