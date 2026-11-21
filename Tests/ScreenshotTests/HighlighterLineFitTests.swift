import AppKit
import XCTest
@testable import PanelumiCore

final class HighlighterLineFitTests: XCTestCase {
    private let imageWidth = 640
    private let imageHeight = 360

    private func base(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    /// Glyphs, not a solid bar: a line of text is mostly paper between marks.
    private func glyphRow(_ context: CGContext, topRow: Int, height: Int) {
        context.setFillColor(NSColor.black.cgColor)
        for x in stride(from: 64, to: 576, by: 16) {
            context.fill(CGRect(x: x, y: imageHeight - topRow - height, width: 5, height: height))
        }
    }

    private func band(atY y: CGFloat) -> [CGPoint] {
        [CGPoint(x: 0.1, y: y), CGPoint(x: 0.9, y: y)]
    }

    func testFitsTheHeightAndRowOfTheLineUnderTheBand() throws {
        let image = try base { glyphRow($0, topRow: 100, height: 22) }

        let fit = try XCTUnwrap(HighlighterLineFit.fit(
            in: image, points: band(atY: 0.31), width: 0.03, pointScale: 2
        ))

        XCTAssertEqual(fit.width, 22 * 1.15 / CGFloat(imageWidth), accuracy: 0.004,
                       "the band takes the line's height plus a little air")
        XCTAssertEqual(fit.centerY, 110.5 / CGFloat(imageHeight), accuracy: 0.01,
                       "the band centres on the glyphs, not on the press point")
    }

    func testNoLineUnderTheBandLeavesTheMarkAlone() throws {
        let image = try base { _ in }

        XCTAssertNil(HighlighterLineFit.fit(
            in: image, points: band(atY: 0.5), width: 0.03, pointScale: 2
        ))
    }

    func testASolidBlockIsNotALine() throws {
        let image = try base { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 120, width: imageWidth, height: 60))
        }

        XCTAssertNil(HighlighterLineFit.fit(
            in: image, points: band(atY: 0.5), width: 0.03, pointScale: 2
        ), "a filled area is not text")
    }

    func testFitsALightLineOnADarkCapture() throws {
        let image = try base { context in
            context.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            context.setFillColor(.white)
            for x in stride(from: 64, to: 576, by: 16) {
                context.fill(CGRect(x: x, y: imageHeight - 100 - 22, width: 5, height: 22))
            }
        }

        let fit = try XCTUnwrap(HighlighterLineFit.fit(
            in: image, points: band(atY: 0.31), width: 0.03, pointScale: 2
        ))
        XCTAssertEqual(fit.width, 22 * 1.15 / CGFloat(imageWidth), accuracy: 0.004)
    }
}
