import AppKit
import XCTest
import PanelumiKit
@testable import PanelumiCore

private struct FakeProvider: MenuItemProvider {
    let identifier: String
    private let make: @Sendable @MainActor () -> [SwitchItem]
    init(_ identifier: String, make: @escaping @Sendable @MainActor () -> [SwitchItem]) {
        self.identifier = identifier
        self.make = make
    }
    @MainActor var items: [SwitchItem] { make() }
}

@MainActor
final class MenuItemProviderTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    private func row(_ id: String, title: String? = nil, isEnabled: @escaping () -> Bool = { true }) -> SwitchItem {
        SwitchItem(id: id, title: title ?? id, symbolName: "circle", kind: .action, isEnabled: isEnabled, perform: {})
    }

    private let catalogIDs = ["a", "b", "c"]

    private func makeModel(
        itemProviders: [any MenuItemProvider] = [],
        bindings: [String: HotkeyBinding] = [:],
        hidden: [String] = []
    ) -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-item-provider-\(UUID().uuidString).json")
        urls.append(url)
        let store = ConfigStore(url: url)
        store.update { config in
            config.didSeedScreenshotShortcut = true
            for (id, binding) in bindings { config.setHotkey(binding, for: id) }
            for id in hidden { config.setEnabled(false, for: id) }
        }
        let catalog = SwitchCatalog(items: catalogIDs.map { row($0) })
        return AppModel(catalog: catalog, store: store, itemProviders: itemProviders)
    }

    private func binding(_ keyCode: UInt32) -> HotkeyBinding {
        HotkeyBinding(
            keyCode: keyCode,
            modifiers: HotkeyBinding.controlModifier | HotkeyBinding.optionModifier
                | HotkeyBinding.commandModifier | HotkeyBinding.shiftModifier,
            label: "F\(keyCode)"
        )
    }

    func testNoProvidersLeavesMenuItemsUnchanged() {
        let model = makeModel()
        XCTAssertEqual(model.menuItems.map(\.id), catalogIDs)
        XCTAssertEqual(model.menuItems.map(\.id), model.catalogMenuItems.map(\.id))
    }

    func testProvidersAppendAfterCatalogInListedOrder() {
        let model = makeModel(itemProviders: [
            FakeProvider("one") { [self.row("x"), self.row("y")] },
            FakeProvider("two") { [self.row("z")] },
        ])
        XCTAssertEqual(model.menuItems.map(\.id), ["a", "b", "c", "x", "y", "z"])
        XCTAssertEqual(model.catalogMenuItems.map(\.id), catalogIDs)
    }

    func testIDCollidingWithCatalogIsDroppedWithoutFalseHotkeyIssue() {
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("b", title: "Injected"), self.row("x")] }],
            bindings: ["b": binding(105)]
        )
        XCTAssertEqual(model.menuItems.map(\.id), ["a", "b", "c", "x"])
        XCTAssertEqual(model.menuItems.first { $0.id == "b" }?.title, "b")
        XCTAssertTrue(model.hotkeyIssues.isEmpty, "\(model.hotkeyIssues)")
    }

    func testDuplicateIDAcrossProvidersKeepsFirst() {
        let model = makeModel(itemProviders: [
            FakeProvider("one") { [self.row("x", title: "First")] },
            FakeProvider("two") { [self.row("x", title: "Second")] },
        ])
        let injected = model.menuItems.filter { $0.id == "x" }
        XCTAssertEqual(injected.map(\.title), ["First"])
    }

    func testProviderWithRepeatedIdentifierIsDropped() {
        let model = makeModel(itemProviders: [
            FakeProvider("same") { [self.row("x")] },
            FakeProvider("same") { [self.row("y")] },
        ])
        XCTAssertEqual(model.menuItems.map(\.id), catalogIDs + ["x"])
    }

    func testBindingForInjectedIDIsNotRegisteredAndNotReported() {
        // The same binding on a catalog id would be reported as "already used"
        // if the injected row were registered too.
        let shared = binding(105)
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("x")] }],
            bindings: ["x": shared, "a": shared]
        )
        XCTAssertTrue(model.hotkeyIssues.isEmpty, "\(model.hotkeyIssues)")
    }

    func testCatalogHotkeyRegistrationIsUnchangedByProviders() {
        let shared = binding(105)
        // One model at a time: a second live model would hit the first one's
        // Carbon registrations.
        var without: AppModel? = makeModel(bindings: ["a": shared, "b": shared])
        let baseline = without?.hotkeyIssues
        without = nil
        let with = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("x")] }],
            bindings: ["a": shared, "b": shared]
        )
        XCTAssertEqual(baseline, ["b: \(shared.displayString) is already used by a."])
        XCTAssertEqual(with.hotkeyIssues, baseline)
    }

    func testIDMatchingHiddenCatalogRowIsStillDropped() {
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("b", title: "Injected")] }],
            hidden: ["b"]
        )
        XCTAssertEqual(model.menuItems.map(\.id), ["a", "c"])
    }

    private final class Flag: @unchecked Sendable { var value = false }

    func testValidationReflectsIsEnabledOnEachOpen() throws {
        let flag = Flag()
        let model = makeModel(itemProviders: [FakeProvider("one") {
            [
                SwitchItem(id: "gate", title: "Gate", symbolName: "circle", kind: .action,
                           subtitle: { "Needs setup" }, isEnabled: { flag.value }, perform: {}),
                SwitchItem(id: "sub", title: "Sub", symbolName: "circle", kind: .action,
                           actions: { [.init(title: "Child") {}] }, perform: {}),
            ]
        }])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        XCTAssertTrue(menu.autoenablesItems)
        func row(_ prefix: String) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.first { ($0.attributedTitle?.string ?? "").hasPrefix(prefix) })
        }
        let gate = try row("Gate")
        XCTAssertTrue(gate.attributedTitle?.string.contains("Needs setup") == true)

        XCTAssertFalse(controller.validateMenuItem(gate))
        menu.update()
        XCTAssertFalse(gate.isEnabled)

        flag.value = true
        XCTAssertTrue(controller.validateMenuItem(gate))
        menu.update()
        XCTAssertTrue(gate.isEnabled)

        flag.value = false
        menu.update()
        XCTAssertFalse(gate.isEnabled)

        // Built-in rows, submenu entries and the Settings row keep answering true.
        XCTAssertTrue(controller.validateMenuItem(try XCTUnwrap(menu.items.first)))
        let child = try XCTUnwrap(try row("Sub").submenu?.items.first)
        XCTAssertTrue(controller.validateMenuItem(child))
        let settings = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("showSettings") })
        XCTAssertTrue(controller.validateMenuItem(settings))
        menu.update()
        XCTAssertTrue(settings.isEnabled)
    }

    func testMenuLinesListInjectedRowsAfterBuiltInsWithoutShortcuts() {
        let shared = binding(105)
        let model = makeModel(
            itemProviders: [
                FakeProvider("one") { [self.row("x", title: "Extra"), self.row("a", title: "Dup")] },
                FakeProvider("two") { [self.row("y", title: "Other")] },
            ],
            bindings: ["x": shared, "b": binding(106)],
            hidden: ["c"]
        )
        let lines = Dump.menuLines(model: model)
        XCTAssertEqual(lines.first, "menu items: 4 (2 of 3 switches, 1 hidden; 2 added)")
        XCTAssertEqual(Array(lines.dropFirst()), [
            " 1 a",
            " 2 b [\(binding(106).displayString)]",
            " 3 Extra",
            " 4 Other",
        ])
    }

    private final class Text: @unchecked Sendable {
        var title = "Old"
        var subtitle = "one"
    }

    func testOpeningMenuRefreshesSubtitleButNotTitle() throws {
        let text = Text()
        let model = makeModel(itemProviders: [FakeProvider("one") {
            [SwitchItem(id: "dyn", title: text.title, symbolName: "circle", kind: .action,
                        subtitle: { text.subtitle }, perform: {})]
        }])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        func dynRow() throws -> String {
            try XCTUnwrap(menu.items.compactMap { $0.attributedTitle?.string }
                .first { $0.hasPrefix("Old") || $0.hasPrefix("New") })
        }
        XCTAssertTrue(try dynRow().contains("one"))

        text.subtitle = "two"
        text.title = "New"
        controller.menuWillOpen(menu)
        let opened = try dynRow()
        XCTAssertTrue(opened.hasPrefix("Old"), opened)
        XCTAssertTrue(opened.contains("two"), opened)
        XCTAssertFalse(opened.contains("one"), opened)
        controller.menuDidClose(menu)
    }

    func testLaunchOptionsEqualityComparesIdentifiersInOrder() {
        let a = FakeProvider("a") { [] }
        let b = FakeProvider("b") { [] }
        XCTAssertEqual(LaunchOptions(menuItemProviders: [a, b]), LaunchOptions(menuItemProviders: [FakeProvider("a") { [] }, b]))
        XCTAssertNotEqual(LaunchOptions(menuItemProviders: [a, b]), LaunchOptions(menuItemProviders: [b, a]))
        XCTAssertNotEqual(LaunchOptions(menuItemProviders: [a]), LaunchOptions())
        XCTAssertEqual(LaunchOptions(), LaunchOptions(menuItemProviders: []))
    }

    func testSwitchItemIsEnabledDefaultsToTrue() {
        XCTAssertTrue(row("q").isEnabled())
    }
}
