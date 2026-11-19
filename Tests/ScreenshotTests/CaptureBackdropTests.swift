import AppKit
import XCTest
@testable import PanelumiCore

/// The picture the overlay hands its window before the view has drawn: if it
/// differs from what the view draws, the screen changes appearance a frame
/// after the overlay appears.
final class CaptureBackdropTests: XCTestCase {
    private func white(side: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(gray: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context?.makeImage()
    }

    private func level(_ image: CGImage, x: Int, y: Int) -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Int(bytes[(y * image.width + x) * 4])
    }

    @MainActor
    func testTheWindowUnderThePointerIsLeftOutOfTheDim() throws {
        let source = try XCTUnwrap(white(side: 40))

        let backdrop = try XCTUnwrap(
            SelectionController.backdrop(
                of: source, scale: 1, hovering: CGRect(x: 10, y: 10, width: 20, height: 20)
            )
        )

        let dimmed = 255 * (1 - SelectionView.dimAlpha)
        XCTAssertEqual(Double(level(backdrop, x: 2, y: 2)), dimmed, accuracy: 2,
                       "Outside the window the frame carries the overlay's dim")
        XCTAssertEqual(level(backdrop, x: 20, y: 20), 255,
                       "The window a click would capture stays at full brightness")
    }

    @MainActor
    func testWithoutAWindowTheFrameIsDimmedAllOver() throws {
        let source = try XCTUnwrap(white(side: 20))

        let backdrop = try XCTUnwrap(
            SelectionController.backdrop(of: source, scale: 1, hovering: nil)
        )

        let dimmed = 255 * (1 - SelectionView.dimAlpha)
        for (x, y) in [(2, 2), (10, 10), (17, 17)] {
            XCTAssertEqual(Double(level(backdrop, x: x, y: y)), dimmed, accuracy: 2)
        }
    }

    @MainActor
    func testTheWindowIsScaledFromPointsToPixels() throws {
        let source = try XCTUnwrap(white(side: 40))

        // A 2x screen: a 10-point window starting at 5 points covers 10..30.
        let backdrop = try XCTUnwrap(
            SelectionController.backdrop(
                of: source, scale: 2, hovering: CGRect(x: 5, y: 5, width: 10, height: 10)
            )
        )

        let dimmed = 255 * (1 - SelectionView.dimAlpha)
        XCTAssertEqual(level(backdrop, x: 20, y: 20), 255,
                       "The pointer's window is cleared at its pixel position, not its point position")
        XCTAssertEqual(Double(level(backdrop, x: 35, y: 35)), dimmed, accuracy: 2,
                       "Outside it the dim is unchanged")
    }
}
