import SwiftUI

/// A page added to Settings.
///
/// The host knows only the title, the symbol and a view to draw. The view is
/// built on the main actor when the page is shown, so the extension keeps its
/// own types and state. Pages appear after the built-in pages, in the order
/// their providers are listed.
public struct SettingsPage: Identifiable, Sendable {
    /// Must be unique across all pages and must not match the id of a built-in
    /// page; a page that breaks either rule is dropped. A stable reverse-DNS
    /// string is recommended. `--pane <id>` opens the page with this id.
    public let id: String
    /// Already localised; the host does not look it up.
    public let title: String
    /// An SF Symbol name, shown with `Label(_:systemImage:)`. A wrong name
    /// shows no icon.
    public let symbolName: String

    private let content: @MainActor @Sendable () -> AnyView

    public init(
        id: String,
        title: String,
        symbolName: String,
        content: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.content = content
    }

    @MainActor
    func makeView() -> AnyView {
        content()
    }

    /// What the sidebar shows for a page; the window is rebuilt when it changes.
    struct Signature: Equatable {
        let id: String
        let title: String
        let symbolName: String
    }

    var signature: Signature {
        Signature(id: id, title: title, symbolName: symbolName)
    }
}

/// Adds pages to Settings.
///
/// Register providers with `LaunchOptions.settingsPageProviders`. With none
/// registered the window is exactly as it was. Conforming types must be
/// `Sendable` because `LaunchOptions` is; a `@MainActor` conforming type must
/// declare `identifier` as `nonisolated`.
public protocol SettingsPageProvider: Sendable {
    /// Stable, unique name, for example a reverse-DNS string. Never shown to
    /// the user. Used to compare `LaunchOptions` values and to drop a provider
    /// whose identifier repeats an earlier one.
    nonisolated var identifier: String { get }

    /// Pages appended to Settings, in order. Read each time the window opens;
    /// when the ids, titles or symbols differ from the last read, the window
    /// is rebuilt and returns to General.
    @MainActor var pages: [SettingsPage] { get }
}
