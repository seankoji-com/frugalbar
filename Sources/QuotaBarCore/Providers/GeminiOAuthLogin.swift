import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth authorization-code flow for FrugalBar's desktop client.
/// Tokens are stored only in the macOS Keychain.
public final class GeminiOAuthLogin: NSObject, @unchecked Sendable {
    public static let shared = GeminiOAuthLogin()

    /// How long to wait for the user to finish in the browser before giving the
    /// port back. Without this a closed browser tab wedges sign-in forever.
    private static let completionTimeout: TimeInterval = 300

    private var clientID: String { GeminiOAuthSession.clientID }
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var state = ""
    private var verifier = ""

    public func signIn() async throws {
        let alreadyRunning = lock.withLock { self.listener != nil }
        // Reporting success for a sign-in we never started would leave the user
        // staring at "Connected" with no token.
        guard !alreadyRunning else { throw ProviderError.badResponse }

        state = Self.randomURLSafeString()
        verifier = Self.randomURLSafeString()

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
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI(port: port)),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        if let url = components.url {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    private func handleCallback(_ request: String, connection: NWConnection) {
        let target = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first
        let url = target.flatMap { URL(string: "http://127.0.0.1\($0)") }

        // Browsers speculatively request /favicon.ico and friends on the same
        // origin. Treating those as a failed callback would abort a sign-in
        // that is still in progress.
        guard url?.path == "/oauth/callback" else {
            Self.respond(on: connection, status: "404 Not Found", body: "")
            return
        }

        let code = url?.queryItem(named: "code")
        let returnedState = url?.queryItem(named: "state")
        let error = url?.queryItem(named: "error")
        let succeeded = error == nil && returnedState == state && code != nil
        let message = succeeded
            ? "<html><body><h2>FrugalBar</h2><p>You may close this window.</p></body></html>"
            : "<html><body><h2>FrugalBar</h2><p>Sign-in did not complete. You may close this window.</p></body></html>"
        Self.respond(on: connection, status: "200 OK", body: message)

        guard succeeded, let code else {
            finish(.failure(ProviderError.badResponse))
            return
        }
        Task {
            do {
                try await exchange(code: code)
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private static func respond(on connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func exchange(code: String) async throws {
        guard let port = lock.withLock({ self.listener?.port }) else { throw ProviderError.badResponse }

        let session = try await GeminiOAuthSession.requestToken(fields: [
            "code": code,
            "client_id": clientID,
            "redirect_uri": Self.redirectURI(port: port),
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ], existingRefreshToken: nil)
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

    private static func redirectURI(port: NWEndpoint.Port) -> String {
        "http://127.0.0.1:\(port)/oauth/callback"
    }

    private static func randomURLSafeString() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
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
