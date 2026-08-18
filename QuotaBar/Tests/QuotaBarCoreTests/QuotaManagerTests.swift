import Testing
import Foundation
@testable import QuotaBarCore

struct QuotaManagerTests {

    @Test func sortedSnapshots_returnsInCanonicalOrder() async {
        let manager = QuotaManager.shared
        // Force fresh fetch — no keys configured, all should be unauthenticated/unsupported
        let results = await manager.forceRefresh()
        let sorted = await manager.sortedSnapshots()

        // All 7 vendors should be present
        #expect(sorted.count == 7)
        // Order: Claude, Gemini, OpenCode, Copilot, OpenRouter, GitHubRest, GitHubGraphql
        #expect(sorted[0].vendorId == .claude)
        #expect(sorted[1].vendorId == .gemini)
        #expect(sorted[2].vendorId == .opencode)
        #expect(sorted[3].vendorId == .copilot)
        #expect(sorted[4].vendorId == .openrouter)
        #expect(sorted[5].vendorId == .githubRest)
        #expect(sorted[6].vendorId == .githubGraphql)

        // All 7 should have results in the cache
        #expect(results.count == 7)
    }

    @Test func overallStatus_returnsWorst() async {
        let manager = QuotaManager.shared
        _ = await manager.forceRefresh()
        // With no keys configured, we expect errors — the overall status should be
        // at least .unauthenticated severity
        let status = await manager.overallStatus()
        #expect(status.severity >= ProviderStatus.unauthenticated.severity)
    }

    @Test func cacheFreshness_startsStale() async {
        let manager = QuotaManager.shared
        let fresh = await manager.isCacheFresh()
        #expect(fresh == false)
    }

    @Test func cacheFreshness_afterFetch() async {
        let manager = QuotaManager.shared
        _ = await manager.forceRefresh()
        let fresh = await manager.isCacheFresh()
        #expect(fresh == true)
    }

    @Test func cachedSnapshots_returnsAll() async {
        let manager = QuotaManager.shared
        _ = await manager.forceRefresh()
        let cached = await manager.cachedSnapshots()
        #expect(cached.count == 7)
    }
}
