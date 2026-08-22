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

    @Test("empty JSON object (missing login field) returns badResponse")
    func missingLoginField() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: "{}", status: 200)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == ProviderStatus.unavailable(UnavailableReason.badResponse))
    }

    @Test("missing Copilot quota response stays unavailable")
    func validUserResponse() async throws {
        let provider = GitHubCopilotProvider(token: "tok")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"login":"octocat"}"#, status: 200)
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
