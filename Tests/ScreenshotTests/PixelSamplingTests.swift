import AppKit
import XCTest
@testable import PanelumiCore

final class PixelSamplingTests: XCTestCase {
    private func image(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let (r, g, b) = fill(column, row)
                let index = (row * width + column) * 4
                bytes[index] = r
                bytes[index + 1] = g
                bytes[index + 2] = b
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    func testPureSRGBRedComesBackUnshifted() throws {
        let red = try image(width: 4, height: 4) { _, _ in (255, 0, 0) }
        let color = try XCTUnwrap(SelectionView.srgbPixel(of: red, column: 1, row: 2))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.004)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.004)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.004)
    }

    func testRowsCountFromTheTop() throws {
        let split = try image(width: 2, height: 2) { _, row in row == 0 ? (0, 0, 255) : (0, 255, 0) }
        let top = try XCTUnwrap(SelectionView.srgbPixel(of: split, column: 0, row: 0))
        let bottom = try XCTUnwrap(SelectionView.srgbPixel(of: split, column: 0, row: 1))
        XCTAssertEqual(top.blueComponent, 1, accuracy: 0.004)
        XCTAssertEqual(bottom.greenComponent, 1, accuracy: 0.004)
    }

    func testOutsideTheImageGivesNothing() throws {
        let red = try image(width: 2, height: 2) { _, _ in (255, 0, 0) }
        XCTAssertNil(SelectionView.srgbPixel(of: red, column: 5, row: 0))
    }
}
