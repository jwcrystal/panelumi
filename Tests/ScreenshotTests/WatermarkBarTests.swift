import AppKit
import SwiftUI
import XCTest
@testable import SwitchDeckCore

final class WatermarkModeTests: XCTestCase {
    @MainActor
    func testModeWritesTheTwoFlags() {
        let session = CaptureSession()

        session.watermarkMode = .shown
        XCTAssertTrue(session.watermarkEnabled)
        XCTAssertFalse(session.watermarkHidden)

        session.watermarkMode = .hidden
        XCTAssertTrue(session.watermarkEnabled)
        XCTAssertTrue(session.watermarkHidden)
        XCTAssertNotNil(session.watermarkOptions, "hidden still keeps the watermark in the payload")

        session.watermarkMode = .off
        XCTAssertFalse(session.watermarkEnabled)
        XCTAssertFalse(session.watermarkHidden)
        XCTAssertNil(session.watermarkOptions)
    }

    @MainActor
    func testFlagsReadBackAsTheirMode() {
        let session = CaptureSession()

        session.watermarkEnabled = false
        session.watermarkHidden = false
        XCTAssertEqual(session.watermarkMode, .off)

        session.watermarkEnabled = true
        XCTAssertEqual(session.watermarkMode, .shown)

        session.watermarkHidden = true
        XCTAssertEqual(session.watermarkMode, .hidden)
    }
}

final class WatermarkBarTests: XCTestCase {
    @MainActor
    func testChangingTheToolClosesTheBar() {
        let session = CaptureSession()
        session.showsWatermarkBar = true
        session.tool = .rectangle
        XCTAssertFalse(session.showsWatermarkBar)
        XCTAssertEqual(session.tool, .rectangle, "opening the submenu must not change the tool")
    }

    @MainActor
    func testSelectingAnAnnotationClosesTheBar() {
        let session = CaptureSession()
        session.showsWatermarkBar = true
        session.selectionIndex = 0
        XCTAssertFalse(session.showsWatermarkBar)
    }

    @MainActor
    func testPrepareForCaptureStartsWithTheBarClosed() {
        let session = CaptureSession()
        session.showsWatermarkBar = true
        session.prepareForCapture()
        XCTAssertFalse(session.showsWatermarkBar)
    }

    @MainActor
    func testEscapeClosesTheBarBeforeTheCapture() {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        var cancelled = false
        view.onCancel = { cancelled = true }
        session.showsWatermarkBar = true

        XCTAssertNil(view.handleKeyEvent(escapeEvent(in: view)))
        XCTAssertFalse(session.showsWatermarkBar)
        XCTAssertFalse(cancelled, "the first Esc only closes the submenu")

        XCTAssertNil(view.handleKeyEvent(escapeEvent(in: view)))
        XCTAssertTrue(cancelled, "the next Esc closes the capture")
    }

    @MainActor
    func testEscapeClosesTheBarFromKeyDownToo() {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        var cancelled = false
        view.onCancel = { cancelled = true }
        session.showsWatermarkBar = true

        view.keyDown(with: escapeEvent(in: view))
        XCTAssertFalse(session.showsWatermarkBar)
        XCTAssertFalse(cancelled)

        view.keyDown(with: escapeEvent(in: view))
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testMouseDownInTheSelectionClosesTheBar() {
        for tool in [CaptureSession.Tool.select, .rectangle, .line] {
            let (view, session, window) = makeEditingView()
            defer { window.close() }
            session.tool = tool
            session.showsWatermarkBar = true

            let point = NSPoint(x: 200, y: 150)
            view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: view))
            view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: view))

            XCTAssertFalse(session.showsWatermarkBar, "\(tool) must close the submenu")
            XCTAssertEqual(session.tool, tool)
        }
    }

    @MainActor
    func testTheBarKeepsTheToolbarHeight() {
        _ = NSApplication.shared
        func size(_ configure: (CaptureSession) -> Void) -> NSSize {
            let session = CaptureSession()
            configure(session)
            return NSHostingView(rootView: CaptureToolbarView(session: session)).fittingSize
        }
        let plain = size { _ in }
        for tool in CaptureSession.Tool.allCases {
            let withBar = size {
                $0.tool = tool
                $0.showsWatermarkBar = true
            }
            XCTAssertEqual(withBar.height, plain.height, accuracy: 0.5,
                           "\(tool) must keep the toolbar height with the submenu open")
        }
    }

    @MainActor
    func testTheBarFitsTheOptionsRowWidth() {
        _ = NSApplication.shared
        let session = CaptureSession()
        let size = NSHostingView(rootView: WatermarkBar(session: session)).fittingSize
        XCTAssertLessThanOrEqual(size.width, 420, "the submenu must stay within the options row")
        XCTAssertEqual(size.height, 26, accuracy: 0.5)
    }

    // MARK: - Helpers

    @MainActor
    private func makeEditingView() -> (SelectionView, CaptureSession, NSWindow) {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let session = CaptureSession()
        let view = SelectionView(
            screen: screen,
            session: session,
            captureBase: { _, _ in nil }
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.presetSelection(CGRect(x: 20, y: 20, width: 400, height: 300))
        return (view, session, window)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in view: SelectionView
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func escapeEvent(in view: SelectionView) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
    }
}
