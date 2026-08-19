import Foundation
@testable import QuotaBarCore

/// Shared test URLProtocol stub across all test files
final class SharedURLProtocolStub: URLProtocol {

    struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> StubResponse)?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []

    static var handler: (@Sendable (URLRequest) -> StubResponse)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _capturedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _capturedRequests = []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SharedURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: (@Sendable (URLRequest) -> StubResponse)?
        Self.lock.lock()
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

func withSharedStubbedHTTP<T: Sendable>(
    _ handler: @escaping @Sendable (URLRequest) -> SharedURLProtocolStub.StubResponse,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    SharedURLProtocolStub.reset()
    SharedURLProtocolStub.handler = handler
    return try await QuotaHTTP.$session.withValue(SharedURLProtocolStub.makeSession()) {
        try await operation()
    }
}
