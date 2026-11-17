import Foundation

/// Runs async operations one at a time, in the order they were submitted.
///
/// The capture service shares one inventory cache across calls, so two
/// overlapping captures can race; this chains them instead. Each operation
/// starts only after the previous one has returned or failed, and every caller
/// still receives its own result.
@MainActor
final class SerialAsyncGate {
    /// The last queued operation. A new operation awaits it before starting.
    private var tail: Task<Void, Never>?

    /// Runs `operation` after every operation submitted before it. Returns the
    /// operation's own value; an operation that fails or returns nil still
    /// lets the queue move on.
    func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let current = Task { @MainActor () -> T in
            _ = await previous?.value
            return await operation()
        }
        tail = Task { @MainActor in _ = await current.value }
        return await current.value
    }
}
