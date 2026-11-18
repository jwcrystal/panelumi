import AppKit
import XCTest
@testable import PanelumiCore

/// The external delivery path: an extension hands an image to the normal output
/// pipeline. No real event delivery, key window, local monitor or Screen
/// Recording is involved.
final class CaptureDeliverTests: XCTestCase {
    // MARK: - Delivering

    @MainActor
    func testDeliverCopiesTheImageAndClosesTheOverlay() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let region = context.region
        let image = try harness.image(width: 12, height: 9)

        context.deliver(image, to: [.copy])

        XCTAssertEqual(harness.takeover.endReasons, [.delivered])
        XCTAssertEqual(harness.deliveries.count, 1)
        let delivery = try XCTUnwrap(harness.deliveries.first)
        XCTAssertTrue(delivery.payload.base === image, "The delivered image is the payload base")
        XCTAssertEqual(delivery.payload.base?.width, 12)
        XCTAssertEqual(delivery.payload.base?.height, 9)
        XCTAssertTrue(delivery.payload.annotations.isEmpty)
        XCTAssertEqual(delivery.payload.rect, region)
        XCTAssertTrue(delivery.payload.screen === harness.screen)
        XCTAssertEqual(delivery.output, .copy)
        XCTAssertFalse(harness.controller.isActive, "Delivery closes the overlay")
        XCTAssertFalse(context.isActive)
        XCTAssertFalse(harness.controller.session.takeoverActive)
    }

    @MainActor
    func testEveryOutputRunsInTheFixedOrder() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let image = try harness.image(width: 6, height: 4)

        try harness.deliver(image, to: [.copy, .save])
        XCTAssertEqual(harness.deliveries.map(\.output), [.copy, .save])

        let second = try Harness()
        defer { second.cleanup() }
        try second.deliver(image, to: [.pin, .copy, .save])

        XCTAssertEqual(second.deliveries.map(\.output), [.copy, .save, .pin])
        XCTAssertEqual(second.takeover.endReasons, [.delivered])
    }

    @MainActor
    func testAnEmptyOutputSetDoesNothing() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let image = try harness.image(width: 6, height: 4)
        let windows = harness.overlayWindows

        context.deliver(image, to: [])

        XCTAssertTrue(harness.deliveries.isEmpty)
        XCTAssertEqual(harness.takeover.endReasons.count, 0)
        XCTAssertTrue(harness.controller.isActive, "An empty set leaves the takeover active")
        XCTAssertTrue(harness.controller.session.takeoverActive)
        XCTAssertTrue(context.isActive)
        for window in windows {
            XCTAssertTrue(window.ignoresMouseEvents)
        }
    }

    @MainActor
    func testTheDeliveredPayloadCarriesTheSessionWatermark() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let image = try harness.image(width: 8, height: 8)
        harness.controller.session.watermarkEnabled = true
        harness.controller.session.watermarkText = "Test mark"
        harness.controller.session.watermarkHidden = true

        context.deliver(image, to: [.copy])

        let payload = try XCTUnwrap(harness.deliveries.first?.payload)
        XCTAssertEqual(payload.watermark?.text, "Test mark")
        XCTAssertFalse(payload.watermarkVisible, "A hidden watermark is still recorded")
    }

    @MainActor
    func testTheDeliveredPayloadRendersAtTheBasePixelSize() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let image = try harness.image(width: 21, height: 13)

        context.deliver(image, to: [.copy])

        let payload = try XCTUnwrap(harness.deliveries.first?.payload)
        let base = try XCTUnwrap(payload.base)
        let rendered = AnnotationRenderer.render(
            base: base,
            annotations: payload.annotations,
            watermark: payload.watermarkVisible ? payload.watermark : nil
        )
        let rep = rendered.representations.compactMap { $0 as? NSBitmapImageRep }.first
        XCTAssertEqual(rep?.pixelsWide, base.width)
        XCTAssertEqual(rep?.pixelsHigh, base.height)
    }

    // MARK: - Beginning

    @MainActor
    func testDeliverInsideBeginIsAppliedOnce() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let image = try harness.image(width: 6, height: 4)
        harness.fake.beginAction = { context in context.deliver(image, to: [.copy]) }

        try XCTUnwrap(harness.view).requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.fake.beginCalls, ["entry"])
        XCTAssertEqual(harness.takeover.endReasons, [.delivered])
        XCTAssertEqual(harness.deliveries.count, 1)
        XCTAssertEqual(harness.deliveries.first?.output, .copy)
        XCTAssertFalse(harness.controller.isActive)
    }

    @MainActor
    func testDeliverInsideBeginIsDroppedWhenBeginDeclines() throws {
        let harness = try Harness(returnsTakeover: false)
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        let image = try harness.image(width: 6, height: 4)
        harness.fake.beginAction = { context in context.deliver(image, to: [.copy]) }

        view.requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertTrue(harness.deliveries.isEmpty, "A declined begin drops its deliver")
        XCTAssertEqual(harness.takeover.endReasons.count, 0)
        XCTAssertTrue(harness.controller.isActive, "The overlay never closed")
        XCTAssertEqual(view.toolbarHost?.isHidden, false, "The toolbar stays")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        XCTAssertFalse(context.isActive)
    }

    @MainActor
    func testCancelInsideBeginWinsOverDeliver() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let image = try harness.image(width: 6, height: 4)
        harness.fake.beginAction = { context in
            context.cancel()
            context.deliver(image, to: [.copy])
        }

        try XCTUnwrap(harness.view).requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.takeover.endReasons, [.cancelled], "Cancel wins and ends once")
        XCTAssertTrue(harness.deliveries.isEmpty, "The deliver after a cancel never runs")
        XCTAssertEqual(harness.cancelled, 1)
        XCTAssertFalse(harness.controller.isActive)
    }

    @MainActor
    func testTheFirstDeliverInsideBeginWins() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let first = try harness.image(width: 6, height: 4)
        let second = try harness.image(width: 9, height: 5)
        harness.fake.beginAction = { context in
            context.deliver(first, to: [.copy])
            context.deliver(second, to: [.save])
        }

        try XCTUnwrap(harness.view).requestCaptureAction(harness.fake.identifier, "entry")

        XCTAssertEqual(harness.deliveries.count, 1, "Only the first deliver runs")
        XCTAssertTrue(harness.deliveries.first?.payload.base === first, "The first image wins")
        XCTAssertEqual(harness.deliveries.map(\.output), [.copy])
        XCTAssertEqual(harness.takeover.endReasons, [.delivered])
    }

    @MainActor
    func testDeliverFromHandleKeyIsConsumedAndRunsOnce() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let image = try harness.image(width: 6, height: 4)
        harness.takeover.consumesKeys = false
        harness.takeover.onHandleKey = { _ in context.deliver(image, to: [.save]) }

        let event = keyEvent(36, "\r", in: view)
        XCTAssertNil(view.handleKeyEvent(event), "The key that delivered stays consumed")

        XCTAssertEqual(harness.takeover.endReasons, [.delivered])
        XCTAssertEqual(harness.deliveries.map(\.output), [.save], "Return's own copy never ran")
        XCTAssertFalse(harness.controller.isActive)
    }

    // MARK: - After the end

    @MainActor
    func testTheContextStaysQuietAfterDelivery() throws {
        defer { ColorToast.closeAll() }
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        let image = try harness.image(width: 6, height: 4)
        let toastsBefore = ColorToast.currentWindows.count

        context.deliver(image, to: [.copy])
        context.deliver(image, to: [.pin])
        context.cancel()
        context.showMessage("Again")

        XCTAssertFalse(context.isActive)
        XCTAssertEqual(harness.deliveries.map(\.output), [.copy], "No second delivery")
        XCTAssertEqual(harness.takeover.endReasons, [.delivered], "No second takeoverDidEnd")
        XCTAssertEqual(
            ColorToast.currentWindows.count,
            toastsBefore,
            "No message after the end"
        )
        XCTAssertFalse(harness.controller.isActive)
    }

    // MARK: - Messages

    @MainActor
    func testShowMessagePutsAToastAboveTheOverlayAndKeepsItPastDelivery() throws {
        defer { ColorToast.closeAll() }
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.showMessage("Hello")

        let toast = try XCTUnwrap(ColorToast.currentWindows.last)
        XCTAssertTrue(toast.isVisible)
        XCTAssertGreaterThan(
            toast.level.rawValue,
            NSWindow.Level.screenSaver.rawValue,
            "The message must sit above the overlay"
        )
        XCTAssertTrue(toast.screen === context.screen, "The message sits on the context's screen")

        context.deliver(try harness.image(width: 4, height: 4), to: [.copy])

        XCTAssertTrue(
            ColorToast.currentWindows.contains { $0 === toast },
            "A message shown before deliver outlives the takeover"
        )
        XCTAssertTrue(toast.isVisible)

        let count = ColorToast.currentWindows.count
        context.showMessage("After")
        XCTAssertEqual(ColorToast.currentWindows.count, count, "An inactive context shows nothing")
    }

    @MainActor
    func testTheColourCopyToastKeepsItsDefaults() throws {
        defer { ColorToast.closeAll() }
        let harness = try Harness()
        defer { harness.cleanup() }

        let window = ColorToast.show("Copied #000000")

        XCTAssertEqual(window.level, .statusBar, "The colour-copy toast is unchanged")
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(window.windowNumber, 0)
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(window.windowNumber)),
            "The colour-copy toast is not part of the exclusion set"
        )

        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        context.showMessage("Hello")
        let message = try XCTUnwrap(ColorToast.currentWindows.last)
        XCTAssertTrue(message.isVisible)
        XCTAssertGreaterThan(message.windowNumber, 0)
        XCTAssertTrue(
            SelectionController.overlayWindowIDs.contains(CGWindowID(message.windowNumber)),
            "A message toast is left out of live captures"
        )
        XCTAssertFalse(
            SelectionController.overlayWindowIDs.contains(CGWindowID(window.windowNumber)),
            "Showing a message does not add the colour-copy toast"
        )
    }

    // MARK: - Helpers

    /// One started capture plus the fakes behind it. Records what reaches the
    /// capture handler.
    @MainActor
    private final class Harness {
        let screen: NSScreen
        let selection: CGRect
        let fake: FakeExtension
        let takeover: FakeTakeover
        let controller: SelectionController
        private(set) var deliveries: [(payload: CapturePayload, output: CaptureSession.Output)] = []
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
                onCapture: { [weak self] payload, output in
                    self?.deliveries.append((payload, output))
                },
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

        @MainActor
        var overlayWindows: [NSWindow] {
            overlayViews.compactMap(\.window)
        }

        /// Starts a takeover, then delivers from outside it in one step.
        @MainActor
        func deliver(
            _ image: CGImage,
            to outputs: Set<CaptureOutput>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            guard let view else {
                XCTFail("No overlay view", file: file, line: line)
                return
            }
            view.requestCaptureAction(fake.identifier, "entry")
            guard let context = fake.contexts.last else {
                XCTFail("No context", file: file, line: line)
                return
            }
            context.deliver(image, to: outputs)
        }

        /// Closes a still-live overlay so one failure cannot leak into the next
        /// test.
        @MainActor
        func cleanup() {
            guard controller.isActive, let view else { return }
            view.onCancel?()
        }

        @MainActor
        func image(width: Int, height: Int) throws -> CGImage {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw XCTSkip("Could not allocate a test bitmap")
            }
            context.setFillColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else {
                throw XCTSkip("Could not make a test image")
            }
            return image
        }
    }

    @MainActor
    private func keyEvent(
        _ keyCode: UInt16,
        _ characters: String,
        in view: SelectionView,
        type: NSEvent.EventType = .keyDown,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
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
