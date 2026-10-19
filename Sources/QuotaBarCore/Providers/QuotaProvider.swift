import Foundation

/// Request intent travels with the fetch, including through the deadline task.
/// Direct provider callers retain manual-refresh semantics.
enum QuotaFetchContext {
    @TaskLocal static var isUserInitiated = true
}

// MARK: - Provider adapter protocol

public protocol QuotaProvider: Sendable {
    var vendorId: VendorIdentifier { get }
    var displayName: String { get }
    var category: MetricCategory { get }
    /// Stable identity for this provider *instance*: the cache key, the spawn
    /// key, and the key its history is recorded under.
    ///
    /// A *requirement*, not merely an extension member, and deliberately so:
    /// `QuotaManager` holds `[any QuotaProvider]`, and a member that exists
    /// only in an extension is statically dispatched through an existential —
    /// it would return the default `vendorId.rawValue` for every provider and
    /// collapse two OpenCode Go workspaces onto one cache key. Declared here,
    /// a provider that serves several independent subscriptions under one
    /// vendor — OpenCode Go workspaces — witnesses its own per-workspace key
    /// and two instances coexist instead of overwriting each other.
    var instanceID: String { get }
    func fetchSnapshot() async throws -> QuotaSnapshot
}

extension QuotaProvider {
    /// One instance per vendor by default; see the requirement above.
    public var instanceID: String { vendorId.rawValue }

    /// Returns the injected credential if there is one, otherwise resolves it
    /// from the credential store off the cooperative thread pool.
    func credential(injected: String?, for vendor: VendorIdentifier) async -> String? {
        if let injected { return injected.isEmpty ? nil : injected }
        let discovered = await CredentialStore.apiKeyAsync(for: vendor)
        return (discovered?.isEmpty ?? true) ? nil : discovered
    }

    /// Convenience for the common "we cannot read this vendor" outcome.
    func unavailable(_ reason: UnavailableReason) -> QuotaSnapshot {
        QuotaManager.unavailableSnapshot(for: self, reason: reason)
    }
}

// MARK: - Shared parsing helpers

extension String {
    /// Vendors pad plan names and tier tokens inconsistently; every provider
    /// that reads one needs this, so it is named once here.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Shared HTTP utilities

public enum QuotaHTTP {

    /// The session used for all provider requests.
    ///
    /// A task-local so tests can substitute a `URLProtocol`-backed session for
    /// the duration of a call — `QuotaHTTP.$session.withValue(stub) { ... }`.
    /// Task-locals propagate into child tasks, so this reaches providers
    /// running inside `QuotaManager`'s `TaskGroup`.
    @TaskLocal public static var session: URLSession = QuotaHTTP.makeDefaultSession()

    public static func makeDefaultSession() -> URLSession {
        #if DEBUG
        // Under a test host, refuse real network I/O rather than silently
        // performing it. A test that forgets to install a stub should fail
        // loudly, not quietly hit a vendor.
        if TestHost.isActive {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [BlockedNetworkProtocol.self]
            return URLSession(configuration: cfg)
        }
        #endif
        return URLSession(configuration: defaultConfiguration())
    }

    /// What every real provider request is made with.
    ///
    /// Split out from `makeDefaultSession()` so the policy can be asserted
    /// directly: under a test host that function returns the blocked session
    /// instead, whose configuration says nothing about what the app ships.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 8.0
        cfg.waitsForConnectivity = false
        // Every provider request must reach the vendor. An ephemeral session
        // still keeps an in-memory `URLCache`, and a replayed response is
        // indistinguishable, downstream, from a fresh one: a provider that
        // answered a 200 ten minutes ago would be re-read as a reading *now*,
        // stamped with the current time, and a cached 429 would report a
        // throttle the vendor never just sent. The unified log caught exactly
        // that — a 429 served with `cache_hit=true` — and a refresh that
        // reports a state the vendor has already moved on from is the same
        // class of bug as a stale figure: a number nobody measured just now,
        // presented as current. Nothing here is cacheable: a quota figure is
        // true only as of when the vendor said it.
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        // The app's own name and the version actually running, so a vendor's
        // access log can tell releases apart; the old "QuotaBar/1.0" named a
        // product that no longer exists at a version that never changed.
        cfg.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
        return cfg
    }

