import AppKit
import SwitchKit
import XCTest
@testable import SwitchDeckCore

/// Calls the overlay's key handling directly: no key window, no real event
/// delivery and no local monitor are involved.
final class SelectionViewKeyTests: XCTestCase {
    @MainActor
    func testEscapeCancelsTheCapture() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in XCTFail("Esc must not deliver a capture") },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))

        XCTAssertNil(view.handleKeyEvent(keyEvent(53, "\u{1b}", in: view)))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(controller.isActive)
    }

    @MainActor
    func testReturnAndKeypadEnterCopyTheCapture() throws {
        for (keyCode, characters) in [(36, "\r"), (76, "\u{3}")] as [(UInt16, String)] {
            let screen = try requireScreen()
            let controller = SelectionController()
            var outputs: [CaptureSession.Output] = []
            controller.begin(
                onCapture: { _, output in outputs.append(output) },
                onCancel: { XCTFail("Return must deliver instead of cancelling") },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: editingRect(on: screen)
            )
            defer { cancel(controller, on: screen) }
            let view = try XCTUnwrap(overlayView(on: screen))

            XCTAssertNil(view.handleKeyEvent(keyEvent(keyCode, characters, in: view)))
            XCTAssertEqual(outputs.count, 1)
            guard outputs.count == 1 else { continue }
            guard case .copy = outputs[0] else {
                XCTFail("Key \(keyCode) must deliver a copy output")
                continue
            }
            XCTAssertFalse(controller.isActive)
        }
    }

    @MainActor
    func testSpaceSavesAndPPinsTheCapture() throws {
        for (keyCode, characters) in [(49, " "), (35, "p")] as [(UInt16, String)] {
            let screen = try requireScreen()
            let controller = SelectionController()
            var outputs: [CaptureSession.Output] = []
            controller.begin(
                onCapture: { _, output in outputs.append(output) },
                onCancel: { XCTFail("Key \(keyCode) must deliver instead of cancelling") },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: editingRect(on: screen)
            )
            defer { cancel(controller, on: screen) }
            let view = try XCTUnwrap(overlayView(on: screen))

            XCTAssertNil(view.handleKeyEvent(keyEvent(keyCode, characters, in: view)))
            XCTAssertEqual(outputs.count, 1)
            guard outputs.count == 1 else { continue }
            if keyCode == 49 {
                guard case .save = outputs[0] else {
                    XCTFail("Space must save")
                    continue
                }
            } else {
                guard case .pin = outputs[0] else {
                    XCTFail("P must pin")
                    continue
                }
            }
            XCTAssertFalse(controller.isActive)
        }
    }

    /// Nothing is selected yet, so the overlay is still framing: Return and Esc
    /// must reach the responder chain untouched.
    @MainActor
    func testFramingKeysArePassedOnWhenNotEditing() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Framing must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil }
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))

        let returnEvent = keyEvent(36, "\r", in: view)
        XCTAssertTrue(view.handleKeyEvent(returnEvent) === returnEvent)
        let escapeEvent = keyEvent(53, "\u{1b}", in: view)
        XCTAssertTrue(view.handleKeyEvent(escapeEvent) === escapeEvent)
        XCTAssertTrue(controller.isActive)
    }

    @MainActor
    func testDeleteRemovesTheSelectedAnnotation() throws {
        for (keyCode, characters) in deleteKeys {
            let screen = try requireScreen()
            let controller = SelectionController()
            var cancelled = false
            controller.begin(
                onCapture: { _, _ in XCTFail("Delete must not deliver a capture") },
                onCancel: { cancelled = true },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: editingRect(on: screen)
            )
            defer { cancel(controller, on: screen) }
            let view = try XCTUnwrap(overlayView(on: screen))

            let session = controller.session
            session.tool = .select
            session.annotations = [Annotation(
                shape: .rectangle(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.4, y: 0.4)),
                color: .red
            )]
            session.selectionIndex = 0

            XCTAssertNil(view.handleKeyEvent(keyEvent(keyCode, characters, in: view)))
            XCTAssertTrue(session.annotations.isEmpty)
            XCTAssertNil(session.selectionIndex)
            XCTAssertFalse(cancelled)

            // The delete is one history step, so ⌘Z brings the annotation back.
            XCTAssertNil(view.handleKeyEvent(keyEvent(6, "z", in: view, modifiers: [.command])))
            XCTAssertEqual(session.annotations.count, 1)
        }
    }

    /// Typing a hex colour such as #ABD123 uses letters that are tool shortcuts;
    /// while a text view owns the keys they must reach it, not switch tools.
    @MainActor
    func testToolLettersReachAFocusedTextView() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Typing must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let window = try XCTUnwrap(view.window)

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        view.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let session = controller.session
        let toolBefore = session.tool

        for (keyCode, characters) in [(UInt16(0), "a"), (11, "b"), (2, "d"), (34, "i")] {
            let event = keyEvent(keyCode, characters, in: view)
            XCTAssertTrue(view.handleKeyEvent(event) === event, "\(characters) must pass through")
        }
        XCTAssertEqual(session.tool, toolBefore)
        XCTAssertFalse(session.isPickingColor)
    }

    @MainActor
    func testDeleteWithNothingSelectedIsPassedOn() throws {
        for (keyCode, characters) in deleteKeys {
            let screen = try requireScreen()
            let controller = SelectionController()
            var cancelled = false
            controller.begin(
                onCapture: { _, _ in XCTFail("Delete must not deliver a capture") },
                onCancel: { cancelled = true },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: editingRect(on: screen)
            )
            defer { cancel(controller, on: screen) }
            let view = try XCTUnwrap(overlayView(on: screen))

            XCTAssertNil(controller.session.selectionIndex)
            let event = keyEvent(keyCode, characters, in: view)
            XCTAssertTrue(view.handleKeyEvent(event) === event)
            XCTAssertFalse(cancelled)
        }
    }

    /// Delete only removes annotations while the select tool is active, even
    /// when a selection index survives some other change.
    @MainActor
    func testDeleteWithADrawingToolKeepsTheAnnotation() throws {
        for (keyCode, characters) in deleteKeys {
            let screen = try requireScreen()
            let controller = SelectionController()
            var cancelled = false
            controller.begin(
                onCapture: { _, _ in XCTFail("Delete must not deliver a capture") },
                onCancel: { cancelled = true },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: editingRect(on: screen)
            )
            defer { cancel(controller, on: screen) }
            let view = try XCTUnwrap(overlayView(on: screen))

            let session = controller.session
            session.annotations = [Annotation(
                shape: .rectangle(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.4, y: 0.4)),
                color: .red
            )]
            // Switching tools clears the index, so set the index afterwards.
            session.tool = .rectangle
            session.selectionIndex = 0

            let event = keyEvent(keyCode, characters, in: view)
            XCTAssertTrue(view.handleKeyEvent(event) === event)
            XCTAssertEqual(session.annotations.count, 1)
            XCTAssertFalse(cancelled)
        }
    }

    @MainActor
    func testAnUnrelatedKeyIsPassedOn() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in XCTFail("An unrelated key must not deliver a capture") },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))

        let event = keyEvent(0, "q", in: view)
        XCTAssertTrue(view.handleKeyEvent(event) === event)
        XCTAssertFalse(cancelled)
    }

    /// Pins only the framing-time side of the colour key: with no selection
    /// there is no editing overlay, so key 8 falls through untouched. The
    /// hover-colour branch (copy the colour, toast, cancel) needs a real hover
    /// colour and pasteboard, so nothing here would fail if that branch broke.
    @MainActor
    func testColourKeyWithoutASelectionIsPassedOn() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in XCTFail("The colour key must not deliver a capture") },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil }
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))

        let event = keyEvent(8, "c", in: view)
        XCTAssertTrue(view.handleKeyEvent(event) === event)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(controller.isActive)
    }

    @MainActor
    func testToolLetterKeysSwitchTheTool() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        for (characters, tool) in [("r", CaptureSession.Tool.rectangle), ("O", .ellipse), ("t", .text), ("B", .blur)] {
            XCTAssertNil(view.handleKeyEvent(keyEvent(0, characters, in: view)))
            XCTAssertEqual(session.tool, tool)
        }

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "v", in: view)))
        XCTAssertEqual(session.tool, .select)
    }

    @MainActor
    func testTogglingTheActiveToolPutsItDown() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        session.toggleTool(.rectangle)
        XCTAssertEqual(session.tool, .rectangle)
        session.toggleTool(.rectangle)
        XCTAssertEqual(session.tool, .select)

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "r", in: view)))
        XCTAssertEqual(session.tool, .rectangle)
        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "r", in: view)))
        XCTAssertEqual(session.tool, .select)
    }

    @MainActor
    func testEscapeClosesTheTextFieldBeforePuttingDownText() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Esc must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        session.tool = .text
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: editingPoint(on: screen), in: view))
        XCTAssertNotNil(view.pendingTextFieldForDebug)

        XCTAssertNil(view.handleKeyEvent(keyEvent(53, "\u{1b}", in: view)))
        XCTAssertNil(view.pendingTextFieldForDebug)
        XCTAssertEqual(session.tool, .text)
        XCTAssertTrue(controller.isActive)
    }

    @MainActor
    func testEscapePutsDownTheToolBeforeClosing() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        var cancels = 0
        controller.begin(
            onCapture: { _, _ in XCTFail("Esc must not deliver a capture") },
            onCancel: { cancels += 1 },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        session.tool = .rectangle
        XCTAssertNil(view.handleKeyEvent(keyEvent(53, "\u{1b}", in: view)))
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(cancels, 0)

        XCTAssertNil(view.handleKeyEvent(keyEvent(53, "\u{1b}", in: view)))
        XCTAssertEqual(cancels, 1)
    }

    @MainActor
    func testToolLetterKeysAreIgnoredWithAShortcutModifier() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        for modifiers: NSEvent.ModifierFlags in [[.command], [.control], [.option]] {
            let event = keyEvent(0, "r", in: view, modifiers: modifiers)
            XCTAssertTrue(view.handleKeyEvent(event) === event)
            XCTAssertEqual(session.tool, .select)
        }
    }

    @MainActor
    func testLettersStayInTheTextFieldWhileItIsOpen() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        session.tool = .text
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: editingPoint(on: screen),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        view.mouseDown(with: click)
        XCTAssertNotNil(view.pendingTextFieldForDebug)

        let letter = keyEvent(0, "r", in: view)
        XCTAssertTrue(view.handleKeyEvent(letter) === letter)
        XCTAssertEqual(session.tool, .text)

        let tab = keyEvent(48, "\t", in: view)
        XCTAssertTrue(view.handleKeyEvent(tab) === tab)
        XCTAssertTrue(session.toolbarVisible)
    }

    @MainActor
    func testTabTogglesToolbarVisibility() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tab must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        XCTAssertTrue(session.toolbarVisible)
        XCTAssertNil(view.handleKeyEvent(keyEvent(48, "\t", in: view)))
        XCTAssertFalse(session.toolbarVisible)
        XCTAssertNil(view.handleKeyEvent(keyEvent(48, "\t", in: view)))
        XCTAssertTrue(session.toolbarVisible)
    }

    @MainActor
    func testHeldToolLetterLeavesTheToolAlone() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "r", in: view, isARepeat: true)))
        XCTAssertEqual(session.tool, .select)

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "r", in: view)))
        XCTAssertEqual(session.tool, .rectangle)

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "r", in: view, isARepeat: true)))
        XCTAssertEqual(session.tool, .rectangle)
    }

    @MainActor
    func testHeldColourKeyLeavesTheEyedropperAlone() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        session.tool = .rectangle
        XCTAssertNil(view.handleKeyEvent(keyEvent(34, "i", in: view, isARepeat: true)))
        XCTAssertFalse(session.isPickingColor)

        XCTAssertNil(view.handleKeyEvent(keyEvent(34, "i", in: view)))
        XCTAssertTrue(session.isPickingColor)
    }

    @MainActor
    func testHeldTabLeavesTheToolbarAlone() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tab must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        XCTAssertTrue(session.toolbarVisible)
        XCTAssertNil(view.handleKeyEvent(keyEvent(48, "\t", in: view, isARepeat: true)))
        XCTAssertTrue(session.toolbarVisible)

        XCTAssertNil(view.handleKeyEvent(keyEvent(48, "\t", in: view)))
        XCTAssertFalse(session.toolbarVisible)
    }

    // MARK: - Helpers

    /// Forward delete and the fn-Delete variant must behave the same.
    private var deleteKeys: [(UInt16, String)] { [(51, "\u{7f}"), (117, "\u{7f}")] }

    @MainActor
    func testToolLetterDuringADragLeavesTheDrawingToolAlone() throws {
        let screen = try requireScreen()
        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in XCTFail("Tools must not deliver a capture") },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(overlayView(on: screen))
        let session = controller.session

        session.tool = .rectangle
        let start = editingPoint(on: screen)
        let end = CGPoint(x: start.x + 40, y: start.y + 30)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: view))

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "v", in: view)))
        XCTAssertEqual(session.tool, .rectangle)

        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: view))
        XCTAssertEqual(session.annotations.count, 1)
        guard case .rectangle = session.annotations.first?.shape else {
            return XCTFail("The drag should still commit a rectangle")
        }

        XCTAssertNil(view.handleKeyEvent(keyEvent(0, "v", in: view)))
        XCTAssertEqual(session.tool, .select)
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
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

    /// The middle of `editingRect` in the overlay's own coordinates.
    @MainActor
    private func editingPoint(on screen: NSScreen) -> CGPoint {
        let rect = editingRect(on: screen)
        return CGPoint(x: rect.midX - screen.frame.minX, y: rect.midY - screen.frame.minY)
    }

    @MainActor
    private func overlayView(on screen: NSScreen) -> SelectionView? {
        NSApp.windows.compactMap { window -> SelectionView? in
            guard window.isVisible, let view = window.contentView as? SelectionView else { return nil }
            return view
        }
        .first { $0.screen == screen }
    }

    /// Cancels a still-active overlay. Called from `defer` before any throwing
    /// lookup, so a failed lookup cannot leave the controller active.
    @MainActor
    private func cancel(_ controller: SelectionController, on screen: NSScreen) {
        guard controller.isActive, let view = overlayView(on: screen) else { return }
        view.onCancel?()
    }

    @MainActor
    private func keyEvent(_ keyCode: UInt16, _ characters: String, in view: SelectionView,
                          modifiers: NSEvent.ModifierFlags = [],
                          isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }
}
