import AppKit
import XCTest
@testable import SwitchDeckCore

/// A capture extension that only records what the host asks it to do. Not
/// `private` so the extension tests can share it.
@MainActor
final class FakeExtension: CaptureExtension {
    nonisolated let identifier: String
    var toolbarItem: CaptureToolbarItem?
    private(set) var beginCalls: [String] = []
    private(set) var contexts: [CaptureContext] = []
    var takeover: CaptureTakeover? = FakeTakeover()

    init(identifier: String = "test.extension", toolbarItem: CaptureToolbarItem? = nil) {
        self.identifier = identifier
        self.toolbarItem = toolbarItem
    }

    func begin(_ entryID: String, context: CaptureContext) -> CaptureTakeover? {
        beginCalls.append(entryID)
        contexts.append(context)
        return takeover
    }
}

/// A takeover that records the calls it receives.
@MainActor
final class FakeTakeover: CaptureTakeover {
    private(set) var keys: [CaptureKey] = []
    private(set) var endReasons: [CaptureEndReason] = []
    var consumesKeys = false

    func handleKey(_ key: CaptureKey) -> Bool {
        keys.append(key)
        return consumesKeys
    }

    func takeoverDidEnd(reason: CaptureEndReason) {
        endReasons.append(reason)
    }
}

final class CaptureExtensionAPITests: XCTestCase {
    @MainActor
    func testLauncherAcceptsLaunchOptions() {
        let _: (LaunchOptions) -> Void = SwitchDeckLauncher.run
    }

    @MainActor
    func testLaunchOptionsHaveDefaults() {
        let _: () -> Void = { _ = LaunchOptions() }
        _ = LaunchOptions(identity: .standard)
        XCTAssertEqual(LaunchOptions(), LaunchOptions())
    }

    @MainActor
    func testLaunchOptionsCompareExtensionIdentifiers() {
        let one = LaunchOptions(captureExtensions: [FakeExtension(identifier: "test.one")])
        let same = LaunchOptions(captureExtensions: [FakeExtension(identifier: "test.one")])
        let other = LaunchOptions(captureExtensions: [FakeExtension(identifier: "test.two")])
        let ordered = LaunchOptions(captureExtensions: [
            FakeExtension(identifier: "test.one"),
            FakeExtension(identifier: "test.two"),
        ])
        let reversed = LaunchOptions(captureExtensions: [
            FakeExtension(identifier: "test.two"),
            FakeExtension(identifier: "test.one"),
        ])

        XCTAssertEqual(one, same)
        XCTAssertNotEqual(one, other)
        XCTAssertNotEqual(one, LaunchOptions())
        XCTAssertNotEqual(ordered, reversed)
    }

    func testToolbarEntryIsIdentifiedByID() {
        let entries = [
            CaptureToolbarItem.Entry(id: "entry-1", title: "First"),
            CaptureToolbarItem.Entry(id: "entry-2", title: "Second"),
        ]
        let item = CaptureToolbarItem(
            title: "Example",
            systemImage: "sparkles",
            entries: entries
        )

        XCTAssertEqual(item.entries.map(\.id), ["entry-1", "entry-2"])
        let byIdentity = Set(item.entries.map(\.id))
        XCTAssertEqual(byIdentity.count, item.entries.count)
        XCTAssertEqual(item.entries.first, CaptureToolbarItem.Entry(id: "entry-1", title: "First"))
    }
}
