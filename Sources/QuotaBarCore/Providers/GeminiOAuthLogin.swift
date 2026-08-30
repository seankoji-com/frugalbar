import AppKit
import Foundation
import Network

/// Google OAuth authorization-code flow for the configured desktop client.
/// Tokens are stored only in the macOS Keychain.
///
/// Deliberately mirrors the `antigravity-usage` CLI's flow, which is known to
/// work against this client: an ephemeral loopback port, a bare `/callback`
/// path, and a plain code exchange. It carries **no PKCE** — the earlier
/// version added `code_challenge`/`code_verifier`, and sign-in failed at the
/// exchange with nothing saved. When a reference implementation works and a
/// variant does not, match the reference.
public final class GeminiOAuthLogin: NSObject, @unchecked Sendable {
    public static let shared = GeminiOAuthLogin()

    /// How long to wait for the user to finish in the browser before giving the
    /// port back. Without this a closed browser tab wedges sign-in forever.
    private static let completionTimeout: TimeInterval = 300

    private var clientID: String? { GeminiOAuthSession.clientID }

    /// Stores the Google OAuth client this app signs in as.
    ///
    /// Kept in the Keychain rather than the source tree: the repository is
    /// public, and a committed `client_secret` is a published one.
    ///
    /// The two fields treat "blank" differently, because the UI treats them
    /// differently. The client ID field is shown pre-filled, so clearing it is
    /// a deliberate revert to the built-in client. The secret is never read
    /// back for display, so its field is *always* blank on open — clearing the
    /// stored secret on save would wipe it every time Settings was reopened.
    /// Blank there means "keep what is stored"; `clearClientSecret()` removes it.
    public static func saveClientConfiguration(clientID: String, clientSecret: String) throws {
        if let secret = secretToStore(entered: clientSecret) {
            try KeychainManager.shared.set(key: secret, label: GeminiOAuthSession.clientSecretKeychainLabel)
        }
        try store(clientID, label: GeminiOAuthSession.clientIDKeychainLabel)
    }

