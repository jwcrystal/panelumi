import Foundation

/// Runs async operations one at a time, in the order they were submitted.
///
/// Live captures and base-region captures share the capture service's inventory
/// cache, so two overlapping ones can race; this chains them instead. Window
/// captures are not serialised here. Each operation starts only after the
/// previous one has returned or failed, and every caller still receives its own
/// result. A cancelled caller cancels its own queued work and waits no longer.
@MainActor
final class SerialAsyncGate {
    /// The last queued operation. A new operation awaits it before starting.
    private var tail: Task<Void, Never>?

    /// Runs `operation` after every operation submitted before it. Returns the
    /// operation's own value; an operation that fails or returns nil still
    /// lets the queue move on. Cancelling the calling task cancels the queued
    /// work rather than leaving it waiting.
    func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let current = Task { @MainActor () -> T in
            _ = await previous?.value
            return await operation()
        }
        tail = Task { @MainActor in _ = await current.value }
        return await withTaskCancellationHandler {
            await current.value
        } onCancel: {
            current.cancel()
        }
    }
}
