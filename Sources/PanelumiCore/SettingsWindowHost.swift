import AppKit
import SwiftUI

/// Owns the Settings window between opens. Showing it is left to the caller, so
/// the window can be built and checked without activating the app.
@MainActor
final class SettingsWindowHost {
    private let readPages: () -> [SettingsPage]
    private let makeView: ([SettingsPage], SettingsView.Page) -> AnyView
    private var window: NSWindow?
    private var signature: [SettingsPage.Signature] = []

    init(
        pages: @escaping () -> [SettingsPage],
        makeView: @escaping ([SettingsPage], SettingsView.Page) -> AnyView
    ) {
        self.readPages = pages
        self.makeView = makeView
    }

    /// `--pane customize` opens Settings on a given page, built-in or injected;
    /// used for screenshots and quick checks.
    static func initialPage(arguments: [String], pages: [SettingsPage]) -> SettingsView.Page {
        guard let index = arguments.firstIndex(of: "--pane"), arguments.indices.contains(index + 1) else {
            return .builtin(.general)
        }
        let raw = arguments[index + 1]
        if let pane = SettingsView.Pane(rawValue: raw) {
            return .builtin(pane)
        }
        if pages.contains(where: { $0.id == raw }) {
            return .injected(raw)
        }
        return .builtin(.general)
    }

    /// Pages are read on every call. The window is kept between calls, so
    /// its content is replaced only when the pages differ, which otherwise
    /// keeps the selected page and pane state. A new hosting controller, not a
    /// new rootView, because SwiftUI would keep a selection that may name a
    /// page that is gone.
    func prepareWindow(arguments: [String] = CommandLine.arguments) -> NSWindow {
        let pages = readPages()
        let newSignature = pages.map(\.signature)

        if let window {
            if newSignature != signature {
                signature = newSignature
                let frame = window.frame
                window.contentViewController = NSHostingController(rootView: makeView(pages, .builtin(.general)))
                window.setFrame(frame, display: false)
            }
            return window
        }

        let initial = Self.initialPage(arguments: arguments, pages: pages)
        let hosting = NSHostingController(rootView: makeView(pages, initial))
        signature = newSignature
        let created = NSWindow(contentViewController: hosting)
        created.title = "Panelumi"
        created.styleMask = [.titled, .closable, .miniaturizable]
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        return created
    }
}
