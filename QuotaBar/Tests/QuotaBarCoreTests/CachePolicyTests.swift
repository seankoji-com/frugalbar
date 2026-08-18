import Testing
import Foundation
@testable import QuotaBarCore

struct CachePolicyTests {

    @Test func defaultPolicy_hasSaneValues() {
        let policy = CachePolicy.default
        #expect(policy.cacheTTL == 30)
        #expect(policy.backgroundRefreshInterval == 120)
        #expect(policy.perProviderTimeout == 6)
    }

    @Test func customPolicy_usesSuppliedValues() {
        let policy = CachePolicy(cacheTTL: 60, backgroundRefreshInterval: 300, perProviderTimeout: 10)
        #expect(policy.cacheTTL == 60)
        #expect(policy.backgroundRefreshInterval == 300)
        #expect(policy.perProviderTimeout == 10)
    }

    @Test func customPolicy_defaultsPerProviderTimeoutWhenOmitted() {
        let policy = CachePolicy(cacheTTL: 15, backgroundRefreshInterval: 45)
        #expect(policy.perProviderTimeout == 6)
    }
}
