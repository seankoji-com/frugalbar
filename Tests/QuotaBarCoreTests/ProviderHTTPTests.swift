import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - URLProtocol stub

/// A `URLProtocol` stub that serves canned responses instead of performing
/// real network I/O. Tests substitute it into `QuotaHTTP.session` via
/// `QuotaHTTP.$session.withValue(...)`.
///
/// `URLProtocol` subclasses are instantiated internally by `URLSession`, so
/// there is no way to inject per-instance state — the handler, request
/// count, and captured requests are necessarily static (process-wide).
/// Every test in this file shares that static state, so the suite below is
/// `.serialized` to keep tests from stomping on each other.
final class URLProtocolStub: URLProtocol {

    struct Stubbed {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Stubbed)?
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []

    static var handler: (@Sendable (URLRequest) -> Stubbed)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requestCount
    }

    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _capturedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requestCount = 0
        _capturedRequests = []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: (@Sendable (URLRequest) -> Stubbed)?
        Self.lock.lock()
        Self._requestCount += 1
        Self._capturedRequests.append(request)
        handler = Self._handler
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Builds a canned HTTP response body/status pair.
private func canned(status: Int = 200, body: String, headers: [String: String] = [:]) -> URLProtocolStub.Stubbed {
    URLProtocolStub.Stubbed(status: status, headers: headers, body: Data(body.utf8))
}

/// Runs `operation` with `QuotaHTTP.session` substituted for a session backed
/// by `URLProtocolStub`, and `handler` wired up to answer every request.
///
/// Resets the stub's state *before* installing the handler, so a previous
/// test's canned responses or counters can never leak in. Deliberately does
/// NOT reset afterwards — callers routinely want to inspect
/// `URLProtocolStub.requestCount` / `.capturedRequests` once `operation` has
/// returned, and resetting here would wipe that state out from under them.
private func withStubbedHTTP<T: Sendable>(
    _ handler: @escaping @Sendable (URLRequest) -> URLProtocolStub.Stubbed,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    URLProtocolStub.reset()
    URLProtocolStub.handler = handler
    return try await QuotaHTTP.$session.withValue(URLProtocolStub.makeSession()) {
        try await operation()
    }
}

