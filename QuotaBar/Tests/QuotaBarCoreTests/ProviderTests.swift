import Testing
import Foundation
@testable import QuotaBarCore

/// Mock URLProtocol that intercepts all URLSession requests and returns
/// canned data, status codes, or errors — no real network I/O.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler not set")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Sets up the shared URLSession to use MockURLProtocol for the duration of
/// the given closure. Returns a handle for the caller to set responses.
struct MockHTTPSession {
    static func withMockSession(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Replace the QuotaHTTP session
        MockURLProtocol.requestHandler = handler
    }

    static func reset() {
        MockURLProtocol.requestHandler = nil
    }
}

// MARK: - Snapshot factory helpers

extension QuotaSnapshot {
    static func mock(
        vendorId: VendorIdentifier = .opencode,
        status: ProviderStatus = .healthy,
        metric: MetricType = .count(remaining: 80, limit: 100, unitName: "units")
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: vendorId.displayName,
            category: vendorId == .openrouter ? .apiSpendAndCredits
                     : vendorId == .githubRest || vendorId == .githubGraphql ? .developerLimits
                     : .aiSubscriptions,
            metric: metric,
            status: status,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}

// MARK: - Provider tests

@Test func claudeProvider_returnsUnsupported() async throws {
    let provider = ClaudeQuotaProvider()
    let snap = try await provider.fetchSnapshot()
    #expect(snap.vendorId == .claude)
    #expect(snap.consumptionFraction == nil)
}

@Test func geminiProvider_unauthenticatedWhenNoKey() async throws {
    let provider = GeminiQuotaProvider(apiKey: "")
    let snap = try await provider.fetchSnapshot()
    #expect(snap.status == .unauthenticated)
}

@Test func githubRestProvider_unauthenticatedWhenNoToken() async throws {
    let provider = GitHubRestProvider(token: "")
    let snap = try await provider.fetchSnapshot()
    #expect(snap.status == .unauthenticated)
}

@Test func githubGraphQLProvider_unauthenticatedWhenNoToken() async throws {
    let provider = GitHubGraphQLProvider(token: "")
    let snap = try await provider.fetchSnapshot()
    #expect(snap.status == .unauthenticated)
}

@Test func githubCopilotProvider_unauthenticatedWhenNoToken() async throws {
    let provider = GitHubCopilotProvider(token: "")
    let snap = try await provider.fetchSnapshot()
    #expect(snap.status == .unauthenticated)
}

@Test func openRouterProvider_unauthenticatedWhenNoKey() async throws {
    let provider = OpenRouterProvider(apiKey: "")
    let snap = try await provider.fetchSnapshot()
    #expect(snap.status == .unauthenticated)
}

@Test func openCodeGoProvider_unauthenticatedWhenNoKey() async throws {
    let provider = OpenCodeGoProvider(apiKey: "")
    let snap = try await provider.fetchSnapshot()
    #expect(snap.status == .unauthenticated)
}
