import AppKit
import XCTest
@testable import SwitchDeckCore

/// The live region capture: the gate that serialises it, the context API wired
/// through a real takeover, and one permission-gated end-to-end check.
///
/// The gate and context tests need no Screen Recording, event delivery or key
/// window. The end-to-end test is opt-in, because it captures real pixels.
final class CaptureLiveTests: XCTestCase {
    // MARK: - Serialising

    @MainActor
    func testGateRunsOperationsOneAtATimeInSubmissionOrder() async {
        let gate = SerialAsyncGate()
        let log = GateLog()
        var tasks: [Task<Int, Never>] = []
        for index in 0..<5 {
            tasks.append(Task { @MainActor in
                await gate.run {
                    log.enter(index)
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    log.leave()
                    return index * 10
                }
            })
        }

        for (index, task) in tasks.enumerated() {
            let value = await task.value
            XCTAssertEqual(value, index * 10, "Each call keeps its own result")
        }

        XCTAssertEqual(log.maxInFlight, 1, "Never two operations at once")
        XCTAssertEqual(log.order, [0, 1, 2, 3, 4], "Submission order is kept")
        XCTAssertEqual(log.inFlight, 0, "Every operation left the gate")
    }

    @MainActor
    func testGateKeepsGoingAfterAnEmptyResult() async {
        let gate = SerialAsyncGate()
        var tasks: [Task<Int?, Never>] = []
        for index in 0..<3 {
            tasks.append(Task { @MainActor in
                await gate.run { index == 2 ? index : nil }
            })
        }

        var results: [Int?] = []
        for task in tasks {
            results.append(await task.value)
        }

        XCTAssertEqual(results.compactMap { $0 }, [2], "The queue moves past nil results")
    }

    // MARK: - The context

