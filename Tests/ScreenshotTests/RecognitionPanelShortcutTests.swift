import AppKit
import XCTest
@testable import SwitchDeckCore

final class RecognitionPanelShortcutTests: XCTestCase {
    private func shortcut(
        _ characters: String,
        keyCode: UInt16 = 0,
        flags: NSEvent.ModifierFlags = .command,
        selection: NSRange? = NSRange(location: 0, length: 0),
        length: Int = 10
    ) -> RecognitionPanel.Shortcut? {
        RecognitionPanel.shortcut(
            characters: characters, keyCode: keyCode, flags: flags, selection: selection, length: length
        )
    }

    func testCommandCWithEverythingSelectedCopiesAll() {
        XCTAssertEqual(shortcut("c", selection: NSRange(location: 0, length: 10)), .copyAll)
    }

    func testCommandCWithNothingSelectedCopiesAll() {
        XCTAssertEqual(shortcut("c"), .copyAll)
    }

    func testCommandCWithoutTextFocusCopiesAll() {
        XCTAssertEqual(shortcut("c", selection: nil), .copyAll)
    }

    func testCommandCWithPartialSelectionCopiesTheSelection() {
        XCTAssertEqual(shortcut("c", selection: NSRange(location: 2, length: 3)), .copy)
    }

    func testCommandReturnCopiesAllIncludingKeypadEnter() {
        XCTAssertEqual(shortcut("\r", keyCode: 36), .copyAll)
        XCTAssertEqual(shortcut("\u{3}", keyCode: 76, flags: [.command, .numericPad]), .copyAll)
    }

    func testEditingShortcutsReachTheTextView() {
        XCTAssertEqual(shortcut("a"), .selectAll)
        XCTAssertEqual(shortcut("x"), .cut)
        XCTAssertEqual(shortcut("v"), .paste)
        XCTAssertEqual(shortcut("z"), .undo)
        XCTAssertEqual(shortcut("Z", flags: [.command, .shift]), .redo)
    }

    func testEditingShortcutsNeedTextFocus() {
        XCTAssertNil(shortcut("a", selection: nil))
        XCTAssertNil(shortcut("v", selection: nil))
    }

    func testOtherModifiersAreLeftAlone() {
        XCTAssertNil(shortcut("c", flags: [.command, .option]))
        XCTAssertNil(shortcut("c", flags: []))
        XCTAssertNil(shortcut("q"))
    }

    @MainActor
    func testPanelRoutesCommandCToCopyAndCommandAToTheTextView() throws {
        let panel = RecognitionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "hello world"
        panel.contentView = textView
        panel.makeFirstResponder(textView)
        var copies = 0
        panel.onCopy = { copies += 1 }

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: try key("a", keyCode: 0)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 11))

        XCTAssertTrue(panel.performKeyEquivalent(with: try key("c", keyCode: 8)))
        XCTAssertEqual(copies, 1)
    }

    private func key(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
