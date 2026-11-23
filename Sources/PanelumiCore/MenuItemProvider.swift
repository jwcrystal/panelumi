import PanelumiKit

/// Adds rows to the status-bar menu.
///
/// Register providers with `LaunchOptions.menuItemProviders`. Their rows are appended
/// after the built-in switches, in the order the providers are listed, and are
/// not part of the catalog: they cannot be reordered or hidden in Settings.
/// With no providers registered the menu is unchanged.
///
/// Conforming types must be `Sendable` because `LaunchOptions` is.
/// A `@MainActor` conforming type must declare `identifier` as `nonisolated`.
public protocol MenuItemProvider: Sendable {
    /// Stable, unique name, for example a reverse-DNS string. Never shown to
    /// the user. Used to compare `LaunchOptions` values. A provider whose
    /// identifier repeats an earlier one is ignored.
    nonisolated var identifier: String { get }

    /// Rows appended to the menu, in order. Read each time the menu is built,
    /// so it must be cheap, must not prompt and must not mutate anything.
    /// A row can carry a global shortcut like a built-in one, and Settings ›
    /// Shortcuts lists it; the config stores the binding under the row's id.
    /// Shortcuts follow the rows: every menu rebuild registers a row that
    /// appeared and drops one that went away.
    ///
    /// Only `state`, `subtitle`, `isEnabled` and submenu checkmarks are
    /// refreshed when the menu opens. `title`, `symbolName`, `kind` and the
    /// shape of `actions` are fixed until the next build. Put anything that
    /// changes often in `subtitle`; for a change to the fixed fields, ask for
    /// a rebuild through the closure passed to `bind(rebuildMenu:)`.
    @MainActor var items: [SwitchItem] { get }

    /// Called once, when the status-bar menu starts using this provider, with a
    /// closure that rebuilds the menu. Call it after anything `items` returns
    /// changes in a way the open-time refresh does not cover: rows added or
    /// removed, a new `title`, `symbolName` or `kind`, or a different set of
    /// submenu entries. Calling it while the menu is open rebuilds after it
    /// closes. Do not call it from `items`.
    ///
    /// The default implementation ignores the closure.
    @MainActor func bind(rebuildMenu: @escaping @MainActor () -> Void)
}

extension MenuItemProvider {
    @MainActor public func bind(rebuildMenu: @escaping @MainActor () -> Void) {}
}
