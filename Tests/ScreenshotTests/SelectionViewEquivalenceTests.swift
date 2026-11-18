import AppKit
import SwiftUI
import PanelumiKit
import XCTest
@testable import PanelumiCore

/// Pins the overlay's structure and drawing without a key window, a real local
/// monitor or Screen Recording permission.
final class SelectionViewEquivalenceTests: XCTestCase {
    @MainActor
    func testEditingInstallsExactlyOneToolbarHost() throws {
        let screen = try requireScreen()

        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: editingRect(on: screen)
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(Self.overlayView(on: screen))

        XCTAssertEqual(
            view.subviews.filter { $0 is NSHostingView<CaptureToolbarView> }.count,
            1,
            "Editing must install exactly one toolbar host"
        )
        XCTAssertFalse(view.subviews.contains { $0 is NSHostingView<CaptureToolbarView> && $0.isHidden },
                       "The toolbar starts visible")
    }

    /// Smoke check only: a fresh session's toolbar must report a non-zero and
    /// deterministic fitting size. This does not pin the toolbar's layout.
    @MainActor
    func testToolbarViewHasStableNonZeroFittingSize() {
        let first = NSHostingView(rootView: CaptureToolbarView(session: CaptureSession())).fittingSize
        let second = NSHostingView(rootView: CaptureToolbarView(session: CaptureSession())).fittingSize

        XCTAssertGreaterThan(first.width, 0)
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertEqual(first, second, "Two toolbars for fresh sessions must size identically")
    }

    @MainActor
    func testFrozenFrameShowsDimmedSourceOutsideSelection() throws {
        let screen = try requireScreen()
        try XCTSkipUnless(screen.frame.width > 0, "Rendering needs a usable screen")
        let selection = editingRect(on: screen)
        let source = solidImage(red: 200, green: 0, blue: 0)

        let controller = SelectionController()
        controller.begin(
            onCapture: { _, _ in },
            onCancel: {},
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil },
            initialSelection: selection,
            frozen: { _ in source }
        )
        defer { cancel(controller, on: screen) }
        let view = try XCTUnwrap(Self.overlayView(on: screen))

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        guard rep.pixelsWide > 4, rep.pixelsHigh > 4,
              let pixel = rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
        else {
            throw XCTSkip("Headless CI returned no bitmap for the frozen frame")
        }

        // Colour management shifts a device-RGB red as it is drawn, so compare
        // against the same image drawn untouched rather than the raw bytes.
        let undimmed = try XCTUnwrap(renderedPixel(of: source))
        // The corner is far outside the centred selection, so it must show the
        // frozen red darkened by the dim overlay: neither clear nor untouched.
        XCTAssertGreaterThan(pixel.redComponent, 0.05, "Outside the selection must keep the frozen pixels")
        XCTAssertLessThan(pixel.redComponent, undimmed.redComponent,
                          "Outside the selection must be darker than the source frame")
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent * 2,
                             "A pure red frame must stay red-dominant")
        XCTAssertGreaterThan(pixel.redComponent, pixel.blueComponent * 2,
                             "A pure red frame must stay red-dominant")
        XCTAssertLessThan(pixel.greenComponent, 0.25)
        XCTAssertLessThan(pixel.blueComponent, 0.25)
    }

    // MARK: - Helpers

    @MainActor
    private func requireScreen() throws -> NSScreen {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Needs a screen to host the overlay")
        }
        return screen
    }

    /// A rect in global screen coordinates, well inside the screen.
    @MainActor
    private func editingRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(
            x: frame.midX - 100,
            y: frame.midY - 75,
            width: 200,
            height: 150
        )
    }

    @MainActor
    static func overlayView(on screen: NSScreen) -> SelectionView? {
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
        guard controller.isActive, let view = Self.overlayView(on: screen) else { return }
        view.onCancel?()
    }

    /// Draws an image untouched into a small bitmap and reads its centre, so a
    /// comparison shares the same colour management as the overlay render.
    private func renderedPixel(of image: CGImage) throws -> NSColor {
        let side = 8
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: image, size: NSSize(width: side, height: side))
            .draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.colorAt(x: side / 2, y: side / 2)?.usingColorSpace(.sRGB))
    }

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8,
                            width: Int = 640, height: Int = 480) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                     blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
