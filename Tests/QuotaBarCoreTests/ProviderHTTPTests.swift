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
        var suspend: Bool = false
        var responseGate: HTTPResponseGate?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Stubbed)?
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var _failNextRequest = false
    nonisolated(unsafe) private static var _nextFailureCode: URLError.Code?

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
        _failNextRequest = false
        _nextFailureCode = nil
    }

    static var failNextRequest: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failNextRequest }
        set { lock.lock(); defer { lock.unlock() }; _failNextRequest = newValue }
    }

    static var nextFailureCode: URLError.Code? {
        get { lock.lock(); defer { lock.unlock() }; return _nextFailureCode }
        set { lock.lock(); defer { lock.unlock() }; _nextFailureCode = newValue }
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
        let shouldFail: Bool
        let failureCode: URLError.Code?
        Self.lock.lock()
        Self._requestCount += 1
        Self._capturedRequests.append(request)
        handler = Self._handler
        shouldFail = Self._failNextRequest
        Self._failNextRequest = false
        failureCode = Self._nextFailureCode
        Self._nextFailureCode = nil
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(failureCode ?? .cannotFindHost))
            return
        }

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = handler(request)
        // Deliberately never answers. The provider must cancel the request at
        // its own deadline; URLSession's real network timeout is not the test.
        if stub.suspend { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        let deliver = {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = stub.responseGate {
            gate.hold(deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

/// Holds a real stubbed URLSession response until the test releases it. The
/// signal fires only after delivery is installed, so cancellation always
/// precedes the response, without sleeping or racing a short request budget.
final class HTTPResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: (() -> Void)?
    private let held = AsyncStream<Void>.makeStream()

    func hold(_ delivery: @escaping () -> Void) {
        lock.lock()
        self.delivery = delivery
        lock.unlock()
        held.continuation.yield(())
        held.continuation.finish()
    }

    func waitUntilHeld() async {
        for await _ in held.stream { break }
    }

    func release() {
        lock.lock()
        let deliver = delivery
        delivery = nil
        lock.unlock()
        deliver?()
    }
}

/// Builds a canned HTTP response body/status pair.
private func canned(status: Int = 200, body: String, headers: [String: String] = [:]) -> URLProtocolStub.Stubbed {
    URLProtocolStub.Stubbed(status: status, headers: headers, body: Data(body.utf8))
}

private func extractBody(from request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
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
    let session = URLProtocolStub.makeSession()
    defer { session.finishTasksAndInvalidate() }
    return try await QuotaHTTP.$session.withValue(session) {
        try await operation()
    }
}

private let githubPayload = #"""
{"resources":{"core":{"limit":5000,"remaining":4500,"reset":1700000000},"graphql":{"limit":5000,"remaining":1000,"reset":1700000500}}}
"""#

// MARK: - Suite

@Suite("HTTP-backed provider behaviour", .serialized)
struct ProviderHTTPTests {

    private let agyBothPools = #"{"groups":[{"displayName":"Gemini 4 Argon","description":"Separate on Pro","buckets":[{"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.7,"resetTime":"2099-01-09T00:00:00Z"}]},{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0}]},{"displayName":"Claude and GPT models","description":"Shared allowance","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.4,"resetTime":"2099-01-08T00:00:00Z"},{"bucketId":"3p-5h","window":"5h","remainingFraction":0.8,"resetTime":"2099-01-01T05:00:00Z"}]}]}"#

    @Test("AGY exposes Claude's shared pool independently and reuses Gemini's scoped response")
    func agyClaudeSeparateSharedPool() async throws {
        #expect(QuotaManager.defaultProviders().filter { $0.vendorId == .antigravityClaude }.count == 1)
        #expect(QuotaManager.defaultProviders().filter { $0.vendorId == .antigravityArgon }.count == 1)
        let payload = agyBothPools
        let snapshots = try await withStubbedHTTP({ request in
            if request.url!.path.hasSuffix("loadCodeAssist") {
                return canned(body: #"{"cloudaicompanionProject":"selected-project","paidTier":{"name":"Published plan"}}"#)
            }
            let body = try! JSONSerialization.jsonObject(with: extractBody(from: request)) as! [String: String]
            #expect(body == ["project": "selected-project"])
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "antigravity/cli/1.4.3")
            return canned(body: payload)
        }) {
            let manager = QuotaManager(providerFactory: {
                let batch = AntigravityRequestBatch()
                return [GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: .gemini, requests: batch),
                        GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: .claude, requests: batch),
                        GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: .argon, requests: batch)]
            })
            return await manager.forceRefresh()
        }
        #expect(URLProtocolStub.requestCount == 2)
        let claude = try #require(snapshots["antigravity_claude"])
        #expect(claude.vendorId == .antigravityClaude)
        #expect(claude.displayName == "AGY Claude/GPT")
        #expect(claude.shortVendorName == "AGY Claude/GPT")
        #expect(claude.status.confidence == .measured)
        #expect(abs(try #require(claude.row1?.primaryFraction) - 0.2) < 0.00001)
        #expect(abs(try #require(claude.row2?.primaryFraction) - 0.6) < 0.00001)
        #expect(claude.row1?.label == "5H" && claude.row2?.label == "WK")
        #expect(claude.row1?.windowLength == QuotaWindow.fiveHours)
        #expect(claude.row2?.resetsAt == ISO8601DateFormatter().date(from: "2099-01-08T00:00:00Z"))
        #expect(claude.planName == "Published plan")
        #expect(claude.auxiliaryInfo?.contains("Claude and GPT models · Shared allowance · Project: selected-project") == true)
        #expect(snapshots["gemini"]?.row1?.primaryFraction == 1)
        #expect(snapshots["claude"] == nil)
        let argon = try #require(snapshots["antigravity_argon"])
        #expect(argon.vendorId == .antigravityArgon)
        #expect(argon.displayName == "AGY Argon")
        #expect(argon.status.confidence == .measured)
        #expect(abs(try #require(argon.row1?.primaryFraction) - 0.3) < 0.00001)
        #expect(argon.row1?.label == "WK")
        #expect(argon.row1?.windowLength == QuotaWindow.week)
        #expect(argon.row1?.resetsAt == ISO8601DateFormatter().date(from: "2099-01-09T00:00:00Z"))
        #expect(argon.row2 == nil && argon.row3 == nil)
        #expect(argon.planName == "Published plan")
        #expect(argon.auxiliaryInfo == "Gemini 4 Argon · Separate on Pro · Project: selected-project")
        #expect(VendorIdentifier.antigravityClaude.displayName == claude.displayName)
    }

    @Test("Argon requires its own readable quota group, never a model mention", arguments: [
        #"{"groups":[{"displayName":"Gemini Models","description":"Includes Argon","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1}]}]}"#,
        #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"remainingFraction":1,"disabled":true}]}]}"#,
        #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"remainingFraction":1,"disabled":"false"}]}]}"#,
        #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"remainingFraction":-0.1}]}]}"#,
        #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"window":"weekly"}]}]}"#,
        #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"remainingFraction":"oops"}]}]}"#,
        #"{"groups":[{"displayName":"Argon A","buckets":[{"remainingFraction":1}]},{"displayName":"Argon B","buckets":[{"remainingFraction":0}]}]}"#
    ])
    func argonUnavailable(payload: String) async throws {
        let snapshot = try await withStubbedHTTP({ request in
            request.url!.path.hasSuffix("loadCodeAssist")
                ? canned(body: #"{"cloudaicompanionProject":"p"}"#) : canned(body: payload)
        }) {
            try await GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://cloudcode-pa.googleapis.com/v1internal:", allowance: .argon).fetchSnapshot()
        }
        #expect(URLProtocolStub.requestCount == 2)
        #expect(snapshot.vendorId == .antigravityArgon)
        #expect(snapshot.status == .unavailable(.unsupported("Antigravity reported no Argon quota")))
        #expect(snapshot.displayBars.isEmpty)
        #expect(snapshot.consumptionFraction == nil)
    }

    @Test("Argon cannot replace Gemini or invalidate Claude, even with Claude-named buckets or malformed fields", arguments: [false, true])
    func argonDoesNotMaskOtherPools(malformed: Bool) async throws {
        let bad = malformed ? #""oops""# : "0.7"
        let payload = agyBothPools.replacingOccurrences(of: "0.7", with: bad)
            .replacingOccurrences(of: "gemini-argon-wtu-weekly", with: "claude-argon-weekly")
        let result = try await withStubbedHTTP({ request in
            request.url!.path.hasSuffix("loadCodeAssist")
                ? canned(body: #"{"cloudaicompanionProject":"p"}"#) : canned(body: payload)
        }) {
            let batch = AntigravityRequestBatch()
            var snapshots: [QuotaSnapshot] = []
            for allowance: GeminiQuotaProvider.Allowance in [.gemini, .claude, .argon] {
                snapshots.append(try await GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: allowance, requests: batch).fetchSnapshot())
            }
            return snapshots
        }
        #expect(URLProtocolStub.requestCount == (malformed ? 4 : 2))
        #expect(result[0].row1?.primaryFraction == 1)
        #expect(result[1].status.confidence == .measured)
        #expect(result[2].status.confidence == (malformed ? .unavailable : .measured))
    }

    @Test("AGY Claude never borrows missing, disabled, ambiguous or malformed quota", arguments: [
        #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":1}]}]}"#,
        #"{"groups":[{"displayName":"GPT models","buckets":[{"window":"weekly","remainingFraction":1}]}]}"#,
        #"{"groups":[{"displayName":"Claude and GPT models","buckets":[{"remainingFraction":1,"disabled":true}]}]}"#,
        #"{"groups":[{"displayName":"Claude models","buckets":[{"remainingFraction":1.1}]}]}"#,
        #"{"groups":[{"displayName":"Claude models","buckets":[{"window":"5h"}]}]}"#,
        #"{"groups":[{"displayName":"Claude models","buckets":[{"remainingFraction":"oops"}]}]}"#,
        #"{"groups":[{"displayName":"Claude A","buckets":[{"remainingFraction":1}]},{"displayName":"Claude B","buckets":[{"remainingFraction":0}]}]}"#
    ])
    func agyClaudeUnavailable(payload: String) async throws {
        let snapshot = try await withStubbedHTTP({ request in
            request.url!.path.hasSuffix("loadCodeAssist")
                ? canned(body: #"{"cloudaicompanionProject":"p"}"#) : canned(body: payload)
        }) {
            try await GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://cloudcode-pa.googleapis.com/v1internal:", allowance: .claude).fetchSnapshot()
        }
        #expect(URLProtocolStub.requestCount == 2)
        #expect(snapshot.status.confidence != .measured)
        #expect(snapshot.displayBars.isEmpty)
        #expect(snapshot.consumptionFraction == nil)
    }

    @Test("AGY pools fall through absent pools and host failures, but stop on rejected credentials", arguments: [200, 404, 429, 500, 401], [GeminiQuotaProvider.Allowance.claude, .argon])
    func agyClaudeHostFallback(status: Int, allowance: GeminiQuotaProvider.Allowance) async throws {
        let payload = agyBothPools
        let snapshot = try await withStubbedHTTP({ request in
            if request.url!.path.hasSuffix("loadCodeAssist") {
                return canned(body: #"{"cloudaicompanionProject":"p"}"#)
            }
            return request.url!.host!.hasPrefix("daily-")
                ? canned(status: status, body: #"{"groups":[{"displayName":"Gemini Models"}]}"#)
                : canned(body: payload)
        }) {
            try await GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: allowance).fetchSnapshot()
        }
        #expect(URLProtocolStub.requestCount == (status == 401 ? 2 : 4))
        if status == 401 { #expect(snapshot.status == .unavailable(.credentialRejected)) }
        else { #expect(snapshot.status.confidence == .measured) }
    }

    @Test("AGY Claude hiding is independent and each pass obtains a fresh shared response")
    func agyClaudeVisibilityAndFreshPass() async throws {
        let payload = agyBothPools
        for hidden: Set<VendorIdentifier> in [[], [.gemini], [.antigravityClaude], [.antigravityArgon],
            [.gemini, .antigravityClaude], [.gemini, .antigravityArgon], [.antigravityClaude, .antigravityArgon],
            [.gemini, .antigravityClaude, .antigravityArgon]] {
            let result = try await withStubbedHTTP({ request in
                request.url!.path.hasSuffix("loadCodeAssist")
                    ? canned(body: #"{"cloudaicompanionProject":"p"}"#) : canned(body: payload)
            }) {
                let manager = QuotaManager(cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, minPollInterval: 0),
                    providerFactory: {
                        let batch = AntigravityRequestBatch()
                        return [GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: .gemini, requests: batch),
                                GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: .claude, requests: batch),
                                GeminiQuotaProvider(accessToken: "token", environment: [:], allowance: .argon, requests: batch)]
                    }, displayPreferences: { ProviderDisplayPreferences(hidden: hidden) })
                _ = await manager.forceRefresh()
                return await manager.forceRefresh()
            }
            #expect(URLProtocolStub.requestCount == (hidden.count == 3 ? 0 : 4))
            #expect((result["gemini"] != nil) == !hidden.contains(.gemini))
            #expect((result["antigravity_claude"] != nil) == !hidden.contains(.antigravityClaude))
            #expect((result["antigravity_argon"] != nil) == !hidden.contains(.antigravityArgon))
        }
    }

    private func geminiBoundedFallback(stalledPath: String) async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let outcome = try await withStubbedHTTP({ request in
            if request.url?.host == "daily-cloudcode-pa.googleapis.com",
               request.url?.path == stalledPath {
                var response = canned(body: "{}")
                response.suspend = true
                return response
            }
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"alternate-project"}"#)
            }
            #expect(extractBody(from: request) == Data(#"{"project":"alternate-project"}"#.utf8))
            return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0}]}]}"#)
        }) {
            // A missing request bound returns a normal assertion failure below,
            // rather than hanging the suite or accepting a process timeout.
            await GeminiRequestBudget.$seconds.withValue(0.2) {
                await withDeadline(seconds: 5) { try await provider.fetchSnapshot() }
            }
        }
        switch outcome {
        case .success(let snapshot):
            #expect(snapshot.status == .measured(.critical))
            #expect(snapshot.row1?.primaryFraction == 1)
            #expect(snapshot.row1?.label == "WK")
        case .failure(let reason):
            Issue.record("The alternate host must supply a reading before the outer deadline: \(reason)")
        }
        let paths = URLProtocolStub.capturedRequests.map { $0.url?.path }
        #expect(paths == (stalledPath == "/v1internal:loadCodeAssist"
            ? ["/v1internal:loadCodeAssist", "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"]
            : ["/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary", "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"]))
        #expect(URLProtocolStub.capturedRequests.suffix(2).allSatisfy {
            $0.url?.host == "cloudcode-pa.googleapis.com"
        })
    }

    @Test("Gemini bounds project lookup so the alternate host can answer")
    func geminiBoundsProjectLookup() async throws {
        try await geminiBoundedFallback(stalledPath: "/v1internal:loadCodeAssist")
    }

    @Test("Gemini bounds scoped quota so the alternate host can answer")
    func geminiBoundsScopedQuota() async throws {
        try await geminiBoundedFallback(stalledPath: "/v1internal:retrieveUserQuotaSummary")
    }

    @Test("Gemini cancellation prevents further host requests")
    func geminiCancellationStopsHostWalk() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let started = AsyncStream<Void>.makeStream()
        let result = try await withStubbedHTTP({ _ in
            started.continuation.yield(())
            var response = canned(body: "{}")
            response.suspend = true
            return response
        }) {
            let task = Task {
                try await GeminiRequestBudget.$seconds.withValue(0.2) { try await provider.fetchSnapshot() }
            }
            for await _ in started.stream { break }
            task.cancel()
            return await task.result
        }
        switch result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("A cancelled fetch must not return a reading")
        }
        #expect(URLProtocolStub.requestCount == 1)
    }

    @Test("Gemini cancellation before fetching starts no HTTP request")
    func geminiCancellationBeforeRequest() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let start = AsyncStream<Void>.makeStream()
        let result = try await withStubbedHTTP({ _ in
            canned(body: #"{"cloudaicompanionProject":"selected-project"}"#)
        }) {
            let task = Task {
                // Cancellation ends this nonthrowing wait too. Either way the
                // provider cannot start until the task is already cancelled.
                for await _ in start.stream { break }
                return try await provider.fetchSnapshot()
            }
            task.cancel()
            start.continuation.finish()
            return await task.result
        }
        switch result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("A fetch cancelled before HTTP must throw CancellationError")
        }
        #expect(URLProtocolStub.requestCount == 0)
        #expect(URLProtocolStub.capturedRequests.isEmpty)
    }

    private func geminiRejectsCancelledResponse(path: String) async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let gate = HTTPResponseGate()
        let result = try await withStubbedHTTP({ request in
            let isProject = request.url?.path == "/v1internal:loadCodeAssist"
            if !isProject {
                #expect(extractBody(from: request) == Data(#"{"project":"selected-project"}"#.utf8))
            }
            var response = canned(body: isProject
                ? #"{"cloudaicompanionProject":"selected-project"}"#
                : #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0}]}]}"#)
            if request.url?.path == path { response.responseGate = gate }
            return response
        }) {
            let task = Task {
                // The gate determines ordering. A generous bound keeps the
                // production timeout from being the mechanism under test.
                try await GeminiRequestBudget.$seconds.withValue(30) { try await provider.fetchSnapshot() }
            }
            await gate.waitUntilHeld()
            task.cancel()
            gate.release()
            return await task.result
        }
        switch result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("A response delivered after cancellation must not become a reading")
        }
        let expectedPaths = path == "/v1internal:loadCodeAssist"
            ? ["/v1internal:loadCodeAssist"]
            : ["/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"]
        #expect(URLProtocolStub.requestCount == expectedPaths.count)
        #expect(URLProtocolStub.capturedRequests.map { $0.url?.path } == expectedPaths)
        #expect(URLProtocolStub.capturedRequests.allSatisfy { $0.url?.host == "daily-cloudcode-pa.googleapis.com" })
    }

    @Test("Gemini cancellation rejects a late project response without requesting quota")
    func geminiCancellationRejectsLateProject() async throws {
        try await geminiRejectsCancelledResponse(path: "/v1internal:loadCodeAssist")
    }

    @Test("Gemini cancellation rejects a late scoped quota reading")
    func geminiCancellationRejectsLateQuota() async throws {
        try await geminiRejectsCancelledResponse(path: "/v1internal:retrieveUserQuotaSummary")
    }

    @Test("a quota transport failure preserves an independently read monthly entitlement")
    func claudeMonthlyCreditSurvivesQuotaTransportFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grant = try #require(try ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"25.00"}"#.utf8), now: now))
        let provider = ClaudeQuotaProvider(apiKey: "test-token", monthlyCredit: { _ in grant })
        let snapshot = try await withStubbedHTTP({ _ in canned(body: "{}") }) {
            URLProtocolStub.failNextRequest = true
            return try await provider.fetchSnapshot(now: now)
        }
        #expect(URLProtocolStub.requestCount == 1)
        #expect(snapshot.status == .unavailable(.offline))
        #expect(snapshot.monthlyAPICredit == grant)
        #expect(snapshot.consumptionFraction == nil)
        #expect(snapshot.apiCredits.isEmpty)
    }

    // MARK: Stub sanity

    @Test("the URLProtocol stub is actually invoked by requests")
    func stubActuallyIntercepts() async throws {
        let provider = OpenRouterProvider(apiKey: "key")
        _ = try await withStubbedHTTP({ _ in canned(body: #"{"data":{"usage":1,"limit":10}}"#) }) {
            try await provider.fetchSnapshot()
        }
        // /auth/key and /credits. The key-less /models catalog call is gone
        // with the model badges it fed.
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

    @Test("OpenAI reads banked reset credits and names them in the row note")
    func openAIResetCredits() async throws {
        let provider = OpenAIQuotaProvider(accessToken: "session-token")
        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"""
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":30,"reset_at":1787891551}},
             "credits":{"has_credits":true,"unlimited":false,"balance":"12.50"},
             "rate_limit_reset_credits":{"available_count":"2"}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }
        #expect(URLProtocolStub.requestCount == 1)
        #expect(snap.resetCreditsAvailable == 2)
        #expect(snap.auxiliaryInfo == "Live ChatGPT subscription quota · 2 reset credits banked")
        #expect(snap.resetCreditsApplicable == nil)
        #expect(snap.row1?.primaryFraction == 0.30)
    }

    /// Absent is nil, never 0 — and a credit block in a shape we did not
    /// anticipate costs only the credit count, never the usage reading.
    @Test("OpenAI without, or with malformed, reset credits keeps the reading and reports nil")
    func openAIResetCreditsAbsentOrMalformed() throws {
        let absent = try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: Data(#"""
        {"rate_limit":{"primary_window":{"used_percent":10}}}
        """#.utf8))
        #expect(absent.rate_limit_reset_credits == nil)
        #expect(absent.credits == nil)

        let malformed = try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: Data(#"""
        {"rate_limit":{"primary_window":{"used_percent":10}},
         "credits":"unexpected","rate_limit_reset_credits":{"available_count":"many"}}
        """#.utf8))
        #expect(malformed.rate_limit?.primary_window?.used_percent == 10)
        #expect(malformed.credits == nil)
        #expect(malformed.rate_limit_reset_credits?.available_count == nil)

        let numeric = try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: Data(#"""
        {"credits":{"has_credits":"true","balance":3.5},"rate_limit_reset_credits":{"available_count":1}}
        """#.utf8))
        #expect(numeric.credits?.has_credits == true)
        #expect(numeric.credits?.balance == "3.5")
        #expect(numeric.rate_limit_reset_credits?.available_count == 1)

        let provider = OpenAIQuotaProvider(accessToken: "t")
        let snap = provider.makeSnapshot(response: absent, accountPlan: nil, cliSource: "test",
                                         now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snap.resetCreditsAvailable == nil)
        #expect(snap.auxiliaryInfo == "Live ChatGPT subscription quota")
    }

    @Test("the OpenAI row note mentions credits only when at least one is available")
    func openAIResetCreditNote() {
        #expect(OpenAIQuotaProvider.auxiliaryInfo(resetCredits: nil) == "Live ChatGPT subscription quota")
        #expect(OpenAIQuotaProvider.auxiliaryInfo(resetCredits: 0) == "Live ChatGPT subscription quota")
        #expect(OpenAIQuotaProvider.auxiliaryInfo(resetCredits: 1)
                == "Live ChatGPT subscription quota · 1 reset credit banked")
        #expect(OpenAIQuotaProvider.auxiliaryInfo(resetCredits: 2, applicable: 0)
                == "Live ChatGPT subscription quota · 2 reset credits banked")
        #expect(OpenAIQuotaProvider.auxiliaryInfo(resetCredits: 2, applicable: 1)
                == "Live ChatGPT subscription quota · 2 reset credits banked · 1 redeemable now")
        // Nothing banked means nothing to say, whatever "applicable" claims.
        #expect(OpenAIQuotaProvider.auxiliaryInfo(resetCredits: 0, applicable: 1)
                == "Live ChatGPT subscription quota")
    }

    /// The live `wham/usage` shape from a Pro account (2026-10-03), credit
    /// blocks included. `balance` is decoded but its unit is unverified, so
    /// nothing may render it.
    @Test("OpenAI decodes the live Pro payload's credit blocks")
    func openAILivePayload() throws {
        let live = #"""
        {"plan_type":"pro","credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":"62500","approx_local_messages":[15625,81250],"approx_cloud_messages":[2500,15625]},"rate_limit_reset_credits":{"available_count":2,"applicable_available_count":0},"rate_limit_upsell":null,
         "rate_limit":{"primary_window":{"used_percent":40,"reset_at":1791050000,"limit_window_seconds":18000}}}
        """#
        let response = try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: Data(live.utf8))
        #expect(response.plan_type == "pro")
        #expect(response.credits == .init(has_credits: true, unlimited: false, balance: "62500"))
        #expect(response.rate_limit_reset_credits == .init(available_count: 2, applicable_available_count: 0))

        let snap = OpenAIQuotaProvider(accessToken: "t").makeSnapshot(
            response: response, accountPlan: nil, cliSource: "test",
            now: Date(timeIntervalSince1970: 1_791_040_000))
        #expect(snap.resetCreditsAvailable == 2)
        #expect(snap.resetCreditsApplicable == 0)
        #expect(snap.auxiliaryInfo == "Live ChatGPT subscription quota · 2 reset credits banked")
        #expect(!(snap.auxiliaryInfo ?? "").contains("62500"))
        #expect(snap.badgeText == "60% left")
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
        // /auth/key and /credits. The key-less /models catalog call is gone
        // with the model badges it fed.
        #expect(URLProtocolStub.requestCount == 2)
        #expect(balance == Decimal(74.75))
        // One figure, one label: the balance. `spent` is nil so the chip can
        // never print the account's lifetime usage under a "spent" label while
        // the same row's subtitle shows the balance — the shape DeepSeek's
        // balance-only row already has.
        #expect(limit == nil)
        #expect(spent == nil)
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

    @Test("Gemini requests the CLI quota pool on both project and summary requests", arguments: [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:",
        "https://cloudcode-pa.googleapis.com/v1internal:"
    ])
    func geminiCLIRequestIdentity(base: String) async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: ["FRUGALBAR_GEMINI_API_BASE": base])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"account-project","paidTier":{"name":"Google AI Pro"}}"#)
            }
            // A representative of the live response difference on 22 October
            // 2026. Changing only the User-Agent exposed Gemini's spent week;
            // the bare agent returned just the independent Claude/GPT pool.
            // Keep this literal independent of the production constant.
            let gemini = request.value(forHTTPHeaderField: "User-Agent") == "antigravity/cli/1.4.3"
                ? #"{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0,"resetTime":"2099-01-04T13:12:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"disabled":true}]},"#
                : ""
            return canned(body: """
            {"groups":[\(gemini){"displayName":"Claude and GPT models","buckets":[
              {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.5519576},
              {"bucketId":"3p-5h","window":"5h","remainingFraction":1}]}]}
            """)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "0% left")
        #expect(snap.bars.count == 1)
        #expect(snap.row1?.label == "WK")
        #expect(snap.row1?.primaryFraction == 1)
        #expect(snap.row1?.usedText == "100% used")
        #expect(snap.row1?.resetsAt == ISO8601DateFormatter().date(from: "2099-01-04T13:12:00Z"))
        #expect(snap.row2 == nil)
        #expect(snap.row3 == nil)
        #expect(URLProtocolStub.requestCount == 2)
        let requests = URLProtocolStub.capturedRequests
        #expect(requests.map(\.url?.path) == [
            "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"
        ])
        #expect(requests.allSatisfy { $0.url?.host == URL(string: base)?.host })
        let projectRequest = try #require(requests.first)
        let quotaRequest = try #require(requests.last)
        #expect(projectRequest.value(forHTTPHeaderField: "User-Agent") == "antigravity/cli/1.4.3")
        #expect(quotaRequest.value(forHTTPHeaderField: "User-Agent") == "antigravity/cli/1.4.3")
        let body = try JSONSerialization.jsonObject(with: extractBody(from: quotaRequest)) as? [String: String]
        #expect(body == ["project": "account-project"])
    }

    /// Representative reconstruction of the screenshot, not a live capture.
    /// A populated unscoped response must never suppress project selection.
    @Test("Gemini scopes a populated summary before reporting the screenshot's exhausted weekly quota")
    func geminiScopesPopulatedSummary() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"account-project","paidTier":{"name":"Google AI Pro"}}"#)
            }
            let body = (try? JSONSerialization.jsonObject(with: extractBody(from: request))) as? [String: String]
            if body?["project"] != "account-project" {
                // FrugalBar's old request path accepted these plausible values.
                return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.77},{"bucketId":"gemini-5h","window":"5h","remainingFraction":1}]}]}"#)
            }
            return canned(body: #"""
            {"groups":[
              {"displayName":"Claude and GPT models","buckets":[
                {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.552},
                {"bucketId":"3p-5h","window":"5h","remainingFraction":1}]},
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0,"resetTime":"2099-01-04T13:12:00Z"},
                {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"disabled":true}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }
        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "0% left")
        #expect(snap.planName == "Google AI Pro")
        #expect(snap.bars.count == 1)
        #expect(snap.row1?.label == "WK")
        #expect(snap.row1?.primaryFraction == 1)
        #expect(snap.row1?.usedText == "100% used")
        #expect(snap.row1?.resetsAt == ISO8601DateFormatter().date(from: "2099-01-04T13:12:00Z"))
        #expect(snap.row2 == nil)
        #expect(snap.row3 == nil)
        #expect(snap.displayBars.allSatisfy { $0.label != "5H" })
        #expect(URLProtocolStub.requestCount == 2)
        #expect(URLProtocolStub.capturedRequests.map(\.url?.path) == [
            "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary"
        ])
    }

    @Test("Gemini uses the scoped quota even when an unscoped or other-host pool is more consumed")
    func geminiScopedQuotaIsNotMaximumAcrossPools() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"selected-project"}"#)
            }
            let body = (try? JSONSerialization.jsonObject(with: extractBody(from: request))) as? [String: String]
            let selected = body?["project"] == "selected-project" && request.url?.host == "daily-cloudcode-pa.googleapis.com"
            return canned(body: selected
                ? #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.9}]}]}"#
                : #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0}]}]}"#)
        }) { try await provider.fetchSnapshot() }
        #expect(snap.status == .measured(.none))
        let fraction = try #require(snap.row1?.primaryFraction)
        #expect(abs(fraction - 0.1) < 0.000_001)
        #expect(URLProtocolStub.requestCount == 2)
        #expect(URLProtocolStub.capturedRequests.allSatisfy { $0.url?.host == "daily-cloudcode-pa.googleapis.com" })
    }

    @Test("Gemini never reads an unscoped quota when project discovery is absent or malformed")
    func geminiRequiresSelectedProject() async throws {
        for body in ["{}", #"{"cloudaicompanionProject":"  "}"#, "not json"] {
            let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://cloudcode-pa.googleapis.com/v1internal:")
            let snap = try await withStubbedHTTP({ _ in canned(body: body) }) { try await provider.fetchSnapshot() }
            #expect(snap.status.confidence == .unavailable)
            #expect(snap.bars.isEmpty)
            #expect(snap.consumptionFraction == nil)
            #expect(URLProtocolStub.requestCount == 1)
            #expect(URLProtocolStub.capturedRequests.first?.url?.path == "/v1internal:loadCodeAssist")
        }
    }

    @Test("a failed Gemini scoped quota is never replaced by a populated unscoped response")
    func geminiScopedFailureDoesNotReadUnscopedQuota() async throws {
        for status in [401, 404, 429, 503, 200] {
            let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://cloudcode-pa.googleapis.com/v1internal:")
            let snap = try await withStubbedHTTP({ request in
                if request.url?.path == "/v1internal:loadCodeAssist" {
                    return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
                }
                let body = (try? JSONSerialization.jsonObject(with: extractBody(from: request))) as? [String: String]
                if body?["project"] != nil { return canned(status: status, body: "not json") }
                return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":1}]}]}"#)
            }) { try await provider.fetchSnapshot() }
            #expect(snap.status == .unavailable(QuotaHTTP.failureReason(for: status) ?? .badResponse))
            #expect(snap.bars.isEmpty)
            #expect(URLProtocolStub.requestCount == 2)
        }
    }

    @Test("Gemini preserves scoped quota transport failures for the engine")
    func geminiScopedTransportFailureIsRethrown() async throws {
        for code in [URLError.Code.timedOut, .cannotConnectToHost] {
            let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://cloudcode-pa.googleapis.com/v1internal:")
            await #expect(throws: URLError.self) {
                try await withStubbedHTTP({ _ in
                    URLProtocolStub.nextFailureCode = code
                    URLProtocolStub.failNextRequest = true
                    return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
                }) { try await provider.fetchSnapshot() }
            }
            #expect(URLProtocolStub.requestCount == 2)
        }
    }

    @Test("disabled and invalid scoped Gemini buckets remain unavailable")
    func geminiScopedBucketsNeedReading() async throws {
        for bucket in [
            #"{"window":"5h","remainingFraction":0.5,"disabled":true}"#,
            #"{"window":"weekly","remainingFraction":1.5}"#,
            #"{"window":"weekly","remainingFraction":-0.5}"#,
            #"{"window":"weekly"}"#
        ] {
            let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://cloudcode-pa.googleapis.com/v1internal:")
            let snap = try await withStubbedHTTP({ request in
                if request.url?.path == "/v1internal:loadCodeAssist" {
                    return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
                }
                return canned(body: "{\"groups\":[{\"displayName\":\"Gemini Models\",\"buckets\":[\(bucket)]}]}")
            }) { try await provider.fetchSnapshot() }
            #expect(snap.status == .unavailable(.unsupported("Antigravity reported no Gemini quota")))
            #expect(snap.bars.isEmpty)
            #expect(snap.consumptionFraction == nil)
            #expect(URLProtocolStub.requestCount == 2)
        }
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

    @Test("Gemini uses the CLI backend rather than the unrelated full quota pool")
    func geminiUsesCLIQuotaBackend() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"account-project","paidTier":{"name":"Google AI Pro"}}"#)
            }
            // The daily backend is the measured agy pool for this account.
            return canned(body: #"""
            {"groups":[{"displayName":"Gemini Models","buckets":[
              {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.119401865},
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9908481}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }

        #expect(URLProtocolStub.requestCount == 2)
        #expect(URLProtocolStub.capturedRequests.allSatisfy {
            $0.url?.host == "daily-cloudcode-pa.googleapis.com"
        })
        #expect(snap.status == .measured(.warning))
        #expect(snap.badgeText == "12% left")
        #expect(snap.planName == "Google AI Pro")
        let weekly = try #require(snap.bars.first { $0.label == "WK" }?.primaryFraction)
        let fiveHour = try #require(snap.bars.first { $0.label == "5H" }?.primaryFraction)
        #expect(abs(weekly - 0.880598135) < 0.000_000_1)
        #expect(abs(fiveHour - 0.0091519) < 0.000_000_1)
        #expect(!QuotaAdvice.evaluate(from: [snap]).message.contains("100% remaining"))
    }

    @Test("Gemini public init uses the production quota endpoint")
    func geminiUsesProductionEndpointByDefault() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        _ = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true { return canned(body: #"{"cloudaicompanionProject":"account-project"}"#) }
            return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.5}]}]}"#)
        }) { try await provider.fetchSnapshot() }
        #expect(URLProtocolStub.capturedRequests.map(\.url?.absoluteString) == [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        ])
    }

    @Test("Gemini reports a missing configured route")
    func geminiReportsMissingRoute() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://daily-cloudcode-pa.googleapis.com/v1internal:")
        let snap = try await withStubbedHTTP({ _ in
            if URLProtocolStub.requestCount == 1 { return canned(status: 404, body: "") }
            if URLProtocolStub.requestCount == 2 { return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5}]}]}"#) }
            return canned(body: #"{"cloudaicompanionProject":"account-project","paidTier":{"name":"Google AI Pro"}}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .unavailable(.badResponse))
        #expect(URLProtocolStub.capturedRequests.count == 1)
        #expect(URLProtocolStub.capturedRequests[0].url?.host == "daily-cloudcode-pa.googleapis.com")
    }

    @Test("Gemini reports a transient configured backend failure")
    func geminiReportsTransientFailure() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://daily-cloudcode-pa.googleapis.com/v1internal:")
        let snap = try await withStubbedHTTP({ _ in
            if URLProtocolStub.requestCount == 1 { return canned(status: 503, body: "") }
            if URLProtocolStub.requestCount == 2 { return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5}]}]}"#) }
            return canned(body: #"{"cloudaicompanionProject":"account-project","paidTier":{"name":"Google AI Pro"}}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .unavailable(.badResponse))
        #expect(URLProtocolStub.capturedRequests.count == 1)
        #expect(URLProtocolStub.capturedRequests.first?.url?.host == "daily-cloudcode-pa.googleapis.com")
    }

    @Test("Gemini reports an initial configured DNS failure")
    func geminiReportsInitialTransportFailure() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", apiBaseOverride: "https://daily-cloudcode-pa.googleapis.com/v1internal:")
        await #expect(throws: URLError.self) {
            try await withStubbedHTTP({ _ in
                canned(body: "{}")
            }) {
                URLProtocolStub.failNextRequest = true
                return try await provider.fetchSnapshot()
            }
        }
        #expect(URLProtocolStub.capturedRequests.count == 1)
        #expect(URLProtocolStub.capturedRequests[0].url?.host == "daily-cloudcode-pa.googleapis.com")
    }

    /// Payload captured verbatim from a live authenticated request. The old
    /// source (`fetchAvailableModels`) exposed one `remainingFraction` per
    /// model, so the row showed a single bar and silently omitted the weekly
    /// limit — which was the binding constraint.
    @Test("Gemini renders both metered windows, shortest first")
    func geminiParsesQuota() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project","paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#)
            }
            return canned(body: #"""
            {"groups":[
              {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro",
               "buckets":[
                 {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2099-01-04T00:00:00Z","remainingFraction":0.28312185},
                 {"bucketId":"gemini-5h","window":"5h","resetTime":"2099-01-01T00:00:00Z","remainingFraction":0.845952}]},
              {"displayName":"Claude and GPT models",
               "buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.31}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }

        // Weekly is 71.7% used, so the provider warns — the pressure that was
        // invisible while only the five-hour window was read.
        #expect(snap.status == .measured(.warning))
        // Shortest window first, as every other provider renders.
        #expect(snap.row1?.label == "5H")
        #expect(snap.row2?.label == "WK")
        #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.154048) < 0.000_01)
        #expect(abs((snap.row2?.primaryFraction ?? 0) - 0.71687815) < 0.000_01)
        // The badge follows the fuller window, which is the binding one.
        #expect(snap.badgeText == "28% left")
        #expect(snap.planName == "Google AI Pro")
    }

    /// The reported bug: `daily-cloudcode-pa.googleapis.com` answered 200 with
    /// only the "Claude and GPT models" group, so the row read "Antigravity
    /// reported no Gemini quota" while the plain host served Gemini's windows
    /// for the same token. Neither host is authoritative, so both are asked —
    /// in the order the `agy` CLI and T3 Code's Antigravity probe use — and the
    /// first summary carrying a Gemini window ends the walk.
    @Test("Gemini falls through to the second host when the first has no Gemini group")
    func geminiFallsThroughToSecondHost() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                let project = request.url?.host == "daily-cloudcode-pa.googleapis.com" ? "daily-project" : "plain-project"
                return canned(body: "{\"cloudaicompanionProject\":\"\(project)\",\"paidTier\":{\"name\":\"Google AI Pro\"}}")
            }
            let body = (try? JSONSerialization.jsonObject(with: extractBody(from: request))) as? [String: String]
            let expected = request.url?.host == "daily-cloudcode-pa.googleapis.com" ? "daily-project" : "plain-project"
            guard body?["project"] == expected else { return canned(status: 401, body: "{}") }
            if request.url?.host == "daily-cloudcode-pa.googleapis.com" {
                // Exactly what the daily host returned for the reporting account.
                return canned(body: #"""
                {"groups":[{"displayName":"Claude and GPT models","buckets":[
                  {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.31},
                  {"bucketId":"3p-5h","window":"5h","remainingFraction":0.44}]}]}
                """#)
            }
            return canned(body: #"""
            {"groups":[
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2099-01-04T00:00:00Z","remainingFraction":0.28312185},
                {"bucketId":"gemini-5h","window":"5h","resetTime":"2099-01-01T00:00:00Z","remainingFraction":0.845952}]},
              {"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.31}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }

        #expect(URLProtocolStub.capturedRequests.map(\.url?.host) == [
            "daily-cloudcode-pa.googleapis.com",
            "daily-cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com"
        ])
        #expect(snap.status == .measured(.warning))
        // Gemini's own windows, not the third-party group's.
        #expect(snap.row1?.label == "5H")
        #expect(snap.row2?.label == "WK")
        #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.154048) < 0.000_01)
        #expect(abs((snap.row2?.primaryFraction ?? 0) - 0.71687815) < 0.000_01)
        // A production host is the normal case, so neither one is named as a
        // source — the plain host's windows are no more "the source" than the
        // daily host's.
        #expect(snap.cliSource == "Google OAuth")
        #expect(snap.auxiliaryInfo == "Live Antigravity subscription quota")
    }

    /// A host that fails outright does not end the walk either.
    @Test("Gemini tries the next host after a failed one")
    func geminiContinuesAfterFailedHost() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            if request.url?.host == "daily-cloudcode-pa.googleapis.com" {
                return canned(status: 503, body: "")
            }
            return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.90}]}]}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .measured(.none))
        #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.10) < 0.000_01)
        #expect(URLProtocolStub.capturedRequests.count == 4)
    }

    /// Neither host publishing a Gemini window is the one case that still reads
    /// "no Gemini quota" — and it names that, not a generic bad response.
    @Test("Gemini names the missing window only when no host publishes it")
    func geminiNeitherHostHasGemini() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            return canned(body: #"{"groups":[{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":0.31}]}]}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .unavailable(.unsupported("Antigravity reported no Gemini quota")))
        // Each host gets its own project lookup and one scoped summary.
        #expect(URLProtocolStub.requestCount == 4)
    }

    /// A bucket the vendor switched off keeps whatever fraction it last
    /// published; drawing it would report a window nothing is metered against.
    @Test("Gemini skips a disabled bucket rather than drawing its stale fraction")
    func geminiSkipsDisabledBucket() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            return canned(body: #"""
            {"groups":[{"displayName":"Gemini Models","buckets":[
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.845952},
              {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.10,"disabled":true}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.bars.count == 1)
        #expect(snap.row1?.label == "5H")
        #expect(snap.row2 == nil)
    }

    /// A group whose every bucket is switched off is no reading either, so the
    /// next host is still worth asking.
    @Test("Gemini treats an all-disabled group as no reading and asks the next host")
    func geminiAllDisabledGroupFallsThrough() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            if request.url?.host == "daily-cloudcode-pa.googleapis.com" {
                return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"disabled":true}]}]}"#)
            }
            return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.25}]}]}"#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status.confidence == .measured)
        #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.75) < 0.000_01)
    }

    /// A rejected credential is the one verdict that overrules an earlier
    /// host's transport failure. Left standing, the stale timeout would be
    /// thrown and the row would read "Vendor slow — will retry" for a token the
    /// vendor just refused — sending the user to check a connection that is
    /// fine, and losing the poll-floor exemption a corrected credential needs.
    @Test("an earlier host's transport failure does not mask a later host's credential rejection")
    func geminiRejectionOutranksStaleTransportFailure() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ _ in
            // The first host never reaches the handler: `failNextRequest` fails
            // it at the transport layer. The second one refuses the token.
            canned(status: 401, body: "{}")
        }) {
            URLProtocolStub.nextFailureCode = .timedOut
            URLProtocolStub.failNextRequest = true
            return try await provider.fetchSnapshot()
        }

        #expect(URLProtocolStub.requestCount == 2)
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    @Test("Gemini scoped quota credential rejection ends the default host walk")
    func geminiScopedRejectionEndsHostWalk() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"p"}"#)
            }
            return canned(status: 401, body: "{}")
        }) { try await provider.fetchSnapshot() }

        #expect(snap.status == .unavailable(.credentialRejected))
        #expect(URLProtocolStub.requestCount == 2)
        #expect(URLProtocolStub.capturedRequests.map { $0.url?.host } == [
            "daily-cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com",
        ])
        #expect(URLProtocolStub.capturedRequests.map { $0.url?.path } == [
            "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary",
        ])
    }

    @Test("Gemini scoped quota credential rejection clears an earlier host timeout")
    func geminiScopedRejectionOutranksStaleTransportFailure() async {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        // A thrown timeout must fail the status assertion too, rather than
        // ending the test before it checks the credential verdict.
        let snap = try? await withStubbedHTTP({ request in
            if request.url?.path == "/v1internal:loadCodeAssist" {
                return canned(body: #"{"cloudaicompanionProject":"p"}"#)
            }
            return canned(status: 401, body: "{}")
        }) {
            URLProtocolStub.nextFailureCode = .timedOut
            URLProtocolStub.failNextRequest = true
            return try await provider.fetchSnapshot()
        }

        #expect(snap?.status == .unavailable(.credentialRejected))
        #expect(URLProtocolStub.requestCount == 3)
        #expect(URLProtocolStub.capturedRequests.map { $0.url?.host } == [
            "daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com",
        ])
        #expect(URLProtocolStub.capturedRequests.map { $0.url?.path } == [
            "/v1internal:loadCodeAssist", "/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary",
        ])
    }

    /// The other half of that asymmetry: a 200 without a Gemini group does *not*
    /// overrule a host that never answered, because which host publishes the
    /// windows is exactly what differs between accounts — so it cannot stand in
    /// for one that timed out.
    @Test("a content-less answer does not overrule a host that never answered")
    func geminiContentLessAnswerDoesNotMaskTransportFailure() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token", environment: [:])
        do {
            _ = try await withStubbedHTTP({ request in
                if request.url?.path == "/v1internal:loadCodeAssist" {
                    return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
                }
                return canned(body: #"{"groups":[{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":0.31}]}]}"#)
            }) {
                URLProtocolStub.nextFailureCode = .timedOut
                URLProtocolStub.failNextRequest = true
                return try await provider.fetchSnapshot()
            }
            Issue.record("A content-less host answer must not hide the earlier timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(URLProtocolStub.requestCount == 3)
        #expect(URLProtocolStub.capturedRequests.map { $0.url?.host } == [
            "daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com",
        ])
    }

    /// The response also carries a "Claude and GPT models" group — a separate
    /// Antigravity allowance. Averaging it into a row labelled Gemini would
    /// report a number for a pool the row does not name.
    @Test("the third-party model group is not counted as Gemini")
    func geminiIgnoresThirdPartyGroup() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            return canned(body: #"""
            {"groups":[
              {"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":0.01}]},
              {"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.90}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }

        #expect(snap.bars.count == 1)
        #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.10) < 0.000_01)
        #expect(snap.status == .healthy)
    }

    /// Window lengths come from the vendor's own name for the bucket, so a
    /// pace marker is never placed against a length we assumed.
    @Test("pace markers use the window length the API names")
    func geminiWindowLengths() {
        #expect(GeminiQuotaProvider.windowLength(for: "5h") == QuotaWindow.fiveHours)
        #expect(GeminiQuotaProvider.windowLength(for: "weekly") == QuotaWindow.week)
        #expect(GeminiQuotaProvider.windowLength(for: "fortnightly") == nil)
        #expect(GeminiQuotaProvider.label(for: "5h") == "5H")
        #expect(GeminiQuotaProvider.label(for: "weekly") == "WK")
        #expect(GeminiQuotaProvider.label(for: nil) == "AG")
    }

    @Test("Gemini preserves timeout errors for the provider deadline")
    func geminiTimeoutIsRethrown() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        await #expect(throws: URLError.self) {
            try await withStubbedHTTP({ _ in canned(body: "{}") }) {
                URLProtocolStub.nextFailureCode = .timedOut
                URLProtocolStub.failNextRequest = true
                return try await provider.fetchSnapshot()
            }
        }
    }

    @Test("Gemini API base accepts documented URL forms and rejects other hosts")
    func geminiAPIBaseValidation() {
        for raw in [
            "https://daily-cloudcode-pa.googleapis.com",
            "https://daily-cloudcode-pa.googleapis.com/",
            "https://daily-cloudcode-pa.googleapis.com/v1internal",
            "https://daily-cloudcode-pa.googleapis.com/v1internal/",
            "https://daily-cloudcode-pa.googleapis.com/v1internal:"
        ] {
            let result = GeminiQuotaProvider.apiBase(from: raw)
            #expect(result.invalid == false)
            #expect(result.value == "https://daily-cloudcode-pa.googleapis.com/v1internal:")
        }
        for raw in [
            "http://daily-cloudcode-pa.googleapis.com",
            "https://example.com",
            "https://daily-cloudcode-pa.googleapis.com/other",
            "https://daily-cloudcode-pa.googleapis.com:443"
        ] {
            let result = GeminiQuotaProvider.apiBase(from: raw)
            #expect(result.value == nil)
            #expect(result.invalid == true)
        }
        #expect(GeminiQuotaProvider.apiBase(from: nil).invalid == false)
        #expect(GeminiQuotaProvider.apiBase(from: "").invalid == false)
    }

    /// Every project and quota request must keep the token out of its
    /// URL.
    @Test("Gemini keeps the token out of every request URL, not just the first")
    func geminiTokenNeverInAnyURL() async throws {
        let provider = GeminiQuotaProvider(accessToken: "super-secret-key")
        _ = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            return canned(body: #"""
            {"groups":[{"displayName":"Gemini Models","buckets":[
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5}]}]}
            """#)
        }) { try await provider.fetchSnapshot() }

        #expect(URLProtocolStub.capturedRequests.count == 2)
        for request in URLProtocolStub.capturedRequests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer super-secret-key")
            #expect(request.url?.absoluteString.contains("super-secret-key") == false)
        }
    }

    /// A well-formed response that simply carries no quota is "nothing to
    /// read", not a malformed payload.
    @Test("Gemini reports no model quota as unsupported, not a bad response")
    func geminiNoQuotaIsUnsupported() async throws {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let snap = try await withStubbedHTTP({ request in
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                return canned(body: #"{"cloudaicompanionProject":"account-project"}"#)
            }
            return canned(body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h"}]}]}"#)
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
        #expect(snap.row1?.label == "5H")
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

    /// Every OpenCode window has a known length, so all three carry a marker.
    @Test("each window gets a pace marker from its own length")
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
        #expect(snap.row1?.expectedPaceFraction != nil)
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

    /// The direct path used to send a one-token Haiku request every poll and
    /// read the rate-limit headers, spending the quota it reported. It must
    /// read the free usage endpoint instead, and never POST to /v1/messages.
    @Test("Claude reads the OAuth usage endpoint directly without a model request")
    func claudeDirectReadsUsageEndpoint() async throws {
        let body = #"{"five_hour":{"utilization":10,"resets_at":"2026-09-15T06:59:59.000000+00:00"},"seven_day":{"utilization":20,"resets_at":"2026-09-19T00:00:00+00:00"}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(URLProtocolStub.requestCount == 1)
        let request = try #require(URLProtocolStub.capturedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(snap.cliSource == "Claude OAuth usage endpoint")
        #expect(snap.row1?.primaryFraction == 0.10)
        #expect(snap.row2?.primaryFraction == 0.20)
    }

    /// Utilization has been observed as a fraction and as a percentage.
    /// Reading a percentage as a fraction would report 42% usage as 4200% and
    /// get discarded, so the provider must normalise rather than reject.
    @Test("Claude accepts percentage-scaled and fraction-scaled utilization")
    func claudeAcceptsPercentScale() async throws {
        let body = #"{"five_hour":{"utilization":42,"resets_at":null},"seven_day":{"utilization":0.88,"resets_at":null}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.row1?.primaryFraction == 0.42)
        #expect(snap.row2?.primaryFraction == 0.88)
        #expect(snap.status == .warning)
    }

    /// Badge and menu-bar urgency must be driven by the same window, or the
    /// icon goes red while the row still claims plenty of headroom.
    @Test("Claude badge reflects the fuller window, not just the weekly one")
    func claudeBadgeTracksWorstWindow() async throws {
        let body = #"{"five_hour":{"utilization":99},"seven_day":{"utilization":5}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "1% left")
    }

    /// The exact `cedar_ember` block the OAuth surface returned on 3 Oct 2026
    /// for an account that holds one full reset on claude.ai: Anthropic
    /// declines to serve grants to this surface. That must read as "no
    /// figure", never as "0 banked".
    @Test("Claude reset grants not served to the OAuth surface produce no reset-credit figure")
    func claudeGrantsNotServed() async throws {
        let body = #"{"five_hour":{"utilization":32,"resets_at":"2026-10-03T06:09:59.514943+00:00"},"seven_day":{"utilization":77,"resets_at":"2026-10-03T22:59:59.514967+00:00"},"cedar_ember":{"eligible":false,"ineligible_reason":"surface","at_limit":false,"exhausted":[],"grants":[],"next_grant_id":null,"weekly_resets_at":null,"cooldown_until":null,"event_props":null}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.status.confidence == .measured)
        #expect(snap.resetCreditsAvailable == nil)
        #expect(snap.resetCreditsApplicable == nil)
        #expect(snap.auxiliaryInfo == "Live Claude subscription quota")
    }

    /// The grant the claude.ai web session was served the same day (from a
    /// HAR of the usage page). If Anthropic ever serves it to the OAuth
    /// surface, the row carries the banked count and the usable-now count.
    @Test("Claude reset grants, when served, are summed into the reset-credit fields")
    func claudeGrantsServed() async throws {
        let body = #"{"five_hour":{"utilization":33,"resets_at":"2026-10-03T06:09:59.579123+00:00"},"seven_day":{"utilization":78,"resets_at":"2026-10-03T22:59:59.579146+00:00"},"cedar_ember":{"eligible":true,"ineligible_reason":null,"at_limit":false,"exhausted":[],"grants":[{"id":"opus55-launch-promax-20260921","label":"Claude Opus 5.5 launch: one usage-limit reset for Pro and Max","resets_total":1,"resets_left":1,"starts_at":"2026-09-22T16:00:00+00:00","ends_at":"2026-10-22T16:00:00+00:00","clears":["five_hour","seven_day","seven_day_overage_included"],"paused":false,"usable_now":true,"use_requires_limit":false,"percent_used":{"five_hour":33,"seven_day":78},"blocking":[],"arm":null},{"id":"fivehour-x","resets_total":2,"resets_left":1,"clears":["five_hour"],"usable_now":false}],"next_grant_id":"opus55-launch-promax-20260921"}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.resetCreditsAvailable == 2)
        #expect(snap.resetCreditsApplicable == 1)
        #expect(snap.auxiliaryInfo == "Live Claude subscription quota · 2 reset credits banked · 1 redeemable now")
    }

    /// A grant without its count makes the total unknowable: nil, never a
    /// partial sum.
    @Test("a Claude grant missing resets_left yields no reset-credit figure")
    func claudeGrantWithoutCount() async throws {
        let body = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_left":1,"usable_now":true},{"id":"b","clears":["five_hour"]}]}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.resetCreditsAvailable == nil)
        #expect(snap.resetCreditsApplicable == nil)
        #expect(snap.auxiliaryInfo == "Live Claude subscription quota")
    }

    /// A malformed grant entry must not take the usage windows down with it.
    @Test("a malformed cedar_ember block never breaks the Claude usage reading")
    func claudeGrantsMalformed() async throws {
        let body = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"cedar_ember":"nope"}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.status.confidence == .measured)
        #expect(snap.row1?.primaryFraction == 0.10)
        #expect(snap.resetCreditsAvailable == nil)
    }

    /// A 200 whose body is not the usage shape must not render as health.
    @Test("Claude direct path treats an undecodable body as a bad response")
    func claudeDirectBadBody() async throws {
        let snap = try await withStubbedHTTP({ _ in canned(body: "{}") }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
        #expect(snap.consumptionFraction == nil)
    }

    @Test("Claude direct path maps 401 to credential rejected")
    func claudeDirect401() async throws {
        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await ClaudeQuotaProvider(apiKey: "expired").fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    /// A model-scoped weekly window caps one model, not the plan. Every bar in
    /// a snapshot is read as plan-wide (exhaustion sorting, advice's worst
    /// bar, the `displayBars` collapse), so a spent Opus window must not
    /// become a bar: it would mark the row exhausted and hide the 5-hour
    /// bucket while the badge still reads "80% left".
    @Test("Claude keeps a spent Opus weekly window out of the plan-wide bars")
    func claudeModelWeeklyWindowIsNotPlanWide() async throws {
        let body = #"{"five_hour":{"utilization":5},"seven_day":{"utilization":20},"seven_day_opus":{"utilization":100}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.row3 == nil)
        #expect(snap.isQuotaExhausted == false)
        #expect(snap.displayBars.map(\.label).contains("5H"))
        let worst = snap.quotaBars.compactMap(\.primaryFraction).max()
        #expect(worst == 0.20)
        #expect(snap.status == .measured(.none))
        #expect(snap.badgeText == "80% left")
    }

    /// One reshaped primary window must not discard the other, healthy one.
    @Test("Claude keeps the weekly reading when the 5-hour window is malformed")
    func claudeMalformedPrimaryWindow() async throws {
        let body = #"{"five_hour":{"utilization":null},"seven_day":{"utilization":20}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.row1 == nil)
        #expect(snap.row2?.primaryFraction == 0.20)
        #expect(snap.status == .measured(.none))

        let flipped = #"{"five_hour":{"utilization":10},"seven_day":"reshaped"}"#
        let other = try await withStubbedHTTP({ _ in canned(body: flipped) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(other.row1?.primaryFraction == 0.10)
        #expect(other.row2 == nil)
    }

    /// The model windows are supplementary: a null or reshaped one must not
    /// throw away the 5-hour and weekly readings.
    @Test("Claude ignores a null or malformed model window")
    func claudeMalformedModelWindow() async throws {
        let body = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"seven_day_opus":null,"seven_day_sonnet":{"utilization":"n/a"}}"#
        let snap = try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
        #expect(snap.row1?.primaryFraction == 0.10)
        #expect(snap.row2?.primaryFraction == 0.20)
        #expect(snap.row3 == nil)
    }

    /// When Claude CLI is routed through LiteLLM/CLIProxyAPI, the session consuming
    /// tokens lives in CLIProxyAPI on the LAN server. Probing local Keychain credentials
    /// completely misses the active session. ClaudeQuotaProvider must query CLIProxyAPI's
    /// management endpoints (/v0/management/auth-files and /v0/management/api-call)
    /// to obtain live Claude OAuth quota.
    @Test("Claude queries CLIProxyAPI management endpoints and parses live usage")
    func claudeQueriesCLIProxyManagement() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-secret-key"
        )
        let provider = ClaudeQuotaProvider(cliProxyConfig: config)

        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-secret-key")
                return canned(body: #"""
                {
                  "files": [
                    {
                      "id": "claude-test-user",
                      "auth_index": "claude_idx_123",
                      "provider": "claude",
                      "email": "user@example.com",
                      "disabled": false
                    }
                  ]
                }
                """#)
            }
            if request.url?.path == "/v0/management/api-call" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-secret-key")
                let bodyData = extractBody(from: request)
                let json = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                #expect(json["auth_index"] as? String == "claude_idx_123")
                #expect(json["url"] as? String == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
                #expect(json["method"] as? String == "GET")

                return canned(body: #"""
                {
                  "status_code": 200,
                  "body": "{\"five_hour\":{\"utilization\":1.0,\"resets_at\":\"2026-09-15T06:59:59.000000+00:00\"},\"seven_day\":{\"utilization\":0.23,\"resets_at\":\"2026-09-19T00:00:00.000000+00:00\"}}"
                }
                """#)
            }
            return canned(status: 404, body: "not found")
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(URLProtocolStub.requestCount == 2)
        #expect(snap.status == .measured(.critical))
        #expect(snap.cliSource == "CLI Proxy (hub.test)")
        #expect(snap.badgeText == "0% left")
        #expect(snap.row1?.label == "5H")
        #expect(snap.row1?.primaryFraction == 1.0)
        #expect(snap.row2?.label == "WK")
        #expect(snap.row2?.primaryFraction == 0.23)
        #expect(snap.resetsAt != nil)
    }

    @Test("Claude CLI Proxy maps 401 credential rejection")
    func claudeCLIProxy401() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "bad-key"
        )
        let provider = ClaudeQuotaProvider(cliProxyConfig: config)

        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "Unauthorized") }) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.status == .unavailable(.credentialRejected))
    }

    @Test("Claude CLI Proxy with no Claude account falls back to not configured")
    func claudeCLIProxyNoAccount() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-key"
        )
        let provider = ClaudeQuotaProvider(cliProxyConfig: config)

        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"files":[{"provider":"codex","auth_index":"idx1"}]}"#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.status == .unavailable(.notConfigured))
    }

    /// The reported bug. Anthropic throttles its usage endpoint per account
    /// token, and the CLI Proxy's Claude token sat at 429 for a whole day with
    /// `Retry-After: 2377` while this Mac's own Claude token answered the same
    /// endpoint 200. The provider returned the proxy's failure as its own
    /// answer, so the row read "Rate limited" with no bars all day — one
    /// credential's failure reported against another.
    @Test("a proxy-side 429 does not mask a working direct Claude token")
    func claudeProxyRateLimitFallsThroughToDirectToken() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-key"
        )
        let provider = ClaudeQuotaProvider(
            cliProxyConfig: config, directCredential: { "direct-claude-token" })

        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"""
                {"files":[{"provider":"claude","auth_index":"claude_idx","disabled":false}]}
                """#)
            }
            if request.url?.path == "/v0/management/api-call" {
                // What the proxy relays for a throttled account: the vendor's
                // own 429 and its Retry-After, inside the wrapper.
                return canned(body: #"""
                {"status_code":429,"header":{"Retry-After":["2377"]},
                 "body":"{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Rate limited. Please try again later.\"}}"}
                """#)
            }
            // The direct token path. This is the request the fix must reach.
            #expect(request.url?.host == "api.anthropic.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer direct-claude-token")
            return canned(body: #"""
            {"five_hour":{"utilization":53.0,"resets_at":"2026-10-13T13:40:00+00:00"},
             "seven_day":{"utilization":8.0,"resets_at":"2026-10-17T23:00:00+00:00"}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(URLProtocolStub.requestCount == 3)
        #expect(snap.status == .measured(.none))
        #expect(snap.cliSource == "Claude OAuth usage endpoint")
        #expect(snap.row1?.label == "5H")
        #expect(snap.row1?.primaryFraction == 0.53)
        #expect(snap.row2?.primaryFraction == 0.08)
    }

    @Test("a direct success retains the proxy throttle across automatic provider rebuilds")
    func claudeProxyCooldownSurvivesDirectSuccess() async throws {
        let config = CLIProxyConfig(url: try #require(URL(string: "http://hub.test:8317")),
                                    managementKey: "test-management")
        let backoff = ClaudeProxyBackoff()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"{"files":[{"provider":"claude","auth_index":"test-index"}]}"#)
            }
            if request.url?.path == "/v0/management/api-call" {
                return canned(body: #"{"status_code":429,"header":{"Retry-After":["90"]},"body":"{}"}"#)
            }
            #expect(request.url?.host == "api.anthropic.com")
            return canned(body: #"{"five_hour":{"utilization":53},"seven_day":{"utilization":8}}"#)
        }) {
            // Rebuild, just as QuotaManager's factory does on each pass.
            let first = ClaudeQuotaProvider(cliProxyConfig: config,
                directCredential: { "direct-test-token" }, proxyBackoff: backoff)
            let initial = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await first.fetchSnapshot(now: now)
            }
            #expect(initial.status == .measured(.none))
            #expect(URLProtocolStub.requestCount == 3)
            let rebuilt = ClaudeQuotaProvider(cliProxyConfig: config,
                directCredential: { "direct-test-token" }, proxyBackoff: backoff)
            let second = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await rebuilt.fetchSnapshot(now: now.addingTimeInterval(60))
            }
            #expect(second.status == .measured(.none))
            #expect(second.staleReading == nil)
            #expect(URLProtocolStub.requestCount == 4)
            // At the exact vendor deadline, the proxy becomes eligible again.
            _ = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await rebuilt.fetchSnapshot(now: now.addingTimeInterval(90))
            }
            #expect(URLProtocolStub.requestCount == 7)
            // A person can probe again during the renewed cooldown.
            _ = try await rebuilt.fetchSnapshot(now: now.addingTimeInterval(91))
            #expect(URLProtocolStub.requestCount == 10)
        }
    }

    @Test("manager automatic passes retain proxy backoff while manual refresh can probe it")
    func claudeManagerPropagatesRefreshIntent() async throws {
        let config = CLIProxyConfig(url: try #require(URL(string: "http://hub.test:8317")),
                                    managementKey: "test-management")
        let backoff = ClaudeProxyBackoff()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120,
                perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: {
                [ClaudeQuotaProvider(cliProxyConfig: config,
                    directCredential: { "direct-test-token" }, proxyBackoff: backoff)]
            })
        try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"{"files":[{"provider":"claude","auth_index":"test-index"}]}"#)
            }
            if request.url?.path == "/v0/management/api-call" {
                return canned(body: #"{"status_code":429,"header":{"Retry-After":["90"]},"body":"{}"}"#)
            }
            #expect(request.url?.host == "api.anthropic.com")
            return canned(body: #"{"five_hour":{"utilization":53}}"#)
        }) {
            _ = await manager.refresh()
            #expect(URLProtocolStub.requestCount == 3)
            let next = await manager.refresh()
            #expect(URLProtocolStub.requestCount == 4)
            #expect(next["claude"]?.status == .measured(.none))
            _ = await manager.forceRefresh()
            #expect(URLProtocolStub.requestCount == 7)
        }
    }

    @Test("a remembered proxy throttle still permits independent direct fallback and reports failure")
    func claudeRememberedThrottleDoesNotClaimHealth() async throws {
        let config = CLIProxyConfig(url: try #require(URL(string: "http://hub.test:8317")),
                                    managementKey: "test-management")
        let backoff = ClaudeProxyBackoff()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await backoff.record(.rateLimited(retryAfter: now.addingTimeInterval(90)), config: config)
        let provider = ClaudeQuotaProvider(cliProxyConfig: config,
            directCredential: { "direct-test-token" }, proxyBackoff: backoff)
        let snapshot = try await withStubbedHTTP({ request in
            #expect(request.url?.host == "api.anthropic.com")
            return canned(status: 500, body: "{}")
        }) {
            try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await provider.fetchSnapshot(now: now)
            }
        }
        #expect(URLProtocolStub.requestCount == 1)
        #expect(snapshot.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(90))))
        #expect(snapshot.row1 == nil)
    }

    @Test("a proxy configuration change does not inherit another proxy's throttle")
    func claudeProxyCooldownConfigurationBoundary() async throws {
        let config = CLIProxyConfig(url: try #require(URL(string: "http://hub.test:8317")),
                                    managementKey: "test-management")
        let changed = CLIProxyConfig(url: config.url, managementKey: "replacement-test-management")
        let backoff = ClaudeProxyBackoff()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await backoff.record(.rateLimited(retryAfter: now.addingTimeInterval(90)), config: config)
        #expect(await backoff.retryAfter(config: changed, now: now) == nil)
        #expect(await backoff.retryAfter(config: config, now: now) == now.addingTimeInterval(90))
        #expect(await backoff.retryAfter(config: config, now: now.addingTimeInterval(90)) == nil)
        await backoff.record(nil, config: config)
        #expect(await backoff.retryAfter(config: config, now: now) == nil)
    }

    @Test("a failed manual proxy probe preserves the earlier throttle")
    func claudeFailedProbeRetainsThrottle() async throws {
        let config = CLIProxyConfig(url: try #require(URL(string: "http://hub.test:8317")),
                                    managementKey: "test-management")
        let backoff = ClaudeProxyBackoff()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let until = now.addingTimeInterval(600)
        await backoff.record(.rateLimited(retryAfter: until), config: config)
        await backoff.record(.badResponse, config: config)
        #expect(await backoff.retryAfter(config: config, now: now) == until)
        await backoff.record(.credentialRejected, config: config)
        #expect(await backoff.retryAfter(config: config, now: now) == until)
        await backoff.record(.rateLimited(retryAfter: now.addingTimeInterval(30)), config: config)
        #expect(await backoff.retryAfter(config: config, now: now) == until)
        #expect(await backoff.retryAfter(config: config, now: until) == nil)
        await backoff.record(nil, config: config)
        #expect(await backoff.retryAfter(config: config, now: now) == nil)
    }

    @Test("a direct throttle survives an earlier proxy retry deadline")
    func claudeDirectCooldownIndependentOfProxy() async throws {
        let config = CLIProxyConfig(url: try #require(URL(string: "http://hub.test:8317")),
                                    managementKey: "test-management")
        let backoff = ClaudeProxyBackoff()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = ClaudeQuotaProvider(cliProxyConfig: config,
            directCredential: { "direct-test-token" }, proxyBackoff: backoff)
        try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"{"files":[{"provider":"claude","auth_index":"test-index"}]}"#)
            }
            if request.url?.path == "/v0/management/api-call" {
                return canned(body: #"{"status_code":429,"header":{"Retry-After":["30"]},"body":"{}"}"#)
            }
            return canned(status: 429, body: "{}", headers: ["Retry-After": "600"])
        }) {
            _ = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await provider.fetchSnapshot(now: now)
            }
            #expect(URLProtocolStub.requestCount == 3)
            _ = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await provider.fetchSnapshot(now: now.addingTimeInterval(30))
            }
            // Proxy is due, direct is still cooling down. Repeated sync or
            // popover loads cannot issue the direct OAuth request early.
            #expect(URLProtocolStub.requestCount == 5)
            _ = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await provider.fetchSnapshot(now: now.addingTimeInterval(31))
            }
            #expect(URLProtocolStub.requestCount == 5)
            _ = try await QuotaFetchContext.$isUserInitiated.withValue(false) {
                try await provider.fetchSnapshot(now: now.addingTimeInterval(600))
            }
            #expect(URLProtocolStub.requestCount == 8)
            _ = try await provider.fetchSnapshot(now: now.addingTimeInterval(601))
            #expect(URLProtocolStub.requestCount == 11)
        }
        #expect(await backoff.directRetryAfter(token: "replacement-token", now: now) == nil)
    }

    /// The other half of the same rule: when there is no second credential to
    /// try, the proxy's own reason is the honest one to report — and it now
    /// carries the vendor's Retry-After instead of an unquantified "will retry".
    @Test("a proxy-side 429 with no second credential reports the vendor's Retry-After")
    func claudeProxyRateLimitWithoutDirectToken() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-key"
        )
        let provider = ClaudeQuotaProvider(cliProxyConfig: config, directCredential: { nil })
        let now = Date()

        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"{"files":[{"provider":"claude","auth_index":"claude_idx"}]}"#)
            }
            return canned(body: #"""
            {"status_code":429,"header":{"Retry-After":["2377"]},"body":"{\"error\":{\"type\":\"rate_limit_error\"}}"}
            """#)
        }) {
            try await provider.fetchSnapshot(now: now)
        }

        #expect(snap.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(2377))))
    }

    /// A relayed throttle is Anthropic's own answer, so the same policy applies
    /// through the proxy: a 403 is the vendor holding a working token back, not
    /// a key to go and check, and a 429 with no usable `Retry-After` still
    /// carries the five-minute cooldown.
    @Test("a proxy-relayed Claude throttle is reported as a rate limit, not a bad credential")
    func claudeProxyRelayed403IsAThrottle() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-key"
        )
        let provider = ClaudeQuotaProvider(cliProxyConfig: config, directCredential: { nil })
        let now = Date()

        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"{"files":[{"provider":"claude","auth_index":"claude_idx"}]}"#)
            }
            return canned(body: #"""
            {"status_code":403,"header":{"Retry-After":["0"]},"body":"{\"error\":{\"type\":\"permission_error\"}}"}
            """#)
        }) {
            try await provider.fetchSnapshot(now: now)
        }

        #expect(snap.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(300))))
    }

    /// A 429 direct from Anthropic carries the same instruction, and it was
    /// dropped on this path too — the Claude provider is one of the few that
    /// reads the header at all.
    @Test("the direct Claude path keeps the Retry-After from a 429")
    func claudeDirectRateLimitKeepsRetryAfter() async throws {
        let provider = ClaudeQuotaProvider(apiKey: "oauth-token")
        let now = Date()

        let snap = try await withStubbedHTTP({ _ in
            canned(status: 429, body: #"{"error":{"type":"rate_limit_error"}}"#, headers: ["Retry-After": "90"])
        }) {
            try await provider.fetchSnapshot(now: now)
        }

        #expect(snap.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(90))))
    }

    /// Anthropic answers this endpoint's throttle with `Retry-After: 0`, and a
    /// non-positive delta is "no instruction" to `QuotaHTTP.retryAfterDate` —
    /// so the row carried no instant at all and the poll loop re-asked every
    /// 120 s for the whole ~40-minute window the account spends throttled.
    /// Claude Code, the client this endpoint exists for, holds off five minutes
    /// in exactly that case; the row must carry an instant again so
    /// `QuotaManager` has something to gate the automatic poll behind.
    @Test("a Claude 429 with no usable Retry-After buys the five-minute cooldown")
    func claudeDirectRateLimitUsesFiveMinuteFloor() async throws {
        let now = Date()
        for headers in [[String: String](), ["Retry-After": "0"], ["Retry-After": ""]] {
            let snap = try await withStubbedHTTP({ _ in
                canned(status: 429, body: #"{"error":{"type":"rate_limit_error"}}"#, headers: headers)
            }) {
                try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot(now: now)
            }
            #expect(snap.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(300))))
        }
        // And the user sees the window rather than "will retry". 300 s is five
        // minutes whatever the wall clock says when the remedy is built.
        let snap = try await withStubbedHTTP({ _ in canned(status: 429, body: "{}") }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot(now: now)
        }
        #expect(snap.status.unavailableReason?.remedy == "Vendor throttling — retry in 5 min")
    }

    /// When the vendor does say, its figure is an instruction — clamped to the
    /// hour Claude Code clamps to, so a day-long value cannot park the row.
    @Test("a Claude 429 honours the vendor's Retry-After up to the one-hour cap")
    func claudeDirectRateLimitHonoursRetryAfterUpToCap() async throws {
        let now = Date()
        let asked = try await withStubbedHTTP({ _ in
            canned(status: 429, body: "{}", headers: ["Retry-After": "2377"])
        }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot(now: now)
        }
        #expect(asked.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(2377))))

        let capped = try await withStubbedHTTP({ _ in
            canned(status: 429, body: "{}", headers: ["Retry-After": "7200"])
        }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot(now: now)
        }
        #expect(capped.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(3600))))
    }

    /// Anthropic throttles this endpoint with 403 as well as 429. Read as
    /// `credentialRejected` it was exempt from the poll floor, so a throttle
    /// was re-asked on every cycle *and* the row told the user to check a key
    /// that was working. 401 is still the rejected credential, and still
    /// exempt from the floor, because re-signing-in can fix it instantly.
    @Test("a 403 from the Claude usage endpoint is a throttle, not a rejected credential")
    func claudeDirect403IsAThrottle() async throws {
        let now = Date()
        let throttled = try await withStubbedHTTP({ _ in canned(status: 403, body: "{}") }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot(now: now)
        }
        #expect(throttled.status == .unavailable(.rateLimited(retryAfter: now.addingTimeInterval(300))))

        let rejected = try await withStubbedHTTP({ _ in canned(status: 401, body: "{}") }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot(now: now)
        }
        #expect(rejected.status == .unavailable(.credentialRejected))
    }

    @Test("OpenAI queries CLIProxyAPI management endpoints and parses live usage")
    func openaiQueriesCLIProxyManagement() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-secret-key"
        )
        let provider = OpenAIQuotaProvider(cliProxyConfig: config)

        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-secret-key")
                return canned(body: #"""
                {
                  "files": [
                    {
                      "id": "codex-test-user",
                      "auth_index": "codex_idx_123",
                      "provider": "codex",
                      "email": "user@example.com",
                      "disabled": false,
                      "id_token": {
                        "chatgpt_account_id": "acc-1234",
                        "chatgpt_plan_type": "pro"
                      }
                    }
                  ]
                }
                """#)
            }
            if request.url?.path == "/v0/management/api-call" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-secret-key")
                let bodyData = extractBody(from: request)
                let json = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                #expect(json["auth_index"] as? String == "codex_idx_123")
                #expect(json["url"] as? String == "https://chatgpt.com/backend-api/wham/usage")
                #expect(json["method"] as? String == "GET")
                let headers = json["header"] as? [String: String] ?? [:]
                #expect(headers["Chatgpt-Account-Id"] == "acc-1234")
                #expect(headers["OpenAI-Beta"] == "codex-1")

                return canned(body: #"""
                {
                  "status_code": 200,
                  "body": "{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":95.0,\"reset_at\":1789455599,\"limit_window_seconds\":18000},\"secondary_window\":{\"used_percent\":20.0,\"reset_at\":1789800000,\"limit_window_seconds\":604800}}}"
                }
                """#)
            }
            return canned(status: 404, body: "not found")
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(URLProtocolStub.requestCount == 2)
        #expect(snap.status == .measured(.critical))
        #expect(snap.cliSource == "CLI Proxy (hub.test)")
        #expect(snap.badgeText == "5% left")
        #expect(snap.row1?.label == "5H")
        #expect(snap.row1?.primaryFraction == 0.95)
        #expect(snap.row2?.label == "WK")
        #expect(snap.row2?.primaryFraction == 0.20)
        #expect(snap.resetsAt != nil)
    }

    @Test("OpenAI CLI Proxy maps 401 credential rejection")
    func openaiCLIProxy401() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "bad-key"
        )
        let provider = OpenAIQuotaProvider(cliProxyConfig: config)

        let snap = try await withStubbedHTTP({ _ in canned(status: 401, body: "Unauthorized") }) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.status == .unavailable(.credentialRejected))
    }

    @Test("OpenAI CLI Proxy with no Codex account falls back to not configured")
    func openaiCLIProxyNoAccount() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-key"
        )
        let provider = OpenAIQuotaProvider(cliProxyConfig: config)

        let snap = try await withStubbedHTTP({ _ in
            canned(body: #"{"files":[{"provider":"claude","auth_index":"idx1"}]}"#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(snap.status == .unavailable(.notConfigured))
    }

    /// The same shape as the Claude case above: the local Codex session is a
    /// separate credential from the proxy's, so one being throttled must not
    /// blank the row when the other can still be read.
    @Test("a proxy-side 429 does not mask a working direct Codex token")
    func openaiProxyRateLimitFallsThroughToDirectToken() async throws {
        let config = CLIProxyConfig(
            url: try #require(URL(string: "http://hub.test:8317")),
            managementKey: "mgmt-key"
        )
        let provider = OpenAIQuotaProvider(
            cliProxyConfig: config, directCredential: { "direct-codex-token" })

        let snap = try await withStubbedHTTP({ request in
            if request.url?.path == "/v0/management/auth-files" {
                return canned(body: #"{"files":[{"provider":"codex","auth_index":"codex_idx"}]}"#)
            }
            if request.url?.path == "/v0/management/api-call" {
                return canned(body: #"""
                {"status_code":429,"header":{"Retry-After":["120"]},"body":"{\"error\":{\"message\":\"rate limited\"}}"}
                """#)
            }
            #expect(request.url?.host == "chatgpt.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer direct-codex-token")
            return canned(body: #"""
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":85,"reset_at":1787891551}}}
            """#)
        }) {
            try await provider.fetchSnapshot()
        }

        #expect(URLProtocolStub.requestCount == 3)
        #expect(snap.status == .measured(.warning))
        #expect(snap.row1?.primaryFraction == 0.85)
    }

    // MARK: - Prepaid API credits

/// The prepaid API credit balances the vendors publish inside the same usage
/// payload as the quota. They ride the snapshot as entries of their own and
/// must never be folded into the quota, the bars, or the urgency bands.
///
/// The unit is the load-bearing part: Anthropic's legacy `extra_usage` amounts
/// are **minor units** and OpenAI's `credits.balance` is a **count of credits**.
/// Getting either scale wrong prints a number nobody measured — a $20 monthly
/// limit as $2,000, or 62,500 credits as $62,500.

    private func claudeCredits(_ extra: String) async throws -> QuotaSnapshot {
        let body = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},\#(extra)}"#
        return try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await ClaudeQuotaProvider(apiKey: "oauth-token").fetchSnapshot()
        }
    }

    private func openAI(credits: String, resetCredits: String = "") async throws -> QuotaSnapshot {
        let comma = credits.isEmpty || resetCredits.isEmpty ? "" : ","
        let body = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":10}},"credits":\#(credits)\#(comma)\#(resetCredits)}"#
        return try await withStubbedHTTP({ _ in canned(body: body) }) {
            try await OpenAIQuotaProvider(accessToken: "t", accountID: "a").fetchSnapshot()
        }
    }

    // MARK: Anthropic

    /// The older `extra_usage` block: `used_credits` and `monthly_limit` are
    /// minor units with no `decimal_places` stated, so the documented default
    /// of cents applies. 2050 minor units is $20.50, not $2,050.
    @Test("extra_usage minor units are scaled to dollars")
    func extraUsageIsMinorUnits() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"}"#)

        #expect(snap.apiCredits.count == 1)
        let entry = try #require(snap.apiCredits.first)
        #expect(entry.id == "claude.extra-usage")
        #expect(entry.vendorId == .claude)
        #expect(entry.currencyBasis == .prepaidCredit)
        #expect(entry.detail == "$200.00 monthly limit")
        guard case .currency(let balance, let limit, let spent, let code) = entry.metric else {
            Issue.record("expected a currency entry, got \(entry.metric)")
            return
        }
        #expect(balance == Decimal(string: "179.50"))
        #expect(limit == Decimal(string: "200.00"))
        // Not `used`: a spend figure under a balance label is the wrong-label
        // defect this codebase already shipped once.
        #expect(spent == nil)
        #expect(code == "USD")
    }

    /// When the payload states its own scale, that scale wins over the default.
    @Test("decimal_places overrides the cents default")
    func decimalPlacesWins() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000,"currency":"USD","decimal_places":3}"#)
        let entry = try #require(snap.apiCredits.first)
        guard case .currency(let balance, let limit, _, _) = entry.metric else {
            Issue.record("expected a currency entry")
            return
        }
        #expect(balance == Decimal(string: "3.766"))
        #expect(limit == Decimal(string: "5.000"))
    }

    /// The newer `spend` block states its own exponent per amount, so nothing
    /// is assumed at all.
    @Test("the spend block's own exponent is honoured")
    func spendBlockExponent() async throws {
        let snap = try await claudeCredits(#""spend":{"enabled":true,"used":{"amount_minor":541,"currency":"USD","exponent":2},"limit":{"amount_minor":2000,"currency":"USD","exponent":2}}"#)
        let entry = try #require(snap.apiCredits.first)
        guard case .currency(let balance, let limit, _, let code) = entry.metric else {
            Issue.record("expected a currency entry")
            return
        }
        #expect(balance == Decimal(string: "14.59"))
        #expect(limit == Decimal(string: "20.00"))
        #expect(code == "USD")
    }

    /// The two shapes have been seen side by side, and the lenient decoding
    /// exists so that one unusable block cannot cost a figure the other
    /// published. A `spend` block that is present but states no exponent for
    /// its amounts used to short-circuit the whole read and surface no credit
    /// at all.
    @Test("a spend block that states no scale falls through to extra_usage")
    func unusableSpendBlockFallsThrough() async throws {
        let snap = try await claudeCredits(#""spend":{"enabled":true,"used":{"amount_minor":541,"currency":"USD"}},"extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"}"#)
        let entry = try #require(snap.apiCredits.first)
        guard case .currency(let balance, let limit, _, _) = entry.metric else {
            Issue.record("expected the extra_usage figure, got \(entry.metric)")
            return
        }
        #expect(balance == Decimal(string: "179.50"))
        #expect(limit == Decimal(string: "200.00"))
        #expect(entry.source == "OAuth usage payload · extra_usage")
    }

    /// The same for a `spend` block the vendor switched off: a pool being off
    /// says nothing about the `extra_usage` block beside it.
    @Test("a disabled spend block falls through to extra_usage")
    func disabledSpendBlockFallsThrough() async throws {
        let snap = try await claudeCredits(#""spend":{"enabled":false,"used":{"amount_minor":541,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"}"#)
        let entry = try #require(snap.apiCredits.first)
        #expect(entry.source == "OAuth usage payload · extra_usage")
    }

    /// Provenance is the block the figure was actually read from, not a fixed
    /// label — the two blocks publish the same pool in different shapes, and a
    /// tooltip naming the wrong one is worse than naming none.
    @Test("the entry names the block that served its figure")
    func provenanceNamesTheBlock() async throws {
        let spent = try await claudeCredits(#""spend":{"enabled":true,"used":{"amount_minor":541,"currency":"USD","exponent":2},"limit":{"amount_minor":2000,"currency":"USD","exponent":2}}"#)
        #expect(spent.apiCredits.first?.source == "OAuth usage payload · spend")

        let legacy = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"}"#)
        #expect(legacy.apiCredits.first?.source == "OAuth usage payload · extra_usage")
    }

    /// A pool past its limit is the account most worth warning about, so it is
    /// drawn at zero rather than dropping out of the card. `remaining` is nil
    /// exactly when `used` has passed `limit`, and both figures here are real
    /// ones the vendor published — the no-limit case above is the one that
    /// yields nothing.
    @Test("a pool past its limit reports zero rather than vanishing")
    func overLimitPoolStillReports() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":20500,"monthly_limit":20000,"currency":"USD"}"#)
        #expect(snap.apiCredits.count == 1)
        let entry = try #require(snap.apiCredits.first)
        guard case .currency(let balance, let limit, _, _) = entry.metric else {
            Issue.record("expected a currency entry, got \(entry.metric)")
            return
        }
        // The floor `OpenRouterProvider` also puts under its credit
        // subtraction: a balance has no negative form, and "$0.00 left" is the
        // honest reading of an allowance that has been spent past its end.
        #expect(balance == 0)
        #expect(limit == Decimal(string: "200.00"))
        #expect(entry.detail == "$200.00 monthly limit")
    }

    /// A negative figure is not a balance. The derived path already refused
    /// one; a published negative is refused too rather than drawn.
    @Test("a negative promo balance yields no entry")
    func negativePromoBalanceYieldsNothing() async throws {
        let snap = try await claudeCredits(#""iguana_necktie":{"remaining_dollars":-5}"#)
        #expect(snap.apiCredits.isEmpty)
    }

    /// A pool with no published limit has only a *used* figure, and the metric
    /// has one place for a number: a balance. Printing used under a balance
    /// label would assert a fact nobody measured, so nothing is drawn.
    @Test("an uncapped extra-usage pool yields no entry")
    func uncappedPoolYieldsNothing() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":2050}"#)
        #expect(snap.apiCredits.isEmpty)
    }

    /// A pool the vendor turned off is not a stale figure.
    @Test("a disabled extra-usage pool yields no entry")
    func disabledPoolYieldsNothing() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":false,"used_credits":2050,"monthly_limit":20000}"#)
        #expect(snap.apiCredits.isEmpty)
    }

    /// `iguana_necktie` states its amounts in dollars already, so they are
    /// never scaled. Preserve the published subscription-period end as a date
    /// so the UI does not have to parse display copy or use another pool's date.
    @Test("promo credit preserves dollars and the subscription month end")
    func promoCreditIsAlreadyDollars() async throws {
        let snap = try await claudeCredits(#""iguana_necktie":{"limit_dollars":200,"used_dollars":50,"remaining_dollars":150,"resets_at":"2026-11-15T00:00:00+00:00"}"#)
        let entry = try #require(snap.apiCredits.first { $0.id == "claude.promo-credit" })
        #expect(entry.label == "Promo credit")
        #expect(entry.detail == "Subscription month ends 15 Nov 2026")
        #expect(entry.monthlyPeriodEnd == ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z"))
        #expect(entry.extendsSubscription)
        guard case .currency(let balance, let limit, let spent, _) = entry.metric else {
            Issue.record("expected a currency entry")
            return
        }
        #expect(balance == Decimal(150))
        #expect(limit == Decimal(200))
        #expect(spent == nil)
    }

    /// Both pools at once are two entries, never one merged figure: they are
    /// different money with different expiry rules.
    @Test("two pools produce two entries")
    func twoPoolsTwoEntries() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"},"iguana_necktie":{"remaining_dollars":150}"#)
        #expect(snap.apiCredits.map(\.id) == ["claude.extra-usage", "claude.promo-credit"])
        #expect(snap.apiCredits.first?.label == "Extra usage")
    }

    /// Credits never become quota: no window, no fraction, no reset.
    @Test("an Anthropic credit entry leaves the quota untouched")
    func creditLeavesQuotaAlone() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"}"#)
        #expect(snap.row1?.label == "5H")
        #expect(snap.row1?.primaryFraction == 0.10)
        #expect(snap.resetsAt == nil)
        #expect(snap.status == .measured(.none))
    }

    // MARK: OpenAI

    /// `credits.balance` is a count of API credits — the unit OpenAI's own
    /// console prints — so it is surfaced as a count and never as money.
    @Test("an OpenAI credit balance is a count, not dollars")
    func openAIBalanceIsACount() async throws {
        let snap = try await openAI(credits: #"{"has_credits":true,"unlimited":false,"balance":"62500"}"#)
        #expect(snap.apiCredits.count == 1)
        let entry = try #require(snap.apiCredits.first)
        #expect(entry.id == "openai.api-credits")
        #expect(entry.currencyBasis == nil)
        guard case .credits(let remaining, let unit) = entry.metric else {
            Issue.record("expected a credits entry, got \(entry.metric)")
            return
        }
        #expect(remaining == 62_500)
        #expect(unit == "credits")
    }

    @Test("an unlimited credit pool carries no count")
    func openAIUnlimitedHasNoCount() async throws {
        let snap = try await openAI(credits: #"{"has_credits":true,"unlimited":true,"balance":"62500"}"#)
        let entry = try #require(snap.apiCredits.first)
        guard case .credits(let remaining, _) = entry.metric else {
            Issue.record("expected a credits entry")
            return
        }
        // The vendor said the account is not metered by this figure. A count
        // there would have to be invented, so the balance is not looked at.
        #expect(remaining == nil)
    }

    @Test("an account holding no credits publishes no entry")
    func openAICreditlessAccountIsSilent() async throws {
        let snap = try await openAI(credits: #"{"has_credits":false,"unlimited":false,"balance":"0"}"#)
        #expect(snap.apiCredits.isEmpty)
    }

    @Test("a missing or unparseable credit balance publishes no entry")
    func openAIUnreadableBalanceIsSilent() async throws {
        let missing = try await openAI(credits: #"{"has_credits":true,"unlimited":false}"#)
        #expect(missing.apiCredits.isEmpty)

        let invalid = try await openAI(credits: #"{"has_credits":true,"balance":"not a number"}"#)
        #expect(invalid.apiCredits.isEmpty)
    }

    @Test("OpenAI fractional usage credits retain the published balance", arguments: [
        #""60085.4229770000""#, "60085.4229770000"
    ])
    func openAIFractionalCredits(_ balance: String) async throws {
        let snap = try await openAI(credits: #"{"has_credits":true,"unlimited":false,"balance":\#(balance)}"#)
        let entry = try #require(snap.apiCredits.first)
        guard case .credits(let remaining, let unit) = entry.metric else {
            Issue.record("expected a credits entry")
            return
        }
        #expect(remaining.map { String(describing: $0) } == "60085.422977")
        #expect(unit == "credits")
        #expect(entry.extendsSubscription)
        #expect(snap.row1?.primaryFraction == 0.10)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.status == .measured(.none))
        #expect(URLProtocolStub.requestCount == 1)
    }

    @Test("invalid credit balances are absent, never zero or unlimited", arguments: [
        "", ".5", "-1", "-0.1", "NaN", "inf", "Infinity", "1.2garbage", "1,234", "1e999",
        "123456789012345678901234567890123456789012345678901"
    ])
    func invalidCreditBalances(_ raw: String) {
        #expect(OpenAIQuotaProvider.apiCredits(from: .init(has_credits: true, unlimited: false, balance: raw)).isEmpty)
    }

    @Test("credit parsing preserves zero, decimal precision and integer compatibility")
    func exactCreditBalances() {
        #expect(OpenAIQuotaProvider.creditCount("0") == 0)
        #expect(OpenAIQuotaProvider.creditCount("62500.000") == 62_500)
        #expect(OpenAIQuotaProvider.creditCount(" 00060085.4229770000 ") == Decimal(string: "60085.422977"))
        #expect(OpenAIQuotaProvider.creditCount("0.000000000000000000000000000000001")
                == Decimal(string: "0.000000000000000000000000000000001"))
    }

    @Test("Foundation emits exact plain decimal credit text", arguments: [
        ("6.0085422977E4", "60085.422977"),
        ("0.00000000000000000000000000000000000001", "0.00000000000000000000000000000000000001"),
        ("10000000000000000000000000000000000000", "10000000000000000000000000000000000000")
    ])
    func canonicalCreditText(_ raw: String, _ expected: String) throws {
        let value = try #require(Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")))
        let canonical = NSDecimalNumber(decimal: value).stringValue
        #expect(canonical == expected)
        #expect(OpenAIQuotaProvider.creditCount(canonical) == value)
    }

    /// The credits block rides the same fetch as the quota, so it costs no
    /// extra request — the whole reason it is an entry rather than a second
    /// provider.
    @Test("the credit entry costs no extra request")
    func creditsRideTheSameFetch() async throws {
        _ = try await openAI(credits: #"{"has_credits":true,"balance":"250"}"#)
        #expect(URLProtocolStub.requestCount == 1)
    }

    // MARK: The rebuild paths

    /// `resetsAt` is a `let`, so attaching a hand-entered cycle row rebuilds
    /// the snapshot. The initializer takes no credit entries, so a rebuild that
    /// forgot to copy them would make the credits blink out of the popover
    /// whenever a cycle row is attached.
    @Test("a rebuild for a hand-entered cycle keeps the credit entries")
    func rebuildKeepsCredits() async throws {
        let snap = try await claudeCredits(#""extra_usage":{"is_enabled":true,"used_credits":2050,"monthly_limit":20000,"currency":"USD"}"#)
        #expect(!snap.apiCredits.isEmpty)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let attached = QuotaManager.attachingCycleRow(
            to: snap, cycle: SubscriptionCycle(anchorDate: now.addingTimeInterval(-86_400 * 4)), now: now)
        #expect(!attached.apiCredits.isEmpty)

        let stripped = QuotaManager.removingStaleCycleRow(from: attached)
        #expect(stripped.apiCredits == snap.apiCredits)
    }
}
