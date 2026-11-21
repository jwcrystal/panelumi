import AppKit
import XCTest
@testable import PanelumiCore

final class WindowPickTests: XCTestCase {
    func testApplicationWindowsAreCapturedLive() {
        for level in [NSWindow.Level.normal, .floating, .modalPanel] {
            XCTAssertTrue(WindowPick.isPickable(layer: level.rawValue), "\(level) should be pickable")
            XCTAssertFalse(
                WindowPick.isFrozenOnly(layer: level.rawValue),
                "\(level) is still on screen when the click lands, so it is captured live"
            )
        }
    }

    func testStatusItemsMenusAndFloatingWidgetsComeFromTheFrozenFrame() {
        let levels = [
            CGWindowLevelForKey(.statusWindow),
            CGWindowLevelForKey(.popUpMenuWindow),
            // A desktop dashboard or any app that floats itself above everything.
            CGWindowLevelForKey(.screenSaverWindow),
        ]
        for level in levels {
            let layer = Int(level)
            XCTAssertTrue(WindowPick.isPickable(layer: layer), "layer \(layer) should be pickable")
            XCTAssertTrue(
                WindowPick.isFrozenOnly(layer: layer),
                "layer \(layer) closes once the overlay takes the keyboard"
            )
        }
    }

    func testTheDockIsPickedButNotCaptured() {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertTrue(WindowPick.isPickable(layer: dock))
        // Its window covers the whole display, so the pixels come from the
        // frozen frame over the strip instead of a capture of that window.
        XCTAssertTrue(WindowPick.isDock(layer: dock))
        XCTAssertFalse(WindowPick.isFrozenOnly(layer: dock))
    }

    func testTheMenuBarCursorAndTheGapStayOutOfThePicker() {
        let unpickable = [
            // The strip the pointer rests on right after its icon was clicked:
            // answering it would hide the panel the user is aiming at.
            Int(CGWindowLevelForKey(.mainMenuWindow)),
            Int(CGWindowLevelForKey(.cursorWindow)),
            Int(CGWindowLevelForKey(.desktopIconWindow)),
            // Between a modal panel (8) and the Dock (20), nothing.
            9, 12, 19,
            // The notification centre's window is the whole display; paying a
            // capture of it on every press is not worth what it offers.
            21,
        ]
        for layer in unpickable {
            XCTAssertFalse(WindowPick.isPickable(layer: layer), "layer \(layer) must not be pickable")
        }
    }

    func testAMenuMayBeSmallerThanAWindow() {
        XCTAssertEqual(WindowPick.minimumSize(layer: NSWindow.Level.normal.rawValue), 60)
        XCTAssertLessThan(
            WindowPick.minimumSize(layer: Int(CGWindowLevelForKey(.popUpMenuWindow))),
            WindowPick.minimumSize(layer: NSWindow.Level.normal.rawValue),
            "A short menu or tooltip still has to be pickable"
        )
    }

    func testPressSnapshotKeepsEveryPickableWindow() {
        let list = [
            Self.window(1, layer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                        bounds: CGRect(x: 100, y: 100, width: 200, height: 120)),
            Self.window(2, layer: NSWindow.Level.normal.rawValue,
                        bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            Self.window(3, layer: Int(CGWindowLevelForKey(.statusWindow)),
                        bounds: CGRect(x: 900, y: 20, width: 300, height: 400)),
        ]
        XCTAssertEqual(WindowPick.pressSnapshot(from: list).map(\.id), [1, 2, 3])
    }

    func testPressSnapshotLeavesOutHiddenTinyAndExcludedWindows() {
        let list = [
            Self.window(1, layer: 101, bounds: CGRect(x: 0, y: 0, width: 200, height: 100)),
            Self.window(2, layer: 101, bounds: CGRect(x: 0, y: 0, width: 200, height: 100), alpha: 0),
            Self.window(3, layer: 101, bounds: CGRect(x: 0, y: 0, width: 8, height: 8)),
            Self.window(4, layer: 25, bounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
        ]
        XCTAssertEqual(WindowPick.pressSnapshot(from: list).map(\.id), [1, 4])
        XCTAssertEqual(WindowPick.pressSnapshot(from: list, excluding: [1]).map(\.id), [4])
    }

    func testTheTopmostWindowUnderThePointWins() {
        let snapshot = [
            PressWindow(id: 9, layer: 101, bounds: CGRect(x: 100, y: 100, width: 200, height: 100)),
            PressWindow(id: 8, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
        ]
        XCTAssertEqual(WindowPick.window(at: CGPoint(x: 150, y: 150), in: snapshot)?.id, 9)
        XCTAssertEqual(WindowPick.window(at: CGPoint(x: 10, y: 10), in: snapshot)?.id, 8)
        XCTAssertNil(WindowPick.window(at: CGPoint(x: 900, y: 900), in: snapshot))
    }

    func testTheDockStripIsWhatTheScreenLosesToIt() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        // At the bottom, under the visible area.
        XCTAssertEqual(
            WindowPick.dockStrip(frame: frame, visible: CGRect(x: 0, y: 72, width: 1512, height: 877)),
            CGRect(x: 0, y: 0, width: 1512, height: 72)
        )
        // On the left.
        XCTAssertEqual(
            WindowPick.dockStrip(frame: frame, visible: CGRect(x: 80, y: 0, width: 1432, height: 949)),
            CGRect(x: 0, y: 0, width: 80, height: 949)
        )
        // On the right.
        XCTAssertEqual(
            WindowPick.dockStrip(frame: frame, visible: CGRect(x: 0, y: 0, width: 1432, height: 949)),
            CGRect(x: 1432, y: 0, width: 80, height: 949)
        )
        // Hidden: the visible frame is the whole frame minus the menu bar.
        XCTAssertNil(
            WindowPick.dockStrip(frame: frame, visible: CGRect(x: 0, y: 0, width: 1512, height: 949))
        )
    }

    /// A window list entry shaped like `CGWindowListCopyWindowInfo` output.
    private static func window(
        _ id: CGWindowID,
        layer: Int,
        bounds: CGRect,
        alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }
}
