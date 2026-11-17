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
    /// The region of each `begin` call, in the same order as `beginCalls`.
    private(set) var beginRegions: [CGRect] = []
    private(set) var contexts: [CaptureContext] = []
    /// The takeover to return; nil makes `begin` decline.
    var takeover: CaptureTakeover? = FakeTakeover()
    /// Runs inside `begin` before the takeover is returned, so a test can call
    /// `context.cancel()` synchronously.
    var beginAction: ((CaptureContext) -> Void)?

    init(identifier: String = "test.extension", toolbarItem: CaptureToolbarItem? = nil) {
        self.identifier = identifier
        self.toolbarItem = toolbarItem
    }

    func begin(_ entryID: String, context: CaptureContext) -> CaptureTakeover? {
        beginCalls.append(entryID)
        beginRegions.append(context.region)
        contexts.append(context)
        beginAction?(context)
        return takeover
    }
}

/// A takeover that records the calls it receives.
@MainActor
final class FakeTakeover: CaptureTakeover {
    private(set) var keys: [CaptureKey] = []
    private(set) var endReasons: [CaptureEndReason] = []
    var consumesKeys = false
    /// Runs inside `takeoverDidEnd`, after the reason is recorded, so a test
    /// can read the state the host has restored by then.
    var onEnd: ((CaptureEndReason) -> Void)?
    /// Runs inside `handleKey` before the result is returned.
    var onHandleKey: ((CaptureKey) -> Void)?

    func handleKey(_ key: CaptureKey) -> Bool {
        keys.append(key)
        onHandleKey?(key)
        return consumesKeys
    }

    func takeoverDidEnd(reason: CaptureEndReason) {
        endReasons.append(reason)
        onEnd?(reason)
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
