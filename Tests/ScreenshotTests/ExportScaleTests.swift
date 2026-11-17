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

    func testExportKeepsEveryPixelAndIsSizedInPoints() throws {
        let base = try solidImage(CGSize(width: 600, height: 400))
        let image = AnnotationRenderer.render(base: base, annotations: [], pointScale: 2)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 600)
        XCTAssertEqual(rep.pixelsHigh, 400)
        XCTAssertEqual(image.size, NSSize(width: 300, height: 200))
    }

    func testOneXExportIsSizedLikeItsPixels() throws {
        let base = try solidImage(CGSize(width: 600, height: 400))
        let image = AnnotationRenderer.render(base: base, annotations: [])
        XCTAssertEqual(image.size, NSSize(width: 600, height: 400))
    }

    /// The pasteboard gets the image as TIFF, so this is what a paste carries.
    /// 144 is the 2x row, not a constant: the tag follows the capture's pixels
    /// per point, so the image opens at the size it had on screen.
    func testCopiedCaptureIsTaggedAtTheScaleItWasTakenOn() throws {
        let base = try solidImage(CGSize(width: 600, height: 400))
        for scale in captureScales {
            let image = AnnotationRenderer.render(base: base, annotations: [], pointScale: scale)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            let label = "\(scale)x"
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600, label)
            // TIFF leaves out a resolution tag at the 72 dpi default.
            let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
            XCTAssertEqual(dpi, 72 * scale, accuracy: 0.5, label)
        }
    }

    func testSavedCaptureIsTaggedAtTheScaleItWasTakenOn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchdeck-dpi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = try solidImage(CGSize(width: 600, height: 400))

        for scale in captureScales {
            let image = AnnotationRenderer.render(base: base, annotations: [], pointScale: scale)
            for format in ScreenshotPreferences.ImageFormat.allCases {
                let label = "\(scale)x \(format.title)"
                let url = try XCTUnwrap(
                    ScreenshotSaver.write(image, watermark: nil, folder: folder, format: format, quality: 0.8),
                    label
                )
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), label)
                let properties = try XCTUnwrap(
                    CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                    label
                )
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600, label)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 400, label)
                let dpi = try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Double, label)
                XCTAssertEqual(dpi, 72 * scale, accuracy: 0.5, label)
            }
        }
    }

    // MARK: - Helpers

    /// A 1x display, a fractional scale from a scaled resolution, and Retina.
    private let captureScales: [CGFloat] = [1, 1.5, 2]

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
