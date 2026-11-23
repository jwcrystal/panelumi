import SwiftUI
import XCTest
@testable import PanelumiCore

private final class PageProvider: SettingsPageProvider, @unchecked Sendable {
    let identifier: String
    private let make: @MainActor () -> [SettingsPage]
    private(set) var reads = 0

    init(_ identifier: String, make: @escaping @MainActor () -> [SettingsPage] = {
        [SettingsPage(id: "page", title: "Extra", symbolName: "square") { AnyView(EmptyView()) }]
    }) {
        self.identifier = identifier
        self.make = make
    }

    @MainActor var pages: [SettingsPage] {
        reads += 1
        return make()
    }
}

@MainActor
private final class IsolatedProvider: SettingsPageProvider {
    nonisolated let identifier: String = "isolated"
    var pages: [SettingsPage] {
        [SettingsPage(id: "isolated.page", title: "Isolated", symbolName: "square") { AnyView(EmptyView()) }]
    }
}

@MainActor
final class SettingsPageTests: XCTestCase {
    func testLaunchOptionsComparePageProvidersByIdentifierAndOrder() {
        let first = LaunchOptions(settingsPageProviders: [PageProvider("one"), PageProvider("two")])
        let same = LaunchOptions(settingsPageProviders: [PageProvider("one"), PageProvider("two")])
        let reversed = LaunchOptions(settingsPageProviders: [PageProvider("two"), PageProvider("one")])
        let fewer = LaunchOptions(settingsPageProviders: [PageProvider("one")])

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, reversed)
        XCTAssertNotEqual(first, fewer)
        XCTAssertNotEqual(first, LaunchOptions())
    }

    func testPagesCarryTheirOwnTitleAndSymbol() {
        let page = SettingsPage(id: "pro.x", title: "Pro X", symbolName: "star") { AnyView(EmptyView()) }
        XCTAssertEqual(page.id, "pro.x")
        XCTAssertEqual(page.title, "Pro X")
        XCTAssertEqual(page.symbolName, "star")
    }

    func testPagesAreBuiltOnlyWhenRead() {
        let provider = PageProvider("one")
        let options = LaunchOptions(settingsPageProviders: [provider])
        XCTAssertEqual(provider.reads, 0)
        XCTAssertEqual(options.settingsPageProviders.count, 1)
        XCTAssertEqual(provider.reads, 0)
        _ = options.settingsPageProviders[0].pages
        XCTAssertEqual(provider.reads, 1)
    }

    func testRepeatedProviderIdentifierAndPageIDAreDropped() {
        func page(_ id: String, _ title: String) -> SettingsPage {
            SettingsPage(id: id, title: title, symbolName: "square") { AnyView(EmptyView()) }
        }
        let first = PageProvider("one") { [page("p1", "First"), page("shared", "First shared")] }
        let repeated = PageProvider("one") { [page("p2", "Repeated")] }
        let other = PageProvider("two") { [page("shared", "Other shared"), page("p3", "Other")] }

        let pages = AppDelegate.settingsPages(from: [first, repeated, other])

        XCTAssertEqual(pages.map(\.title), ["First", "First shared", "Other"])
        XCTAssertEqual(repeated.reads, 0)
    }

    func testSignatureChangesWithWhatTheSidebarShows() {
        func page(_ id: String, _ title: String, _ symbol: String = "square") -> SettingsPage {
            SettingsPage(id: id, title: title, symbolName: symbol) { AnyView(EmptyView()) }
        }
        XCTAssertEqual(page("p", "A").signature, page("p", "A").signature)
        XCTAssertNotEqual(page("p", "A").signature, page("q", "A").signature)
        XCTAssertNotEqual(page("p", "A").signature, page("p", "B").signature)
        XCTAssertNotEqual(page("p", "A").signature, page("p", "A", "star").signature)
    }

    func testInitialPageFollowsPaneArgument() {
        let pages = [SettingsPage(id: "pro.x", title: "X", symbolName: "star") { AnyView(EmptyView()) }]
        func initial(_ arguments: [String]) -> SettingsView.Page {
            SettingsWindowHost.initialPage(arguments: arguments, pages: pages)
        }
        XCTAssertEqual(initial(["x", "--pane", "screenshot"]), .builtin(.screenshot))
        XCTAssertEqual(initial(["x", "--pane", "pro.x"]), .injected("pro.x"))
        XCTAssertEqual(initial(["x", "--pane", "nope"]), .builtin(.general))
        XCTAssertEqual(initial(["x", "--pane"]), .builtin(.general))
        XCTAssertEqual(initial(["x"]), .builtin(.general))
    }

    func testMainActorProviderWithNonisolatedIdentifierWorks() {
        let options = LaunchOptions(settingsPageProviders: [IsolatedProvider()])
        XCTAssertEqual(options.settingsPageProviders.map(\.identifier), ["isolated"])
        XCTAssertEqual(AppDelegate.settingsPages(from: options.settingsPageProviders).map(\.id), ["isolated.page"])
    }
}
