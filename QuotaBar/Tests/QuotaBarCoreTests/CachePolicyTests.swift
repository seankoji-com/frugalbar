import Testing
import Foundation
@testable import QuotaBarCore

struct CachePolicyTests {

    @Test func defaultPolicy_hasSaneValues() {
        let policy = CachePolicy.default
        #expect(policy.cacheTTL == 30)
        #expect(policy.backgroundRefreshInterval == 120)
    }

    @Test func customPolicy() {
        let policy = CachePolicy(cacheTTL: 60, backgroundRefreshInterval: 300)
        #expect(policy.cacheTTL == 60)
        #expect(policy.backgroundRefreshInterval == 300)
    }
}
