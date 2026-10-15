import CryptoKit
import Foundation
import Security

/// Google's installed-app OAuth flow for sync (D§2.2.B): random `state`,
/// S256 PKCE, one scope, `access_type=offline` and `prompt=consent`.
public enum SyncOAuth {
    /// The only scope sync ever asks for.
    public static let scope = "https://www.googleapis.com/auth/drive.appdata"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// 32 bytes from the system CSPRNG, base64url without padding (43 chars).
    static func randomToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    /// The consent URL. `loginHint` is set only for the cleanup sign-in,
    /// which must come back as the account the cleanup belongs to.
    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        pkce: SyncPKCE,
        loginHint: String? = nil
    ) -> URL {
        var pairs: [(String, String)] = [
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", scope),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", SyncPKCE.method),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        if let loginHint { pairs.append(("login_hint", loginHint)) }
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = SyncFormEncoding.encode(pairs)
        return components.url!
    }

    /// The loopback callback's query, checked: the `state` must be the one this
    /// sign-in generated (compared in constant time), and a code must be there.
    static func validateCallback(_ parameters: [String: String], expectedState: String) throws -> String {
        guard let state = parameters["state"], !state.isEmpty else { throw SyncSignInError.stateMismatch }
        guard constantTimeEquals(state, expectedState) else { throw SyncSignInError.stateMismatch }
        if parameters["error"] != nil { throw SyncSignInError.denied }
        guard let code = parameters["code"], !code.isEmpty else { throw SyncSignInError.denied }
        return code
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}

/// RFC 7636 S256: the verifier is 43 characters of base64url, the challenge
/// is BASE64URL(SHA256(verifier)).
public struct SyncPKCE: Sendable, Equatable {
    public static let method = "S256"
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    public static func generate() -> SyncPKCE { SyncPKCE(verifier: SyncOAuth.randomToken()) }
}

public enum SyncSignInError: Error, Equatable, Sendable {
    /// The callback's `state` was missing or not this sign-in's.
    case stateMismatch
    /// The user declined, or the callback carried no code.
    case denied
    /// No callback within five minutes.
    case timedOut
    case cancelled
    /// The listener could not bind a loopback port.
    case listenerFailed
    case exchangeFailed(SyncRefreshFailure)
    /// Google returned no refresh token, so publishing could not continue
    /// after the access token expires.
    case noRefreshToken
    /// The refresh token was written but did not read back.
    case notPersisted
    /// A cleanup or re-sign-in came back as a different Google account.
    case wrongAccount
    case accountLookupFailed
}

// MARK: - Refresh failures (REQ-MAC-OAUTH c)

/// Why a token-endpoint call failed. The two kinds are mutually exclusive.
public enum SyncRefreshFailure: Error, Equatable, Sendable {
    /// Network errors, timeouts, any 429 (with or without an `error` field)
    /// and any 5xx. Retried with backoff.
    case transient(TransientReason)
    /// Any other 4xx: `invalid_grant`, `invalid_client`, `unauthorized_client`,
    /// `invalid_scope`, `deleted_client`, `org_internal` and the rest.
    /// Publishing stops and Settings says "Sign in again"; nothing retries.
    case terminal(status: Int, oauthError: String?)

    public enum TransientReason: Equatable, Sendable {
        case network
        case timeout
        case rateLimited(oauthError: String?)
        case server(status: Int)
        case unexpectedStatus(Int)
        case malformedResponse
    }

    public var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    /// Classifies a token-endpoint status. nil for success.
    static func classify(status: Int, body: Data) -> SyncRefreshFailure? {
        switch status {
        case 200..<300: return nil
        case 429: return .transient(.rateLimited(oauthError: oauthErrorCode(body)))
        case 400..<500: return .terminal(status: status, oauthError: oauthErrorCode(body))
        case 500..<600: return .transient(.server(status: status))
        default: return .transient(.unexpectedStatus(status))
        }
    }

    static func classify(transportError error: Error) -> SyncRefreshFailure {
        if error is SyncTimeoutError { return .transient(.timeout) }
        if let urlError = error as? URLError, urlError.code == .timedOut { return .transient(.timeout) }
        return .transient(.network)
    }

