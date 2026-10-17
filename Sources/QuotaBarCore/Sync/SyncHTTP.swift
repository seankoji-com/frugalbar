import Foundation

/// One request to Google's token endpoint or Drive. Sync speaks to Google
/// through `SyncTransport` only, so tests substitute a fake and nothing in
/// the suite can reach the network.
public struct SyncHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Decoded query parameters. Values are for tests and decisions only;
    /// they are never logged.
    public var queryItems: [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }
}

public struct SyncHTTPResponse: Sendable {
    public var status: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public protocol SyncTransport: Sendable {
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse
}

/// The production transport: an ephemeral session with no cache, so every
/// read is Google's answer now. Under a test host it refuses all I/O, like
/// `QuotaHTTP.makeDefaultSession()`, so a test that forgets its fake fails
/// instead of contacting Google.
public struct URLSessionSyncTransport: SyncTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = SyncPublisher.requestTimeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
        #if DEBUG
        if TestHost.isActive { config.protocolClasses = [BlockedNetworkProtocol.self] }
        #endif
        session = URLSession(configuration: config)
    }

    public func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        for (key, value) in request.headers { req.setValue(value, forHTTPHeaderField: key) }
        req.httpBody = request.body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return SyncHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// `application/x-www-form-urlencoded` and query encoding that escapes
/// everything outside RFC 3986's unreserved set, so a `+` or `/` in a code or
/// token survives the round trip.
enum SyncFormEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

/// The `Date` header of an HTTP response (IMF-fixdate), or nil.
enum SyncHTTPDate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
