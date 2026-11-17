import AppKit

/// One extension takeover, from `begin` returning a takeover until it ends.
///
/// The controller owns the run through `activeTakeover`; the run owns the
/// context handed to the extension and remembers how it ended so the end path
/// runs exactly once.
@MainActor
final class TakeoverRun {
    /// The view whose toolbar started the takeover; it draws the border.
    weak var view: SelectionView?
    /// The context handed to the extension.
    let context: CaptureContext
    /// Nil until `begin` returns a takeover.
    var takeover: CaptureTakeover?
    /// Non-nil once the takeover ended; makes ending idempotent.
    var endedReason: CaptureEndReason?
    /// True while `CaptureExtension.begin` is still running.
    var beginning = true
    /// The extension called `cancel()` synchronously inside `begin`.
    var pendingCancel = false
    /// The extension called `deliver` synchronously inside `begin`.
    var pendingDeliver: (image: CGImage, outputs: Set<CaptureOutput>)?
    /// Windows the extension handed to `attach`. The run owns what it must
    /// close at the end.
    var attached: [NSWindow] = []

    init(
        view: SelectionView,
        region: CGRect,
        screen: NSScreen,
        cancel: @escaping () -> Void,
        deliver: @escaping (CGImage, Set<CaptureOutput>) -> Void = { _, _ in },
        message: @escaping (String) -> Void = { _ in },
        attach: @escaping (NSWindow) -> Void = { _ in }
    ) {
        self.view = view
        self.context = CaptureContext(
            region: region,
            screen: screen,
            cancel: cancel,
            deliver: deliver,
            message: message,
            attach: attach
        )
    }
}

/// Indirect holder that lets a context's cancel closure reach the run being
/// created, without the run and its context retaining each other.
@MainActor
final class TakeoverRunBox {
    /// Set once the run exists.
    weak var run: TakeoverRun?
}