    /// The OAuth `error` string, when the body carries one as a string.
    static func oauthErrorCode(_ body: Data) -> String? {
        struct Body: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Body.self, from: body))?.error
    }
}

// MARK: - Token endpoint

struct SyncTokenResponse: Sendable, Equatable {
    let accessToken: String
    let expiresIn: TimeInterval?
    let refreshToken: String?
}

struct SyncTokenEndpoint: Sendable {
    let configuration: SyncClientConfiguration
    let transport: any SyncTransport
    let clock: any SyncClock

    func exchange(code: String, verifier: String, redirectURI: String) async -> Result<SyncTokenResponse, SyncRefreshFailure> {
        await post([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("client_id", configuration.clientID),
            ("client_secret", configuration.clientSecret),
        ])
    }

    func refresh(refreshToken: String) async -> Result<SyncTokenResponse, SyncRefreshFailure> {
        await post([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", configuration.clientID),
            ("client_secret", configuration.clientSecret),
        ])
    }

    private func post(_ pairs: [(String, String)]) async -> Result<SyncTokenResponse, SyncRefreshFailure> {
        let request = SyncHTTPRequest(
            method: "POST",
            url: SyncOAuth.tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(SyncFormEncoding.encode(pairs).utf8)
        )
        let transport = self.transport
        let response: SyncHTTPResponse
        do {
            response = try await withSyncTimeout(seconds: SyncPublisher.requestTimeout, clock: clock) {
                try await transport.send(request)
            }
        } catch {
            return .failure(SyncRefreshFailure.classify(transportError: error))
        }
        if let failure = SyncRefreshFailure.classify(status: response.status, body: response.body) {
            return .failure(failure)
        }
        struct Body: Decodable {
            let access_token: String
            let expires_in: Double?
            let refresh_token: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.body) else {
            return .failure(.transient(.malformedResponse))
        }
        return .success(SyncTokenResponse(
            accessToken: body.access_token, expiresIn: body.expires_in, refreshToken: body.refresh_token))
    }
}

// MARK: - Access tokens

/// Why Drive could not be given an access token.
public enum SyncAuthError: Error, Equatable, Sendable {
    case notSignedIn
    case refresh(SyncRefreshFailure)
}

/// Turns the Keychain's refresh token into short-lived access tokens. The
/// refresh token is read from the Keychain on each refresh and never held
/// longer than the request that uses it.
actor SyncAccessTokens {
    private let endpoint: SyncTokenEndpoint
    private let secrets: any SyncSecretStore
    private let clock: any SyncClock
    private var cached: (token: String, expiry: Date)?

    init(endpoint: SyncTokenEndpoint, secrets: any SyncSecretStore, clock: any SyncClock) {
        self.endpoint = endpoint
        self.secrets = secrets
        self.clock = clock
    }

    func invalidate() { cached = nil }

    /// A fresh token from a sign-in, so the first Drive calls need no refresh.
    func prime(_ token: String, expiresIn: TimeInterval?) {
        cached = (token, clock.now().addingTimeInterval(expiresIn ?? 3600))
    }

    func accessToken() async throws -> String {
        if let cached, cached.expiry > clock.now().addingTimeInterval(60) { return cached.token }
        guard let refreshToken = try? secrets.read(SyncSecretAccount.refreshToken) else {
            throw SyncAuthError.notSignedIn
        }
        switch await endpoint.refresh(refreshToken: refreshToken) {
        case .success(let response):
            cached = (response.accessToken, clock.now().addingTimeInterval(response.expiresIn ?? 3600))
            return response.accessToken
        case .failure(let failure):
            cached = nil
            // Google rejected this token for good. Deleting it records that
            // outside the state file, so a relaunch after a lost state write
            // cannot send it again; only a new sign-in stores another.
            if failure.isTerminal, (try? secrets.read(SyncSecretAccount.refreshToken)) == refreshToken {
                try? secrets.delete(SyncSecretAccount.refreshToken)
            }
            throw SyncAuthError.refresh(failure)
        }
    }
}
