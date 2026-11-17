import SwiftUI
import XCTest
@testable import SwitchDeckCore

@MainActor
final class PopoverEdgeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    private let size = CGSize(width: 640, height: 110)

    private func edge(for selection: CGRect) -> Edge {
        let origin = SelectionView.toolbarOrigin(selection: selection, size: size, bounds: bounds)
        return SelectionView.popoverEdge(
            toolbar: CGRect(origin: origin, size: size),
            selection: selection,
            bounds: bounds
        )
    }

    func testOpensDownwardWhenTheToolbarIsBelowTheSelection() {
        XCTAssertEqual(edge(for: CGRect(x: 300, y: 400, width: 800, height: 400)), .bottom)
    }

    func testOpensUpwardWhenTheToolbarMovedAboveTheSelection() {
        XCTAssertEqual(edge(for: CGRect(x: 300, y: 20, width: 800, height: 400)), .top)
    }

    func testTakesTheRoomierSideInsideAFullScreenSelection() {
        XCTAssertEqual(edge(for: bounds), .top, "the toolbar sits near the bottom, so the room is above")
    }

    func testInsideATallSelectionNearTheTopOpensDownward() {
        let toolbar = CGRect(x: 400, y: 800, width: 640, height: 110)
        let selection = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        XCTAssertEqual(SelectionView.popoverEdge(toolbar: toolbar, selection: selection, bounds: bounds), .bottom)
    }
}
