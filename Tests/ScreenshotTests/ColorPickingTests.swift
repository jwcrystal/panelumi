import AppKit
import SwiftUI
import XCTest
@testable import SwitchDeckCore

final class AnnotationPaletteRGBTests: XCTestCase {
    func testHexProducesChannelValues() throws {
        XCTAssertEqual(AnnotationPalette.rgb(fromHex: "#FF8000"),
                       AnnotationPalette.RGB(red: 255, green: 128, blue: 0))
        XCTAssertEqual(AnnotationPalette.rgb(fromHex: "ff8000"),
                       AnnotationPalette.RGB(red: 255, green: 128, blue: 0))
    }

    func testChannelsCoverBothEnds() throws {
        XCTAssertEqual(AnnotationPalette.rgb(fromHex: "#000000"),
                       AnnotationPalette.RGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(AnnotationPalette.rgb(fromHex: "#FFFFFF"),
                       AnnotationPalette.RGB(red: 255, green: 255, blue: 255))
        XCTAssertNil(AnnotationPalette.rgb(fromHex: "#GGGGGG"))
        XCTAssertNil(AnnotationPalette.rgb(fromHex: "#FFF"))
    }

    func testChannelsRoundTripThroughColorAndHex() throws {
        let samples = [
            AnnotationPalette.RGB(red: 0, green: 0, blue: 0),
            AnnotationPalette.RGB(red: 255, green: 255, blue: 255),
            AnnotationPalette.RGB(red: 1, green: 2, blue: 3),
            AnnotationPalette.RGB(red: 18, green: 52, blue: 86),
        ]
        for sample in samples {
            let color = AnnotationPalette.color(sample)
            XCTAssertEqual(AnnotationPalette.rgb(for: color), sample)
            XCTAssertEqual(
                AnnotationPalette.hex(for: color),
                String(format: "#%02X%02X%02X", sample.red, sample.green, sample.blue)
            )
        }
    }

    func testColorClampsOutOfRangeChannels() {
        let color = AnnotationPalette.color(.init(red: 300, green: -4, blue: 128))
        XCTAssertEqual(AnnotationPalette.rgb(for: color),
                       AnnotationPalette.RGB(red: 255, green: 0, blue: 128))
    }

    func testCardTextContrastFollowsLuminance() {
        XCTAssertTrue(AnnotationPalette.prefersDarkText(on: .white))
        XCTAssertFalse(AnnotationPalette.prefersDarkText(on: .black))
        XCTAssertTrue(AnnotationPalette.prefersDarkText(
            on: AnnotationPalette.color(.init(red: 255, green: 204, blue: 0))
        ))
        XCTAssertFalse(AnnotationPalette.prefersDarkText(
            on: AnnotationPalette.color(.init(red: 108, green: 92, blue: 231))
        ))
        XCTAssertFalse(AnnotationPalette.prefersDarkText(
            on: AnnotationPalette.color(.init(red: 10, green: 20, blue: 60))
        ))
    }
}

final class ColorPickingTests: XCTestCase {
    private let keys = [ScreenshotPreferences.recentAnnotationColorsKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    @MainActor
    func testClickInsideSelectionPicksTheBasePixelAndCreatesNothing() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        session.tool = .rectangle
        session.annotations = [Annotation(shape: .line(from: .zero, to: .zero), style: AnnotationStyle())]
        session.isPickingColor = true
        let point = NSPoint(x: 80, y: 150)

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: view))

