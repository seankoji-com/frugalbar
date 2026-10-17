import Foundation
import Synchronization

/// The part of `SyncPublisher` a request belongs to. Each one runs inside
/// its scope as a task-local, so the request carries it down through the
/// token refresh, Drive and timeout layers to `GatedSyncTransport`.
enum SyncNetworkScope: Sendable {
    /// A publish attempt: discovery, duplicate deletes, metadata, the
    /// upload, the verification read, and any token refresh they need.
    case publish
    /// Stop's cleanup: deleting this session's files and the re-lists.
    case cleanup

    @TaskLocal static var current: SyncNetworkScope?
}

/// The gate refused a request, so it was never sent.
struct SyncRequestWithheld: Error {}

/// Every request the publisher sends goes through here. Immediately before
/// sending, it asks the publisher whether the request's scope may contact
/// Google now; a request with no scope, from a cancelled task, or refused by
/// the publisher is withheld. This is the one place the rule is enforced, so
/// a step that resumes after Stop, a lost write or "Sign in again" cannot
/// send anything, whichever await it resumes from.
final class GatedSyncTransport: SyncTransport, Sendable {
    typealias Permit = @Sendable (SyncNetworkScope) async -> Bool

    private let inner: any SyncTransport
    private let permit = Mutex<Permit?>(nil)

    init(_ inner: any SyncTransport) { self.inner = inner }

    /// Set once by the publisher's init; nothing is sent before it is.
    func bind(_ permit: @escaping Permit) { self.permit.withLock { $0 = permit } }

    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        guard let scope = SyncNetworkScope.current, !Task.isCancelled,
              let permit = permit.withLock({ $0 }), await permit(scope), !Task.isCancelled
        else { throw SyncRequestWithheld() }
        return try await inner.send(request)
    }
}
