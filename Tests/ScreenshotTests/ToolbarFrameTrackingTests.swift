import AppKit
import SwiftUI
import XCTest
@testable import PanelumiCore

/// The toolbar is framed from a fitting size read one main-queue turn after
/// the tool changes. The host must be laid out before that read, or its frame
/// is one state behind and the toolbar jumps when the next change lands.
final class ToolbarFrameTrackingTests: XCTestCase {
    @MainActor
    func testToolbarKeepsItsHeightAndTopEdgeWhenTheToolChanges() throws {
        let screen = try requireScreen()
        let selection = CGRect(
            x: screen.frame.midX - 150, y: screen.frame.midY, width: 300, height: 200
        )
        let controller = SelectionController(captureExtensions: [])
        controller.begin(
            onCapture: { _, _ in XCTFail("Editing must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: selection
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let host = try XCTUnwrap(view.toolbarHost)
        let session = controller.session
        pump()

        session.tool = .pen
        pump()
        let penFrame = host.frame
        let penFitting = host.fittingSize
        let penEdge = view.popoverPlacement.edge

        session.tool = .select
        pump()
        let selectFrame = host.frame
        let selectFitting = host.fittingSize
        let selectEdge = view.popoverPlacement.edge

        XCTAssertEqual(penFrame.height, penFitting.height, accuracy: 0.5)
        XCTAssertEqual(selectFrame.height, selectFitting.height, accuracy: 0.5)
        XCTAssertEqual(penEdge, Edge.bottom)
        XCTAssertEqual(selectEdge, Edge.bottom)
        XCTAssertEqual(penFrame.maxY, selectFrame.maxY, accuracy: 0.5)
    }

    @MainActor
    func testToolbarKeepsItsSideAboveASelectionNearTheBottom() throws {
        let screen = try requireScreen()
        let selection = CGRect(
            x: screen.frame.midX - 150, y: screen.frame.minY + 100, width: 300, height: 200
        )
        let controller = SelectionController(captureExtensions: [])
        controller.begin(
            onCapture: { _, _ in XCTFail("Editing must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: selection
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let host = try XCTUnwrap(view.toolbarHost)
        let session = controller.session
        pump()

        session.tool = .pen
        pump()
        let penHeight = host.frame.height
        let penFitting = host.fittingSize.height
        let penEdge = view.popoverPlacement.edge

        session.tool = .select
        pump()
        let selectHeight = host.frame.height
        let selectFitting = host.fittingSize.height
        let selectEdge = view.popoverPlacement.edge

        XCTAssertEqual(penHeight, penFitting, accuracy: 0.5)
        XCTAssertEqual(selectHeight, selectFitting, accuracy: 0.5)
        XCTAssertEqual(penEdge, selectEdge)
        XCTAssertEqual(penEdge, Edge.top)
    }

    @MainActor
    private func pump() {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private func requireScreen() throws -> NSScreen {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Needs a screen to host the overlay")
        }
        return screen
    }

    @MainActor
    private func overlayView(on screen: NSScreen) -> SelectionView? {
        NSApp.windows.compactMap { $0.contentView as? SelectionView }
            .first { $0.window?.isVisible == true && $0.screen == screen }
    }

    /// Cancels a still-active overlay. Called from `defer` before any throwing
    /// lookup, so a failed lookup cannot leave the controller active.
    @MainActor
    private func cancel(_ controller: SelectionController, on screen: NSScreen) {
        guard controller.isActive, let view = overlayView(on: screen) else { return }
        view.onCancel?()
    }
}
