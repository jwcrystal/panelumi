import Foundation

/// Runs async operations one at a time, in the order they were submitted.
///
/// Live captures and base-region captures share the capture service's inventory
/// cache, so two overlapping ones can race; this chains them instead. Window
/// captures are not serialised here. Each operation starts only after the
/// previous one has returned or failed, and every caller still receives its own
/// result. Cancelling a caller cancels its task; it still waits for the operations ahead
/// of it, so an operation should check `Task.isCancelled` before doing real work.
@MainActor
final class SerialAsyncGate {
    /// The last queued operation. A new operation awaits it before starting.
    private var tail: Task<Void, Never>?

    /// Runs `operation` after every operation submitted before it. Returns the
    /// operation's own value; an operation that fails or returns nil still
    /// lets the queue move on. Cancelling the calling task cancels the queued
    /// task; the caller still waits for earlier operations, and the operation
    /// runs with `Task.isCancelled == true`, so it should return early.
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
