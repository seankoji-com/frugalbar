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
        // Secondary's spent week hides its 5H column from its row and empties
        // it in the group: a pool spent on the week has no 5H headroom, so the
        // group's 5H is Account 2's full window plus Secondary's zero.
        #expect(claude.summary(for: .fiveHour) == .average(remaining: 0.5, reported: 2, count: 4))
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
        // headroom, so they are not averaged; the spent Command Code month is
        // counted, at zero. All six publishers still count toward the pools.
        #expect(measured == 3 && poolCount == 7)
        // One dot per pool, in pool order: green exactly where that pool
        // brings headroom of its own to the window. A spent month is red even
        // though it counts toward the average at zero (owner, 26 Nov 2026).
        let coverage = deepSeek.coverage(for: .monthly)
        #expect(coverage.enumerated().filter { $0.element }.map(\.offset) == [2, 4])
        #expect(deepSeek.spentCount(for: .monthly) == 1)
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

    @Test("a pool spent on a longer window counts as exhausted in every shorter column")
    func longerWindowExhaustionCarriesDown() throws {
        let monthBlocked = Fixtures.snapshot("opencode-go:month-blocked", .opencode, "Month blocked", [
            Fixtures.bar("5H", 0.0, resetsInHours: 3, windowHours: 5),
            Fixtures.bar("WK", 0.1, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 1.0, resetsInHours: 400, windowHours: 720, blocked: true),
        ])
        let half = Fixtures.snapshot("opencode-go:half", .opencode, "Half", [
            Fixtures.bar("5H", 0.5, resetsInHours: 3, windowHours: 5),
            Fixtures.bar("WK", 0.5, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 0.5, resetsInHours: 400, windowHours: 720),
        ])
        let month = try #require(presentation([monthBlocked, half]).groups.first { $0.id == .deepseek })

        // A blocked figure is still not averaged as headroom in its own
        // column: the month bar is the usable pools' month, and its dot is red.
        #expect(month.summary(for: .monthly) == .average(remaining: 0.5, reported: 1, count: 2))
        #expect(month.coverage(for: .monthly) == [false, true])
        // But the blocked month empties the week and the 5-hour window too: a
        // plan that cannot run has no shorter headroom, so both averages count
        // that pool as exhausted (0) instead of averaging its comfortable 0%
        // and 10% figures (owner, 26 Nov 2026).
        #expect(month.summary(for: .weekly) == .average(remaining: 0.25, reported: 2, count: 2))
        #expect(month.summary(for: .fiveHour) == .average(remaining: 0.25, reported: 2, count: 2))
        #expect(month.coverage(for: .weekly) == [false, true])
        #expect(month.coverage(for: .fiveHour) == [false, true])

        // Same downward rule for a spent week: the 5-hour column counts it as
        // exhausted, and the month is untouched by a shorter window.
        let weekSpent = Fixtures.snapshot("opencode-go:week-spent", .opencode, "Week spent", [
            Fixtures.bar("5H", 0.0, resetsInHours: 3, windowHours: 5),
            Fixtures.bar("WK", 1.0, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 0.1, resetsInHours: 400, windowHours: 720),
        ])
        let week = try #require(presentation([weekSpent, half]).groups.first { $0.id == .deepseek })
        #expect(week.summary(for: .fiveHour) == .average(remaining: 0.25, reported: 2, count: 2))
        #expect(week.coverage(for: .fiveHour) == [false, true])
        #expect(week.summary(for: .monthly) == .average(remaining: 0.7, reported: 2, count: 2))
        #expect(week.coverage(for: .monthly) == [true, true])

        // A spent 5-hour window is exhausted in its own column and nowhere
        // else: it resets within the hour.
        let fiveSpent = Fixtures.snapshot("opencode-go:5h-spent", .opencode, "5H spent", [
            Fixtures.bar("5H", 1.0, resetsInHours: 0.5, windowHours: 5),
            Fixtures.bar("WK", 0.2, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 0.1, resetsInHours: 400, windowHours: 720),
        ])
        let five = try #require(presentation([fiveSpent, half]).groups.first { $0.id == .deepseek })
        #expect(five.summary(for: .fiveHour) == .average(remaining: 0.25, reported: 2, count: 2))
        #expect(five.coverage(for: .fiveHour) == [false, true])
        #expect(five.summary(for: .weekly) == .average(remaining: 0.65, reported: 2, count: 2))
    }

    private func presentation(_ snapshots: [QuotaSnapshot]) -> ProviderGridPresentation {
        ProviderGridPresentation(snapshots: snapshots, serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
    }
}
