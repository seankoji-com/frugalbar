import Foundation

/// One batch per manager pass. Independent pool rows share scoped responses,
/// including failures, without keeping a second cache across refreshes.
actor AntigravityRequestBatch {
    private var tokenTask: Task<String?, Never>?
    private var responses: [String: Task<(Data, HTTPURLResponse), Error>] = [:]

    func token(injected: String?) async -> String? {
        if let tokenTask { return await tokenTask.value }
        let task = Task<String?, Never> {
            if let injected, !injected.isEmpty { return injected }
            guard !TestHost.isActive else { return nil }
            // Our own session first, because it is the one we can renew.
            if let session = await GeminiOAuthSession.loadRefreshed() { return session.accessToken }
            return await CredentialStore.antigravityAccessTokenAsync()
        }
        tokenTask = task
        return await task.value
    }

    func response(key: String, load: @escaping @Sendable () async throws -> (Data, HTTPURLResponse)) async throws
        -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let task: Task<(Data, HTTPURLResponse), Error>
        if let existing = responses[key] { task = existing }
        else {
            task = Task { try await load() }
            responses[key] = task
        }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }
}
