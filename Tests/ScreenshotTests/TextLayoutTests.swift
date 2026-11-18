import AppKit
import SwiftUI
import XCTest
@testable import PanelumiCore

/// Text and number annotations are selected by what is actually drawn, and the
/// text field shows the text where and how it will be drawn.
final class TextLayoutTests: XCTestCase {
    private let region = CGRect(x: 20, y: 20, width: 400, height: 300)

    // MARK: - Selection by drawn frame

    @MainActor
    func testLongTextIsSelectableAcrossItsWidth() {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        session.annotations = [Annotation(
            shape: .text("A much longer annotation for testing", at: CGPoint(x: 0.1, y: 0.5)),
            style: AnnotationStyle()
        )]
        session.tool = .select

        // 0.3 across is well inside the text but outside the old fixed box.
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: viewPoint(x: 0.3, y: 0.5, down: 7)))

        XCTAssertEqual(session.selectionIndex, 0)
    }

    @MainActor
    func testNumberMarkerIsSelectableUpAndLeftOfItsCenter() {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        session.annotations = [Annotation(shape: .number(1, at: CGPoint(x: 0.5, y: 0.5)), style: AnnotationStyle())]
        session.tool = .select

        let center = viewPoint(x: 0.5, y: 0.5)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: center.x - 8, y: center.y + 8)))

        XCTAssertEqual(session.selectionIndex, 0)
    }

    @MainActor
    func testSelectionFrameCoversTheDrawnText() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        let annotation = Annotation(shape: .text("Hello world", at: CGPoint(x: 0.2, y: 0.4)), style: AnnotationStyle())
        session.annotations = [annotation]

        let frame = try XCTUnwrap(view.annotationFrameForDebug(0))
        let drawn = try XCTUnwrap(AnnotationRenderer.frame(of: annotation, in: region))
        XCTAssertTrue(frame.insetBy(dx: -0.5, dy: -0.5).contains(drawn), "\(frame) must cover \(drawn)")
    }

    @MainActor
    func testDraggingTextCornerMovesInsteadOfResizing() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        let original = Annotation(
            shape: .text("A much longer annotation for testing", at: CGPoint(x: 0.1, y: 0.5)),
            style: AnnotationStyle()
        )
        session.annotations = [original]
        session.tool = .select
        let inside = viewPoint(x: 0.3, y: 0.5, down: 7)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: inside))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: inside))
        XCTAssertEqual(session.selectionIndex, 0)

        let frame = try XCTUnwrap(view.annotationFrameForDebug(0))
        let corner = NSPoint(x: frame.maxX, y: frame.minY)
        let target = NSPoint(x: corner.x - 30, y: corner.y - 20)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: corner))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: target))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: target))

        guard case .text(let text, let at) = session.annotations.first?.shape else {
            return XCTFail("the text annotation must remain")
        }
        XCTAssertEqual(text, "A much longer annotation for testing")
        XCTAssertEqual(at.x, 0.1 - 30 / region.width, accuracy: 0.002, "a corner drag moves the text")
        XCTAssertEqual(at.y, 0.5 + 20 / region.height, accuracy: 0.002)
        XCTAssertEqual(session.annotations.first?.textScale, original.textScale, "the size must not change")
    }

    // MARK: - Text field

    @MainActor
    func testTextFieldUsesTheAnnotationFontAndColor() throws {
        let wide = CGRect(x: 20, y: 20, width: 800, height: 400)
        let (view, session, window) = makeEditingView(selection: wide)
        defer { window.close() }
        session.defaultStyle.color = .red
        session.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 200, y: 300)))

        let field = try XCTUnwrap(view.pendingTextFieldForDebug)
        XCTAssertEqual(field.font?.pointSize ?? 0, 800 * 0.022, accuracy: 0.01)
        let expected = try XCTUnwrap(NSColor(Color.red).usingColorSpace(.sRGB))
        let actual = try XCTUnwrap(field.textColor?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02)
        XCTAssertFalse(field.isBezeled)
        XCTAssertFalse(field.drawsBackground)
    }

    @MainActor
    func testTextFieldFollowsStyleChangesWhileOpen() throws {
        let wide = CGRect(x: 20, y: 20, width: 800, height: 400)
        let (view, session, window) = makeEditingView(selection: wide)
        defer { window.close() }
        session.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 200, y: 300)))
        let field = try XCTUnwrap(view.pendingTextFieldForDebug)

        session.activeStyle.textScale = 0.030
        // The view relays style changes on the next main-queue turn; a loaded
        // CI runner can take longer than one short spin to get there.
        let deadline = Date().addingTimeInterval(2)
        while abs((field.font?.pointSize ?? 0) - 800 * 0.030) > 0.01, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(field.font?.pointSize ?? 0, 800 * 0.030, accuracy: 0.01)
    }

    @MainActor
    func testTextNearTheRightEdgeStaysInsideTheSelection() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        var delivered: CapturePayload?
        view.onCapture = { payload, _ in delivered = payload }
        session.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: region.maxX - 5, y: 200)))
        let field = try XCTUnwrap(view.pendingTextFieldForDebug)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("hello wide world", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertLessThanOrEqual(field.frame.maxX, region.maxX + 1, "the field must stay inside the selection")

        session.onCopy()
        let annotation = try XCTUnwrap(delivered?.annotations.first)
        let drawn = try XCTUnwrap(AnnotationRenderer.frame(of: annotation, in: region))
        XCTAssertLessThanOrEqual(drawn.maxX, region.maxX + 1, "the committed text must fit the selection")
    }

    @MainActor
    func testCommittedTextLandsWhereTheFieldShowedIt() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        session.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 120, y: 200)))
        let field = try XCTUnwrap(view.pendingTextFieldForDebug)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        let fieldFrame = field.frame

        session.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 380, y: 60)))

        let frame = try XCTUnwrap(view.annotationFrameForDebug(0))
        XCTAssertEqual(frame.minX, fieldFrame.minX, accuracy: 5)
        XCTAssertEqual(frame.maxY, fieldFrame.maxY, accuracy: 5)
    }

    // MARK: - Helpers

    @MainActor
    private func makeEditingView(selection: CGRect? = nil) -> (SelectionView, CaptureSession, NSWindow) {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let session = CaptureSession()
        let view = SelectionView(screen: screen, session: session) { _, _ in nil }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.presetSelection(selection ?? region)
        return (view, session, window)
    }

    /// A view point from normalized coordinates (y grows downwards), moved
    /// `down` points lower on screen.
    private func viewPoint(x: CGFloat, y: CGFloat, down: CGFloat = 0) -> NSPoint {
        NSPoint(x: region.minX + x * region.width, y: region.maxY - y * region.height - down)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
