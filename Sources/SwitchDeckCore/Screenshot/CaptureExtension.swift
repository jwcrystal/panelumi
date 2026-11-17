import AppKit

/// Adds an action to the capture toolbar.
///
/// Register extensions with `LaunchOptions.captureExtensions`. The toolbar shows
/// one item per extension that returns a non-nil `toolbarItem`, after the
/// built-in tools. With no extensions registered the capture UI is unchanged.
///
/// Conforming types must be `Sendable` because `LaunchOptions` is. Keep state
/// in the `CaptureTakeover` returned from `begin`, not in the extension.
/// A `@MainActor` conforming type must declare `identifier` as `nonisolated`.
public protocol CaptureExtension: Sendable {
    /// Stable, unique name, for example a reverse-DNS string. Used to tell
    /// extensions apart (the host keeps the first of two equal identifiers) and
    /// to compare `LaunchOptions` values. Never shown to the user.
    var identifier: String { get }

    /// The toolbar item, or nil to show none. Read on the main actor when the
    /// user starts editing the selection: once per editing view, so a selection
    /// spanning two displays reads it for each. The host keeps that snapshot
    /// until the capture ends (the SwiftUI toolbar body is re-evaluated often
    /// and must not call back into the extension). The host does not wrap or
    /// localise any string in it; supply final, localised text.
    @MainActor var toolbarItem: CaptureToolbarItem? { get }

    /// Called when the user picks one of the item's entries.
    ///
    /// Return a takeover to take control of the selection, or nil to decline
    /// (nothing happens and the toolbar stays). You may call `context.cancel`
    /// or `context.deliver` before returning; the host applies either right
    /// after `begin` returns (see `CaptureTakeover`). A `cancel()` or
    /// `deliver` made inside `begin` is dropped when `begin` returns nil. Two
    /// delivers inside `begin`: the first one wins. When both were called, the
    /// cancel wins.
    @MainActor func begin(_ entryID: String, context: CaptureContext) -> CaptureTakeover?
}

/// What an extension shows in the capture toolbar. Value type with defaults so
/// fields can be added later without breaking callers.
public struct CaptureToolbarItem: Equatable, Sendable {
    /// One choice of the item.
    public struct Entry: Equatable, Sendable, Identifiable {
        /// Passed back to `CaptureExtension.begin`. Unique within the item.
        public var id: String
        /// Menu text, already localised.
        public var title: String
        /// Creates an entry from its identity and menu text.
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Text for the item as a whole, already localised.
    public var title: String
    /// SF Symbol name for the toolbar button.
    public var systemImage: String
    /// Tooltip. Falls back to `title` when nil.
    public var help: String?
    /// VoiceOver label. Falls back to `title` when nil.
    public var accessibilityLabel: String?
    /// One entry renders a plain button; two or more render a popover with one
    /// button per entry; none hides the item. Required: an item without entries
    /// is meaningless, so there is no default.
    public var entries: [Entry]

    /// Creates an item; `entries` has no default because an item without
    /// entries is hidden.
    public init(
        title: String,
        systemImage: String,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        entries: [Entry]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.entries = entries
    }
}

/// Where an image delivered by an extension goes. Same outcomes as the
/// toolbar's copy, save and pin buttons; `deliver` takes a set.
public struct CaptureOutput: Hashable, Sendable {
    /// Copies the image to the clipboard.
    public static let copy = CaptureOutput(rawValue: "copy")
    /// Writes the image to the folder and format Settings › Screenshot picked.
    public static let save = CaptureOutput(rawValue: "save")
    /// Opens the image in a small floating window the user can move or close.
    public static let pin = CaptureOutput(rawValue: "pin")
    let rawValue: String
    private init(rawValue: String) { self.rawValue = rawValue }
}

extension CaptureOutput {
    /// The pipeline output behind a public one. `.recognizeText` has no public
    /// equivalent, so it cannot appear here.
    var sessionOutput: CaptureSession.Output {
        if self == .copy { return .copy }
        if self == .save { return .save }
        return .pin
    }
}

/// Why a takeover ended. Constructed by the host only.
public struct CaptureEndReason: Equatable, Sendable {
    /// `CaptureContext.deliver` ran; the image entered the output pipeline.
    public static let delivered = CaptureEndReason(rawValue: "delivered")
    /// The extension called `CaptureContext.cancel()`.
    public static let cancelled = CaptureEndReason(rawValue: "cancelled")
    /// The host ended it: Esc that `handleKey` did not handle, the overlay was
    /// torn down, or another capture path closed the overlay.
    public static let dismissed = CaptureEndReason(rawValue: "dismissed")
    let rawValue: String
    private init(rawValue: String) { self.rawValue = rawValue }
}

/// A key press during a takeover. Only key-down events, only while the
/// capture window is the key window.
public struct CaptureKey: Equatable, Sendable {
    /// Hardware key code (`NSEvent.keyCode`).
    public var keyCode: UInt16
    /// `NSEvent.charactersIgnoringModifiers`, nil when not available.
    public var characters: String?
    /// Device-independent modifier flags only (`.deviceIndependentFlagsMask` applied).
    public var modifierFlags: NSEvent.ModifierFlags
    /// True for auto-repeat events.
    public var isRepeat: Bool

    /// True when the key is Escape (key code 53).
    public var isEscape: Bool { keyCode == 53 }

