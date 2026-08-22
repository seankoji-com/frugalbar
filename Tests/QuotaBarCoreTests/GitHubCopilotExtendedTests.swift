import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - File-local HTTP stub

/// A URLProtocol stub scoped to this file so tests here do not share static
/// state with URLProtocolStub in ProviderHTTPTests.swift.
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

private func canned(body: String, status: Int = 200) -> LocalStub.StubbedResponse {
    LocalStub.StubbedResponse(status: status, headers: [:], body: Data(body.utf8))
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

@Suite("GitHubCopilot provider — extended", .serialized)
struct GitHubCopilotExtendedTests {

    @Test("malformed JSON body returns badResponse")
    func malformedJson() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "not json at all", status: 200)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(UnavailableReason.badResponse))
        #expect(snap.consumptionFraction == nil)
    }

    /// A seat with no metered allowance is not a malformed payload, and it is
    /// certainly not an empty bar.
    @Test("a response carrying no quota snapshot reports no metered quota")
    func missingQuotaSnapshots() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "{}", status: 200)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .unavailable)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.row1 == nil)
    }

    @Test("full Copilot quota response produces a measured gauge")
    func measuredCopilotQuota() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"""
            {"copilot_plan":"individual","quota_reset_date":"2099-01-01",
             "quota_snapshots":{
               "premium_interactions":{"entitlement":300,"remaining":60,"percent_remaining":20,"unlimited":false},
               "chat":{"entitlement":1000,"remaining":900,"percent_remaining":90,"unlimited":false}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .measured)
        #expect(snap.status == .warning)
        #expect(snap.row1?.primaryFraction == 0.8)
        // Both allowances share one monthly reset, so the label names the window.
        #expect(snap.row1?.label == "MO")
        #expect(snap.row2?.label == "MO")
        #expect(snap.row1?.usedText?.hasPrefix("Premium:") == true)
        #expect(snap.row2?.usedText?.hasPrefix("Chat:") == true)
        #expect(abs((snap.row2?.primaryFraction ?? 0) - 0.1) < 0.0001)
        #expect(snap.badgeText == "20% left")
        #expect(snap.planName == "Individual")
        // A bare yyyy-MM-dd reset date is the common shape and must still parse.
        #expect(snap.resetsAt != nil)
    }

    /// The request that made this provider fail: it must present the GitHub
    /// OAuth token to the entitlement endpoint, not mint a Copilot token.
    @Test("Copilot reads copilot_internal/user with the GitHub OAuth token")
    func requestShape() async throws {
        let provider = GitHubCopilotProvider(token: "gho_example")
        nonisolated(unsafe) var seen: URLRequest?
        _ = try await withStubbedHTTP({ request in
            seen = request
            return canned(body: #"{"quota_snapshots":{"chat":{"entitlement":100,"remaining":50}}}"#)
        }) {
            try await provider.fetchSnapshot()
        }
        let request = try #require(seen)
        #expect(request.url?.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token gho_example")
        #expect(request.value(forHTTPHeaderField: "Editor-Version") != nil)
    }

    /// An exhausted allowance must not read as merely busy.
    @Test("a fully consumed Copilot allowance is critical")
    func exhaustedCopilotQuota() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"""
            {"copilot_plan":"individual",
             "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":0,"percent_remaining":0}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .critical)
        #expect(snap.badgeText == "Exhausted")
    }

    /// An unlimited plan has no denominator. Reporting it as 0% used would
    /// claim headroom that nobody measured.
    @Test("an unlimited allowance draws no bar")
    func unlimitedCopilotQuota() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"""
            {"copilot_plan":"business",
             "quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .unavailable)
        #expect(snap.row1 == nil)
    }

    /// A zero-entitlement, zero-remaining snapshot is GitHub's shape for a seat
    /// billed by token rather than by quota — a placeholder, not a reading.
    @Test("a zero-entitlement placeholder stays unavailable")
    func validUserResponse() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}"#, status: 200)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status.confidence == .unavailable)
        #expect(snap.consumptionFraction == nil)
    }


    @Test("empty token short-circuits without network request")
    func emptyTokenNoRequest() async throws {
        let provider = GitHubCopilotProvider(token: "")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"login":"octocat"}"#, status: 200)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(UnavailableReason.notConfigured))
        #expect(LocalStub.requestCount == 0)
    }

    @Test("403 maps to credentialRejected")
    func forbidden() async throws {
        let provider = GitHubCopilotProvider(token: "bad")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "{}", status: 403)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(UnavailableReason.credentialRejected))
    }

    @Test("500 maps to badResponse")
    func serverError() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "internal error", status: 500)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(UnavailableReason.badResponse))
    }
}
