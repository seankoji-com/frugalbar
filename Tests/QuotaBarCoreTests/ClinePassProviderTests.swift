import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - File-local HTTP stub

/// Answers every request to api.cline.bot with a responder, and records each
/// request so a test can prove the provider actually reached the stub.
private final class ClinePassStub: URLProtocol {
    struct Stubbed: Sendable {
        let status: Int
        let body: Data
    }

    nonisolated(unsafe) private static var responder: (@Sendable (URLRequest) -> Stubbed)?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    private static let lock = NSLock()

    static func install(_ responder: @escaping @Sendable (URLRequest) -> Stubbed) {
        lock.withLock {
            Self.responder = responder
            _requests = []
        }
    }

    static func remove() {
        lock.withLock { responder = nil }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClinePassStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host == "api.cline.bot" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let responder: (@Sendable (URLRequest) -> Stubbed)? = Self.lock.withLock {
            Self._requests.append(request)
            return Self.responder
        }
        guard let stub = responder?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("ClinePass provider", .serialized)
struct ClinePassProviderTests {

    /// 2026-09-25T10:00:00Z — every reset below is measured from here.
    let now = Date(timeIntervalSince1970: 1_790_330_400)

    private func fetch(
        status: Int = 200,
        body: String,
        apiKey: String = "workos:test-token"
    ) async throws -> QuotaSnapshot {
        try await fetch(apiKey: apiKey) { _ in .init(status: status, body: Data(body.utf8)) }
    }

    private func fetch(
        apiKey: String,
        responder: @escaping @Sendable (URLRequest) -> ClinePassStub.Stubbed
    ) async throws -> QuotaSnapshot {
        ClinePassStub.install(responder)
        defer { ClinePassStub.remove() }
        return try await QuotaHTTP.$session.withValue(ClinePassStub.makeSession()) {
            try await ClinePassQuotaProvider(apiKey: apiKey).fetchSnapshot(now: now)
        }
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    private func limits(_ five: String = "2", _ week: String = "57", _ month: String = "28") -> String {
        """
        {"limits":[
          {"type":"five_hour","percentUsed":\(five),"resetsAt":"\(iso(3600))"},
          {"type":"weekly","percentUsed":\(week),"resetsAt":"\(iso(2 * 86400))"},
          {"type":"monthly","percentUsed":\(month),"resetsAt":"\(iso(10 * 86400))"}
        ]}
        """
    }

    private func wrapped(_ inner: String) -> String {
        #"{"success":true,"data":"# + inner + "}"
    }

    // MARK: - Windows

    @Test("a wrapped body yields all three windows with labels, lengths, fractions and pace")
    func wrappedBody() async throws {
        let snapshot = try await fetch(body: wrapped(limits()))

        #expect(snapshot.status == .measured(.none))
        let five = try #require(snapshot.row1)
        let week = try #require(snapshot.row2)
        let month = try #require(snapshot.row3)

        #expect(five.label == "5H")
        #expect(five.windowLength == QuotaWindow.fiveHours)
        #expect(five.primaryFraction == 0.02)
        // One hour left of five: four fifths elapsed.
        #expect(abs((five.expectedPaceFraction ?? -1) - 0.8) < 1e-9)
        #expect(five.usedText == "2% used")

        #expect(week.label == "WK")
        #expect(week.windowLength == QuotaWindow.week)
        #expect(week.primaryFraction == 0.57)
        #expect(abs((week.expectedPaceFraction ?? -1) - 5.0 / 7.0) < 1e-9)

        let monthReset = now.addingTimeInterval(10 * 86400)
        let monthLength = try #require(DualBarMetrics.monthWindowLength(endingAt: monthReset))
        #expect(month.label == "MO")
        #expect(month.windowLength == monthLength)
        #expect(month.primaryFraction == 0.28)
        #expect(abs((month.expectedPaceFraction ?? -1) - (monthLength - 10 * 86400) / monthLength) < 1e-9)
        #expect(month.resetText?.hasPrefix("Resets ") == true)

        // The longest window decides the snapshot's reset.
        #expect(snapshot.resetsAt == monthReset)
        #expect(snapshot.badgeText == "43% left")
        #expect(snapshot.planName == "ClinePass")
        #expect(snapshot.metric == .subscription(tierName: "ClinePass", renewalDate: nil))
        #expect(snapshot.auxiliaryInfo == "Live ClinePass usage")
    }

    @Test("a bare body decodes the same as a wrapped one")
    func bareBody() async throws {
        let snapshot = try await fetch(body: limits())
        #expect(snapshot.row1?.primaryFraction == 0.02)
        #expect(snapshot.row2?.primaryFraction == 0.57)
        #expect(snapshot.row3?.primaryFraction == 0.28)
    }

    @Test("nanosecond reset timestamps parse")
    func nanosecondTimestamps() async throws {
        let body = #"{"limits":[{"type":"weekly","percentUsed":57,"resetsAt":"2026-09-25T14:32:27.073666206Z"}]}"#
        let snapshot = try await fetch(body: body)
        let expected = Date(timeIntervalSince1970: 1_790_346_747.073)
        let reset = try #require(snapshot.row2?.resetsAt)
        #expect(abs(reset.timeIntervalSince(expected)) < 0.001)
        #expect(ClinePassQuotaProvider.parseResetsAt("2026-09-25T14:32:27Z") != nil)
        #expect(ClinePassQuotaProvider.parseResetsAt("2026-09-25T14:32:27.5+10:00") != nil)
    }

    @Test("a window with no percentage is skipped, never drawn at 0%")
    func missingPercentSkipsRow() async throws {
        let body = """
        {"limits":[
          {"type":"five_hour","resetsAt":"\(iso(3600))"},
          {"type":"weekly","percentUsed":null,"resetsAt":"\(iso(86400))"},
          {"type":"monthly","percentUsed":"40","resetsAt":"\(iso(86400))"}
        ]}
        """
        let snapshot = try await fetch(body: body)
        #expect(snapshot.row1 == nil)
        #expect(snapshot.row2 == nil)
        #expect(snapshot.row3?.primaryFraction == 0.4)
    }

    @Test("unknown window types are ignored")
    func unknownTypesIgnored() async throws {
        let body = #"{"limits":[{"type":"daily","percentUsed":99},{"type":"weekly","percentUsed":10}]}"#
        let snapshot = try await fetch(body: body)
        #expect(snapshot.row1 == nil)
        #expect(snapshot.row2?.primaryFraction == 0.1)
        #expect(snapshot.row3 == nil)
        #expect(snapshot.status == .measured(.none))
    }

    // MARK: - Nothing to report

    @Test("an envelope with no usable window is a bad response, not a healthy reading",
          arguments: [
            #"{"success":true,"data":{"limits":[]}}"#,
            #"{"limits":[]}"#,
            #"{"limits":[{"type":"daily","percentUsed":5}]}"#,
            #"{"limits":[{"type":"weekly"}]}"#,
            #"{"success":false,"data":{"limits":[{"type":"weekly","percentUsed":5}]}}"#,
            #"{"data":null,"error":"internal error","success":false}"#,
            "not json",
          ])
    func emptyIsBadResponse(body: String) async throws {
        let snapshot = try await fetch(body: body)
        #expect(snapshot.status == .unavailable(.badResponse))
        #expect(snapshot.row1 == nil && snapshot.row2 == nil && snapshot.row3 == nil)
    }

    // MARK: - Status codes

    /// The exact body the live API returned on 2026-10-03 for an account
    /// with no ClinePass.
    static let noPlanBody = #"{"data":null,"error":"no plan history found for user","success":false}"#

    @Test("404 with the live no-plan body means the account has no ClinePass")
    func notFoundIsUnsupported() async throws {
        let snapshot = try await fetch(status: 404, body: Self.noPlanBody)
        #expect(snapshot.status == .unavailable(.unsupported("No ClinePass subscription on this account")))
        #expect(snapshot.row1 == nil)
    }

    @Test("404 is unsupported whatever its body says")
    func notFoundWithDecodableBody() async throws {
        let snapshot = try await fetch(status: 404, body: limits())
        #expect(snapshot.status == .unavailable(.unsupported("No ClinePass subscription on this account")))
        #expect(snapshot.row1 == nil)
    }

    @Test("the no-plan envelope under HTTP 200 is still unsupported, not healthy")
    func noPlanUnder200() async throws {
        let snapshot = try await fetch(status: 200, body: Self.noPlanBody)
        #expect(snapshot.status == .unavailable(.unsupported("No ClinePass subscription on this account")))
    }

    @Test("401 and 403 are a rejected credential, even with a decodable body", arguments: [401, 403])
    func rejected(status: Int) async throws {
        let snapshot = try await fetch(status: status, body: limits())
        #expect(snapshot.status == .unavailable(.credentialRejected))
        #expect(snapshot.row1 == nil)
    }

    @Test("a 5xx with a decodable body is a bad response")
    func serverError() async throws {
        let snapshot = try await fetch(status: 500, body: limits())
        #expect(snapshot.status == .unavailable(.badResponse))
    }

    // MARK: - Request

    @Test("the stub is hit once, at the usage-limits path, with the bearer credential")
    func requestShape() async throws {
        _ = try await fetch(body: limits())
        let requests = ClinePassStub.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == ClinePassQuotaProvider.usageLimitsURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer workos:test-token")
        #expect(request.url?.query == nil)
    }

    @Test("a bare credential rejected with 401 is retried once with the workos: prefix")
    func workosRetry() async throws {
        let snapshot = try await fetch(apiKey: "raw-token") { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            return auth == "Bearer workos:raw-token"
                ? .init(status: 200, body: Data(#"{"limits":[{"type":"weekly","percentUsed":5}]}"#.utf8))
                : .init(status: 401, body: Data("{}".utf8))
        }
        #expect(snapshot.status == .measured(.none))
        #expect(ClinePassStub.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == ["Bearer raw-token", "Bearer workos:raw-token"])
    }

    @Test("a plain API key that succeeds is sent once, with no prefix")
    func plainKeyNoPrefix() async throws {
        _ = try await fetch(body: limits(), apiKey: "plain-api-key")
        #expect(ClinePassStub.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == ["Bearer plain-api-key"])
    }

    @Test("an already-prefixed credential is not retried")
    func noRetryWhenPrefixed() async throws {
        let snapshot = try await fetch(status: 401, body: "{}")
        #expect(snapshot.status == .unavailable(.credentialRejected))
        #expect(ClinePassStub.requests.count == 1)
    }

    @Test("an empty injected credential is not configured and makes no request")
    func emptyKey() async throws {
        let snapshot = try await fetch(status: 200, body: limits(), apiKey: "")
        #expect(snapshot.status == .unavailable(.notConfigured))
        #expect(ClinePassStub.requests.isEmpty)
    }

    // MARK: - Urgency

    @Test("urgency follows the fullest window", arguments: [
        ("10", "69", "20", Urgency.none, "31% left"),
        ("70", "10", "20", Urgency.warning, "30% left"),
        ("10", "89", "20", Urgency.warning, "11% left"),
        ("10", "20", "90", Urgency.critical, "10% left"),
        ("100", "20", "30", Urgency.critical, "0% left"),
        ("150", "20", "30", Urgency.critical, "0% left"),
    ])
    func urgency(five: String, week: String, month: String, expected: Urgency, badge: String) async throws {
        let snapshot = try await fetch(body: limits(five, week, month))
        #expect(snapshot.status == .measured(expected))
        #expect(snapshot.badgeText == badge)
    }
}
