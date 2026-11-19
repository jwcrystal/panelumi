import AppKit
import XCTest
@testable import PanelumiCore

/// The pin is dragged by its own picture, which fills the window: the window's
/// `isMovableByWindowBackground` only starts a drag while the view under the
/// pointer allows one.
final class PinnedWindowDragTests: XCTestCase {
    @MainActor
    func testThePictureLetsTheWindowMove() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertTrue(
            content.imageView.mouseDownCanMoveWindow,
            "the image covers the pin, so a plain NSImageView would leave nothing to drag"
        )
    }

    @MainActor
    func testThePictureCoversTheWholePin() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.imageView.frame, content.bounds)
    }

    @MainActor
    func testTheZoomReadoutFollowsHowFarThePinIsFromThePictureSize() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        content.naturalWidth = 1000
        content.syncZoom()
        XCTAssertEqual(content.toolbar.zoom, 0.4, accuracy: 0.0001)
    }

    @MainActor
    func testTheZoomReadoutOpensAtThePicturesOwnSize() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        content.naturalWidth = 500
        content.syncZoom()
        XCTAssertEqual(content.toolbar.zoom, 1, accuracy: 0.0001)
    }

    @MainActor
    func testThePillWaitsForThePointer() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.toolbar.isHidden)

        content.isPointerInside = true
        XCTAssertFalse(content.toolbar.isHidden)

        content.isPointerInside = false
        XCTAssertTrue(content.toolbar.isHidden)
        XCTAssertEqual(content.toolbar.alphaValue, 0)
    }

    @MainActor
    func testZoomHoldsThePointUnderThePointerStill() {
        let window = PinnedWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.naturalSize = NSSize(width: 400, height: 300)

        window.setZoom(2, around: NSPoint(x: 300, y: 250))

        XCTAssertEqual(window.frame.width, 800, accuracy: 0.5)
        XCTAssertEqual(window.frame.midX, 300, accuracy: 0.5)
        XCTAssertEqual(window.frame.midY, 250, accuracy: 0.5)
    }

    @MainActor
    func testZoomStopsAtTheEndsOfItsRange() {
        let window = PinnedWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.naturalSize = NSSize(width: 400, height: 300)

        window.setZoom(99)
        XCTAssertEqual(window.frame.width, 1600, accuracy: 0.5)
        XCTAssertEqual(window.zoom, 4, accuracy: 0.0001)

        window.setZoom(0.001)
        XCTAssertEqual(window.zoom, 0.1, accuracy: 0.0001)
    }

    @MainActor
    func testTheWheelZoomsAroundThePointer() throws {
        let window = PinnedWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.naturalSize = NSSize(width: 400, height: 300)

        let scroll = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
        )
        window.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))

        XCTAssertGreaterThan(window.zoom, 1.05)
        XCTAssertLessThan(window.zoom, 1.2)
    }

    @MainActor
    func testANarrowPinKeepsCopyAndCloseInACompactPill() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
        content.isPointerInside = true
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.toolbar.isCompact)
        XCTAssertFalse(content.toolbar.isHidden)
    }

    @MainActor
    func testAWidePinShowsTheFullPill() {
        let content = PinnedContentView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        content.isPointerInside = true
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.toolbar.isCompact)
        XCTAssertFalse(content.toolbar.isHidden)
    }
}
