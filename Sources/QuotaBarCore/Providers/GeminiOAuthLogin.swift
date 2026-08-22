import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth authorization-code flow for FrugalBar's desktop client.
/// Tokens are stored only in the macOS Keychain.
public final class GeminiOAuthLogin: NSObject, @unchecked Sendable {
    public static let shared = GeminiOAuthLogin()

    private let clientID = "598649530021-n2bb3flau0ff6mt7v316kimt57rolkan.apps.googleusercontent.com"
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Void, Error>?
    private var state = ""
    private var verifier = ""

    public func signIn() async throws {
        guard listener == nil else { return }
        state = Self.randomURLSafeString()
        verifier = Self.randomURLSafeString()
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8) else { return }
                self.handleCallback(request, connection: connection)
            }
        }
        listener.start(queue: .main)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, let port = listener.port else { return }
                let redirect = "http://127.0.0.1:\(port)/oauth/callback"
                var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                components.queryItems = [
                    .init(name: "client_id", value: self.clientID),
                    .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"),
                    .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "consent"),
                    .init(name: "state", value: self.state),
                    .init(name: "code_challenge", value: Self.challenge(for: self.verifier)),
                    .init(name: "code_challenge_method", value: "S256"),
                ]
                if let url = components.url { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
        }
    }

    private func handleCallback(_ request: String, connection: NWConnection) {
        let target = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first
        let url = target.flatMap { URL(string: "http://127.0.0.1\($0)") }
        let code = url?.queryItem(named: "code")
        let returnedState = url?.queryItem(named: "state")
        let error = url?.queryItem(named: "error")
        let message = "<html><body><h2>FrugalBar</h2><p>You may close this window.</p></body></html>"
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)".utf8), completion: .contentProcessed { _ in connection.cancel() })

        guard error == nil, returnedState == state, let code else {
            finish(.failure(ProviderError.badResponse)); return
        }
        Task {
            do { try await exchange(code: code) ; finish(.success(())) }
            catch { finish(.failure(error)) }
        }
    }

    private func exchange(code: String) async throws {
        guard let port = listener?.port else { throw ProviderError.badResponse }
        let redirect = "http://127.0.0.1:\(port)/oauth/callback"
        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect), .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.access_token.isEmpty
        else { throw ProviderError.badResponse }
        let session = GeminiOAuthSession(accessToken: token.access_token, refreshToken: token.refresh_token ?? "", expiry: Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600)))
        let encoded = try JSONEncoder().encode(session)
        try KeychainManager.shared.set(key: String(decoding: encoded, as: UTF8.self), label: GeminiOAuthSession.keychainLabel)
    }

    private func finish(_ result: Result<Void, Error>) {
        listener?.cancel(); listener = nil
        let continuation = continuation; self.continuation = nil
        switch result { case .success: continuation?.resume(); case .failure(let error): continuation?.resume(throwing: error) }
    }

    private struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int? }
    private static func randomURLSafeString() -> String { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString() }
    private static func challenge(for verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString() }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private extension URL {
    func queryItem(named name: String) -> String? { URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value }
}
