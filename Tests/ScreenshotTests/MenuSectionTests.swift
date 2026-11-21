import AppKit
import XCTest
import PanelumiKit
@testable import PanelumiCore

private struct FakeSection: MenuSectionProvider {
    let identifier: String
    private let make: @Sendable @MainActor () -> [SwitchItem]
    init(_ identifier: String, make: @escaping @Sendable @MainActor () -> [SwitchItem]) {
        self.identifier = identifier
        self.make = make
    }
    @MainActor var items: [SwitchItem] { make() }
}

@MainActor
final class MenuSectionTests: XCTestCase {
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
        sections: [any MenuSectionProvider] = [],
        bindings: [String: HotkeyBinding] = [:]
    ) -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-section-\(UUID().uuidString).json")
        urls.append(url)
        let store = ConfigStore(url: url)
        store.update { config in
            config.didSeedScreenshotShortcut = true
            for (id, binding) in bindings { config.setHotkey(binding, for: id) }
        }
        let catalog = SwitchCatalog(items: catalogIDs.map { row($0) })
        return AppModel(catalog: catalog, store: store, sections: sections)
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
        let model = makeModel(sections: [
            FakeSection("one") { [self.row("x"), self.row("y")] },
            FakeSection("two") { [self.row("z")] },
        ])
        XCTAssertEqual(model.menuItems.map(\.id), ["a", "b", "c", "x", "y", "z"])
        XCTAssertEqual(model.catalogMenuItems.map(\.id), catalogIDs)
    }

    func testIDCollidingWithCatalogIsDroppedWithoutFalseHotkeyIssue() {
        let model = makeModel(
            sections: [FakeSection("one") { [self.row("b", title: "Injected"), self.row("x")] }],
            bindings: ["b": binding(105)]
        )
        XCTAssertEqual(model.menuItems.map(\.id), ["a", "b", "c", "x"])
        XCTAssertEqual(model.menuItems.first { $0.id == "b" }?.title, "b")
        XCTAssertTrue(model.hotkeyIssues.isEmpty, "\(model.hotkeyIssues)")
    }

    func testDuplicateIDAcrossProvidersKeepsFirst() {
        let model = makeModel(sections: [
            FakeSection("one") { [self.row("x", title: "First")] },
            FakeSection("two") { [self.row("x", title: "Second")] },
        ])
        let injected = model.menuItems.filter { $0.id == "x" }
        XCTAssertEqual(injected.map(\.title), ["First"])
    }

    func testBindingForInjectedIDIsNotRegisteredAndNotReported() {
        // The same binding on a catalog id would be reported as "already used"
        // if the injected row were registered too.
        let shared = binding(105)
        let model = makeModel(
            sections: [FakeSection("one") { [self.row("x")] }],
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
            sections: [FakeSection("one") { [self.row("x")] }],
            bindings: ["a": shared, "b": shared]
        )
        XCTAssertEqual(baseline, ["b: \(shared.displayString) is already used by a."])
        XCTAssertEqual(with.hotkeyIssues, baseline)
    }

    func testDisabledRowBuildsDisabledMenuItemAndKeepsSubtitle() throws {
        let model = makeModel(sections: [FakeSection("one") {
            [
                SwitchItem(id: "off", title: "Off", symbolName: "circle", kind: .action,
                           subtitle: { "Needs setup" }, isEnabled: { false }, perform: {}),
                self.row("on"),
            ]
        }])
        let controller = MenuController(model: model, permissions: PermissionCenter())
        let menu = try XCTUnwrap(controller.currentMenu)
        XCTAssertFalse(menu.autoenablesItems)
        let off = try XCTUnwrap(menu.items.first { ($0.attributedTitle?.string ?? "").hasPrefix("Off") })
        let on = try XCTUnwrap(menu.items.first { ($0.attributedTitle?.string ?? "").hasPrefix("on") })
        XCTAssertFalse(off.isEnabled)
        XCTAssertTrue(off.attributedTitle?.string.contains("Needs setup") == true)
        XCTAssertTrue(on.isEnabled)
        // Rows AppKit used to enable on its own stay enabled.
        let first = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(first.isEnabled)
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("showSettings") && $0.isEnabled })
    }

    func testLaunchOptionsEqualityComparesIdentifiersInOrder() {
        let a = FakeSection("a") { [] }
        let b = FakeSection("b") { [] }
        XCTAssertEqual(LaunchOptions(menuSections: [a, b]), LaunchOptions(menuSections: [FakeSection("a") { [] }, b]))
        XCTAssertNotEqual(LaunchOptions(menuSections: [a, b]), LaunchOptions(menuSections: [b, a]))
        XCTAssertNotEqual(LaunchOptions(menuSections: [a]), LaunchOptions())
        XCTAssertEqual(LaunchOptions(), LaunchOptions(menuSections: []))
    }

    func testSwitchItemIsEnabledDefaultsToTrue() {
        XCTAssertTrue(row("q").isEnabled())
    }
}
