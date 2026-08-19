import Testing
import Foundation
@testable import QuotaBarCore

@Suite("GeminiProvider — Live Validation and Headers", .serialized)
struct GeminiProviderTests {

    @Test("Gemini with empty key returns notConfigured")
    func geminiEmptyKeyReturnsNotConfigured() async throws {
        let provider = GeminiQuotaProvider(apiKey: "")
        let snapshot = try await provider.fetchSnapshot()
        #expect(snapshot.status == .unavailable(.notConfigured))
    }

    @Test("Gemini passes API key in header x-goog-api-key without query string")
    func geminiSendsKeyInHeader() async throws {
        let snapshot = try await withSharedStubbedHTTP({ _ in
            SharedURLProtocolStub.StubResponse(status: 200, headers: [:], body: Data())
        }) {
            let provider = GeminiQuotaProvider(apiKey: "AIzaSyTestApiKey123456")
            return try await provider.fetchSnapshot()
        }

        #expect(snapshot.status == .healthy)
        let req = try #require(SharedURLProtocolStub.capturedRequests.first)
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaSyTestApiKey123456")
        #expect(req.url?.query == nil)
    }

    @Test("Gemini handles 401 and 429 status codes faithfully")
    func geminiErrorHandling() async throws {
        let snap401 = try await withSharedStubbedHTTP({ _ in
            SharedURLProtocolStub.StubResponse(status: 401, headers: [:], body: Data())
        }) {
            let provider = GeminiQuotaProvider(apiKey: "bad-key")
            return try await provider.fetchSnapshot()
        }
        #expect(snap401.status == .unavailable(.credentialRejected))

        let snap429 = try await withSharedStubbedHTTP({ _ in
            SharedURLProtocolStub.StubResponse(status: 429, headers: [:], body: Data())
        }) {
            let provider = GeminiQuotaProvider(apiKey: "rate-limited-key")
            return try await provider.fetchSnapshot()
        }
        #expect(snap429.status == .unavailable(.rateLimited(retryAfter: nil)))
    }
}