    @MainActor
    func testCaptureLiveReturnsTheImageAndReceivesTheContextRegion() async throws {
        let image = try solidImage(red: 0.2, green: 0.4, blue: 0.6)
        let probe = LiveProbe()
        let harness = try Harness(captureLive: { rect, screen in
            probe.record(rect, screen)
            return image
        })
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        let captured = await context.captureLive()

        XCTAssertTrue(captured === image, "The host's image comes back unchanged")
        XCTAssertEqual(probe.calls.count, 1)
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.rect, context.region, "The handler gets the context's region")
        XCTAssertTrue(call.screen === context.screen, "The handler gets the context's screen")
        XCTAssertTrue(context.isActive, "A capture of its own does not end the takeover")
    }

    @MainActor
    func testCaptureLiveWithoutAHandlerReturnsNil() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        let captured = await context.captureLive()

        XCTAssertNil(captured, "The default handler captures nothing")
        XCTAssertTrue(context.isActive)
    }

    @MainActor
    func testCaptureLiveAfterCancelReturnsNilAndDoesNotCallTheHandler() async throws {
        let probe = LiveProbe()
        let harness = try Harness(captureLive: { rect, screen in
            probe.record(rect, screen)
            return nil
        })
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.cancel()
        let captured = await context.captureLive()

        XCTAssertNil(captured)
        XCTAssertTrue(probe.calls.isEmpty, "An inactive context never reaches the handler")
        XCTAssertEqual(harness.takeover.endReasons, [.cancelled])
    }

    @MainActor
    func testCaptureLiveAfterDeliveryReturnsNilAndDoesNotCallTheHandler() async throws {
        let probe = LiveProbe()
        let image = try solidImage(red: 0.8, green: 0.2, blue: 0.2)
        let harness = try Harness(captureLive: { rect, screen in
            probe.record(rect, screen)
            return image
        })
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        context.deliver(image, to: [.copy])
        let captured = await context.captureLive()

        XCTAssertNil(captured)
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(harness.takeover.endReasons, [.delivered])
        XCTAssertEqual(harness.deliveries.map(\.output), [.copy])
    }

    @MainActor
    func testCaptureLiveReturnsNilWhenTheTakeoverEndsWhileTheCaptureRuns() async throws {
        let image = try solidImage(red: 0.3, green: 0.6, blue: 0.3)
        let pending = SuspendedCapture(image: image)
        let harness = try Harness(captureLive: { _, _ in await pending.capture() })
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)

        let call = Task { @MainActor in await context.captureLive() }
        var yields = 0
        while !pending.started, yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        XCTAssertTrue(pending.started, "The handler must have been entered")

        context.cancel()
        pending.resume()

        let captured = await call.value
        XCTAssertNil(captured, "A takeover that ended meanwhile discards the frame")
        XCTAssertEqual(pending.captures, 1)
        XCTAssertFalse(context.isActive)
    }

    // MARK: - The coordinator's region paths

    /// A frozen frame belongs to a timed capture only: a live request goes to
    /// the service instead. A hook stands in for the service, so the test needs
    /// no Screen Recording.
    @MainActor
    func testALiveRegionCaptureIgnoresTheFrozenFrame() async throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Needs a screen to key the frozen frame by")
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = try XCTUnwrap(screen.deviceDescription[key] as? CGDirectDisplayID)
        let frozen = try displayImage(for: screen, red: 0.9, green: 0.1, blue: 0.1)
        let live = try solidImage(red: 0.1, green: 0.2, blue: 0.9)

        let coordinator = ScreenshotCoordinator()
        coordinator.frozenScreens[displayID] = frozen
        let probe = LiveProbe()
        coordinator.regionCaptureHook = { rect, hookScreen in
            probe.record(rect, hookScreen)
            return live
        }

        let frame = screen.frame
        let region = CGRect(
            x: frame.midX - 40,
            y: frame.midY - 30,
            width: 80,
            height: 60
        )

        let timed = await coordinator.captureRegion(region, screen)
        XCTAssertNotNil(timed, "A timed capture crops the frozen frame")
        XCTAssertTrue(probe.calls.isEmpty, "The frozen crop never reaches the service")

        let captured = await coordinator.captureRegion(region, screen, live: true)
        XCTAssertTrue(captured === live, "A live capture reads the service, not the frozen frame")
        XCTAssertEqual(probe.calls.count, 1)
        let call = try XCTUnwrap(probe.calls.first)
        XCTAssertEqual(call.rect, region)
        XCTAssertTrue(call.screen === screen)
    }

    /// With no frozen frame a base capture also goes to the service, through
    /// the same gate as a live capture.
    @MainActor
    func testABaseRegionCaptureWithoutAFrozenFrameUsesTheService() async throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Needs a screen to key the frozen frame by")
        }
        let image = try solidImage(red: 0.4, green: 0.5, blue: 0.6)
        let coordinator = ScreenshotCoordinator()
        let probe = LiveProbe()
        coordinator.regionCaptureHook = { rect, hookScreen in
            probe.record(rect, hookScreen)
            return image
        }
        let frame = screen.frame
        let region = CGRect(x: frame.midX - 20, y: frame.midY - 15, width: 40, height: 30)

        let captured = await coordinator.captureRegion(region, screen)

        XCTAssertTrue(captured === image)
        XCTAssertEqual(probe.calls.count, 1)
    }

    // MARK: - End to end (needs Screen Recording)

    /// Opt-in live pixel check: a capture requested through the context, using
    /// the coordinator's exclusion path, leaves an attached panel out and has
    /// the size the documentation promises.
    @MainActor
    func testLiveCaptureLeavesAnAttachedPanelOutAndHasTheDocumentedSize() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWITCHDECK_LIVE_CAPTURE_TESTS"] == "1")
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording permission is required")
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        let region = CGRect(
            x: visible.midX - 120,
            y: visible.midY - 90,
            width: 240,
            height: 180
        )

        let panel = NSPanel(
            contentRect: region,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .green
        panel.isOpaque = true
        defer { panel.close() }

        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = try XCTUnwrap(screen.deviceDescription[key] as? CGDirectDisplayID)
        let service = ScreenCaptureService()
        let harness = try Harness(captureLive: { _, liveScreen in
            try? await service.captureRegion(
                displayID: displayID,
                rect: region,
                screenFrame: liveScreen.frame,
                excludingWindowIDs: SelectionController.overlayWindowIDs
            )
        })
        defer { harness.cleanup() }
        let view = try XCTUnwrap(harness.view)
        view.requestCaptureAction(harness.fake.identifier, "entry")
        let context = try XCTUnwrap(harness.fake.contexts.last)
        context.attach(panel)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(
            SelectionController.overlayWindowIDs.contains(CGWindowID(panel.windowNumber)),
            "An attached panel belongs to the exclusion set"
        )

        let captured = await context.captureLive()
        let excluded = try XCTUnwrap(captured, "The live path captures the region")
        let plain = try await service.captureRegion(
            displayID: displayID,
            rect: region,
            screenFrame: screen.frame
        )

        let scale = screen.backingScaleFactor
        XCTAssertEqual(excluded.width, Int((region.width * scale).rounded()))
        XCTAssertEqual(excluded.height, Int((region.height * scale).rounded()))

        let covered = try XCTUnwrap(centreColor(of: plain))
        XCTAssertGreaterThan(covered.greenComponent, 0.8, "The panel covers the region without the exclusion")
        let cleared = try XCTUnwrap(centreColor(of: excluded))
        XCTAssertGreaterThan(
            abs(cleared.greenComponent - covered.greenComponent),
            0.1,
            "With the exclusion the panel's pixels are gone"
        )
    }

    // MARK: - Helpers

    /// Counts overlapping operations and remembers the order they entered.
    @MainActor
    private final class GateLog {
        private(set) var order: [Int] = []
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0

        func enter(_ index: Int) {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            order.append(index)
        }

        func leave() {
            inFlight -= 1
        }
    }

    /// Records what the injected live handler receives.
    @MainActor
    private final class LiveProbe {
        private(set) var calls: [(rect: CGRect, screen: NSScreen)] = []

        func record(_ rect: CGRect, _ screen: NSScreen) {
            calls.append((rect, screen))
        }
    }

    /// A handler that stays inside `captureLive` until the test lets it finish.
    @MainActor
    private final class SuspendedCapture {
        private(set) var started = false
        private(set) var captures = 0
        private let image: CGImage
        private var gate: AsyncStream<Void>
        private var continuation: AsyncStream<Void>.Continuation?

        init(image: CGImage) {
            self.image = image
            var continuation: AsyncStream<Void>.Continuation!
            gate = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        func capture() async -> CGImage? {
            started = true
            captures += 1
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return image
        }

        func resume() {
            continuation?.yield(())
            continuation?.finish()
            continuation = nil
        }
    }

    /// One started capture plus the fakes behind it.
    @MainActor
    private final class Harness {
        let screen: NSScreen
        let selection: CGRect
        let fake: FakeExtension
        let takeover: FakeTakeover
        let controller: SelectionController
        private(set) var deliveries: [(payload: CapturePayload, output: CaptureSession.Output)] = []
        private(set) var cancelled = 0

        /// Pass a handler to exercise live capture; omit it to leave `begin`'s
        /// default in place.
        init(captureLive: (@MainActor (CGRect, NSScreen) async -> CGImage?)? = nil) throws {
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
            self.fake = FakeExtension(identifier: "test.one")
            self.fake.takeover = takeover
            self.controller = SelectionController(captureExtensions: [fake])

            let onCapture: (CapturePayload, CaptureSession.Output) -> Void = { [weak self] payload, output in
                self?.deliveries.append((payload, output))
            }
            let onCancel: () -> Void = { [weak self] in self?.cancelled += 1 }
            if let captureLive {
                controller.begin(
                    onCapture: onCapture,
                    onCancel: onCancel,
                    captureBase: { _, _ in nil },
                    captureWindows: { _, _, _ in nil },
                    initialSelection: selection,
                    captureLive: captureLive
                )
            } else {
                controller.begin(
                    onCapture: onCapture,
                    onCancel: onCancel,
                    captureBase: { _, _ in nil },
                    captureWindows: { _, _, _ in nil },
                    initialSelection: selection
                )
            }
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

    @MainActor
    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let width = 8, height = 8
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
        context.setFillColor(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("Could not make a solid test image")
        }
        return image
    }

    /// A frame the size of the screen in points, so cropping to a region keeps
    /// the region's size.
    @MainActor
    private func displayImage(
        for screen: NSScreen,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) throws -> CGImage {
        let width = max(1, Int(screen.frame.width))
        let height = max(1, Int(screen.frame.height))
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
        context.setFillColor(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("Could not make a solid test image")
        }
        return image
    }

    private func centreColor(of image: CGImage) -> NSColor? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB)
    }
}
