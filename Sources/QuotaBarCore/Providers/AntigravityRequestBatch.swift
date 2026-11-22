import Foundation

/// One batch per manager pass. Independent pool rows of the SAME account share
/// scoped responses (including failures) without keeping a second cache across
/// refreshes, while distinct accounts never share tokens or responses.
actor AntigravityRequestBatch {
    private var tokenTasks: [String: Task<String?, Never>] = [:]
    private var responses: [String: Task<(Data, HTTPURLResponse), Error>] = [:]

    func token(accountID: String = "default", injected: String?) async -> String? {
        await token(accountID: accountID) {
            if let injected, !injected.isEmpty { return injected }
            guard !TestHost.isActive else { return nil }
            // Our own session first, because it is the one we can renew.
            if let session = await GeminiOAuthSession.loadRefreshed() { return session.accessToken }
            return await CredentialStore.antigravityAccessTokenAsync()
        }
    }

    func token(
        accountID: String = "default",
        load: @escaping @Sendable () async -> String?
    ) async -> String? {
        if let existing = tokenTasks[accountID] { return await existing.value }
        let task = Task<String?, Never> { await load() }
        tokenTasks[accountID] = task
        return await task.value
    }

    func response(
        accountID: String = "default",
        key: String,
        load: @escaping @Sendable () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let scopedKey = "\(accountID)|\(key)"
        let task: Task<(Data, HTTPURLResponse), Error>
        if let existing = responses[scopedKey] {
            task = existing
        } else {
            task = Task { try await load() }
            responses[scopedKey] = task
        }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }
}
