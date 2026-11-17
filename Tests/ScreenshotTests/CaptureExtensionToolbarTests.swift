import AppKit
import SwiftUI
import XCTest
@testable import SwitchDeckCore

/// The extension toolbar item: the snapshot taken when editing starts, the
/// toolbar it renders into, and the per-view action it reports. No real event
/// delivery, key window or local monitor is involved.
final class CaptureExtensionToolbarTests: XCTestCase {
    /// Two extensions with an item, one without and one with an empty item:
    /// only the first two are kept, in registration order.
    @MainActor
    func testToolbarEntriesSkipMissingAndEmptyItemsAndKeepOrder() {
        let one = FakeExtension(
            identifier: "test.one",
            toolbarItem: singleEntryItem(id: "one")
        )
        let missing = FakeExtension(identifier: "test.missing")
        let two = FakeExtension(
            identifier: "test.two",
            toolbarItem: singleEntryItem(id: "two")
        )
        let empty = FakeExtension(
            identifier: "test.empty",
            toolbarItem: CaptureToolbarItem(title: "Empty", systemImage: "sparkles", entries: [])
        )

        let entries = CaptureSession.toolbarEntries(for: [one, missing, two, empty])

        XCTAssertEqual(entries.map(\.id), ["test.one", "test.two"])
        XCTAssertEqual(entries.map { $0.item.entries.map(\.id) }, [["one"], ["two"]])
    }

    /// An item must widen the toolbar on its own (the host sizes itself from
    /// the fitting size). An extension with no item must leave it untouched.
    @MainActor
    func testToolbarIsWiderForAnItemAndUnchangedWithoutOne() {
        let bare = CaptureSession()
        let withoutItem = CaptureSession()
        withoutItem.extensionToolbarItems = CaptureSession.toolbarEntries(
            for: [FakeExtension(identifier: "test.missing")]
        )
        let withItem = CaptureSession()
        withItem.extensionToolbarItems = CaptureSession.toolbarEntries(
            for: [FakeExtension(identifier: "test.one", toolbarItem: singleEntryItem(id: "one"))]
        )

        let bareSize = fittingSize(of: bare)
        let withoutItemSize = fittingSize(of: withoutItem)
        let withItemSize = fittingSize(of: withItem)

        XCTAssertEqual(withoutItemSize, bareSize, "An extension with no item adds no views")
        XCTAssertGreaterThan(withItemSize.width, bareSize.width, "An item widens the toolbar")
        XCTAssertEqual(withItemSize.height, bareSize.height, "An item keeps the row height")
    }

    /// The snapshot is taken once, at editing start: later changes to the
    /// extension's item do not reach the toolbar.
    @MainActor
    func testEditingSnapshotsTheItemsOnce() throws {
        let screen = try requireScreen()
        let original = singleEntryItem(id: "one")
        let extensionUnderTest = FakeExtension(identifier: "test.one", toolbarItem: original)
        let controller = SelectionController(captureExtensions: [extensionUnderTest])
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in XCTFail("Editing must not deliver a capture") },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }

        XCTAssertEqual(controller.session.extensionToolbarItems.count, 1)
        XCTAssertEqual(controller.session.extensionToolbarItems.first?.id, "test.one")
        XCTAssertEqual(controller.session.extensionToolbarItems.first?.item, original)
        XCTAssertTrue(controller.session.captureActionsAllowed, "A region selection allows actions")

        extensionUnderTest.toolbarItem = nil

        XCTAssertEqual(controller.session.extensionToolbarItems.count, 1, "The snapshot is taken once")
        XCTAssertEqual(controller.session.extensionToolbarItems.first?.item, original)
        XCTAssertFalse(cancelled)
    }

    @MainActor
    func testEditingWithoutExtensionsSnapshotsNothing() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in XCTFail("Editing must not deliver a capture") },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }

        XCTAssertTrue(controller.session.extensionToolbarItems.isEmpty)
        XCTAssertFalse(cancelled)
    }

    /// The view reports the picked entry with the region in global screen
    /// coordinates, and stays quiet while an annotation is on the selection.
    @MainActor
    func testPickingAnEntryReportsTheRegionInScreenSpace() throws {
        let screen = try requireScreen()
        let selection = editingRect(on: screen)
        let controller = SelectionController()
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in XCTFail("A toolbar action must not deliver a capture") },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: selection
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))

        var calls: [(extensionID: String, entryID: String, region: CGRect)] = []
        view.onCaptureAction = { calls.append(($0, $1, $2)) }

        view.requestCaptureAction("test.one", "one")

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.extensionID, "test.one")
        XCTAssertEqual(calls.first?.entryID, "one")
        guard let region = calls.first?.region else { return }
        // The view snaps its selection to the screen's backing scale, so the
        // region matches the requested selection to within that step.
        XCTAssertEqual(region.minX, selection.minX, accuracy: 0.5)
        XCTAssertEqual(region.minY, selection.minY, accuracy: 0.5)
        XCTAssertEqual(region.width, selection.width, accuracy: 0.5)
        XCTAssertEqual(region.height, selection.height, accuracy: 0.5)

        controller.session.annotations = [Annotation(
            shape: .rectangle(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.4, y: 0.4)),
            color: .red
        )]
        view.requestCaptureAction("test.one", "one")

        XCTAssertEqual(calls.count, 1, "An annotation disables the action")
        XCTAssertFalse(cancelled)
    }

    // MARK: - Helpers

    @MainActor
    private func singleEntryItem(id: String) -> CaptureToolbarItem {
        CaptureToolbarItem(
            title: "Example",
            systemImage: "sparkles",
            entries: [CaptureToolbarItem.Entry(id: id, title: "Example")]
        )
    }

    @MainActor
    private func fittingSize(of session: CaptureSession) -> CGSize {
        NSHostingView(rootView: CaptureToolbarView(session: session)).fittingSize
    }

    @MainActor
    private func requireScreen() throws -> NSScreen {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Needs a screen to host the overlay")
        }
        return screen
    }

    /// A rect in global screen coordinates, well inside the screen. Passing it
    /// as `initialSelection` puts the overlay straight into editing.
    @MainActor
    private func editingRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.midX - 100, y: frame.midY - 75, width: 200, height: 150)
    }

    @MainActor
    private func overlayView(on screen: NSScreen) -> SelectionView? {
        NSApp.windows.compactMap { window -> SelectionView? in
            guard window.isVisible, let view = window.contentView as? SelectionView else { return nil }
            return view
        }
        .first { $0.screen == screen }
    }

    /// Cancels a still-active overlay. Called from `defer`, so a failed lookup
    /// cannot leave the controller active.
    @MainActor
    private func cancel(_ controller: SelectionController, on screen: NSScreen) {
        guard controller.isActive, let view = overlayView(on: screen) else { return }
        view.onCancel?()
    }
}
