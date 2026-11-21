import AppKit
import XCTest
@testable import PanelumiCore

/// Every capture freezes the screen before the overlay opens, so the region is
/// cut from the instant the shortcut was pressed rather than from a desktop
/// that kept moving while the region was chosen.
final class CaptureFreezeTests: XCTestCase {
    @MainActor
    func testTheFreezeTakesOneFramePerDisplayBeforeTheOverlayOpens() async throws {
        let displays = screenDisplayIDs()
        guard !displays.isEmpty else { throw XCTSkip("Needs a screen to capture") }
        let frames = try framesByDisplayID(red: 0.9, green: 0.2, blue: 0.2)

        let coordinator = ScreenshotCoordinator()
        // ScreenCaptureKit is not available in the test process.
        coordinator.windowCaptureHook = { _ in nil }
        coordinator.screenRecordingGranted = { true }
        var captured: [CGDirectDisplayID] = []
        coordinator.displayCaptureHook = { displayID in
            captured.append(displayID)
            return frames[displayID]
        }
        var liveCalls = 0
        coordinator.regionCaptureHook = { _, _ in
            liveCalls += 1
            return nil
        }

        coordinator.begin()
        defer { closeOverlay() }
        await waitForOverlay(coordinator)

        XCTAssertEqual(captured, displays, "One frame per display, in screen order")
        XCTAssertEqual(coordinator.frozenScreens.count, displays.count, "Every frame is kept for the overlay")

        let screen = try XCTUnwrap(NSScreen.screens.first)
        let region = CGRect(
            x: screen.frame.midX - 40,
            y: screen.frame.midY - 30,
            width: 80,
            height: 60
        )
        let regionShot = await coordinator.captureRegion(region, screen)
        let shot = try XCTUnwrap(regionShot, "The region is cut from the freeze")

        XCTAssertEqual(shot.width, Int(region.width), "The region keeps its size")
        let colour = try XCTUnwrap(centreColor(of: shot))
        XCTAssertEqual(colour.redComponent, 0.9, accuracy: 0.05, "The pixels are the frozen frame's")
        XCTAssertEqual(liveCalls, 0, "A frozen capture never reaches ScreenCaptureKit")
    }

    @MainActor
    func testASecondPressCallsOffTheCaptureBeforeTheOverlayOpens() async throws {
        let coordinator = ScreenshotCoordinator()
        // ScreenCaptureKit is not available in the test process.
        coordinator.windowCaptureHook = { _ in nil }
        coordinator.screenRecordingGranted = { true }
        let pending = SuspendedFreeze(frames: try framesByDisplayID(red: 0.2, green: 0.9, blue: 0.2))
        coordinator.displayCaptureHook = { displayID in
            await pending.take(displayID)
        }

        coordinator.begin()
        await waitFor(pending) { $0.started }

        coordinator.begin()
        pending.resume()
        await waitForYields(20)

        XCTAssertFalse(coordinator.isSelectionActive, "A cancelled freeze never opens the overlay")
        XCTAssertTrue(coordinator.frozenScreens.isEmpty, "The frames taken meanwhile are dropped")
    }

    @MainActor
    func testCancellingTheOverlayDropsTheFrozenFrames() async throws {
        let frames = try framesByDisplayID(red: 0.2, green: 0.2, blue: 0.9)
        let coordinator = ScreenshotCoordinator()
        // ScreenCaptureKit is not available in the test process.
        coordinator.windowCaptureHook = { _ in nil }
        coordinator.screenRecordingGranted = { true }
        coordinator.displayCaptureHook = { frames[$0] }

        coordinator.begin()
        defer { closeOverlay() }
        await waitForOverlay(coordinator)
        XCTAssertEqual(coordinator.frozenScreens.count, frames.count)

        closeOverlay()

        XCTAssertTrue(coordinator.frozenScreens.isEmpty, "Nothing keeps a full-screen frame after the cancel")
    }

    @MainActor
    func testTextRecognitionFreezesTheScreenToo() async throws {
        let displays = screenDisplayIDs()
        guard !displays.isEmpty else { throw XCTSkip("Needs a screen to capture") }
        let frames = try framesByDisplayID(red: 0.9, green: 0.9, blue: 0.2)

        let coordinator = ScreenshotCoordinator()
        // ScreenCaptureKit is not available in the test process.
        coordinator.windowCaptureHook = { _ in nil }
        coordinator.screenRecordingGranted = { true }
        var captured: [CGDirectDisplayID] = []
        coordinator.displayCaptureHook = { displayID in
            captured.append(displayID)
            return frames[displayID]
        }

        coordinator.beginTextRecognition()
        defer { closeOverlay() }
        await waitForOverlay(coordinator)

        XCTAssertEqual(captured, displays, "Recognition reads the pressed instant as well")
        XCTAssertEqual(coordinator.frozenScreens.count, displays.count)
    }

    // MARK: - Helpers

    private func screenDisplayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap(displayID(for:))
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// One screen-sized frame per display, keyed by the display it belongs to,
    /// so cropping to a region inside that display keeps the region's size.
    @MainActor
    private func framesByDisplayID(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) throws -> [CGDirectDisplayID: CGImage] {
        var frames: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            frames[displayID] = try displayImage(for: screen, red: red, green: green, blue: blue)
        }
        guard !frames.isEmpty else { throw XCTSkip("Needs a screen to capture") }
        return frames
    }

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
        NSBitmapImageRep(cgImage: image)
            .colorAt(x: image.width / 2, y: image.height / 2)?
            .usingColorSpace(.sRGB)
    }

    /// Waits for the freeze to finish and the overlay to open. The overlay is
    /// built on a later main-actor turn, so a test cannot read it right after
    /// `begin` returns.
    @MainActor
    private func waitForOverlay(
        _ coordinator: ScreenshotCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitFor(coordinator, file: file, line: line) { $0.isSelectionActive }
        XCTAssertTrue(coordinator.isSelectionActive, "The overlay never opened", file: file, line: line)
    }

    @MainActor
    private func waitFor<T>(
        _ subject: T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: (T) -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition(subject) { return }
            await Task.yield()
        }
        XCTFail("The condition never held", file: file, line: line)
    }

    @MainActor
    private func waitForYields(_ turns: Int) async {
        for _ in 0..<turns {
            await Task.yield()
        }
    }

    /// Closes whatever overlay `begin` opened, so a failure cannot leave one up.
    @MainActor
    private func closeOverlay() {
        for window in NSApp.windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.onCancel?()
        }
    }

    /// A freeze that stays suspended until the test resumes it, so a second
    /// press can be tested while the frame is still being taken. Later displays
    /// answer at once, so resuming finishes the freeze.
    @MainActor
    private final class SuspendedFreeze {
        private var continuation: CheckedContinuation<Void, Never>?
        private var calls = 0
        let frames: [CGDirectDisplayID: CGImage]
        private(set) var started = false

        init(frames: [CGDirectDisplayID: CGImage]) {
            self.frames = frames
        }

        func take(_ displayID: CGDirectDisplayID) async -> CGImage? {
            calls += 1
            guard calls == 1 else { return frames[displayID] }
            started = true
            await withCheckedContinuation { continuation = $0 }
            return frames[displayID]
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}
