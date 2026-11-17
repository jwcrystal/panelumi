import AppKit
import SwiftUI
import XCTest
@testable import SwitchDeckCore

/// The editor draws in points; the export must draw in the same point space so
/// minimum sizes (text, markers, line width) keep their proportions on Retina.
final class ExportScaleTests: XCTestCase {
    func testSmallRegionTextKeepsItsProportionsAtTwoX() throws {
        let annotation = Annotation(
            shape: .text("Hello", at: CGPoint(x: 0.1, y: 0.3)),
            style: style(textScale: 0.022)
        )
        let oneX = try inkWidthRatio(annotation, pixels: CGSize(width: 300, height: 200), pointScale: 1)
        let twoX = try inkWidthRatio(annotation, pixels: CGSize(width: 600, height: 400), pointScale: 2)
        XCTAssertEqual(twoX, oneX, accuracy: oneX * 0.1, "2x export must match the 1x proportions")
    }

    func testSmallRegionNumberMarkerKeepsItsProportionsAtTwoX() throws {
        let annotation = Annotation(
            shape: .number(1, at: CGPoint(x: 0.5, y: 0.5)),
            style: style(textScale: 0.022)
        )
        let oneX = try inkWidthRatio(annotation, pixels: CGSize(width: 300, height: 200), pointScale: 1)
        let twoX = try inkWidthRatio(annotation, pixels: CGSize(width: 600, height: 400), pointScale: 2)
        XCTAssertEqual(twoX, oneX, accuracy: oneX * 0.1)
    }

    func testExportKeepsPixelSize() throws {
        let base = try solidImage(CGSize(width: 600, height: 400))
        let image = AnnotationRenderer.render(base: base, annotations: [], pointScale: 2)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 600)
        XCTAssertEqual(rep.pixelsHigh, 400)
        XCTAssertEqual(image.size, NSSize(width: 600, height: 400))
    }

    // MARK: - Helpers

    private func style(textScale: CGFloat) -> AnnotationStyle {
        var style = AnnotationStyle()
        style.color = .red
        style.textScale = textScale
        return style
    }

    /// Width of the red ink divided by the image width.
    private func inkWidthRatio(_ annotation: Annotation, pixels: CGSize, pointScale: CGFloat) throws -> CGFloat {
        let base = try solidImage(pixels)
        let image = AnnotationRenderer.render(base: base, annotations: [annotation], pointScale: pointScale)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        var minX = Int.max
        var maxX = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.5 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        XCTAssertLessThanOrEqual(minX, maxX, "the annotation must leave ink")
        return CGFloat(maxX - minX + 1) / CGFloat(rep.pixelsWide)
    }

    private func solidImage(_ size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }
}
