import AppKit
import XCTest
@testable import SwitchDeckCore

/// A text annotation that is still being typed must not be lost when the
/// capture finishes, and Esc during IME composition belongs to the input method.
final class TextEntryTests: XCTestCase {
    @MainActor
    func testFinishingFromToolbarKeepsTextStillBeingTyped() throws {
        for output in [CaptureSession.Output.copy, .save, .pin] {
            let (view, session, _) = makeEditingView()
            var delivered: CapturePayload?
            view.onCapture = { payload, _ in delivered = payload }

            session.tool = .text
            view.mouseDown(with: mouseEvent(at: NSPoint(x: 120, y: 200)))
            let field = try XCTUnwrap(view.pendingTextFieldForDebug)
            field.stringValue = "hello"

            // Toolbar buttons call the session callbacks without moving focus.
            switch output {
            case .copy: session.onCopy()
            case .save: session.onSave()
            case .pin: session.onPin()
            case .recognizeText: XCTFail("not a toolbar action")
            }

            let payload = try XCTUnwrap(delivered, "\(output) must deliver")
            XCTAssertEqual(payload.annotations.count, 1, "\(output) must keep the typed text")
            if case .text(let text, _) = payload.annotations.first?.shape {
                XCTAssertEqual(text, "hello")
            } else {
                XCTFail("\(output) must deliver a text annotation")
            }
        }
    }

    @MainActor
    func testEscapeWhileComposingIsLeftToTheInputMethod() throws {
        let (view, _, window) = makeEditingView()
        defer { window.close() }
        let editor = try beginTyping(in: view, window: window)
        editor.insertText("好", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("ㄏㄠˇ", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        XCTAssertFalse(view.handleTextFieldEscape(), "Esc must reach the input method")
        XCTAssertNotNil(view.pendingTextFieldForDebug, "the field and its text must stay")
    }

    @MainActor
    func testEscapeWithoutCompositionDiscardsTheField() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        let editor = try beginTyping(in: view, window: window)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.handleTextFieldEscape())
        XCTAssertNil(view.pendingTextFieldForDebug)
        XCTAssertTrue(session.annotations.isEmpty, "Esc abandons the text")
    }

    @MainActor
    func testClickingAwayDuringCompositionKeepsWhatIsShown() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        let editor = try beginTyping(in: view, window: window)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("好", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        session.tool = .select
        view.mouseDown(with: mouseEvent(at: NSPoint(x: 300, y: 100)))

        XCTAssertNil(view.pendingTextFieldForDebug)
        XCTAssertEqual(session.annotations.count, 1)
        if case .text(let text, _) = session.annotations.first?.shape {
            XCTAssertEqual(text, "你好")
        } else {
            XCTFail("the composed text must be committed")
        }
    }

    @MainActor
    func testFinishingDuringCompositionDropsTheUnconfirmedText() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        var delivered: CapturePayload?
        view.onCapture = { payload, _ in delivered = payload }
        let editor = try beginTyping(in: view, window: window)
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("ㄏㄠˇ", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        // Copy closes the editor at once, so raw phonetic input must not
        // end up in the image unseen.
        session.onCopy()

        let payload = try XCTUnwrap(delivered)
        XCTAssertEqual(payload.annotations.count, 1)
        if case .text(let text, _) = payload.annotations.first?.shape {
            XCTAssertEqual(text, "你")
        } else {
            XCTFail("the confirmed text must be delivered")
        }
    }

    @MainActor
    func testFinishingWithOnlyUnconfirmedTextAddsNothing() throws {
        let (view, session, window) = makeEditingView()
        defer { window.close() }
        var delivered: CapturePayload?
        view.onCapture = { payload, _ in delivered = payload }
        let editor = try beginTyping(in: view, window: window)
        editor.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        session.onSave()

        XCTAssertEqual(try XCTUnwrap(delivered).annotations.count, 0)
    }

    // MARK: - Helpers

    @MainActor
    private func makeEditingView() -> (SelectionView, CaptureSession, NSWindow) {
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
        view.presetSelection(CGRect(x: 20, y: 20, width: 400, height: 300))
        return (view, session, window)
    }

    @MainActor
    private func beginTyping(in view: SelectionView, window: NSWindow) throws -> NSTextView {
        view.session.tool = .text
        view.mouseDown(with: mouseEvent(at: NSPoint(x: 120, y: 200)))
        // showTextField focuses the field itself; focusing it again would end
        // and restart editing.
        let field = try XCTUnwrap(view.pendingTextFieldForDebug)
        return try XCTUnwrap(field.currentEditor() as? NSTextView, "the field must be editing")
    }

    private func mouseEvent(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
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
