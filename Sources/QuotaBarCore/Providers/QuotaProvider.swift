import Foundation

// MARK: - Provider adapter protocol

public protocol QuotaProvider: Sendable {
    var vendorId: VendorIdentifier { get }
    var displayName: String { get }
    var category: MetricCategory { get }
    func fetchSnapshot() async throws -> QuotaSnapshot
}

extension QuotaProvider {
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
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 8.0
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "QuotaBar/1.0"]
        return URLSession(configuration: cfg)
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
    public static func failureReason(for status: Int) -> UnavailableReason? {
        switch status {
        case 200...299: nil
        case 401, 403:  .credentialRejected
        case 429:       .rateLimited(retryAfter: nil)
        default:        .badResponse
        }
    }
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
