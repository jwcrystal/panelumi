import Combine
import Foundation
import PanelumiKit

/// Owns the catalog and the saved config, publishes changes so the menu and the
/// settings window stay in sync, and keeps global shortcuts in step with the
/// config.
@MainActor
final class AppModel: ObservableObject {
    let catalog: SwitchCatalog
    private let store: ConfigStore
    /// The providers in use, without repeated identifiers.
    let itemProviders: [any MenuItemProvider]
    private let hotkeys = HotkeyCenter()
    private var registeredIDs: [String] = []

    @Published private(set) var config: PanelumiConfig
    /// Shortcut problems to show in Settings › Shortcuts. Empty means all good.
    @Published private(set) var hotkeyIssues: [String] = []

    /// Set by the menu controller: runs one switch by id, with error reporting.
    var runSwitch: ((String) -> Void)?

    init(catalog: SwitchCatalog = .standard(), store: ConfigStore = ConfigStore(),
         itemProviders: [any MenuItemProvider] = []) {
        self.catalog = catalog
        self.store = store
        var seenProviders = Set<String>()
        self.itemProviders = itemProviders.filter { provider in
            let isNew = seenProviders.insert(provider.identifier).inserted
            #if DEBUG
            if !isNew {
                NSLog("Panelumi: %@", "menu item provider \(provider.identifier) is listed more than once; only the first is used.")
            }
            #endif
            return isNew
        }
        self.config = store.config
        seedScreenshotShortcutIfNeeded()
        registerHotkeys()
    }

    /// Installs ⌥E once as the default screenshot shortcut. Later, the user
    /// can change or clear it in Settings › Screenshot.
    private func seedScreenshotShortcutIfNeeded() {
        guard !config.didSeedScreenshotShortcut else { return }

        var updated = config
        updated.didSeedScreenshotShortcut = true
        if updated.hotkey(for: ScreenshotCoordinator.id) == nil {
            updated.setHotkey(
                HotkeyBinding(keyCode: 14, modifiers: HotkeyBinding.optionModifier, label: "E"),
                for: ScreenshotCoordinator.id
            )
        }

        store.update { $0 = updated }
        config = store.config
    }

    /// Every switch in the user's order, including hidden ones (settings list).
    var orderedItems: [SwitchItem] {
        config.orderedIDs(from: catalog.ids).compactMap(catalog.item(id:))
    }

    /// Only the built-in switches shown in the menu.
    var catalogMenuItems: [SwitchItem] {
        orderedItems.filter { config.isEnabled($0.id) }
    }

    /// The shortcut to show next to a row. It comes from the config, so a row
    /// that lost a conflict to an earlier row still shows its label.
    func shortcutLabel(for id: String) -> String? {
        config.hotkey(for: id)?.displayString
    }

    /// The rows Settings › Shortcuts lists: every built-in switch, hidden ones
    /// included, then the rows the item providers add.
    var shortcutItems: [SwitchItem] {
        let builtInIDs = Set(catalog.ids)
        return orderedItems + menuItems.filter { !builtInIDs.contains($0.id) }
    }

    /// Everything the menu shows: the visible built-in switches, then the rows
    /// the item providers add. An id that is already taken, by a built-in
    /// (hidden or not) or by an earlier provider row, is dropped. Providers that
    /// repeat an identifier were already dropped in `init`.
    var menuItems: [SwitchItem] {
        var seen = Set(catalog.ids)
        var injected: [SwitchItem] = []
        for provider in itemProviders {
            for item in provider.items {
                if seen.insert(item.id).inserted {
                    injected.append(item)
                } else {
                    reportDroppedDuplicate(item.id, provider: provider.identifier)
                }
            }
        }
        return catalogMenuItems + injected
    }

    private var reportedDuplicateIDs = Set<String>()

    private func reportDroppedDuplicate(_ id: String, provider: String) {
        #if DEBUG
        guard reportedDuplicateIDs.insert(id).inserted else { return }
        NSLog("Panelumi: %@", "menu item provider \(provider) returned id \(id), which is already taken; the row is dropped.")
        #endif
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        update { $0.setEnabled(enabled, for: id) }
    }

    func setHotkey(_ binding: HotkeyBinding?, for id: String) {
        update { $0.setHotkey(binding, for: id) }
    }

    func markSetupComplete() {
        guard !config.didCompleteSetup else { return }
        update { $0.didCompleteSetup = true }
    }

    func move(_ id: String, by offset: Int) {
        update { $0.move(id, by: offset, allIDs: catalog.ids) }
    }

    /// Drag reordering from the Customize list. `destination` is SwiftUI's
    /// insertion index over the full list, hidden switches included.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { $0.move(fromOffsets: source, toOffset: destination, allIDs: catalog.ids) }
    }

    private func update(_ body: (inout PanelumiConfig) -> Void) {
        store.update(body)
        config = store.config
        registerHotkeys()
    }

    /// Re-registers every shortcut after a config change.
    ///
    /// Every row the menu shows is registered, built-in or added by a provider.
    /// Conflict checks: identical bindings inside the app are caught here, and
    /// combinations another app already owns fail inside Carbon.
    private func registerHotkeys() {
        registerHotkeys(for: menuItems)
    }

    /// Called by every menu rebuild with the rows it is about to show, so a
    /// provider row that appears or goes away gets or loses its shortcut
    /// without a config change. Unchanged rows are left registered.
    func syncHotkeys(with items: [SwitchItem]) {
        guard items.map(\.id) != registeredIDs else { return }
        registerHotkeys(for: items)
    }

    private func registerHotkeys(for items: [SwitchItem]) {
        hotkeys.unregisterAll()
        registeredIDs = items.map(\.id)

        var issues: [String] = []
        var owners: [HotkeyBinding: String] = [:]

        for item in items {
            guard let binding = config.hotkey(for: item.id) else { continue }

            guard binding.isUsable else {
                issues.append("\(item.title): \(binding.displayString) needs ⌘, ⌥ or ⌃.")
                continue
            }

            if let ownerID = owners[binding] {
                let owner = items.first { $0.id == ownerID }?.title ?? ownerID
                issues.append("\(item.title): \(binding.displayString) is already used by \(owner).")
                continue
            }

            do {
                try hotkeys.register(binding) { [weak self] in
                    self?.runSwitch?(item.id)
                }
                owners[binding] = item.id
            } catch {
                issues.append("\(item.title): \(error.localizedDescription)")
            }
        }

        hotkeyIssues = issues
    }
}
