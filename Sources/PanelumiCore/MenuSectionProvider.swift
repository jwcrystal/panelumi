import PanelumiKit

/// Adds rows to the status-bar menu.
///
/// Register providers with `LaunchOptions.menuSections`. Their rows are appended
/// after the built-in switches, in the order the providers are listed, and are
/// not part of the catalog: they cannot be reordered or hidden in Settings.
/// With no providers registered the menu is unchanged.
///
/// Conforming types must be `Sendable` because `LaunchOptions` is.
/// A `@MainActor` conforming type must declare `identifier` as `nonisolated`.
public protocol MenuSectionProvider: Sendable {
    /// Stable, unique name, for example a reverse-DNS string. Never shown to
    /// the user. Used to compare `LaunchOptions` values.
    nonisolated var identifier: String { get }

    /// Rows appended to the menu, in order. Read each time the menu is built,
    /// so it must be cheap, must not prompt and must not mutate anything.
    /// These rows never get a global shortcut.
    @MainActor var items: [SwitchItem] { get }
}
