import Foundation

/// A completed sign-in: the account, and a fresh access token for the first
/// Drive calls.
public struct SyncSignInResult: Sendable {
    public let account: SyncAccount
    public let accessToken: String
    public let expiresIn: TimeInterval?
}

/// The Mac's installed-app sign-in (D§2.2.B, REQ-MAC-OAUTH a–b).
///
/// Opens nothing itself: `present` receives the consent URL and the caller
/// shows it ("open this link in a browser on this Mac") and opens it. The
/// listener is closed on success, on cancel, and after five minutes.
///
/// Sign-in succeeds only once the refresh token is in the Keychain and reads
/// back. A sign-in that must be a particular account (re-sign-in, or
/// finishing cleanup) checks `about.get`'s `permissionId` *before* anything
/// is stored, so the wrong account never replaces the right one's token.
public struct SyncSignInFlow: Sendable {
    public static let timeout: TimeInterval = 5 * 60

    let configuration: SyncClientConfiguration
    let transport: any SyncTransport
    let secrets: any SyncSecretStore
    let clock: any SyncClock

    public init(
        configuration: SyncClientConfiguration,
        transport: any SyncTransport = URLSessionSyncTransport(),
        secrets: any SyncSecretStore = KeychainSyncSecretStore(),
        clock: any SyncClock = SystemSyncClock()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.secrets = secrets
        self.clock = clock
    }

    public func run(
        listener: any SyncCallbackListener,
        loginHint: String? = nil,
        expectedPermissionId: String? = nil,
        present: @Sendable (URL) async -> Void
    ) async throws -> SyncSignInResult {
        try await run(
            listener: listener, loginHint: loginHint, expectedPermissionId: expectedPermissionId,
            state: SyncOAuth.randomToken(), pkce: .generate(), present: present)
    }

    func run(
        listener: any SyncCallbackListener,
        loginHint: String?,
        expectedPermissionId: String?,
        state: String,
        pkce: SyncPKCE,
        present: @Sendable (URL) async -> Void
    ) async throws -> SyncSignInResult {
        defer { listener.close() }
        let url = SyncOAuth.authorizationURL(
            clientID: configuration.clientID, redirectURI: listener.redirectURI,
            state: state, pkce: pkce, loginHint: loginHint)
        await present(url)

        let parameters: [String: String]
        do {
            parameters = try await withSyncTimeout(seconds: Self.timeout, clock: clock) {
                try await listener.awaitCallback()
            }
        } catch is SyncTimeoutError {
            throw SyncSignInError.timedOut
        } catch is CancellationError {
            throw SyncSignInError.cancelled
        }
        listener.close()
        let code = try SyncOAuth.validateCallback(parameters, expectedState: state)

        let endpoint = SyncTokenEndpoint(configuration: configuration, transport: transport, clock: clock)
        let token: SyncTokenResponse
        switch await endpoint.exchange(code: code, verifier: pkce.verifier, redirectURI: listener.redirectURI) {
        case .success(let response): token = response
        case .failure(let failure): throw SyncSignInError.exchangeFailed(failure)
        }
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else { throw SyncSignInError.noRefreshToken }

        // The account, read with the new access token only: a 401 here must
        // not fall back to whatever refresh token is already stored.
        let lookup = SyncAccessTokens(endpoint: endpoint, secrets: NoSyncSecrets(), clock: clock)
        await lookup.prime(token.accessToken, expiresIn: token.expiresIn)
        let account: SyncAccount
        do {
            account = try await SyncDriveClient(transport: transport, tokens: lookup, clock: clock).account()
        } catch {
            throw SyncSignInError.accountLookupFailed
        }
        if let expectedPermissionId, account.permissionId != expectedPermissionId {
            throw SyncSignInError.wrongAccount
        }

        do {
            try secrets.write(refreshToken, account: SyncSecretAccount.refreshToken)
            guard try secrets.read(SyncSecretAccount.refreshToken) == refreshToken else {
                throw SyncSignInError.notPersisted
            }
        } catch {
            throw SyncSignInError.notPersisted
        }
        return SyncSignInResult(account: account, accessToken: token.accessToken, expiresIn: token.expiresIn)
    }
}

/// A store with nothing in it, so a token lookup can never refresh.
private struct NoSyncSecrets: SyncSecretStore {
    func read(_ account: String) throws -> String? { nil }
    func write(_ value: String, account: String) throws {}
    func delete(_ account: String) throws {}
}
