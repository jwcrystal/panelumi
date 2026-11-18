import AppKit
import SwiftUI
import XCTest
@testable import PanelumiCore

final class ColorPaletteWiringTests: XCTestCase {
    private let keys = [ScreenshotPreferences.recentAnnotationColorsKey]
    private var saved: [String: Any] = [:]

    private let ink = AnnotationPalette.color(.init(red: 10, green: 20, blue: 30))

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    @MainActor
    func testWatermarkColourLeavesTheAnnotationStyleAlone() {
        let session = CaptureSession()
        let before = session.defaultStyle.color
        let target = session.watermarkColorPalette

        target.beginInteractiveChange()
        target.color.wrappedValue = ink
        target.endInteractiveChange()

        XCTAssertEqual(AnnotationPalette.hex(for: session.watermarkColor), "#0A141E")
        XCTAssertEqual(session.defaultStyle.color, before)
        XCTAssertFalse(session.canUndo, "the watermark is not part of the annotation history")
    }

    @MainActor
    func testWatermarkColourReachesThePayload() throws {
        let session = CaptureSession()
        session.setWatermarkEnabled(true)

        session.watermarkColorPalette.color.wrappedValue = ink

        let options = try XCTUnwrap(session.watermarkOptions)
        XCTAssertEqual(AnnotationPalette.hex(for: Color(nsColor: options.color)), "#0A141E")
    }

    @MainActor
    func testBothPalettesShareOneRecentList() {
        let session = CaptureSession()

        session.watermarkColorPalette.remember("#123456")

        XCTAssertEqual(session.recentAnnotationColors, ["#123456"])
        XCTAssertEqual(session.annotationColorPalette.recentColors, ["#123456"])
        XCTAssertEqual(session.watermarkColorPalette.recentColors, ["#123456"])
    }

    @MainActor
    func testAnnotationColourStillRecordsOneStepPerDrag() {
        let session = CaptureSession()
        session.annotations = [Annotation(
            shape: .rectangle(from: .zero, to: .zero),
            style: AnnotationStyle()
        )]
        session.selectionIndex = 0
        let target = session.annotationColorPalette

        target.beginInteractiveChange()
        target.color.wrappedValue = ink
        target.endInteractiveChange()

        XCTAssertEqual(AnnotationPalette.hex(for: session.annotations[0].color), "#0A141E")
        XCTAssertEqual(AnnotationPalette.hex(for: session.defaultStyle.color), "#0A141E")
        XCTAssertTrue(session.canUndo)

        session.undo()
        XCTAssertNotEqual(AnnotationPalette.hex(for: session.annotations[0].color), "#0A141E")
    }

    @MainActor
    func testAnnotationColourWithoutASelectionIsNotHistory() {
        let session = CaptureSession()
        let target = session.annotationColorPalette

        target.beginInteractiveChange()
        target.color.wrappedValue = ink
        target.endInteractiveChange()

        XCTAssertEqual(AnnotationPalette.hex(for: session.defaultStyle.color), "#0A141E")
        XCTAssertFalse(session.canUndo, "editing the defaults alone is not content history")
    }
}
