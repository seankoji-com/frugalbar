import Foundation

/// Runs one operation at a time and hands its result to every caller that
/// arrived while it was running. Callers that arrive afterwards start a new
/// one. Used where several providers in one poll must see the same reading.
@MainActor
final class CoalescedRead<Value: Sendable> {
    private var inFlight: Task<Value, Never>?

    func run(_ operation: @escaping @MainActor () async -> Value) async -> Value {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in await operation() }
        inFlight = task
        let value = await task.value
        if inFlight == task { inFlight = nil }
        return value
    }
}
