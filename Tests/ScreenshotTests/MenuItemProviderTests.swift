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

private final class BindingProvider: MenuItemProvider, @unchecked Sendable {
    let identifier: String
    var rows: @MainActor () -> [SwitchItem]
    private(set) var bindCount = 0
    private(set) var rebuild: (@MainActor () -> Void)?
    private(set) var itemsReads = 0
    var callRebuildFromItems = false

    init(_ identifier: String, rows: @escaping @MainActor () -> [SwitchItem] = { [] }) {
        self.identifier = identifier
        self.rows = rows
    }

    @MainActor var items: [SwitchItem] {
        itemsReads += 1
        if callRebuildFromItems { rebuild?() }
        return rows()
    }

    @MainActor func bind(rebuildMenu: @escaping @MainActor () -> Void) {
        bindCount += 1
        rebuild = rebuildMenu
    }
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

    func testBindingForInjectedIDIsRegisteredAndConflictsAreReported() {
        // The injected row is registered after the built-in ones, so a repeated
        // combination is caught exactly as it is between two built-ins.
        let shared = binding(105)
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("x")] }],
            bindings: ["x": shared, "a": shared]
        )
        XCTAssertEqual(model.hotkeyIssues, ["x: \(shared.displayString) is already used by a."])
        XCTAssertEqual(model.shortcutLabel(for: "x"), shared.displayString)
    }

    func testMenuShowsShortcutsForInjectedRowsToo() throws {
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("x", title: "Injected")] }],
            bindings: ["x": binding(105), "a": binding(106)]
        )
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        func title(_ prefix: String) throws -> String {
            try XCTUnwrap(menu.items.compactMap { $0.attributedTitle?.string }.first { $0.hasPrefix(prefix) })
        }
        XCTAssertTrue(try title("Injected").contains(binding(105).displayString))
        XCTAssertTrue(try title("a").contains(binding(106).displayString))

        controller.menuWillOpen(menu)
        XCTAssertTrue(try title("Injected").contains(binding(105).displayString))
        XCTAssertTrue(try title("a").contains(binding(106).displayString))
        controller.menuDidClose(menu)
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

    func testPerformSwitchRunsAnInjectedRowAndRespectsIsEnabled() throws {
        let flag = Flag()
        var ran = 0
        let model = makeModel(itemProviders: [FakeProvider("one") {
            [SwitchItem(id: "gate", title: "Gate", symbolName: "circle", kind: .action,
                        isEnabled: { flag.value }, perform: { ran += 1 })]
        }])
        let controller = MenuController(model: model, permissions: PermissionCenter())

        flag.value = false
        controller.performSwitch(id: "gate")
        XCTAssertEqual(ran, 0)

        flag.value = true
        controller.performSwitch(id: "gate")
        XCTAssertEqual(ran, 1)
    }

    func testRowThatAppearsLaterIsRegisteredOnRebuild() {
        let shared = binding(105)
        let show = Flag()
        let provider = BindingProvider("one") { show.value ? [self.row("x")] : [] }
        let model = makeModel(itemProviders: [provider], bindings: ["x": shared, "a": shared])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        XCTAssertTrue(model.hotkeyIssues.isEmpty, "\(model.hotkeyIssues)")

        show.value = true
        provider.rebuild?()
        XCTAssertEqual(model.hotkeyIssues, ["x: \(shared.displayString) is already used by a."])

        show.value = false
        provider.rebuild?()
        XCTAssertTrue(model.hotkeyIssues.isEmpty, "\(model.hotkeyIssues)")
        withExtendedLifetime(controller) {}
    }

    func testShortcutItemsKeepHiddenBuiltInsAndAppendInjectedRows() {
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [self.row("x"), self.row("a")] }],
            hidden: ["b"]
        )
        XCTAssertEqual(model.shortcutItems.map(\.id), ["a", "b", "c", "x"])
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

    func testMenuLinesListInjectedRowsAfterBuiltIns() {
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
            " 3 Extra [\(shared.displayString)]",
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

    // MARK: - bind(rebuildMenu:)

    private func titles(_ controller: MenuController) throws -> [String] {
        try XCTUnwrap(controller.currentMenu).items.compactMap { $0.attributedTitle?.string }
    }

    func testProviderWithoutBindLeavesMenuAndRebuildsUnchanged() throws {
        let model = makeModel(itemProviders: [FakeProvider("one") { [self.row("x")] }])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        XCTAssertEqual(try titles(controller).filter { $0.hasPrefix("x") }.count, 1)
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)
        XCTAssertTrue(controller.currentMenu === menu)
    }

    func testEachProviderIsBoundOnceAndDroppedDuplicateIsNot() {
        let first = BindingProvider("same")
        let duplicate = BindingProvider("same")
        let other = BindingProvider("other")
        let model = makeModel(itemProviders: [first, duplicate, other])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        XCTAssertEqual(first.bindCount, 1)
        XCTAssertEqual(duplicate.bindCount, 0)
        XCTAssertEqual(other.bindCount, 1)
        first.rebuild?()
        XCTAssertEqual(first.bindCount, 1)
        withExtendedLifetime(controller) {}
    }

    func testRebuildClosureShowsNewRowsAndTitles() throws {
        let provider = BindingProvider("one") { [self.row("x", title: "Old")] }
        let model = makeModel(itemProviders: [provider])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let before = try XCTUnwrap(controller.currentMenu)
        XCTAssertEqual(try titles(controller).filter { $0.hasPrefix("Old") }.count, 1)

        provider.rows = { [self.row("x", title: "New"), self.row("y", title: "Added")] }
        provider.rebuild?()
        let after = try titles(controller)
        XCTAssertFalse(controller.currentMenu === before)
        XCTAssertEqual(after.filter { $0.hasPrefix("Old") }.count, 0)
        XCTAssertEqual(after.filter { $0.hasPrefix("New") }.count, 1)
        XCTAssertEqual(after.filter { $0.hasPrefix("Added") }.count, 1)
    }

    func testRebuildClosureWhileMenuIsOpenWaitsForClose() throws {
        let provider = BindingProvider("one") { [self.row("x", title: "Old")] }
        let model = makeModel(itemProviders: [provider])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        controller.menuWillOpen(menu)

        provider.rows = { [self.row("x", title: "New")] }
        provider.rebuild?()
        XCTAssertTrue(controller.currentMenu === menu)
        XCTAssertEqual(try titles(controller).filter { $0.hasPrefix("New") }.count, 0)

        controller.menuDidClose(menu)
        XCTAssertFalse(controller.currentMenu === menu)
        XCTAssertEqual(try titles(controller).filter { $0.hasPrefix("New") }.count, 1)
    }

    func testRebuildClosureCalledFromItemsDoesNotRecurse() throws {
        let provider = BindingProvider("one") { [self.row("x", title: "Row")] }
        let model = makeModel(itemProviders: [provider])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        provider.callRebuildFromItems = true
        let readsBefore = provider.itemsReads

        provider.rebuild?()
        XCTAssertEqual(provider.itemsReads - readsBefore, 1)
        XCTAssertEqual(try titles(controller).filter { $0.hasPrefix("Row") }.count, 1)
    }

    func testRebuildClosureAfterControllerReleasedDoesNothing() {
        let provider = BindingProvider("one")
        var controller: MenuController? = MenuController(
            model: makeModel(itemProviders: [provider]), permissions: PermissionCenter())
        let closure = provider.rebuild
        XCTAssertNotNil(closure)
        controller = nil
        closure?()
        XCTAssertNil(controller)
    }

    func testSubmenuEntryValidationFollowsIsEnabled() throws {
        let flag = Flag()
        let model = makeModel(itemProviders: [FakeProvider("one") {
            [SwitchItem(id: "sub", title: "Sub", symbolName: "circle", kind: .action,
                        actions: { [
                            .init(title: "Gated", isEnabled: { flag.value }) {},
                            .init(title: "Plain") {},
                        ] }, perform: {})]
        }])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        let sub = try XCTUnwrap(menu.items.first { ($0.attributedTitle?.string ?? "").hasPrefix("Sub") }?.submenu)
        let gated = try XCTUnwrap(sub.items.first { $0.title == "Gated" })
        let plain = try XCTUnwrap(sub.items.first { $0.title == "Plain" })

        XCTAssertTrue(sub.autoenablesItems)
        XCTAssertTrue(controller.validateMenuItem(plain))
        XCTAssertFalse(controller.validateMenuItem(gated))
        sub.update()
        XCTAssertFalse(gated.isEnabled)
        XCTAssertTrue(plain.isEnabled)

        flag.value = true
        XCTAssertTrue(controller.validateMenuItem(gated))
        sub.update()
        XCTAssertTrue(gated.isEnabled)
    }

    func testMenuActionIsEnabledDefaultsToTrue() {
        XCTAssertTrue(SwitchItem.MenuAction(title: "T") {}.isEnabled())
    }

    func testMenuDumpDoesNotBindProviders() {
        let provider = BindingProvider("one") { [self.row("x")] }
        Dump.printMenu(itemProviders: [provider])
        XCTAssertEqual(provider.bindCount, 0)
    }

    func testRunTargetResolvesBuiltInHiddenInjectedAndRefusesTheRest() {
        let model = makeModel(
            itemProviders: [FakeProvider("one") { [
                self.row("x"),
                self.row("off", title: "Off", isEnabled: { false }),
                self.row("a"),
            ] }],
            hidden: ["b"]
        )
        func resolve(_ id: String) -> Result<SwitchItem, Dump.RunTargetError> {
            Dump.resolveRunTarget(id: id, model: model)
        }
        XCTAssertEqual(try? resolve("a").get().id, "a")
        XCTAssertEqual(try? resolve("b").get().id, "b")
        XCTAssertEqual(try? resolve("x").get().id, "x")
        XCTAssertEqual(resolve("nope").failureValue, .unknown)
        XCTAssertEqual(resolve("off").failureValue, .disabled(title: "Off"))
    }

    @MainActor
    func testScratchModelCarriesTheUserConfigAndNeverWritesTheSource() throws {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("panelumi-scratch-source-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: source) }
        let sourceStore = ConfigStore(url: source)
        sourceStore.update { $0.setEnabled(false, for: "keepAwake") }
        let before = try Data(contentsOf: source)

        let (hidden, seeded) = Dump.withScratchModel(source: source, catalog: .standard(), itemProviders: []) {
            ($0.config.disabled, $0.config.didSeedScreenshotShortcut)
        }

        XCTAssertEqual(hidden, ["keepAwake"])
        XCTAssertTrue(seeded)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    @MainActor
    func testScratchModelWithoutASourceDoesNotCreateIt() {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("panelumi-scratch-missing-\(UUID().uuidString).json")
        Dump.withScratchModel(source: source, catalog: .standard(), itemProviders: []) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