private let githubPayload = #"""
{"resources":{"core":{"limit":5000,"remaining":4500,"reset":1700000000},"graphql":{"limit":5000,"remaining":1000,"reset":1700000500}}}
"""#

// MARK: - Suite

@Suite("HTTP-backed provider behaviour", .serialized)
struct ProviderHTTPTests {

    // MARK: Stub sanity

    @Test("the URLProtocol stub is actually invoked by requests")
    func stubActuallyIntercepts() async throws {
        let provider = OpenRouterProvider(apiKey: "key")
        _ = try await withStubbedHTTP({ _ in canned(body: #"{"data":{"usage":1,"limit":10}}"#) }) {
            try await provider.fetchSnapshot()
        }
        #expect(URLProtocolStub.requestCount == 1)
    }

    // MARK: OpenRouter

    @Test("uncapped key (limit: null) yields nil consumptionFraction and no fabricated cap")
    func openRouterUncappedKey() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"data":{"usage":3.5,"limit":null,"limit_remaining":null,"is_free_tier":false}}"#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.consumptionFraction == nil)
        #expect(snap.status == .measured(.none))
        guard case .currency(_, let limit, _, _) = snap.metric else {
            Issue.record("expected .currency metric, got \(snap.metric)")
            return
        }
        #expect(limit == nil) // never a fabricated $20 (or any other) cap
    }

    @Test("capped key at 95% consumed is critical")
    func openRouterNearExhaustion() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"data":{"usage":9.5,"limit":10,"limit_remaining":0.5}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .measured(.critical))
        #expect(snap.consumptionFraction != nil)
    }

    @Test("capped key at low usage is healthy")
    func openRouterLowUsage() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"data":{"usage":1,"limit":10}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .measured(.none))
    }

    @Test("401 maps to credential rejected")
    func openRouterUnauthorized() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    @Test("429 maps to rate limited")
    func openRouter429RateLimited() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in canned(status: 429, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.rateLimited(retryAfter: nil)))
    }

    @Test("500 maps to bad response")
    func openRouterServerError() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in canned(status: 500, body: "internal error") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
    }

    @Test("garbage body with HTTP 200 is bad response, never measured")
    func openRouterMalformedBody() async throws {
        let provider = OpenRouterProvider(apiKey: "key-123")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: "not json { at all") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
        #expect(snap.status.confidence == .unavailable)
    }

    // MARK: GitHub REST / GraphQL

    @Test("GitHub REST reads resources.core")
    func githubRestReadsCore() async throws {
        await GitHubRateLimitFetcher.shared.reset()
        let provider = GitHubRestProvider(token: "rest-token")
        let snap = try await withStubbedHTTP({ _ in canned(body: githubPayload) }) {
            try await provider.fetchSnapshot()
        }
        guard case .count(let remaining, let limit, _) = snap.metric else {
            Issue.record("expected .count metric, got \(snap.metric)")
            return
        }
        #expect(remaining == 4500)
        #expect(limit == 5000)
    }

    @Test("GitHub GraphQL reads resources.graphql")
    func githubGraphQLReadsGraphql() async throws {
        await GitHubRateLimitFetcher.shared.reset()
        let provider = GitHubGraphQLProvider(token: "graphql-token")
        let snap = try await withStubbedHTTP({ _ in canned(body: githubPayload) }) {
            try await provider.fetchSnapshot()
        }
        guard case .count(let remaining, let limit, _) = snap.metric else {
            Issue.record("expected .count metric, got \(snap.metric)")
            return
        }
        #expect(remaining == 1000)
        #expect(limit == 5000)
    }

    @Test("GitHub GraphQL with a zero limit is unavailable, never a 100%-consumed bar")
    func githubGraphQLZeroLimit() async throws {
        await GitHubRateLimitFetcher.shared.reset()
        let provider = GitHubGraphQLProvider(token: "zero-token")
        let zeroPayload = #"""
        {"resources":{"core":{"limit":5000,"remaining":4500,"reset":1700000000},"graphql":{"limit":0,"remaining":0,"reset":1700000000}}}
        """#
        let snap = try await withStubbedHTTP({ _ in canned(body: zeroPayload) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .unavailable)
        #expect(snap.consumptionFraction == nil)
    }

    @Test("GitHub REST 401 maps to credential rejected")
    func githubRest401() async throws {
        await GitHubRateLimitFetcher.shared.reset()
        let provider = GitHubRestProvider(token: "bad-token")
        try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            do {
                _ = try await provider.fetchSnapshot()
                Issue.record("expected fetchSnapshot to throw")
            } catch let error as ProviderError {
                #expect(error.reason == .credentialRejected)
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }

    @Test("GitHub REST with an empty token short-circuits without issuing a request")
    func githubRestEmptyToken() async throws {
        await GitHubRateLimitFetcher.shared.reset()
        let provider = GitHubRestProvider(token: "")
        let snap = try await withStubbedHTTP({ _ in canned(body: githubPayload) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(URLProtocolStub.requestCount == 0)
    }

    @Test("GitHub GraphQL with an empty token short-circuits without issuing a request")
    func githubGraphQLEmptyToken() async throws {
        await GitHubRateLimitFetcher.shared.reset()
        let provider = GitHubGraphQLProvider(token: "")
        let snap = try await withStubbedHTTP({ _ in canned(body: githubPayload) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(URLProtocolStub.requestCount == 0)
    }

    // MARK: Providers with subscription/API access

    @Test("Claude with empty key reports not configured")
    func claudeNoKey() async throws {
        let provider = ClaudeQuotaProvider(apiKey: "")
        let snap = try await provider.fetchSnapshot()
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(snap.consumptionFraction == nil)
    }

    @Test("Claude with key reports critical subscription")
    func claudeWithKey() async throws {
        let provider = ClaudeQuotaProvider(apiKey: "Claude Max")
        let snap = try await provider.fetchSnapshot()
        #expect(snap.status == .critical)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.metric == .subscription(tierName: "Claude Max", renewalDate: nil))
    }

    @Test("Gemini with no key short-circuits without issuing a request")
    func geminiNoKeyNoRequest() async throws {
        let provider = GeminiQuotaProvider(apiKey: "")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(URLProtocolStub.requestCount == 0)
    }

    @Test("Gemini with a valid key reports healthy AI Studio subscription with no fabricated fraction")
    func geminiValidKeyIsHealthy() async throws {
        let provider = GeminiQuotaProvider(apiKey: "k")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .healthy)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.metric == .subscription(tierName: "AI Studio", renewalDate: nil))
    }

    @Test("Gemini 401 maps to credential rejected")
    func gemini401() async throws {
        let provider = GeminiQuotaProvider(apiKey: "k")
        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    /// Security regression test: the API key must travel in the
    /// `x-goog-api-key` header, never in the request URL — a URL leaks into
    /// proxy logs, error descriptions, and crash reports; a header does not.
    @Test("Gemini sends the key in the header, never in the URL")
    func geminiKeyNeverInURL() async throws {
        let provider = GeminiQuotaProvider(apiKey: "super-secret-key")
        _ = try await withStubbedHTTP({ _ in canned(status: 200, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        let requests = URLProtocolStub.capturedRequests
        #expect(requests.count == 1)
        let req = try #require(requests.first)
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "super-secret-key")
        #expect(req.url?.absoluteString.contains("super-secret-key") == false)
    }

    @Test("OpenCode with no key is not configured, and issues no request")
    func openCodeNoKey() async throws {
        let provider = OpenCodeGoProvider(apiKey: "")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(URLProtocolStub.requestCount == 0)
    }

    @Test("OpenCode with a key reports critical subscription when monthly is exhausted")
    func openCodeWithKey() async throws {
        let provider = OpenCodeGoProvider(apiKey: "k")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .critical)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.metric == .subscription(tierName: "Go", renewalDate: nil))
        #expect(URLProtocolStub.requestCount == 0)
    }


    @Test("Copilot with a valid token reports critical exhausted subscription")
    func copilotValidToken() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: #"{"login":"octocat"}"#) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .critical)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.metric == .subscription(tierName: "Active", renewalDate: nil))
    }




    @Test("Copilot 401 maps to credential rejected")
    func copilot401() async throws {
        let provider = GitHubCopilotProvider(token: "bad")
        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    // MARK: Extended Claude & OpenCode Tests

    @Test("Claude parses live organization and usage payload")
    func claudeLiveTelemetryParsing() async throws {
        let orgJSON = """
        [{"uuid": "org-12345", "name": "Anthropic Org"}]
        """
        let usageJSON = """
        {
            "five_hour": { "utilization": 0.42, "resets_at": "2026-08-19T20:00:00Z" },
            "seven_day": { "utilization": 0.88, "resets_at": "2026-08-23T09:00:00Z" }
        }
        """

        let snap = try await withStubbedHTTP({ req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/organizations/") && url.contains("/usage") {
                return canned(status: 200, body: usageJSON)
            } else if url.contains("/organizations") {
                return canned(status: 200, body: orgJSON)
            }
            return canned(status: 404, body: "{}")
        }) {
            let provider = ClaudeQuotaProvider(apiKey: "sk-ant-sid01-test-session-cookie")
            return try await provider.fetchSnapshot()
        }

        #expect(snap.vendorId == .claude)
        #expect(snap.row1?.primaryFraction == 0.42)
        #expect(snap.row2?.primaryFraction == 0.88)
        #expect(snap.status == .critical)
    }

    @Test("Claude detects Pro and Team tiers accurately")
    func claudeTierDetection() async throws {
        let proProvider = ClaudeQuotaProvider(apiKey: "sk-ant-api03-pro-key")
        let proSnap = try await proProvider.fetchSnapshot()
        #expect(proSnap.planName?.contains("Claude Pro") == true)

        let teamProvider = ClaudeQuotaProvider(apiKey: "sk-ant-api03-team-key")
        let teamSnap = try await teamProvider.fetchSnapshot()
        #expect(teamSnap.planName?.contains("Claude Team") == true)
    }

    @Test("OpenCode with key returns dual-bar metrics")
    func openCodeMetrics() async throws {
        let provider = OpenCodeGoProvider(apiKey: "oc_live_test_key_123")
        let snap = try await provider.fetchSnapshot()
        #expect(snap.vendorId == .opencode)
        #expect(snap.row1?.label == "5H")
        #expect(snap.row2?.label == "WK")
        #expect(snap.row3?.label == "MO")
    }
}

