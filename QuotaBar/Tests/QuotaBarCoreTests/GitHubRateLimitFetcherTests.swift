import Testing
import Foundation
@testable import QuotaBarCore

/// Tests for GitHubRateLimitFetcher that can run in parallel with other suites.
///
/// NOTE: Tests that rely on concurrent access patterns (coalescing, caching)
/// cannot be run safely in parallel because the fetcher is a shared actor
/// singleton. Those behaviours are exercised indirectly through the provider
/// integration tests in ProviderHTTPTests.swift.
///
/// The tests here focus on parsing and data shape — JSON decode behaviour
/// that the provider tests do not cover.

@Suite("GitHubRateLimitFetcher — parsing")
struct GitHubRateLimitFetcherParsingTests {

    // MARK: - Parsing

    @Test("missing graphql resource decodes to nil graphql")
    func missingGraphql() throws {
        let json = #"""
        {"resources":{"core":{"limit":5000,"remaining":4500,"reset":1700000000}}}
        """#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(GitHubRateLimitFetcher.Payload.self, from: data)
        #expect(decoded.resources.core.limit == 5000)
        #expect(decoded.resources.core.remaining == 4500)
        #expect(decoded.resources.graphql == nil)
    }

    @Test("full payload decodes core and graphql")
    func fullPayload() throws {
        let json = #"""
        {"resources":{"core":{"limit":5000,"remaining":4500,"reset":1700000000},"graphql":{"limit":5000,"remaining":1000,"reset":1700000500}}}
        """#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(GitHubRateLimitFetcher.Payload.self, from: data)
        #expect(decoded.resources.core.limit == 5000)
        #expect(decoded.resources.core.remaining == 4500)
        #expect(decoded.resources.graphql?.limit == 5000)
        #expect(decoded.resources.graphql?.remaining == 1000)
    }

    @Test("exhausted core (0 remaining) decodes correctly")
    func exhaustedCore() throws {
        let json = #"""
        {"resources":{"core":{"limit":5000,"remaining":0,"reset":1700000000}}}
        """#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(GitHubRateLimitFetcher.Payload.self, from: data)
        #expect(decoded.resources.core.remaining == 0)
        #expect(decoded.resources.core.limit == 5000)
    }

    @Test("Rate struct decodes correctly")
    func rateStruct() throws {
        let json = #"{"limit":5000,"remaining":4200,"reset":1700000000}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(GitHubRateLimitFetcher.Rate.self, from: data)
        #expect(decoded.limit == 5000)
        #expect(decoded.remaining == 4200)
        #expect(decoded.reset == 1_700_000_000)
    }
}
