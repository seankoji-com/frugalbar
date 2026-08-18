import Foundation

/// Result of a bounded operation: either a value, or the reason we gave up.
public enum DeadlineOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(UnavailableReason)
}

/// Runs `operation` with a hard wall-clock deadline.
///
/// URLSession's `timeoutIntervalForRequest` bounds a single request; it does
/// not bound work that issues several requests, does file I/O, or spawns a
/// subprocess. This bounds the whole operation.
///
/// Errors are mapped to a closed `UnavailableReason` set. Raw error text is
/// deliberately dropped: it can embed a request URL, and request URLs can
/// embed credentials.
func withDeadline<Value: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> Value
) async -> DeadlineOutcome<Value> {
    // Deliberately *not* a TaskGroup. A group awaits every child before it
    // returns, so an operation that ignores cancellation — anything doing
    // synchronous blocking work, such as a subprocess or file read — would
    // hold the deadline open and defeat the point. These are unstructured
    // tasks raced through a first-wins gate, so the timeout always returns
    // on time and the loser is cancelled and abandoned.
    let gate = FirstWins<DeadlineOutcome<Value>>()

    let work = Task {
        let outcome: DeadlineOutcome<Value>
        do {
            outcome = .success(try await operation())
        } catch let error as ProviderError {
            outcome = .failure(error.reason)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                outcome = .failure(.timedOut)
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                outcome = .failure(.offline)
            default:
                outcome = .failure(.badResponse)
            }
        } catch is CancellationError {
            outcome = .failure(.timedOut)
        } catch {
            outcome = .failure(.badResponse)
        }
        await gate.offer(outcome)
    }

    let timeout = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await gate.offer(.failure(.timedOut))
    }

    let result = await gate.value()
    work.cancel()
    timeout.cancel()
    return result
}

/// Resolves once, with whichever value arrives first.
private actor FirstWins<Value: Sendable> {
    private var resolved: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func offer(_ value: Value) {
        guard resolved == nil else { return }
        resolved = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }

    func value() async -> Value {
        if let resolved { return resolved }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Errors a provider raises when it can classify the failure itself.
public struct ProviderError: Error, Sendable, Equatable {
    public let reason: UnavailableReason
    public init(_ reason: UnavailableReason) { self.reason = reason }

    public static let notConfigured = ProviderError(.notConfigured)
    public static let credentialRejected = ProviderError(.credentialRejected)
    public static let badResponse = ProviderError(.badResponse)
}
