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
        #expect(URLProtocolStub.requestCount == 2)
    }

    // MARK: OpenRouter

    // MARK: OpenAI / ChatGPT

    @Test("OpenAI reads the ChatGPT rolling window and sends the selected account header")
    func openAIUsageWindow() async throws {
        let provider = OpenAIQuotaProvider(accessToken: "session-token", accountID: "account-123")
        let snap = try await withStubbedHTTP({ request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
            #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "account-123")
            return canned(body: #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":85,"reset_at":1787891551}}}"#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(URLProtocolStub.requestCount == 1)
        #expect(snap.status == .measured(.warning))
        #expect(snap.row1?.primaryFraction == 0.85)
        #expect(snap.badgeText == "15% left")
        #expect(snap.planName == "Plus")
    }

    /// Both windows are real limits, and each is named from the length OpenAI
    /// reports. Showing only the first, under a label that named neither, drew
    /// the weekly quota as "PLAN" and hid the 5-hour window entirely.
    @Test("OpenAI shows both windows and labels each from its own length")
    func openAIBothWindows() async throws {
        let provider = OpenAIQuotaProvider(accessToken: "session-token")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"""
            {"plan_type":"plus","rate_limit":{
              "primary_window":{"used_percent":30,"reset_at":1787891551,"limit_window_seconds":18000},
              "secondary_window":{"used_percent":92,"reset_at":1788391551,"limit_window_seconds":604800}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.row1?.label == "5H")
        #expect(snap.row1?.primaryFraction == 0.30)
        #expect(snap.row2?.label == "WK")
        #expect(snap.row2?.primaryFraction == 0.92)
        // Urgency and badge both follow the fuller window, so the menu bar and
        // the row cannot disagree about which limit is binding.
        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "8% left")
    }

    @Test("an unlabelled OpenAI window falls back rather than guessing a length")
    func openAIWindowLabels() {
        #expect(OpenAIQuotaProvider.label(forWindowSeconds: 18000) == "5H")
        #expect(OpenAIQuotaProvider.label(forWindowSeconds: 604_800) == "WK")
        #expect(OpenAIQuotaProvider.label(forWindowSeconds: 2_592_000) == "MO")
        #expect(OpenAIQuotaProvider.label(forWindowSeconds: 3600) == "1H")
        #expect(OpenAIQuotaProvider.label(forWindowSeconds: nil) == "PLAN")
    }

    @Test("OpenAI missing usage data is unavailable rather than a zero-percent reading")
    func openAIMissingUsage() async throws {
        let provider = OpenAIQuotaProvider(accessToken: "session-token")
        let snap = try await withStubbedHTTP({ _ in canned(body: #"{"plan_type":"plus"}"#) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
        #expect(snap.consumptionFraction == nil)
    }

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

    @Test("a key that can read credits reports the documented account credit balance")
    func openRouterAccountCredits() async throws {
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/api/v1/credits" {
                return canned(body: #"{"data":{"total_credits":100.5,"total_usage":25.75}}"#)
            }
            return canned(body: #"{"data":{"usage":2}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        guard case .currency(let balance, let limit, let spent, let code) = snap.metric else {
            Issue.record("expected account credit metric")
            return
        }
        #expect(URLProtocolStub.requestCount == 2)
        #expect(balance == Decimal(74.75))
        #expect(limit == nil)
        #expect(spent == Decimal(25.75))
        #expect(code == "USD")
        #expect(snap.badgeText == "$74.75 credit")
    }

    /// /credits is enrichment on top of a reading we already hold. A failure
    /// there must not throw away a perfectly good key-cap gauge.
    @Test("a failing credits call still yields the key-cap reading")
    func openRouterCreditsFailureKeepsKeyCap() async throws {
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/api/v1/credits" {
                return canned(status: 500, body: "{}")
            }
            return canned(body: #"{"data":{"usage":3.5,"limit":10,"limit_remaining":6.5}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        guard case .currency(let balance, let limit, _, _) = snap.metric else {
            Issue.record("expected the key-cap currency metric, got \(snap.metric)")
            return
        }
        #expect(balance == Decimal(6.5))
        #expect(limit == Decimal(10))
        #expect(snap.currencyBasis == .keySpendCap)
        #expect(snap.status.confidence == .measured)
    }

    /// An account with nothing left in it must not render green.
    @Test("an exhausted account credit balance is critical, not healthy")
    func openRouterEmptyCreditIsCritical() async throws {
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/api/v1/credits" {
                return canned(body: #"{"data":{"total_credits":50,"total_usage":50}}"#)
            }
            return canned(body: #"{"data":{"usage":50}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .measured(.critical))
        #expect(snap.currencyBasis == .accountCredit)
        #expect(snap.badgeText == "$0.00 credit")
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

    @Test("Gemini with no key short-circuits without issuing a request")
    func geminiNoKeyNoRequest() async throws {
        let provider = GeminiQuotaProvider(accessToken: "")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(URLProtocolStub.requestCount == 0)
    }

    @Test("Gemini parses live Antigravity model quota")
    func geminiParsesQuota() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":{"id":"project-1"},"planInfo":{"planType":"ANTIGRAVITY"}}"#)
            }
            return canned(body: #"{"models":{"gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.94,"resetTime":"2026-08-22T03:30:11Z"}}}}"#)
        }) { try await provider.fetchSnapshot() }
        #expect(snap.status == .healthy)
        #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.06) < 0.000_001)
    }

    /// The security test previously stubbed a 401 so only the first request
    /// was ever issued — the second call's URL was never inspected. Both must
    /// be token-free.
    @Test("Gemini keeps the token out of every request URL, not just the first")
    func geminiTokenNeverInAnyURL() async throws {
        let provider = GeminiQuotaProvider(accessToken: "super-secret-key")
        _ = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":{"id":"project-1"}}"#)
            }
            return canned(body: #"{"models":{"gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-08-22T03:30:11Z"}}}}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(URLProtocolStub.capturedRequests.count == 2)
        for request in URLProtocolStub.capturedRequests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer super-secret-key")
            #expect(request.url?.absoluteString.contains("super-secret-key") == false)
        }
    }

    /// The menu-bar colour must follow the model closest to its limit, not
    /// whichever one happens to sort first by name.
    @Test("Gemini headlines the fullest model, not the alphabetically first")
    func geminiRanksByUsage() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":{"id":"project-1"}}"#)
            }
            return canned(body: #"{"models":{"gemini-3-alpha":{"displayName":"Alpha","quotaInfo":{"remainingFraction":0.90,"resetTime":"2026-08-22T03:30:11Z"}},"gemini-3-zeta":{"displayName":"Zeta","quotaInfo":{"remainingFraction":0.02,"resetTime":"2026-08-22T03:30:11Z"}}}}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .measured(.critical))
        #expect(snap.row1?.usedText?.contains("Zeta") == true)
        #expect(snap.badgeText == "2% left")
    }

    /// A well-formed response that simply carries no quota is "nothing to
    /// read", not a malformed payload.
    @Test("Gemini reports no model quota as unsupported, not a bad response")
    func geminiNoQuotaIsUnsupported() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":{"id":"project-1"}}"#)
            }
            return canned(body: #"{"models":{"gemini-3-flash":{"displayName":"Flash"}}}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status.confidence == .unavailable)
        #expect(snap.status != .unavailable(.badResponse))
        #expect(snap.consumptionFraction == nil)
    }

    @Test("Gemini 401 maps to credential rejected")
    func gemini401() async throws {
        let provider = GeminiQuotaProvider(accessToken: "k")
        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    @Test("Gemini sends the OAuth token in a header, never in the URL")
    func geminiTokenNeverInURL() async throws {
        let provider = GeminiQuotaProvider(accessToken: "super-secret-key")
        _ = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        let requests = URLProtocolStub.capturedRequests
        #expect(requests.count == 1)
        let req = try #require(requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer super-secret-key")
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

    /// Body captured verbatim from a live authenticated request, so the
    /// parsing is pinned to the shape OpenCode actually sends rather than one
    /// reconstructed from another client's source.
    @Test("OpenCode reads the Go usage API with the key in a header")
    func openCodeWithKey() async throws {
        let provider = OpenCodeGoProvider(apiKey: "super-secret-key")
        let snap = try await withStubbedHTTP({ _ in
            canned(status: 200, body: #"""
            {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-22T14:39:10.189Z"},
                      "weekly":{"status":"ok","percent":40,"resetsAt":"2026-08-24T00:00:00.189Z"},
                      "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-08-23T08:36:39.189Z"}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .critical)
        #expect(snap.row1?.primaryFraction == 0.0)
        #expect(snap.row1?.label == "ROLL")
        #expect(snap.row2?.primaryFraction == 0.40)
        #expect(snap.row3?.primaryFraction == 1.0)
        #expect(snap.badgeText == "Exhausted")
        // A blocked window says so, rather than leaving 100% to be inferred.
        #expect(snap.row3?.usedText?.contains("blocked") == true)
        // Fractional seconds in `resetsAt` must parse, or every reset is lost.
        #expect(snap.row2?.resetText != nil)

        let req = try #require(URLProtocolStub.capturedRequests.first)
        #expect(req.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer super-secret-key")
        #expect(req.url?.absoluteString.contains("super-secret-key") == false)
    }

    /// A window OpenCode reports as blocking is critical even when its
    /// percentage alone would only warn.
    @Test("a rate-limited window is critical whatever its percentage rounds to")
    func openCodeBlockedWindow() async throws {
        let provider = OpenCodeGoProvider(apiKey: "k")
        let snap = try await withStubbedHTTP({ _ in
            canned(status: 200, body: #"""
            {"usage":{"rolling":{"status":"rate-limited","percent":12,"resetsAt":"2026-08-22T14:39:10.189Z"}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .critical)
        #expect(snap.row1?.primaryFraction == 0.12)
    }

    /// "rolling" names no window length, so its bar carries no pace marker —
    /// where "weekly" and "monthly" name their own.
    @Test("only windows that name their length get a pace marker")
    func openCodePaceOnlyWhereKnown() async throws {
        let provider = OpenCodeGoProvider(apiKey: "k")
        let snap = try await withStubbedHTTP({ _ in
            canned(status: 200, body: #"""
            {"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"2099-01-01T00:00:00.000Z"},
                      "weekly":{"status":"ok","percent":20,"resetsAt":"2099-01-01T00:00:00.000Z"},
                      "monthly":{"status":"ok","percent":30,"resetsAt":"2099-01-01T00:00:00.000Z"}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.row1?.expectedPaceFraction == nil)
        #expect(snap.row2?.expectedPaceFraction != nil)
        #expect(snap.row3?.expectedPaceFraction != nil)
    }

    /// A structurally valid body with no window is "OpenCode published nothing",
    /// which must never render as a bar at 0%.
    @Test("OpenCode with no usage window stays unavailable")
    func openCodeNoWindow() async throws {
        let provider = OpenCodeGoProvider(apiKey: "k")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: #"{"usage":{}}"#) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .unavailable)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.row1 == nil)
    }


    @Test("Copilot with missing quota data stays unavailable")
    func copilotValidToken() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in canned(status: 200, body: #"{"copilot_plan":"business"}"#) }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .unavailable)
        #expect(snap.consumptionFraction == nil)
    }




    @Test("Copilot 401 maps to credential rejected")
    func copilot401() async throws {
        let provider = GitHubCopilotProvider(token: "bad")
        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    /// The OAuth beta rejects /v1/messages unless the request identifies
    /// itself as Claude Code. Losing that system block silently turns every
    /// valid token into "Rejected — check the key".
    @Test("Claude identifies itself as Claude Code so the OAuth token is accepted")
    func claudeSendsClaudeCodeSystemPrompt() async throws {
        let headers = ["anthropic-ratelimit-unified-5h-utilization": "0.10", "anthropic-ratelimit-unified-5h-reset": "1787400000", "anthropic-ratelimit-unified-7d-utilization": "0.20", "anthropic-ratelimit-unified-7d-reset": "1787800000"]
        _ = try await withStubbedHTTP({ _ in canned(body: "{}", headers: headers) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        let request = try #require(URLProtocolStub.capturedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? Data()
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["system"] as? String == "You are Claude Code, Anthropic's official CLI for Claude.")
    }

    /// The header has been observed as a fraction and as a percentage. Reading
    /// a percentage as a fraction would report 42% usage as 4200% and get
    /// discarded, so the provider must normalise rather than reject.
    @Test("Claude accepts a percentage-scaled utilization header")
    func claudeAcceptsPercentScale() async throws {
        let headers = ["anthropic-ratelimit-unified-5h-utilization": "42", "anthropic-ratelimit-unified-5h-reset": "1787400000", "anthropic-ratelimit-unified-7d-utilization": "88", "anthropic-ratelimit-unified-7d-reset": "1787800000"]
        let snap = try await withStubbedHTTP({ _ in canned(body: "{}", headers: headers) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.row1?.primaryFraction == 0.42)
        #expect(snap.row2?.primaryFraction == 0.88)
    }

    /// Badge and menu-bar urgency must be driven by the same window, or the
    /// icon goes red while the row still claims plenty of headroom.
    @Test("Claude badge reflects the fuller window, not just the weekly one")
    func claudeBadgeTracksWorstWindow() async throws {
        let headers = ["anthropic-ratelimit-unified-5h-utilization": "0.99", "anthropic-ratelimit-unified-5h-reset": "1787400000", "anthropic-ratelimit-unified-7d-utilization": "0.05", "anthropic-ratelimit-unified-7d-reset": "1787800000"]
        let snap = try await withStubbedHTTP({ _ in canned(body: "{}", headers: headers) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "1% left")
    }

    @Test("Claude parses real usage headers")
    func claudeLiveTelemetryParsing() async throws {
        let headers = ["anthropic-ratelimit-unified-5h-utilization": "0.42", "anthropic-ratelimit-unified-5h-reset": "1787400000", "anthropic-ratelimit-unified-7d-utilization": "0.88", "anthropic-ratelimit-unified-7d-reset": "1787800000"]
        let snap = try await withStubbedHTTP({ _ in canned(body: "{}", headers: headers) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }

        #expect(snap.vendorId == .claude)
        #expect(snap.row1?.primaryFraction == 0.42)
        #expect(snap.row2?.primaryFraction == 0.88)
        #expect(snap.status == .warning)
    }

}
