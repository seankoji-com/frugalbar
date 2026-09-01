import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - File-local HTTP stub
//
// Each test file gets its own URLProtocol stub so parallel suites don't
// contaminate each other's static state (see OpenRouterExtendedTests.swift).
// This one routes by URL so a single stub can answer both `/auth/key` and
// `/api/v1/models` differently within the same test.

private final class CatalogStub: URLProtocol {
    nonisolated(unsafe) private static var _authBody: String = #"{"data":{"usage":1.0,"limit":null}}"#
    nonisolated(unsafe) private static var _authStatus: Int = 200
    nonisolated(unsafe) private static var _modelsBody: String = #"{"data":[]}"#
    nonisolated(unsafe) private static var _modelsStatus: Int = 200
    nonisolated(unsafe) private static var _modelsRequestCount = 0

    static var modelsRequestCount: Int { _modelsRequestCount }

    static func configure(
        authBody: String = #"{"data":{"usage":1.0,"limit":null}}"#,
        authStatus: Int = 200,
        modelsBody: String = #"{"data":[]}"#,
        modelsStatus: Int = 200
    ) {
        _authBody = authBody
        _authStatus = authStatus
        _modelsBody = modelsBody
        _modelsStatus = modelsStatus
        _modelsRequestCount = 0
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let isModels = url.absoluteString.contains("/api/v1/models")
        if isModels { Self._modelsRequestCount += 1 }
        let status = isModels ? Self._modelsStatus : Self._authStatus
        let body = isModels ? Self._modelsBody : Self._authBody
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One `/api/v1/models` catalog entry, as a JSON fragment. `pricing` is
/// omitted entirely when `nil` so a "vendor omits the field" case can be
/// built without a null placeholder standing in for a real value.
private func modelEntry(
    id: String,
    name: String? = nil,
    contextLength: Int? = nil,
    promptPrice: String? = nil,
    completionPrice: String? = nil,
    omitPricing: Bool = false,
    outputModalities: [String] = ["text"]
) -> String {
    var fields = [#""id":"\#(id)""#]
    if let name { fields.append(#""name":"\#(name)""#) }
    if let contextLength { fields.append(#""context_length":\#(contextLength)"#) }
    if !omitPricing {
        let promptField = promptPrice.map { #""prompt":"\#($0)""# } ?? #""prompt":null"#
        let completionField = completionPrice.map { #""completion":"\#($0)""# } ?? #""completion":null"#
        fields.append(#""pricing":{\#(promptField),\#(completionField)}"#)
    }
    let modalitiesJSON = outputModalities.map { #""\#($0)""# }.joined(separator: ",")
    fields.append(#""architecture":{"output_modalities":[\#(modalitiesJSON)]}"#)
    return "{\(fields.joined(separator: ","))}"
}

private func catalogBody(_ entries: [String]) -> String {
    #"{"data":[\#(entries.joined(separator: ","))]}"#
}

/// Runs `operation` under a fresh `QuotaHTTP.session` and a fresh
/// `ModelCatalogCache.current`, so no memoised badge from a previous test can
/// leak into this one.
private func withCatalogSession<T: Sendable>(
    _ session: URLSession,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    try await QuotaHTTP.$session.withValue(session) {
        try await ModelCatalogCache.$current.withValue(ModelCatalogCache()) {
            try await operation()
        }
    }
}

@Suite("OpenRouter model catalog badges", .serialized)
struct OpenRouterModelCatalogTests {

    // MARK: - Normal case with clear winners

    @Test("free badge picks the largest-context free model; cheap badge picks the cheapest qualifying paid model")
    func clearWinners() async throws {
        let entries = [
            // Free models: two qualify, "big-free" has the larger context.
            modelEntry(id: "small-free", name: "Small Free", contextLength: 32_000,
                       promptPrice: "0", completionPrice: "0"),
            modelEntry(id: "big-free", name: "Big Free", contextLength: 128_000,
                       promptPrice: "0", completionPrice: "0"),
            // Not free: nonzero prompt price disqualifies it even though completion is 0.
            modelEntry(id: "half-free", name: "Half Free", contextLength: 999_999_999,
                       promptPrice: "0.001", completionPrice: "0"),
            // Large-context paid: two qualify (>=1M ctx, completion > 0);
            // "cheap-big" has the lower $/M completion price.
            modelEntry(id: "cheap-big", name: "Cheap Big", contextLength: 1_000_000,
                       promptPrice: "0.0000001", completionPrice: "0.00000015"),
            modelEntry(id: "pricey-big", name: "Pricey Big", contextLength: 2_000_000,
                       promptPrice: "0.0000005", completionPrice: "0.0000005"),
            // Paid but under the 1M context floor — excluded from badge 2.
            modelEntry(id: "small-paid", name: "Small Paid", contextLength: 999_999,
                       promptPrice: "0.0000001", completionPrice: "0.0000001"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.freeTierModelBadge != nil)
        #expect(snap.freeTierModelBadge?.contains("Big Free") == true)
        #expect(snap.freeTierModelBadge?.contains("128K") == true)

        #expect(snap.cheapestLargeContextModelBadge != nil)
        #expect(snap.cheapestLargeContextModelBadge?.contains("Cheap Big") == true)
        #expect(snap.cheapestLargeContextModelBadge?.contains("1M") == true)
        #expect(snap.cheapestLargeContextModelBadge?.contains("$0.15/M") == true)

        // The primary, key-based reading is unaffected by the catalog fetch.
        #expect(snap.status == .measured(.none))
    }

    // MARK: - Vendor omits the field

    @Test("empty catalog leaves both badges nil, never a fabricated default")
    func emptyCatalog() async throws {
        CatalogStub.configure(modelsBody: catalogBody([]))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.freeTierModelBadge == nil)
        #expect(snap.cheapestLargeContextModelBadge == nil)
    }

    @Test("a model missing pricing entirely is excluded from both rankings")
    func missingPricingField() async throws {
        let entries = [
            modelEntry(id: "no-pricing", name: "No Pricing", contextLength: 2_000_000, omitPricing: true),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.freeTierModelBadge == nil)
        #expect(snap.cheapestLargeContextModelBadge == nil)
    }

    @Test("a model missing context_length is excluded from both rankings")
    func missingContextLength() async throws {
        let entries = [
            modelEntry(id: "no-context", name: "No Context", contextLength: nil,
                       promptPrice: "0", completionPrice: "0"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.freeTierModelBadge == nil)
        #expect(snap.cheapestLargeContextModelBadge == nil)
    }

    // MARK: - Tie-breaking

    @Test("an audio-output model is excluded: it can never take the free badge")
    func audioModelExcluded() async throws {
        // Mirrors the real defect: Google's Lyria music generator is free with
        // a 1M context and a `text+audio` output — alphabetically first among
        // the 1M-context free models, so it used to win the free badge despite
        // being unusable as a coding model. An audio-output model must lose to
        // a text model that matches on price and context.
        let entries = [
            modelEntry(id: "google/lyria-3-clip-preview", name: "Lyria", contextLength: 1_000_000,
                       promptPrice: "0", completionPrice: "0",
                       outputModalities: ["text", "audio"]),
            modelEntry(id: "minimax/minimax-m3:free", name: "MiniMax M3", contextLength: 1_000_000,
                       promptPrice: "0", completionPrice: "0"),
            modelEntry(id: "thinkingmachines/inkling:free", name: "Inkling", contextLength: 512_000,
                       promptPrice: "0", completionPrice: "0"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.freeTierModelBadge != nil)
        #expect(snap.freeTierModelBadge?.localizedCaseInsensitiveContains("lyria") == false)
        #expect(snap.freeTierModelBadge?.contains("MiniMax M3") == true)
    }

    @Test("ties on context length break alphabetically by id for the free badge")
    func freeTieBreak() async throws {
        let entries = [
            modelEntry(id: "zebra-free", name: "Zebra Free", contextLength: 64_000,
                       promptPrice: "0", completionPrice: "0"),
            modelEntry(id: "alpha-free", name: "Alpha Free", contextLength: 64_000,
                       promptPrice: "0", completionPrice: "0"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.freeTierModelBadge?.contains("Alpha Free") == true)
    }

    @Test("ties on $/M completion price break alphabetically by id for the cheap badge")
    func cheapTieBreak() async throws {
        let entries = [
            modelEntry(id: "zebra-cheap", name: "Zebra Cheap", contextLength: 1_000_000,
                       promptPrice: "0.0000001", completionPrice: "0.0000002"),
            modelEntry(id: "alpha-cheap", name: "Alpha Cheap", contextLength: 1_500_000,
                       promptPrice: "0.0000001", completionPrice: "0.0000002"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.cheapestLargeContextModelBadge?.contains("Alpha Cheap") == true)
    }

    // MARK: - Catalog call fails while the primary call succeeds

    @Test("a failing /models call leaves badges nil without affecting the primary reading")
    func modelsCallFails() async throws {
        CatalogStub.configure(
            authBody: #"{"data":{"usage":3.5,"limit":10,"limit_remaining":6.5}}"#,
            modelsBody: "not json",
            modelsStatus: 500
        )
        let provider = OpenRouterProvider(apiKey: "key")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.freeTierModelBadge == nil)
        #expect(snap.cheapestLargeContextModelBadge == nil)
        // Primary key-based snapshot is untouched by the catalog failure.
        guard case .currency(let balance, let limit, _, _) = snap.metric else {
            Issue.record("expected .currency, got \(snap.metric)")
            return
        }
        #expect(limit == Decimal(10))
        #expect(balance == Decimal(6.5))
    }

    @Test("badges are populated even with no OpenRouter key configured")
    func noKeyStillFetchesCatalog() async throws {
        let entries = [
            modelEntry(id: "big-free", name: "Big Free", contextLength: 128_000,
                       promptPrice: "0", completionPrice: "0"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "")
        let snap = try await withCatalogSession(CatalogStub.makeSession()) {
            try await provider.fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(snap.freeTierModelBadge?.contains("Big Free") == true)
        #expect(CatalogStub.modelsRequestCount == 1)
    }

    @Test("a second fetch within the TTL reuses the memoised catalog instead of re-requesting it")
    func secondFetchWithinTTLIsMemoised() async throws {
        // Every other test in this file wraps a single fetch in its own
        // fresh withCatalogSession scope, which proves the catalog is
        // fetched at all but never proves the memoisation this TTL exists
        // for — this is the one that actually reuses the same cache scope
        // across two fetches and checks the network was hit only once.
        let entries = [
            modelEntry(id: "big-free", name: "Big Free", contextLength: 128_000,
                       promptPrice: "0", completionPrice: "0"),
        ]
        CatalogStub.configure(modelsBody: catalogBody(entries))
        let provider = OpenRouterProvider(apiKey: "key")
        let session = CatalogStub.makeSession()
        try await withCatalogSession(session) {
            let first = try await provider.fetchSnapshot()
            #expect(first.freeTierModelBadge?.contains("Big Free") == true)
            #expect(CatalogStub.modelsRequestCount == 1)

            let second = try await provider.fetchSnapshot()
            #expect(second.freeTierModelBadge?.contains("Big Free") == true)
            #expect(CatalogStub.modelsRequestCount == 1) // still 1 — served from the TTL cache
        }
    }
}