        XCTAssertFalse(session.isPickingColor, "one click finishes picking")
        XCTAssertEqual(session.annotations.count, 1, "picking must not add an annotation")
        let picked = try XCTUnwrap(AnnotationPalette.rgb(for: session.activeStyle.color))
        XCTAssertLessThanOrEqual(abs(picked.red - 255), 8)
        XCTAssertLessThanOrEqual(picked.green, 8)
        XCTAssertLessThanOrEqual(picked.blue, 8)
    }

    @MainActor
    func testClickOnTheOtherHalfPicksItsColour() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        session.isPickingColor = true
        let point = NSPoint(x: 350, y: 150)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: view))

        XCTAssertFalse(session.isPickingColor)
        let picked = try XCTUnwrap(AnnotationPalette.rgb(for: session.activeStyle.color))
        XCTAssertLessThanOrEqual(picked.red, 8)
        XCTAssertLessThanOrEqual(picked.green, 8)
        XCTAssertLessThanOrEqual(abs(picked.blue - 255), 8)
    }

    @MainActor
    func testClickOutsideSelectionOnlyCancelsPicking() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        session.activeStyle.color = AnnotationPalette.color(.init(red: 18, green: 52, blue: 86))
        session.isPickingColor = true
        let point = NSPoint(x: 500, y: 150)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: view))

        XCTAssertFalse(session.isPickingColor)
        XCTAssertEqual(AnnotationPalette.rgb(for: session.activeStyle.color),
                       AnnotationPalette.RGB(red: 18, green: 52, blue: 86))
        XCTAssertTrue(session.annotations.isEmpty)
    }

    @MainActor
    func testEscapeLeavesPickingBeforeItClosesTheCapture() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        var cancelled = false
        view.onCancel = { cancelled = true }
        session.isPickingColor = true

        XCTAssertNil(view.handleKeyEvent(escapeEvent(in: view)))
        XCTAssertFalse(session.isPickingColor)
        XCTAssertFalse(cancelled, "the first Esc only leaves picking")

        XCTAssertNil(view.handleKeyEvent(escapeEvent(in: view)))
        XCTAssertTrue(cancelled, "the next Esc closes the capture")
    }

    @MainActor
    func testEscapeLeavesPickingFromKeyDownToo() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        var cancelled = false
        view.onCancel = { cancelled = true }
        session.isPickingColor = true

        view.keyDown(with: escapeEvent(in: view))
        XCTAssertFalse(session.isPickingColor)
        XCTAssertFalse(cancelled)
    }

    @MainActor
    func testIShortcutTogglesPicking() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        XCTAssertNil(CaptureSession.Tool.tool(forShortcut: "i"), "I belongs to the eyedropper")
        XCTAssertNil(view.handleKeyEvent(letterEvent("i", in: view)))
        XCTAssertTrue(session.isPickingColor)
        XCTAssertNil(view.handleKeyEvent(letterEvent("i", in: view)))
        XCTAssertFalse(session.isPickingColor)
    }

    @MainActor
    func testIShortcutIgnoresModifiersTextEntryAndColourlessTools() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        _ = view.handleKeyEvent(letterEvent("i", in: view, modifiers: [.command]))
        XCTAssertFalse(session.isPickingColor, "⌘I is not the eyedropper")
        _ = view.handleKeyEvent(letterEvent("i", in: view, modifiers: [.control]))
        XCTAssertFalse(session.isPickingColor)
        _ = view.handleKeyEvent(letterEvent("i", in: view, modifiers: [.option]))
        XCTAssertFalse(session.isPickingColor)

        session.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 120, y: 200), in: view))
        XCTAssertNotNil(view.pendingTextFieldForDebug)
        XCTAssertTrue(session.isTextEditing)
        _ = view.handleKeyEvent(letterEvent("i", in: view))
        XCTAssertFalse(session.isPickingColor, "a text field owns the keys")

        session.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 120, y: 200), in: view))
        XCTAssertFalse(session.isTextEditing, "committing the field ends text entry")

        for tool in [CaptureSession.Tool.mosaic, .blur] {
            session.tool = tool
            _ = view.handleKeyEvent(letterEvent("i", in: view))
            XCTAssertFalse(session.isPickingColor, "\(tool) has no colour")
        }
    }

    @MainActor
    func testToolLetterEndsPickingAndSwitchesTools() async throws {
        let (view, session, window) = makeEditingView(base: splitImage())
        defer { window.close() }
        try await waitForBaseImage(view)

        session.isPickingColor = true
        XCTAssertNil(view.handleKeyEvent(letterEvent("r", in: view)))
        XCTAssertFalse(session.isPickingColor)
        XCTAssertEqual(session.tool, .rectangle)
    }

    // MARK: - Helpers

    @MainActor
    private func makeEditingView(base: CGImage?) -> (SelectionView, CaptureSession, NSWindow) {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        let session = CaptureSession()
        let view = SelectionView(
            screen: screen,
            session: session,
            captureBase: { _, _ in base }
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

    @MainActor
    private func waitForBaseImage(_ view: SelectionView) async throws {
        for _ in 0..<100 {
            if view.hasBaseImageForDebug { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the base image must load before sampling")
    }

    /// Red on the left half, blue on the right; the selection is 400 × 300.
    private func splitImage() -> CGImage {
        let width = 400
        let height = 300
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
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
        keyEvent(53, "\u{1b}", in: view)
    }

    private func letterEvent(
        _ character: String,
        in view: SelectionView,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        keyEvent(0, character, in: view, modifiers: modifiers)
    }

    private func keyEvent(
        _ keyCode: UInt16,
        _ characters: String,
        in view: SelectionView,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

final class ColorPickingCaptureTests: XCTestCase {
    private let keys = [
        ScreenshotPreferences.annotationColorKey,
        ScreenshotPreferences.annotationLineWidthKey,
        ScreenshotPreferences.recentAnnotationColorsKey,
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    @MainActor
    func testPrepareForCaptureEndsPicking() {
        ScreenshotPreferences.recentAnnotationColors = ["#102030"]
        let session = CaptureSession()
        session.prepareForCapture()
        session.isPickingColor = true

        session.prepareForCapture()

        XCTAssertFalse(session.isPickingColor)
        XCTAssertEqual(session.recentAnnotationColors, ["#102030"])
    }
}
