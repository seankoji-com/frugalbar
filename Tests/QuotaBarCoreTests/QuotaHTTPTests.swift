import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - FailureReason

@Suite("QuotaHTTP.failureReason")
struct QuotaHTTPFailureReasonTests {

    @Test("2xx returns nil")
    func success() {
        #expect(QuotaHTTP.failureReason(for: 200) == nil)
        #expect(QuotaHTTP.failureReason(for: 204) == nil)
        #expect(QuotaHTTP.failureReason(for: 299) == nil)
    }

    @Test("401 maps to credentialRejected")
    func unauthorized() {
        #expect(QuotaHTTP.failureReason(for: 401) == .credentialRejected)
    }

    @Test("403 maps to credentialRejected")
    func forbidden() {
        #expect(QuotaHTTP.failureReason(for: 403) == .credentialRejected)
    }

    @Test("429 maps to rateLimited")
    func rateLimited() {
        #expect(QuotaHTTP.failureReason(for: 429) == .rateLimited(retryAfter: nil))
    }

    @Test("300s map to badResponse")
    func redirect() {
        #expect(QuotaHTTP.failureReason(for: 301) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 302) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 307) == .badResponse)
    }

    @Test("4xx non-auth codes map to badResponse")
    func clientError() {
        #expect(QuotaHTTP.failureReason(for: 400) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 404) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 418) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 451) == .badResponse)
    }

    @Test("5xx maps to badResponse")
    func serverError() {
        #expect(QuotaHTTP.failureReason(for: 500) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 502) == .badResponse)
        #expect(QuotaHTTP.failureReason(for: 503) == .badResponse)
    }
}

// MARK: - QuotaHTTP.get

@Suite("QuotaHTTP.get")
struct QuotaHTTPGetTests {

    @Test("invalid URL throws badResponse")
    func invalidURL() async throws {
        do {
            _ = try await QuotaHTTP.get(url: "", auth: .none)
            Issue.record("expected throw for empty URL string")
        } catch let error as ProviderError {
            #expect(error.reason == .badResponse)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("non-HTTP response throws badResponse")
    func nonHTTPResponseThrows() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NonHTTPResponseProtocol.self]
        let session = URLSession(configuration: config)

        await QuotaHTTP.$session.withValue(session) {
            do {
                _ = try await QuotaHTTP.get(url: "https://example.com/data", auth: .none)
                Issue.record("expected throw for non-HTTP response")
            } catch let error as ProviderError {
                #expect(error.reason == .badResponse)
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }
}

/// URLProtocol that returns a non-HTTPURLResponse.
private final class NonHTTPResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = URLResponse(
            url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - The shipped session

/// Asserted against `defaultConfiguration()` rather than
/// `makeDefaultSession()`: under a test host that returns the blocked session,
/// whose configuration says nothing about what the app ships.
@Suite("QuotaHTTP default session")
struct QuotaHTTPDefaultSessionTests {

    /// Regression: the session is `.ephemeral`, which does not mean
    /// cache-less — it keeps an in-memory `URLCache`. A replayed response is
    /// indistinguishable from a fresh one, so a provider that answered ten
    /// minutes ago was re-read as a reading *now* (stamped with the current
    /// time), and a cached 429 reported a throttle the vendor never just sent.
    /// Proven red by dropping either line from `defaultConfiguration()`.
    @Test("no provider request can be served from a cache")
    func neverServesCachedResponses() {
        let config = QuotaHTTP.defaultConfiguration()
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.urlCache == nil)
    }

    @Test("the shipping identity and timeouts are unchanged")
    func shippingIdentityAndTimeouts() {
        let config = QuotaHTTP.defaultConfiguration()
        #expect(config.timeoutIntervalForRequest == 4.0)
        #expect(config.timeoutIntervalForResource == 8.0)
        #expect(config.waitsForConnectivity == false)
        #expect(config.httpAdditionalHeaders?["User-Agent"] as? String == AppInfo.userAgent)
    }
}
