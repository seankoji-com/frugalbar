import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - File-local HTTP stub

/// Each test file has its own URLProtocol stub so parallel suites don't
/// contaminate each other's static state.
private final class LocalStub: URLProtocol {
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> StubbedResponse)?
    nonisolated(unsafe) private static var _requestCount = 0

    struct StubbedResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static var handler: (@Sendable (URLRequest) -> StubbedResponse)? {
        get { _handler }
        set { _handler = newValue }
    }

    static var requestCount: Int { _requestCount }

    static func reset() {
        _handler = nil
        _requestCount = 0
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self._requestCount += 1
        guard let handler = Self._handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func canned(body: String, status: Int = 200, headers: [String: String] = [:]) -> LocalStub.StubbedResponse {
    LocalStub.StubbedResponse(status: status, headers: headers, body: Data(body.utf8))
}

private func withStubbedHTTP<T: Sendable>(
    _ handler: @escaping @Sendable (URLRequest) -> LocalStub.StubbedResponse,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    LocalStub.reset()
    LocalStub.handler = handler
    return try await QuotaHTTP.$session.withValue(LocalStub.makeSession()) {
        try await operation()
    }
}

/// Reusable response factory for /api/v1/auth/key responses.
private func openRouterBody(
    usage: Double? = 3.5,
    limit: Double? = 10,
    limitRemaining: Double? = 6.5,
    isFreeTier: Bool? = false
) -> String {
    let usageStr = usage.map { #""usage":\#($0)"# } ?? #""usage":null"#
    let limitStr = limit.map { #""limit":\#($0)"# } ?? #""limit":null"#
    let remainStr = limitRemaining.map { #""limit_remaining":\#($0)"# } ?? #""limit_remaining":null"#
    let freeStr = isFreeTier.map { #""is_free_tier":\#($0)"# } ?? #""is_free_tier":null"#
    return #"""
    {"data":{\#(usageStr),\#(limitStr),\#(remainStr),\#(freeStr)}}
    """#
}

@Suite("OpenRouter provider — extended", .serialized)
struct OpenRouterExtendedTests {

    // MARK: - Free tier

    @Test("free tier key reports auxiliaryInfo 'Free tier'")
    func freeTierAuxiliaryInfo() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(isFreeTier: true))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.auxiliaryInfo == "Free tier")
    }

    @Test("capped non-free key labels its key cap rather than account credit")
    func cappedKeyAuxiliaryInfo() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody())
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.auxiliaryInfo == "Key spend cap, not account credit")
    }

    // MARK: - Edge cases

    @Test("usage of 0 with a cap is healthy and reports 0 consumed")
    func zeroUsageCapped() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 0, limit: 10, limitRemaining: 10))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .measured(.none))
        #expect(snap.consumptionFraction == 0.0)
    }

    @Test("usage equal to cap reports critical")
    func usageEqualsCap() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 10, limit: 10, limitRemaining: 0))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .measured(.critical))
        #expect(snap.consumptionFraction == 1.0)
    }

    @Test("usage at exactly 70% is healthy, 71% is warning")
    func warningBoundary() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        // 70% — still healthy
        let snapHealthy = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 7, limit: 10, limitRemaining: 3))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snapHealthy.status == .measured(.none))
        #expect(snapHealthy.consumptionFraction == 0.7)

        // 71% — warning
        let snapWarning = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 7.1, limit: 10, limitRemaining: 2.9))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snapWarning.status == .measured(.warning))
    }

    @Test("usage at exactly 90% is warning, 91% is critical")
    func criticalBoundary() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snapWarning = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 9, limit: 10, limitRemaining: 1))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snapWarning.status == .measured(.warning))

        let snapCritical = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 9.1, limit: 10, limitRemaining: 0.9))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snapCritical.status == .measured(.critical))
    }

    // MARK: - Missing usage field

    @Test("missing usage field returns badResponse")
    func missingUsageField() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"data":{"limit":10,"limit_remaining":5}}"# )
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
    }

    // MARK: - Missing data key

    @Test("missing data key returns badResponse")
    func missingDataKey() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"not_data":{}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
    }

    // MARK: - Limit_remaining absent (capped key)

    @Test("capped key without limit_remaining computes remaining from cap - usage")
    func cappedKeyNoLimitRemaining() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 3, limit: 10, limitRemaining: nil))
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .measured(.none))
        // remaining = max(10 - 3, 0) = 7 -> fraction = 3/10 = 0.3
        #expect(abs((snap.consumptionFraction ?? -1) - 0.3) < 0.001)
    }

    // MARK: - Retry-After header

    @Test("429 with Retry-After header parses the retry date")
    func rateLimitedWithRetryAfter() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "{}", status: 429, headers: ["Retry-After": "120"])
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.unavailableReason != nil)
        if case .rateLimited(let retryAfter) = snap.status.unavailableReason {
            #expect(retryAfter != nil)
            // retryAfter should be ~120s from now
            let expected = Date().addingTimeInterval(120)
            let diff = abs(retryAfter!.timeIntervalSince(expected))
            #expect(diff < 2, "retryAfter is \(diff)s off from expected")
        } else {
            Issue.record("expected rateLimited with retryAfter")
        }
    }

    @Test("429 without Retry-After header returns rateLimited with nil retryAfter")
    func rateLimitedNoRetryAfter() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "{}", status: 429)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(.rateLimited(retryAfter: nil)))
    }

    @Test("429 with non-numeric Retry-After ignores the header")
    func rateLimitedInvalidRetryAfter() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "{}", status: 429, headers: ["Retry-After": "not-a-number"])
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(.rateLimited(retryAfter: nil)))
    }

    // MARK: - Empty key

    @Test("empty key returns notConfigured without issuing an /auth/key request")
    func emptyKeyNoRequest() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "")
        // No key means the primary /auth/key call never fires — but the
        // model-catalog call needs no key, so it still runs on every
        // refresh (that's what lets its badges appear with no key configured).
        let snap = try await withStubbedHTTP({ request in
            #expect(request.url?.absoluteString.contains("auth/key") != true)
            return canned(body: "unused")
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(LocalStub.requestCount == 1)
    }

    // MARK: - Currency metric shape

    @Test("capped key returns the API's USD key-cap figures without conversion")
    func cappedKeyCurrencyMetric() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 3.5, limit: 10, limitRemaining: 6.5))
        }) {
            try await provider.fetchSnapshot()
        }
        guard case .currency(let balance, let limit, let spent, let code) = snap.metric else {
            Issue.record("expected .currency, got \(snap.metric)")
            return
        }
        #expect(limit == Decimal(10))
        #expect(balance == Decimal(6.5))  // limit_remaining
        #expect(spent == Decimal(3.5))
        #expect(code == "USD")
    }

    @Test("uncapped key returns the API's USD lifetime spend with no cap")
    func uncappedKeyCurrencyMetric() async throws {
        await ModelCatalogCache.shared.reset()
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: openRouterBody(usage: 12.34, limit: nil, limitRemaining: nil))
        }) {
            try await provider.fetchSnapshot()
        }
        guard case .currency(let balance, let limit, let spent, let code) = snap.metric else {
            Issue.record("expected .currency, got \(snap.metric)")
            return
        }
        #expect(limit == nil)
        #expect(spent == Decimal(12.34))
        #expect(balance == Decimal(12.34))
        #expect(code == "USD")
    }
}

@Suite("OpenRouter spend windows", .serialized)
struct OpenRouterSpendWindowTests {

    private func snapshot(body: String) async throws -> QuotaSnapshot {
        let provider = OpenRouterProvider(apiKey: "key")
        return try await QuotaHTTP.$session.withValue(SpendStub.session(body)) {
            try await provider.fetchSnapshot()
        }
    }

    /// Both figures are published by `/auth/key`; neither is derived. The row
    /// shows them as amounts, never as a bar — spend has no cap to measure
    /// against, so a gauge would invent a denominator.
    @Test("daily and weekly spend come straight from the API")
    func spendWindowsArePublished() async throws {
        await ModelCatalogCache.shared.reset()
        let snap = try await snapshot(body: #"""
        {"data":{"usage":96.02,"usage_daily":0.835992537,"usage_weekly":13.000224144,
                 "limit":null,"limit_remaining":null,"is_free_tier":false}}
        """#)
        #expect(snap.spendWindows.count == 2)
        #expect(snap.spendWindows[0].label == "1D")
        #expect(snap.spendWindows[1].label == "WK")
        #expect(snap.spendWindows[0].amount == Decimal(0.835992537))
        #expect(snap.spendWindows[1].amount == Decimal(13.000224144))
        // No bars: there is no denominator for spend.
        #expect(snap.bars.isEmpty)
    }

    /// A window the vendor omits is an absence, not a zero — "$0.00 today"
    /// and "we were not told" are different claims.
    @Test("an omitted window is absent rather than zero")
    func omittedWindowIsNil() async throws {
        await ModelCatalogCache.shared.reset()
        let snap = try await snapshot(body: #"{"data":{"usage":96.02,"limit":null}}"#)
        #expect(snap.spendWindows.count == 2)
        #expect(snap.spendWindows.allSatisfy { $0.amount == nil })
    }

    /// The plan slot carries the credit balance for a money provider, so it
    /// must not also claim a plan name.
    @Test("no plan name is asserted for a spend provider")
    func noPlanNameAsserted() async throws {
        await ModelCatalogCache.shared.reset()
        let snap = try await snapshot(body: #"{"data":{"usage":96.02,"limit":null}}"#)
        #expect(snap.planName == nil)
        #expect(snap.shortPlanName.isEmpty)
    }
}

private enum SpendStub {
    static func session(_ body: String) -> URLSession {
        Proto.body = body
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Proto.self]
        return URLSession(configuration: config)
    }
    final class Proto: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = ""
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            // Only /auth/key answers; the credits enrichment 404s, which is the
            // shape a non-provisioning key sees.
            let isAuth = request.url?.absoluteString.contains("auth/key") == true
            let response = HTTPURLResponse(url: request.url!, statusCode: isAuth ? 200 : 404,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(isAuth ? Self.body.utf8 : "{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
