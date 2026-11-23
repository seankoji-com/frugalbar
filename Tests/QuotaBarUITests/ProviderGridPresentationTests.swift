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
        #expect(claude.summary(for: .fiveHour) == .average(remaining: 1, reported: 2, count: 4))
        #expect(claude.summary(for: .monthly) == nil)

        let deepSeek = try #require(grid.groups.first { $0.id == .deepseek })
        #expect(deepSeek.pools.count == 7)
        #expect(deepSeek.balances.map(\.vendorId) == [.deepseek])
        #expect(grid.groups.allSatisfy { ![.opencode, .commandcode, .opendesign, .antigravityClaude].contains($0.id) })
        guard case .average(_, let measured, let poolCount) = deepSeek.summary(for: .monthly) else {
            Issue.record("Expected the DeepSeek monthly average")
            return
        }
        #expect(measured == 6 && poolCount == 7)
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
        #expect(full.summary(for: .fiveHour) == .spent(reset: now.addingTimeInterval(3600), allMeasuredExhausted: true))

        var partial = snapshots
        partial[0].staleReading = .init(reason: .offline, at: now)
        let missing = Fixtures.snapshot("claude-account:missing", .claude, "Missing", [],
                                        status: .unavailable(.offline))
        let mixed = try #require(presentation(partial + [missing]).groups.first)
        #expect(!mixed.allSpent)
        #expect(mixed.pools.last?.state == .unreadable)
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

    private func presentation(_ snapshots: [QuotaSnapshot]) -> ProviderGridPresentation {
        ProviderGridPresentation(snapshots: snapshots, serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
    }
}
