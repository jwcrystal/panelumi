import AppKit
import SwiftUI
import XCTest
@testable import PanelumiCore

@MainActor
final class SettingsWindowHostTests: XCTestCase {
    private var pages: [SettingsPage] = []
    private var reads = 0
    private var requestedPages: [SettingsView.Page] = []

    private func page(_ id: String, _ title: String = "Extra") -> SettingsPage {
        SettingsPage(id: id, title: title, symbolName: "square") { AnyView(EmptyView()) }
    }

    private func makeHost() -> SettingsWindowHost {
        SettingsWindowHost(
            pages: { [unowned self] in
                reads += 1
                return pages
            },
            makeView: { [unowned self] _, initial in
                requestedPages.append(initial)
                return AnyView(EmptyView())
            }
        )
    }

    func testFirstOpenCreatesTheWindowOnTheRequestedPage() {
        pages = [page("pro.x")]
        let window = makeHost().prepareWindow(arguments: ["x", "--pane", "pro.x"])
        XCTAssertEqual(window.title, "Panelumi")
        XCTAssertEqual(window.styleMask, [.titled, .closable, .miniaturizable])
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(requestedPages, [.injected("pro.x")])
    }

    func testSamePagesKeepTheWindowAndItsController() throws {
        pages = [page("a")]
        let host = makeHost()
        let first = host.prepareWindow(arguments: [])
        let controller = try XCTUnwrap(first.contentViewController)

        let second = host.prepareWindow(arguments: [])
        XCTAssertTrue(first === second)
        XCTAssertTrue(second.contentViewController === controller)
        XCTAssertEqual(requestedPages.count, 1)
    }

    func testChangedPagesInstallANewControllerAndKeepTheFrame() throws {
        pages = [page("a")]
        let host = makeHost()
        let window = host.prepareWindow(arguments: ["x", "--pane", "a"])
        let controller = try XCTUnwrap(window.contentViewController)
        let frame = NSRect(x: 120, y: 140, width: 640, height: 480)
        window.setFrame(frame, display: false)

        pages = [page("a"), page("b")]
        let reopened = host.prepareWindow(arguments: ["x", "--pane", "a"])
        XCTAssertTrue(reopened === window)
        XCTAssertFalse(reopened.contentViewController === controller)
        XCTAssertEqual(reopened.frame, frame)
        XCTAssertEqual(requestedPages, [.injected("a"), .builtin(.general)])
    }

    func testPagesAreReadOnEveryOpen() {
        pages = [page("a")]
        let host = makeHost()
        _ = host.prepareWindow(arguments: [])
        _ = host.prepareWindow(arguments: [])
        _ = host.prepareWindow(arguments: [])
        XCTAssertEqual(reads, 3)
    }
}
