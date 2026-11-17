import AppKit
import XCTest
@testable import SwitchDeckCore

/// Helper windows an extension hands to the host with `attach`: they are raised
/// above the overlay, left out of captures and window picking, and closed when
/// the takeover ends. Every test uses a real panel, always closed.
final class CaptureAttachTests: XCTestCase {
    // MARK: - While active

    @MainActor
    func testAnAttachedVisibleWindowIsRaisedAndExcludedUntilTheEnd() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.attach(panel)

        XCTAssertFalse(panel.isReleasedWhenClosed, "The host keeps the window alive across close")
        XCTAssertGreaterThan(
            panel.level.rawValue,
            NSWindow.Level.screenSaver.rawValue,
            "The helper sits above the overlay"
        )

        panel.orderFrontRegardless()
        let number = panel.windowNumber
        XCTAssertGreaterThan(number, 0, "A visible window has a window number")
        XCTAssertTrue(
            SelectionController.overlayWindowIDs.contains(CGWindowID(number)),
            "A visible helper is left out of captures and window picking"
        )

        context.cancel()

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(number)),
            "The helper is gone from the exclusion set once the takeover ended"
        )
    }

    @MainActor
    func testAnAlreadyHigherLevelIsLeftAlone() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let higher = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 5)
        let panel = makePanel(level: higher)
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.attach(panel)

        XCTAssertEqual(panel.level, higher, "The host never lowers a window")
    }

    @MainActor
    func testAWindowAtTheOverlayLevelIsRaised() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel(level: .screenSaver)
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.attach(panel)

        XCTAssertEqual(
            panel.level.rawValue,
            NSWindow.Level.screenSaver.rawValue + 1,
            "A window at the overlay's level moves just above it"
        )
    }

    @MainActor
    func testAnAttachedWindowThatWasNeverOrderedFrontIsNotExcluded() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.attach(panel)

        XCTAssertFalse(panel.isVisible, "The extension has not ordered it front yet")
        XCTAssertGreaterThan(panel.windowNumber, 0, "The window exists, so only visibility can explain the set")
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(panel.windowNumber)),
            "Only visible helpers are excluded, or the shared content cache would refetch every frame"
        )

        context.cancel()

        // Ordering the window front again only adds its number to the set while
        // the host still tracks it, so this shows the host dropped it.
        panel.orderFrontRegardless()
        XCTAssertTrue(panel.isVisible, "The test owns the window now")
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(panel.windowNumber)),
            "The host forgot the window when the takeover ended"
        )
    }

    // MARK: - Every end path closes

    @MainActor
    func testAttachingInsideBeginIsTrackedAndClosedAtTheEnd() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        harness.fake.beginAction = { context in
            panel.orderFrontRegardless()
            context.attach(panel)
        }
        let view = try XCTUnwrap(harness.view)

        view.requestCaptureAction(harness.fake.identifier, "entry")

        let number = panel.windowNumber
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(SelectionController.overlayWindowIDs.contains(CGWindowID(number)))

        try XCTUnwrap(harness.fake.contexts.last).cancel()

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(SelectionController.overlayWindowIDs.contains(CGWindowID(number)))
    }

    @MainActor
    func testBeginReturningNilClosesTheAttachedWindow() throws {
        let harness = try Harness(returnsTakeover: false)
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        harness.fake.beginAction = { context in
            panel.orderFrontRegardless()
            context.attach(panel)
        }
        let view = try XCTUnwrap(harness.view)

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertFalse(harness.controller.session.takeoverActive)
        XCTAssertFalse(panel.isVisible, "A declined takeover still closes what it attached")
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(panel.windowNumber))
        )
    }

    @MainActor
    func testTheOverlayClosingInsideBeginClosesTheAttachedWindow() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        harness.fake.beginAction = { context in
            panel.orderFrontRegardless()
            context.attach(panel)
            view.onCancel?()
        }

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertFalse(harness.controller.isActive)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(panel.windowNumber))
        )
    }

    @MainActor
    func testCancelClosesTheAttachedWindow() throws {
        try assertPanelClosedByEnding { context, _ in
            context.cancel()
        }
    }

    @MainActor
    func testDeliverClosesTheAttachedWindow() throws {
        let image = try solidImage()
        try assertPanelClosedByEnding { context, _ in
            context.deliver(image, to: [.copy])
        }
    }

    @MainActor
    func testUnhandledEscClosesTheAttachedWindow() throws {
        try assertPanelClosedByEnding { _, view in
            let event = keyEvent(53, "\u{1b}", in: view)
            XCTAssertNil(view.handleKeyEvent(event), "The host consumes the Esc it acted on")
        }
    }

    @MainActor
    func testADisplayChangeClosesTheAttachedWindow() throws {
        try assertPanelClosedByEnding { _, _ in
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
        }
    }

    // MARK: - After the end

    @MainActor
    func testAttachingAfterTheEndIsIgnored() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.cancel()

        panel.orderFrontRegardless()
        context.attach(panel)

        XCTAssertFalse(context.isActive)
        XCTAssertTrue(panel.isVisible, "An inactive context neither tracks nor closes the window")
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(panel.windowNumber)),
            "The window is not tracked, so it stays in the captures it should have been out of"
        )
    }

    // MARK: - Messages

    @MainActor
    func testAVisibleToastIsExcludedAndOutlivesDelivery() throws {
        defer { ColorToast.closeAll() }
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.showMessage("Saved 3 frames")

        let toast = try XCTUnwrap(ColorToast.currentWindows.last)
        XCTAssertTrue(toast.isVisible)
        XCTAssertTrue(
            SelectionController.overlayWindowIDs.contains(CGWindowID(toast.windowNumber)),
            "A message must never appear in a live capture"
        )

        context.deliver(try solidImage(), to: [.copy])

        XCTAssertTrue(ColorToast.currentWindows.contains { $0 === toast })
        XCTAssertTrue(toast.isVisible, "A toast expires by its timer, not by the end")
    }

    // MARK: - Without attachments

    @MainActor
    func testWithNothingAttachedTheSetIsTheVisibleOverlays() throws {
        ColorToast.closeAll()
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")

        let overlays = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window.contentView is SelectionView, window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })

        XCTAssertFalse(overlays.isEmpty)
        XCTAssertEqual(SelectionController.overlayWindowIDs, overlays)
    }

    // MARK: - Helpers

    /// Attaches a visible panel, ends the takeover through `end`, and asserts
    /// the panel is gone. `end` gets the context and the owner view.
    @MainActor
    private func assertPanelClosedByEnding(
        _ end: (CaptureContext, SelectionView) throws -> Void
    ) throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let panel = makePanel()
        defer { close(panel) }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        panel.orderFrontRegardless()
        context.attach(panel)
        let number = panel.windowNumber
        XCTAssertTrue(SelectionController.overlayWindowIDs.contains(CGWindowID(number)))

        try end(context, view)

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(number)),
            "The helper left the exclusion set with the takeover"
        )
        XCTAssertEqual(harness.takeover.endReasons.count, 1)
    }

    @MainActor
    private func makePanel(level: NSWindow.Level = .normal) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 120, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        return panel
    }

    /// Closes a panel without letting AppKit release it; tests hold the only
    /// other reference.
    @MainActor
    private func close(_ panel: NSWindow) {
        panel.isReleasedWhenClosed = false
        panel.orderOut(nil)
        panel.close()
    }

    @MainActor
    private func keyEvent(
        _ keyCode: UInt16,
        _ characters: String,
        in view: SelectionView
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// A small valid image, for `deliver`.
    @MainActor
    private func solidImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not allocate a test bitmap")
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else {
            throw XCTSkip("Could not make a test image")
        }
        return image
    }

    /// One started capture plus the fakes behind it.
    @MainActor
    private final class Harness {
        let screen: NSScreen
        let selection: CGRect
        let fake: FakeExtension
        let takeover: FakeTakeover
        let controller: SelectionController
        private(set) var deliveries: [CaptureSession.Output] = []
        private(set) var cancelled = 0

        init(returnsTakeover: Bool = true) throws {
            guard let screen = NSScreen.screens.first else {
                throw XCTSkip("Needs a screen to host the overlay")
            }
            self.screen = screen
            let frame = screen.frame
            self.selection = CGRect(
                x: frame.midX - 100,
                y: frame.midY - 75,
                width: 200,
                height: 150
            )
            self.takeover = FakeTakeover()
            self.fake = FakeExtension(identifier: "test.one", toolbarItem: nil)
            self.fake.takeover = returnsTakeover ? takeover : nil
            self.controller = SelectionController(captureExtensions: [fake])

            controller.begin(
                onCapture: { [weak self] _, output in self?.deliveries.append(output) },
                onCancel: { [weak self] in self?.cancelled += 1 },
                captureBase: { _, _ in nil },
                captureWindows: { _, _, _ in nil },
                initialSelection: selection
            )
        }

        @MainActor
        var view: SelectionView? {
            overlayViews.first { $0.screen == screen }
        }

        @MainActor
        var overlayViews: [SelectionView] {
            NSApp.windows.compactMap { $0.contentView as? SelectionView }
                .filter { $0.window?.isVisible == true && $0.session === controller.session }
        }

        /// Closes a still-live overlay so one failure cannot leak into the next
        /// test.
        @MainActor
        func cleanup() {
            guard controller.isActive, let view else { return }
            view.onCancel?()
        }
    }
}
