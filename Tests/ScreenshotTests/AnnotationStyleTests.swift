import AppKit
import XCTest
@testable import PanelumiCore

final class AnnotationStyleTests: XCTestCase {
    @MainActor
    private func redPixelCount(_ annotation: Annotation) throws -> Int {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let base = try XCTUnwrap(context.makeImage())
        let rendered = AnnotationRenderer.render(base: base, annotations: [annotation])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.tiffRepresentation)))
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > color.greenComponent + 0.2,
                   color.redComponent > color.blueComponent + 0.2 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    func testOutlineHatchAndSolidActuallyRenderDifferently() throws {
        var annotation = Annotation(shape: .rectangle(from: CGPoint(x: 0.15, y: 0.15), to: CGPoint(x: 0.85, y: 0.85)), color: .red, lineWidth: 0.01)
        let outline = try redPixelCount(annotation)
        annotation.fillStyle = .hatched
        let hatched = try redPixelCount(annotation)
        annotation.fillStyle = .solid
        let solid = try redPixelCount(annotation)
        XCTAssertGreaterThan(hatched, outline)
        XCTAssertGreaterThan(solid, hatched)
    }

    @MainActor
    func testSolidDashedAndDottedLinesHaveRealGaps() throws {
        var annotation = Annotation(shape: .line(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5)), color: .red, lineWidth: 0.015)
        let solid = try redPixelCount(annotation)
        annotation.linePattern = .dashed
        let dashed = try redPixelCount(annotation)
        annotation.linePattern = .dotted
        let dotted = try redPixelCount(annotation)
        XCTAssertGreaterThan(solid, dashed)
        XCTAssertGreaterThan(dashed, dotted)
        XCTAssertGreaterThan(dotted, 0)
    }

    func testAnnotationStyleRoundTripsThroughComputedStyle() {
        var style = AnnotationStyle()
        style.color = .blue
        style.lineWidth = 0.01
        style.textScale = 0.03
        style.textBubble = true
        style.arrowStyle = .sCurve
        style.fillStyle = .solid
        style.linePattern = .dotted
        style.mosaicBlock = 20
        style.numberStyle = .square
        style.highlighterAlpha = 0.5
        style.highlighterWidth = 0.012

        var annotation = Annotation(
            shape: .rectangle(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.9, y: 0.9)),
            style: style
        )

        XCTAssertEqual(annotation.style, style)
        XCTAssertEqual(annotation.color, .blue)
        XCTAssertEqual(annotation.lineWidth, 0.01)
        XCTAssertEqual(annotation.textScale, 0.03)
        XCTAssertTrue(annotation.textBubble)
        XCTAssertEqual(annotation.arrowStyle, .sCurve)
        XCTAssertEqual(annotation.fillStyle, .solid)
        XCTAssertEqual(annotation.linePattern, .dotted)
        XCTAssertEqual(annotation.mosaicBlock, 20)
        XCTAssertEqual(annotation.numberStyle, .square)
        XCTAssertEqual(annotation.highlighterAlpha, 0.5)
        XCTAssertEqual(annotation.highlighterWidth, 0.012)

        annotation.style.numberStyle = .circle
        annotation.style.lineWidth = 0.006

        XCTAssertEqual(annotation.numberStyle, .circle)
        XCTAssertEqual(annotation.lineWidth, 0.006)
        XCTAssertEqual(annotation.style.fillStyle, .solid, "changing one field keeps the rest")
    }

    @MainActor
    func testChangingStyleChangesRenderedPixels() throws {
        var annotation = Annotation(
            shape: .rectangle(from: CGPoint(x: 0.15, y: 0.15), to: CGPoint(x: 0.85, y: 0.85)),
            style: AnnotationStyle()
        )
        let outline = try redPixelCount(annotation)
        XCTAssertGreaterThan(outline, 0)

        annotation.style.color = .blue
        XCTAssertEqual(try redPixelCount(annotation), 0, "the renderer must follow the edited style")

        annotation.style.color = .red
        annotation.style.fillStyle = .solid
        XCTAssertGreaterThan(try redPixelCount(annotation), outline)
    }

    @MainActor
    private func bitmap(_ annotations: [Annotation], over base: CGImage) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let rendered = AnnotationRenderer.render(base: base, annotations: annotations)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.tiffRepresentation)))
    }

    /// A 200×160 page with a row of glyph-like blocks across the middle, the
    /// way a line of text looks to a pixel probe: mostly paper, some ink.
    private func baseImage(_ background: NSColor, ink: NSColor = .black) throws -> (CGImage, [NSRect]) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let glyphs = stride(from: 6, to: 190, by: 26).map {
            NSRect(x: CGFloat($0), y: 72, width: 6, height: 16)
        }
        context.setFillColor(ink.cgColor)
        for glyph in glyphs {
            context.fill(glyph)
        }
        return (try XCTUnwrap(context.makeImage()), glyphs)
    }

    /// `colorAt` counts rows from the top, the glyph rects from the bottom.
    private func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(160 - point.y))?.usingColorSpace(.deviceRGB))
    }

    @MainActor
    private func wideBand() -> Annotation {
        var annotation = Annotation(
            shape: .highlighter(points: [CGPoint(x: 0.02, y: 0.5), CGPoint(x: 0.98, y: 0.5)]),
            color: .yellow
        )
        annotation.highlighterWidth = 0.15
        annotation.highlighterAlpha = 0.5
        return annotation
    }

    func testStraightModeLaysTheBandOnOneRow() {
        let band = Annotation.horizontalBand(
            from: CGPoint(x: 0.2, y: 0.3),
            to: CGPoint(x: 0.8, y: 0.42)
        )

        XCTAssertEqual(band.count, 2)
        XCTAssertEqual(band[0], CGPoint(x: 0.2, y: 0.3))
        XCTAssertEqual(band[1], CGPoint(x: 0.8, y: 0.3), "the row stays where the press landed")
    }

    @MainActor
    func testHighlighterLeavesDarkPixelsUnderTheBandDark() throws {
        // The band has to multiply into a light image instead of painting over
        // it, or the text under a highlighter goes grey.
        let (base, glyphs) = try baseImage(.white)
        let rendered = try bitmap([wideBand()], over: base)
        let onGlyph = try pixel(rendered, at: CGPoint(x: glyphs[3].midX, y: glyphs[3].midY))
        let onPaper = try pixel(rendered, at: CGPoint(x: glyphs[3].maxX + 5, y: glyphs[3].midY))

        XCTAssertLessThan(onGlyph.redComponent, 0.1, "dark pixels under the band stay dark")
        XCTAssertGreaterThan(onPaper.redComponent, 0.9, "the band still tints light paper")
        XCTAssertLessThan(onPaper.blueComponent, 0.85)
    }

    @MainActor
    func testHighlighterKeepsLightPixelsOnDarkContentLight() throws {
        // A multiplied band would disappear into a dark capture, so the stroke
        // screens into dark content instead.
        let (base, glyphs) = try baseImage(NSColor(white: 0.12, alpha: 1), ink: .white)
        var band = wideBand()
        band.highlighterBlend = .screen
        let rendered = try bitmap([band], over: base)
        let onGlyph = try pixel(rendered, at: CGPoint(x: glyphs[3].midX, y: glyphs[3].midY))
        let onPaper = try pixel(rendered, at: CGPoint(x: glyphs[3].maxX + 5, y: glyphs[3].midY))

        XCTAssertGreaterThan(onGlyph.redComponent, 0.9, "light pixels under the band stay light")
        XCTAssertGreaterThan(onPaper.redComponent, 0.4, "the band still shows on dark paper")
        XCTAssertLessThan(onPaper.blueComponent, onPaper.redComponent - 0.1)
    }

    @MainActor
    func testHighlighterBlendIsPickedFromThePressPoint() throws {
        let (light, _) = try baseImage(.white)
        let (dark, _) = try baseImage(NSColor(white: 0.12, alpha: 1), ink: .white)
        let middle = CGPoint(x: 0.5, y: 0.5)

        XCTAssertEqual(AnnotationRenderer.highlighterBlend(in: light, at: middle), .multiply)
        XCTAssertEqual(AnnotationRenderer.highlighterBlend(in: dark, at: middle), .screen)
        XCTAssertEqual(AnnotationRenderer.highlighterBlend(in: nil, at: middle), .multiply)
    }

    @MainActor
    func testHighlighterKeepsTheBlendStoredOnTheMark() throws {
        // The renderer must not re-read the image per frame: that made the
        // band change colour as the stroke grew.
        let (base, glyphs) = try baseImage(.white)
        var band = wideBand()
        band.highlighterBlend = .screen
        let rendered = try bitmap([band], over: base)
        let onGlyph = try pixel(rendered, at: CGPoint(x: glyphs[3].midX, y: glyphs[3].midY))

        XCTAssertGreaterThan(onGlyph.redComponent, 0.4,
                             "the stored blend wins: screen lightens the glyph under a band on light paper")
    }

    @MainActor
    func testHighlighterWidthIgnoresThePenWidth() throws {
        let (base, _) = try baseImage(.white)
        var band = Annotation(
            shape: .highlighter(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)]),
            style: AnnotationStyle(color: .red)
        )

        /// Tinted paper rows in a column through the band. Counting rows keeps
        /// the check off colour-space conversions.
        func tintedRows(_ mark: Annotation) throws -> Int {
            let rendered = try bitmap([mark], over: base)
            return (0..<rendered.pixelsHigh).filter { y in
                guard let color = rendered.colorAt(x: 100, y: y)?.usingColorSpace(.deviceRGB)
                else { return false }
                return color.blueComponent < 0.95
            }.count
        }

        let bandRows = try tintedRows(band)
        XCTAssertGreaterThan(bandRows, 0)

        band.style.lineWidth = 0.016
        XCTAssertEqual(try tintedRows(band), bandRows, "the pen width no longer sizes the band")

        band.style.highlighterWidth = 0.05
        XCTAssertGreaterThan(try tintedRows(band), bandRows + 3)
    }
}
