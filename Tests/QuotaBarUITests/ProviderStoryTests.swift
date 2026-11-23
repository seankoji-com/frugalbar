import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Widget story")
struct ProviderStoryTests {
    let now = GlanceFixtures.now
    var glance: GlancePresentation { GlancePresentation(snapshots: GlanceFixtures.batch, now: now) }

    func story(_ name: String) throws -> ProviderStoryPresentation {
        let pool = try #require(glance.pools.first { $0.name == name })
        return ProviderStoryPresentation(pool: pool, glance: glance, readings: nil, now: now)
    }

    @Test("the top pick says so, and its story names the window in words")
    func topPick() throws {
        let s = try story("Argon · Account 2")
        #expect(s.standing == "Your top pick right now")
        #expect(s.windowName == "weekly")
        #expect(s.lines.contains { $0.text.hasPrefix("It resets in 6d (") })
    }

    @Test("a fast-draining pool's story gives its pace and a labelled run-out, in one time unit")
    func aheadOfPace() throws {
        let s = try story("Gemini · Account 1")
        #expect(s.standing == "Ranked 6th in Use now")
        #expect(s.lines.contains { $0.text == "You've used 73% of the weekly allowance in 2d; 29% of the window has gone." })
        #expect(s.lines.contains { $0.text.hasPrefix("That's 2.6× an even pace") && $0.tone == .caution })
        let runOut = try #require(s.lines.first { $0.symbol == "hourglass" })
        #expect(runOut.text == "At this window's average rate, runs out in 18h, before the reset.")
        // The 5-hour window is told too, as a separate line.
        #expect(s.lines.contains { $0.text.hasPrefix("The 5-hour window has 99% left") })
    }

    @Test("a blocked pool's story says when it comes back and draws no figure")
    func blocked() throws {
        let s = try story("Delta")
        #expect(s.standing == "Blocked · back in 39h")
        #expect(s.tone == .spent)
        #expect(s.lines.first?.text == "The vendor has blocked the monthly window.")
        #expect(!s.lines.contains { $0.symbol == "hourglass" })
    }

    @Test("a stale pool's story leads with the failed poll and makes no projection")
    func stale() throws {
        var snapshots = GlanceFixtures.batch
        let i = try #require(snapshots.firstIndex { $0.claudeAccount?.id == GlanceFixtures.primary.id })
        snapshots[i].staleReading = StaleReading(reason: .rateLimited(retryAfter: nil), at: now)
        let g = GlancePresentation(snapshots: snapshots, now: now)
        let pool = try #require(g.pools.first { $0.name == "Primary" })
        let s = ProviderStoryPresentation(pool: pool, glance: g, readings: nil, now: now)
        #expect(s.lines.first?.symbol == "clock.badge.exclamationmark")
        #expect(!s.lines.contains { $0.symbol == "hourglass" })
    }

    @Test("retired widget layouts are drawn as the story; the picker offers Story and Tokens")
    func layouts() {
        #expect(WidgetFilters.Layout.chart.drawn == .story)
        #expect(WidgetFilters.Layout.overview.drawn == .story)
        #expect(WidgetFilters.Layout.tokens.drawn == .tokens)
        #expect(WidgetFilters.Layout.offered == [.story, .tokens])
        var filters = WidgetFilters()
        filters.storyPoolID = "opencode-go:gamma"
        #expect(WidgetFilters.decode(filters.encoded()).storyPoolID == "opencode-go:gamma")
        #expect(WidgetFilters().layout == .story)
    }
}
