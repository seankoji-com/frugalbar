import Foundation

enum GeminiRequestBudget {
    // Two hosts, each with project lookup then scoped quota: at most 8s of
    // request work, leaving 2s of the engine's 10s for setup and decoding.
    // A task-local lets hermetic tests shorten waits without changing the
    // provider interface used by the original-provider mutation proof.
    @TaskLocal static var seconds: TimeInterval = 2
}
