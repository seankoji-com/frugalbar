import Testing
import Foundation
@testable import QuotaBarCore

struct CachePolicyTests {

    @Test func defaultPolicy_hasSaneValues() {
        let policy = CachePolicy.default
        #expect(policy.cacheTTL == 30)
        #expect(policy.backgroundRefreshInterval == 120)
        #expect(policy.perProviderTimeout == 10)
    }

    /// Gemini and OpenRouter each issue two sequential requests under one
    /// provider deadline. If the ceiling ever drops below twice URLSession's
    /// 4s per-request budget they get cancelled mid-second-call on a slow
    /// network and silently report nothing.
    @Test func defaultPolicy_clearsTwoSequentialRequests() {
        #expect(CachePolicy.default.perProviderTimeout >= 8)
    }

    @Test func customPolicy_usesSuppliedValues() {
        let policy = CachePolicy(cacheTTL: 60, backgroundRefreshInterval: 300, perProviderTimeout: 10)
        #expect(policy.cacheTTL == 60)
        #expect(policy.backgroundRefreshInterval == 300)
        #expect(policy.perProviderTimeout == 10)
    }

    @Test func customPolicy_defaultsPerProviderTimeoutWhenOmitted() {
        let policy = CachePolicy(cacheTTL: 15, backgroundRefreshInterval: 45)
        #expect(policy.perProviderTimeout == 10)
    }
}