    /// What a submitted secret field should write, or nil for "keep what is
    /// stored". Pure, so the rule can be tested without a Keychain round-trip
    /// against the labels the running app uses.
    static func secretToStore(entered: String) -> String? {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What a submitted client-ID field should write, or nil to clear the
    /// override and fall back to the built-in client.
    static func clientIDToStore(entered: String) -> String? {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func clearClientSecret() throws {
        try KeychainManager.shared.delete(label: GeminiOAuthSession.clientSecretKeychainLabel)
    }

    /// The stored client ID, or nil when the built-in one is in use. The
    /// secret is deliberately never read back out for display.
    public static func storedClientID() -> String? {
        guard let stored = try? KeychainManager.shared.get(label: GeminiOAuthSession.clientIDKeychainLabel),
              !stored.isEmpty
        else { return nil }
        return stored
    }

    /// Whether a *user-supplied* secret overrides the vendored default.
    public static func hasClientSecretOverride() -> Bool {
        (try? KeychainManager.shared.get(label: GeminiOAuthSession.clientSecretKeychainLabel))
            .map { !$0.isEmpty } ?? false
    }

    private static func store(_ value: String, label: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainManager.shared.delete(label: label)
        } else {
            try KeychainManager.shared.set(key: trimmed, label: label)
        }
    }
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var state = ""

    public func signIn() async throws {
        // Refuse before opening a browser: without a client there is nothing to
        // sign in *as*, and Google's own error for it is unactionable.
        guard GeminiOAuthSession.isClientConfigured else { throw ProviderError.notConfigured }

        let alreadyRunning = lock.withLock { self.listener != nil }
        // Reporting success for a sign-in we never started would leave the user
        // staring at "Connected" with no token.
        guard !alreadyRunning else { throw ProviderError.badResponse }

        state = Self.randomURLSafeString()

        // Loopback only. `on: .any` binds every interface, which puts the
        // callback endpoint on the local network for the duration of sign-in.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        lock.withLock { self.listener = listener }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.handleCallback(request, connection: connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation

            // The handler must be installed before `start`: NWListener does not
            // replay its state, so a listener that reaches `.ready` first would
            // never open the browser and this call would never return.
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    self.openAuthorizationPage(port: port)
                case .failed, .cancelled:
                    self.finish(.failure(ProviderError.badResponse))
                default:
                    break
                }
            }
            listener.start(queue: .main)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.completionTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ProviderError.badResponse))
            }
        }
    }

    private func openAuthorizationPage(port: NWEndpoint.Port) {
        guard let url = Self.authorizationURL(
            clientID: clientID ?? "",
            redirectURI: Self.redirectURI(port: port),
            state: state
        ) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    static let scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"

    /// The consent URL, matching `antigravity-usage` parameter for parameter.
    ///
    /// Carries **no PKCE**. An earlier version added `code_challenge` and
    /// `code_verifier` on top of a client-secret exchange, and every sign-in
    /// died at the token step with nothing saved and nothing reported.
    static func authorizationURL(clientID: String, redirectURI: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        return components?.url
    }

    /// Fields for the authorization-code exchange. `client_id` and
    /// `client_secret` are merged in by `requestToken`, which owns the
    /// configured client.
    static func exchangeFields(code: String, redirectURI: String) -> [String: String] {
        [
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
    }

    private func handleCallback(_ request: String, connection: NWConnection) {
        let target = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first
        let url = target.flatMap { URL(string: "http://127.0.0.1\($0)") }

        // Browsers speculatively request /favicon.ico and friends on the same
        // origin. Treating those as a failed callback would abort a sign-in
        // that is still in progress.
        guard url?.path == "/callback" else {
            Self.respond(on: connection, status: "404 Not Found", body: "")
            return
        }

        let outcome = Self.callbackOutcome(request: request, expectedState: state)
        let message: String
        switch outcome {
        case .success:
            message = "<html><body><h2>FrugalBar</h2><p>You may close this window.</p></body></html>"
        case .failure:
            message = "<html><body><h2>FrugalBar</h2><p>Sign-in did not complete. You may close this window.</p></body></html>"
        }
        Self.respond(on: connection, status: "200 OK", body: message)

        switch outcome {
        case .success(let code):
            Task {
                do {
                    try await exchange(code: code)
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            }
        case .failure(let error):
            finish(.failure(error))
        }
    }

    /// The parse-and-validate half of the callback: given the raw HTTP
    /// request line and the state we generated for this sign-in, extracts the
    /// authorization code or classifies why the callback cannot be trusted.
    ///
    /// Pure and static so the CSRF check (`returnedState == expectedState`)
    /// — along with a present `error` param and a missing `code` — can be
    /// tested without standing up an `NWConnection`. Every failure path
    /// collapses to the same generic `.badResponse`: none of these is
    /// actionable by the user, and the caller never surfaces the raw
    /// difference, only whether the callback succeeded.
    static func callbackOutcome(request: String, expectedState: String) -> Result<String, ProviderError> {
        let target = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first
        let url = target.flatMap { URL(string: "http://127.0.0.1\($0)") }

        let code = url?.queryItem(named: "code")
        let returnedState = url?.queryItem(named: "state")
        let error = url?.queryItem(named: "error")

        // The state check is the CSRF protection: a callback with a state
        // that does not match the one we generated must be rejected, never
        // relaxed to make some other check easier to satisfy.
        guard error == nil, returnedState == expectedState, let code else {
            return .failure(.badResponse)
        }
        return .success(code)
    }

    private static func respond(on connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func exchange(code: String) async throws {
        guard let port = lock.withLock({ self.listener?.port }) else { throw ProviderError.badResponse }

        let session = try await GeminiOAuthSession.requestToken(
            fields: Self.exchangeFields(code: code, redirectURI: Self.redirectURI(port: port)),
            existingRefreshToken: nil)
        try GeminiOAuthSession.save(session)
    }

    private func finish(_ result: Result<Void, Error>) {
        // `finish` is reachable from the callback, the listener state handler
        // and the timeout concurrently; only the first one may resume.
        let claimed: (CheckedContinuation<Void, Error>, NWListener?, Task<Void, Never>?)? = lock.withLock {
            guard let continuation else { return nil }
            defer {
                self.continuation = nil
                self.listener = nil
                self.timeoutTask = nil
            }
            return (continuation, self.listener, self.timeoutTask)
        }
        guard let (continuation, listener, timeoutTask) = claimed else { return }

        listener?.cancel()
        timeoutTask?.cancel()
        switch result {
        case .success:            continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    /// Matches the redirect these clients are known to be used with — an
    /// ephemeral loopback port and a bare `/callback` path.
    static func redirectURI(port: NWEndpoint.Port) -> String {
        "http://127.0.0.1:\(port)/callback"
    }

    private static func randomURLSafeString() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }

}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension URL {
    func queryItem(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}
