import AppKit
import ImageIO
import XCTest
@testable import PanelumiCore

/// A saved capture is tagged at its pixels-per-point, so a bitmap carrying
/// more pixels than the display can back would be tagged with a density the
/// screen never had (the 301 / 336 dpi reports).
final class CaptureDensityTests: XCTestCase {
    private let region = CGSize(width: 300, height: 200)

    func testInflatedCaptureIsBroughtBackToTheDisplay() throws {
        let capture = try image(width: 1257, height: 838)
        let fitted = CaptureDensity.fitted(capture, for: region, deviceScale: 2)

        XCTAssertEqual(fitted.image.width, 600)
        XCTAssertEqual(fitted.image.height, 400)
        XCTAssertEqual(fitted.scale, 2)
    }

    func testCaptureAtTheDisplayScaleKeepsEveryPixel() throws {
        let capture = try image(width: 600, height: 400)
        let fitted = CaptureDensity.fitted(capture, for: region, deviceScale: 2)

        XCTAssertEqual(fitted.image.width, 600)
        XCTAssertEqual(fitted.scale, 2)
    }

    /// A selection snapped to a device pixel can miss the exact size by one,
    /// and resampling for that would only soften the capture.
    func testHalfPointRoundingIsNotResampled() throws {
        let capture = try image(width: 601, height: 401)
        let fitted = CaptureDensity.fitted(capture, for: region, deviceScale: 2)

        XCTAssertEqual(fitted.image.width, 601)
        XCTAssertEqual(fitted.scale, 601.0 / 300.0, accuracy: 0.0001)
    }

    func testSmallerCaptureKeepsItsOwnScale() throws {
        let capture = try image(width: 300, height: 200)
        let fitted = CaptureDensity.fitted(capture, for: region, deviceScale: 2)

        XCTAssertEqual(fitted.image.width, 300)
        XCTAssertEqual(fitted.scale, 1, accuracy: 0.0001)
    }

    func testInflatedCaptureSavesAtTheDisplayDensity() throws {
        let capture = try image(width: 1257, height: 838)
        let fitted = CaptureDensity.fitted(capture, for: region, deviceScale: 2)
        let image = AnnotationRenderer.render(base: fitted.image, annotations: [], pointScale: fitted.scale)

        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 600)
        XCTAssertEqual(rep.pixelsHigh, 400)
        XCTAssertEqual(image.size, NSSize(width: 300, height: 200))

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelumi-density-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try XCTUnwrap(
            ScreenshotSaver.write(image, watermark: nil, folder: folder, format: .png, quality: 1)
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600)
        XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Double), 144, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIHeight] as? Double), 144, accuracy: 0.001)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
