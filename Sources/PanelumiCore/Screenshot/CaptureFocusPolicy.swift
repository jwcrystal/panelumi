/// Who owns the keyboard while a capture overlay is live.
///
/// macOS 14 activates cooperatively, so ordering the overlay front while the
/// app is inactive does not guarantee the overlay ever becomes key. Any
/// Panelumi window already on screen (Settings, a pinned shot, the recognition
/// panel) can hold the keyboard instead, leaving the overlay drawn with its
/// hints but inert.
struct CaptureFocusPolicy: Equatable {
    var sessionActive: Bool
    var appActive: Bool
    /// A takeover hands the keyboard to its extension, which may attach a
    /// window that becomes key.
    var takeoverActive: Bool

    /// The overlay keeps, or takes back, the keyboard. Another app in front
    /// means the user is elsewhere, and re-keying would fight that switch.
    var claimsKeyboard: Bool {
        sessionActive && appActive && !takeoverActive
    }

    /// True when a key event delivered to Panelumi belongs to the capture.
    /// With a takeover running, a window the extension attached keeps the keys
    /// it took; without one, nothing else may consume a key mid-capture.
    func ownsKeyEvent(overlayIsKey: Bool) -> Bool {
        guard sessionActive else { return false }
        return overlayIsKey || !takeoverActive
    }
}
