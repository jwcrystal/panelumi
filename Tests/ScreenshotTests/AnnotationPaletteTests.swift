import AppKit
import SwiftUI
import XCTest
@testable import SwitchDeckCore

final class AnnotationPaletteTests: XCTestCase {
    func testPresetsAreTenDistinctNamedColors() {
        XCTAssertEqual(AnnotationPalette.presets.count, 10)
        XCTAssertEqual(Set(AnnotationPalette.presets.map(\.hex)).count, 10)
        XCTAssertTrue(AnnotationPalette.presets.allSatisfy { !$0.name.isEmpty })
        XCTAssertEqual(AnnotationPalette.presets.first?.hex, "#FF3B30")
        XCTAssertEqual(AnnotationPalette.presets.last?.hex, "#000000")
    }

    func testHexRoundTripsThroughColor() throws {
        for swatch in AnnotationPalette.presets {
            let color = try XCTUnwrap(AnnotationPalette.color(fromHex: swatch.hex))
            XCTAssertEqual(AnnotationPalette.hex(for: color), swatch.hex)
        }
    }

    func testHexAcceptsLowercaseAndMissingHash() {
        XCTAssertEqual(AnnotationPalette.canonicalHex("ff3b30"), "#FF3B30")
        XCTAssertEqual(AnnotationPalette.canonicalHex("#ff3b30"), "#FF3B30")
        XCTAssertEqual(AnnotationPalette.canonicalHex(" FF3B30 "), "#FF3B30")
        XCTAssertNotNil(AnnotationPalette.nsColor(fromHex: "aabbcc"))
    }

    func testInvalidHexReturnsNil() {
        for value in ["", "#", "#FFF", "#12345", "#1234567", "#GGGGGG", "0x123456", "red"] {
            XCTAssertNil(AnnotationPalette.canonicalHex(value), value)
            XCTAssertNil(AnnotationPalette.color(fromHex: value), value)
            XCTAssertNil(AnnotationPalette.nsColor(fromHex: value), value)
        }
    }

    func testRecentKeepsFiveNewestFirst() {
        var recent: [String] = []
        for value in ["#000001", "#000002", "#000003", "#000004", "#000005", "#000006"] {
            recent = AnnotationPalette.addingRecent(value, to: recent)
        }
        XCTAssertEqual(recent, ["#000006", "#000005", "#000004", "#000003", "#000002"])
    }

    func testRecentMovesAnExistingColorToTheFrontWithoutDuplicating() {
        var recent: [String] = []
        recent = AnnotationPalette.addingRecent("#112233", to: recent)
        recent = AnnotationPalette.addingRecent("#445566", to: recent)
        recent = AnnotationPalette.addingRecent("#112233", to: recent)
        XCTAssertEqual(recent, ["#112233", "#445566"])
    }

    func testRecentIgnoresCase() {
        var recent: [String] = []
        recent = AnnotationPalette.addingRecent("#aabbcc", to: recent)
        recent = AnnotationPalette.addingRecent("#AABBCC", to: recent)
        XCTAssertEqual(recent, ["#AABBCC"])
    }

    func testRecentNeverContainsPresets() {
        var recent: [String] = []
        for swatch in AnnotationPalette.presets {
            recent = AnnotationPalette.addingRecent(swatch.hex, to: recent)
        }
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(AnnotationPalette.addingRecent("#FF3B30", to: ["#112233"]), ["#112233"])
    }
}

final class AnnotationPreferencesTests: XCTestCase {
    private let keys = [
        ScreenshotPreferences.annotationColorKey,
        ScreenshotPreferences.annotationLineWidthKey,
        ScreenshotPreferences.recentAnnotationColorsKey,
    ]
    private var saved: [String: Any] = [:]

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

    func testDefaults() {
        XCTAssertEqual(ScreenshotPreferences.annotationColor, ScreenshotPreferences.defaultAnnotationColor)
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, ScreenshotPreferences.defaultAnnotationLineWidth)
        XCTAssertEqual(ScreenshotPreferences.recentAnnotationColors, [])
    }

    func testValuesRoundTrip() {
        ScreenshotPreferences.annotationColor = "#123456"
        ScreenshotPreferences.annotationLineWidth = 0.012
        ScreenshotPreferences.recentAnnotationColors = ["#112233", "#445566"]

        XCTAssertEqual(ScreenshotPreferences.annotationColor, "#123456")
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, 0.012, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.recentAnnotationColors, ["#112233", "#445566"])
    }

    func testLineWidthIsClampedToTheSliderRange() {
        ScreenshotPreferences.annotationLineWidth = 0.05
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, 0.016, accuracy: 0.0001)
        ScreenshotPreferences.annotationLineWidth = 0.0001
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, 0.0015, accuracy: 0.0001)
    }

    func testLineWidthFallsBackWhenTheStoredValueIsNotANumber() {
        UserDefaults.standard.set("wide", forKey: ScreenshotPreferences.annotationLineWidthKey)
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, ScreenshotPreferences.defaultAnnotationLineWidth)
    }

    func testInvalidAnnotationColorFallsBackToTheDefault() {
        UserDefaults.standard.set("#GGGGGG", forKey: ScreenshotPreferences.annotationColorKey)
        XCTAssertEqual(ScreenshotPreferences.annotationColor, ScreenshotPreferences.defaultAnnotationColor)
    }
}

final class AnnotationPreferencesCaptureTests: XCTestCase {
    private let keys = [
        ScreenshotPreferences.annotationColorKey,
        ScreenshotPreferences.annotationLineWidthKey,
        ScreenshotPreferences.recentAnnotationColorsKey,
    ]
    private var saved: [String: Any] = [:]

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
    func testPrepareForCaptureRestoresTheStoredColorAndLineWidth() {
        ScreenshotPreferences.annotationColor = "#112233"
        ScreenshotPreferences.annotationLineWidth = 0.012
        let session = CaptureSession()

        session.prepareForCapture()

        XCTAssertEqual(AnnotationPalette.hex(for: session.defaultStyle.color), "#112233")
        XCTAssertEqual(session.defaultStyle.lineWidth, 0.012, accuracy: 0.0001)
    }

    @MainActor
    func testStyleChangesAreWrittenBackToPreferences() {
        let session = CaptureSession()
        session.prepareForCapture()

        session.activeStyle.color = Color(.sRGB, red: 1, green: 0.5, blue: 0.25, opacity: 1)
        session.activeStyle.lineWidth = 0.01

        XCTAssertEqual(ScreenshotPreferences.annotationColor, "#FF8040")
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, 0.01, accuracy: 0.0001)
    }

    @MainActor
    func testRecentColorsAreRestoredAndRemembered() {
        ScreenshotPreferences.recentAnnotationColors = ["#102030"]
        let session = CaptureSession()
        session.prepareForCapture()
        XCTAssertEqual(session.recentAnnotationColors, ["#102030"])

        session.rememberRecentColor("#405060")

        XCTAssertEqual(session.recentAnnotationColors, ["#405060", "#102030"])
        XCTAssertEqual(ScreenshotPreferences.recentAnnotationColors, ["#405060", "#102030"])
    }

    @MainActor
    func testRecentColorSelectionMovesTheColorToTheFront() {
        ScreenshotPreferences.recentAnnotationColors = ["#102030", "#405060"]
        let session = CaptureSession()
        session.prepareForCapture()

        session.rememberRecentColor("#405060")

        XCTAssertEqual(session.recentAnnotationColors, ["#405060", "#102030"])
    }
}
