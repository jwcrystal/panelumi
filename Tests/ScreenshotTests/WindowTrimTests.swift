import AppKit
import XCTest
@testable import PanelumiCore

final class WindowTrimTests: XCTestCase {
    /// A 200×100 capture whose only drawn pixels are at (40, 20, 120, 80) in
    /// CG drawing coordinates, which reach the top edge of the bitmap.
    private func sparseImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 40, y: 20, width: 120, height: 80))
        return try XCTUnwrap(context.makeImage())
    }

    func testContentCropsTheTransparentMargin() throws {
        // 200 px wide over 100 points: a 2× capture.
        let bounds = CGRect(x: 1000, y: 200, width: 100, height: 50)
        let trimmed = try XCTUnwrap(WindowTrim.content(of: try sparseImage(), in: bounds))

        XCTAssertEqual(trimmed.image.width, 120)
        XCTAssertEqual(trimmed.image.height, 80)
        XCTAssertEqual(trimmed.rect.minX, 1000 + 20, accuracy: 0.01)
        XCTAssertEqual(trimmed.rect.minY, 200, accuracy: 0.01)
        XCTAssertEqual(trimmed.rect.width, 60, accuracy: 0.01)
        XCTAssertEqual(trimmed.rect.height, 40, accuracy: 0.01)
    }

    func testAWindowWithoutAlphaKeepsItsWholeFrame() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 40,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try XCTUnwrap(context.makeImage())

        let bounds = CGRect(x: 10, y: 20, width: 40, height: 20)
        let trimmed = try XCTUnwrap(WindowTrim.content(of: image, in: bounds))
        XCTAssertEqual(trimmed.rect, bounds)
        XCTAssertEqual(trimmed.image.width, 40)
    }

    func testAnEmptyWindowHasNoContent() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 40,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(WindowTrim.hasAlpha(image))
        XCTAssertNil(WindowTrim.alphaBounds(of: image))
        XCTAssertNil(
            WindowTrim.content(of: image, in: CGRect(x: 0, y: 0, width: 20, height: 10)),
            "A window that draws nothing must not become an empty shot"
        )
    }

    func testAWindowWithoutAlphaHasNoAlphaBounds() throws {
        let image = try XCTUnwrap(Self.opaqueImage())
        XCTAssertFalse(WindowTrim.hasAlpha(image))
    }

    private static func opaqueImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        context?.setFillColor(NSColor.green.cgColor)
        context?.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return context?.makeImage()
    }
}