    /// How a vendor expects its credential to be presented.
    public enum Auth: Sendable {
        case none
        case bearer(String)
        /// A dedicated header, e.g. Google's `x-goog-api-key`.
        /// Preferred over a query parameter: query strings leak into proxy
        /// logs, error descriptions, and crash reports.
        case header(name: String, value: String)
    }

    /// Performs a GET and returns the body plus status code.
    /// Throws `ProviderError` with a classified reason — never raw error text,
    /// which can embed a request URL and therefore a credential.
    public static func get(
        url: String,
        headers: [String: String] = [:],
        auth: Auth = .none
    ) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw ProviderError.badResponse }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"

        switch auth {
        case .none:
            break
        case .bearer(let token):
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .header(let name, let value):
            req.setValue(value, forHTTPHeaderField: name)
        }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse
        }
        return (data, http)
    }

    /// Performs a JSON POST and returns its body plus status code. Credentials
    /// stay in request headers, never in a URL or an error string.
    public static func post(
        url: String,
        body: Data,
        headers: [String: String] = [:],
        auth: Auth = .none
    ) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw ProviderError.badResponse }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch auth {
        case .none:
            break
        case .bearer(let token):
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .header(let name, let value):
            req.setValue(value, forHTTPHeaderField: name)
        }
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        return (data, http)
    }

    /// Maps an HTTP status to a failure reason, or nil when the response is OK.
    ///
    /// `retryAfter` is the raw `Retry-After` header, when the caller has one.
    /// Without it a 429 reads as "will retry" with no idea *when* the vendor
    /// said to come back, which is exactly the instruction a client that keeps
    /// polling every 2 minutes most needs to hear.
    public static func failureReason(
        for status: Int, retryAfter: String? = nil, now: Date = Date()
    ) -> UnavailableReason? {
        switch status {
        case 200...299: nil
        case 401, 403:  .credentialRejected
        case 429:       .rateLimited(retryAfter: retryAfterDate(secondsHeader: retryAfter, now: now))
        default:        .badResponse
        }
    }

    /// The vendor's requested backoff as an absolute instant, or nil when it
    /// asked for none.
    ///
    /// Only the delta-seconds form (`Retry-After: 2377`) is honoured. The
    /// HTTP-date form is ignored rather than parsed: this figure gates the
    /// next automatic poll, and a clock skew between here and the vendor turns
    /// a date into "retry now" or "retry tomorrow" — a wrong instant is worse
    /// than no instant, as everywhere else in this codebase. A non-positive
    /// delta is no instruction at all.
    ///
    /// Delta-seconds is digits and nothing else (RFC 9110 §10.2.3).
    /// `TimeInterval(_:)` also reads "inf", "1e999", "0x1p70", "-5" and "2.5",
    /// and an infinite or 21-digit delay trapped the app: the row's remedy
    /// converts the wait to whole minutes with `Int(_:)`, which crashes past
    /// `Int.max`, and the instant held the automatic poll back for good. A
    /// longer delay than `maximumRetryAfter` is honoured as that cap, so a
    /// vendor asking for a long wait still gets one.
    public static func retryAfterDate(secondsHeader raw: String?, now: Date = Date()) -> Date? {
        guard let text = raw?.trimmed, !text.isEmpty else { return nil }
        guard text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        guard let seconds = TimeInterval(text), seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds > maximumRetryAfter ? maximumRetryAfter : seconds)
    }

    /// The longest backoff `retryAfterDate` honours: one day.
    public static let maximumRetryAfter: TimeInterval = 86_400
}

#if DEBUG
/// Fails every request. Installed as the default session under a test host so
/// an un-stubbed test cannot reach the network.
final class BlockedNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(
            domain: "QuotaBar.TestHermeticity", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Real network access from a test. Wrap the call in QuotaHTTP.$session.withValue(stub) { ... }."]
        ))
    }
    override func stopLoading() {}
}
#endif
