import Foundation

/// Wall-clock time and waiting, injected so every cadence rule (the 2-minute
/// floor, the 15-minute heartbeat, the 20 s timeout, the +2/+10 minute
/// cleanup re-lists, the 5-minute sign-in timeout) is tested under a fake
/// clock instead of real time.
public protocol SyncClock: Sendable {
    func now() -> Date
    /// Returns at `deadline`, or throws `CancellationError` when cancelled.
    func sleep(until deadline: Date) async throws
}

public struct SystemSyncClock: SyncClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let seconds = deadline.timeIntervalSinceNow
        if seconds > 0 { try await Task.sleep(for: .milliseconds(Int((seconds * 1000).rounded(.up)))) }
        try Task.checkCancellation()
    }
}

/// Runs `operation`, giving up after `seconds` of `clock` time with
/// `SyncTimeoutError`. The operation is cancelled when the time runs out.
func withSyncTimeout<Value: Sendable>(
    seconds: TimeInterval,
    clock: any SyncClock,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let deadline = clock.now().addingTimeInterval(seconds)
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(until: deadline)
            throw SyncTimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw SyncTimeoutError() }
        return first
    }
}

public struct SyncTimeoutError: Error, Equatable, Sendable {}