    /// Creates a key press; omitted fields are empty, unmodified and not repeated.
    public init(
        keyCode: UInt16,
        characters: String? = nil,
        modifierFlags: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifierFlags = modifierFlags
        self.isRepeat = isRepeat
    }
}

/// An extension's control of the selection. The host keeps it alive until it
/// ends; there is no other lifetime to manage.
///
/// While a takeover is active the host shows only the dimming and the selection
/// border, hides the toolbar, and lets every mouse event through to the windows
/// underneath. Host shortcuts (Return, Space, P, undo, delete) do not run.
public protocol CaptureTakeover: AnyObject {
    /// Called for each key-down event. Return true to consume it. Return false
    /// to hand it back to the window; the host still does not act on it, except
    /// that an unhandled Escape ends the takeover with `.dismissed` (so the user
    /// can never be stuck). Keys arrive only while the capture window is key; if
    /// the user clicks into another app the keys stop, so an extension must also
    /// offer on-screen controls (for example in a window attached with
    /// `CaptureContext.attach`) or otherwise call `cancel()` from its own state.
    @MainActor func handleKey(_ key: CaptureKey) -> Bool

    /// Called exactly once, on every end path, after the host has restored the
    /// toolbar and the mouse handling. `context` is already inactive.
    @MainActor func takeoverDidEnd(reason: CaptureEndReason)
}

public extension CaptureTakeover {
    /// Default: pass every key back to the host.
    @MainActor func handleKey(_ key: CaptureKey) -> Bool { false }
    /// Default: nothing to restore.
    @MainActor func takeoverDidEnd(reason: CaptureEndReason) {}
}

/// The extension's handle on the capture. Main-actor only. Once the takeover
/// has ended (any reason) the context is inactive and `cancel()`, `deliver`,
/// `showMessage` and `attach` do nothing, and `captureLive` returns nil.
///
/// Coordinate system: `region` is in global AppKit screen coordinates, in
/// points, origin at the bottom-left of the primary display (the same space as
/// `NSScreen.frame` and `NSWindow.frame`). It never changes during a takeover.
@MainActor
public final class CaptureContext {
    /// The selected region (global AppKit coordinates, points). It lies inside `screen.frame`.
    public let region: CGRect
    /// The display holding the region.
    public let screen: NSScreen

    /// False after the takeover ended.
    public var isActive: Bool { active }

    /// Shows a short transient message on `screen`. Pass final, localised
    /// text; the host does not localise it.
    ///
    /// Usable only while active, so show it before `deliver`. Does nothing
    /// when inactive. The output pipeline already gives its own feedback, so
    /// use this for anything beyond that, for example "saved 3 frames":
    /// copy shows nothing, save reports only a failure, and pin shows the
    /// pinned window.
    public func showMessage(_ text: String) {
        guard active else { return }
        onMessage(text)
    }

    /// Sends `image` through the normal output pipeline as if it were the
    /// selection's pixels: the toolbar's watermark settings apply, then every
    /// output in `outputs` runs, in the fixed order copy, save, pin. Ends the
    /// takeover with `.delivered` and closes the capture overlay. `image`
    /// keeps its pixel size.
    ///
    /// Does nothing when inactive or when `outputs` is empty (the takeover
    /// stays active).
    public func deliver(_ image: CGImage, to outputs: Set<CaptureOutput>) {
        guard active, !outputs.isEmpty else { return }
        onDeliver(image, outputs)
    }

    /// Ends the takeover and closes the capture overlay without output.
    /// Reason `.cancelled`.
    public func cancel() {
        guard active else { return }
        onCancel()
    }

    /// Hands a helper window to the host: it is raised above the overlay, kept
    /// out of live captures and window picking, and closed when the takeover
    /// ends. The window should not become key (use a non-activating panel).
    ///
    /// May be called any time while active, also before the window is ordered
    /// front. The host sets `isReleasedWhenClosed` to false. Does nothing when
    /// inactive, so a window attached after the end is neither tracked nor
    /// closed.
    public func attach(_ window: NSWindow) {
        guard active else { return }
        onAttach(window)
    }

    /// Captures the region from the live screen as it is now, ignoring any
    /// frame frozen before the overlay appeared. The host's overlay windows,
    /// every window passed to `attach` and the host's message toasts are left
    /// out of the image.
    ///
    /// The image is `region.size * screen.backingScaleFactor` pixels, each side
    /// rounded to a whole pixel. The host reads the scale from the region's own
    /// display, so a mixed-resolution setup does not change the size.
    ///
    /// Returns nil when Screen Recording is not allowed, when the context is
    /// inactive (also when the takeover ended while the capture was running),
    /// or when the capture failed. Calls are serialised with the host's
    /// base-region captures: a call made while one of those is in flight waits
    /// for it. Window captures are not serialised with them.
    public func captureLive() async -> CGImage? {
        guard active else { return nil }
        let image = await onLive()
        guard active else { return nil }
        return image
    }

    private var active = true
    private let onCancel: () -> Void
    private let onDeliver: (CGImage, Set<CaptureOutput>) -> Void
    private let onMessage: (String) -> Void
    private let onAttach: (NSWindow) -> Void
    private let onLive: @MainActor () async -> CGImage?

    /// Created by the host only.
    init(
        region: CGRect,
        screen: NSScreen,
        cancel: @escaping () -> Void,
        deliver: @escaping (CGImage, Set<CaptureOutput>) -> Void = { _, _ in },
        message: @escaping (String) -> Void = { _ in },
        attach: @escaping (NSWindow) -> Void = { _ in },
        live: @escaping @MainActor () async -> CGImage? = { nil }
    ) {
        self.region = region
        self.screen = screen
        self.onCancel = cancel
        self.onDeliver = deliver
        self.onMessage = message
        self.onAttach = attach
        self.onLive = live
    }

    /// Marks the context inactive; later `cancel()` calls do nothing.
    func invalidate() {
        active = false
    }
}
