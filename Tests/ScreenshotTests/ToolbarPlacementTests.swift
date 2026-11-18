import XCTest
@testable import SwitchDeckCore

@MainActor
final class ToolbarPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    private let size = CGSize(width: 640, height: 110)

    private func frame(for selection: CGRect, bounds: CGRect? = nil) -> CGRect {
        let bounds = bounds ?? self.bounds
        return CGRect(
            origin: SelectionView.toolbarOrigin(selection: selection, size: size, bounds: bounds),
            size: size
        )
    }

    func testSitsBelowTheSelectionWhenThereIsRoom() {
        let selection = CGRect(x: 300, y: 400, width: 800, height: 400)
        let toolbar = frame(for: selection)
        XCTAssertEqual(toolbar.maxY, selection.minY - 10)
        XCTAssertEqual(toolbar.midX, selection.midX)
    }

    func testMovesAboveASelectionThatTouchesTheBottom() {
        let selection = CGRect(x: 300, y: 20, width: 800, height: 400)
        let toolbar = frame(for: selection)
        XCTAssertEqual(toolbar.minY, selection.maxY + 10)
        XCTAssertFalse(toolbar.intersects(selection))
    }

    func testStaysOnScreenInsideASelectionWithNoRoomEitherSide() {
        let selection = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let toolbar = frame(for: selection)
        XCTAssertEqual(toolbar.minY, 10)
        XCTAssertTrue(bounds.contains(toolbar))
    }

    func testTallSelectionNearTheBottomKeepsTheToolbarAtItsBottomEdge() {
        let selection = CGRect(x: 300, y: 40, width: 800, height: 900)
        let toolbar = frame(for: selection)
        XCTAssertEqual(toolbar.minY, selection.minY + 10)
        XCTAssertTrue(bounds.contains(toolbar))
    }

    func testIsClampedToTheSideMargins() {
        XCTAssertEqual(frame(for: CGRect(x: 0, y: 400, width: 100, height: 300)).minX, 8)
        XCTAssertEqual(frame(for: CGRect(x: 1400, y: 400, width: 100, height: 300)).maxX, 1492)
    }

    func testReservedOptionsRowKeepsTheToolbarOnTheSameSide() {
        let selection = CGRect(x: 300, y: 140, width: 800, height: 400)
        let reserve = CaptureToolbarView.optionsRowHeight + 5

        let hidden = CGRect(
            origin: SelectionView.toolbarOrigin(selection: selection, size: size, bounds: bounds, reserve: reserve),
            size: size
        )
        XCTAssertEqual(hidden.minY, selection.maxY + 10)

        let expanded = CGSize(width: size.width, height: size.height + reserve)
        let shown = CGRect(
            origin: SelectionView.toolbarOrigin(selection: selection, size: expanded, bounds: bounds),
            size: expanded
        )
        XCTAssertEqual(shown.minY, selection.maxY + 10)
    }

    func testKeepsTheLeftEdgeVisibleOnAScreenNarrowerThanTheToolbar() {
        let narrow = CGRect(x: 0, y: 0, width: 500, height: 1000)
        XCTAssertEqual(frame(for: CGRect(x: 100, y: 400, width: 300, height: 300), bounds: narrow).minX, 8)
    }
}
