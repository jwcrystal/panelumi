import AppKit
import SwiftUI
import XCTest
@testable import PanelumiCore

final class WatermarkPreferencesTests: XCTestCase {
    private let keys = [
        ScreenshotPreferences.watermarkPlacementKey,
        ScreenshotPreferences.watermarkScaleKey,
        ScreenshotPreferences.watermarkRotationKey,
        ScreenshotPreferences.watermarkOpacityKey,
        ScreenshotPreferences.watermarkColorKey,
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
        XCTAssertEqual(ScreenshotPreferences.watermarkPlacement, .bottomRight)
        XCTAssertEqual(ScreenshotPreferences.watermarkScale, 0.02, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, 0, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkColor, "#FFFFFF")
    }

    func testValuesRoundTrip() {
        ScreenshotPreferences.watermarkPlacement = .topLeft
        ScreenshotPreferences.watermarkScale = 0.04
        ScreenshotPreferences.watermarkRotation = -30
        ScreenshotPreferences.watermarkOpacity = 0.8
        ScreenshotPreferences.watermarkColor = "#32ade6"

        XCTAssertEqual(ScreenshotPreferences.watermarkPlacement, .topLeft)
        XCTAssertEqual(ScreenshotPreferences.watermarkScale, 0.04, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, -30, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkColor, "#32ADE6")
    }

    func testValuesAreClampedToTheSliderRanges() {
        ScreenshotPreferences.watermarkScale = 1
        XCTAssertEqual(ScreenshotPreferences.watermarkScale, 0.06, accuracy: 0.0001)
        ScreenshotPreferences.watermarkScale = 0
        XCTAssertEqual(ScreenshotPreferences.watermarkScale, 0.01, accuracy: 0.0001)

        ScreenshotPreferences.watermarkRotation = 180
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, 90, accuracy: 0.0001)
        ScreenshotPreferences.watermarkRotation = -180
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, -90, accuracy: 0.0001)

        ScreenshotPreferences.watermarkOpacity = 2
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, 1, accuracy: 0.0001)
        ScreenshotPreferences.watermarkOpacity = 0
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, 0.15, accuracy: 0.0001)
    }

    func testStoredOutOfRangeValuesAreClamped() {
        UserDefaults.standard.set(9.0, forKey: ScreenshotPreferences.watermarkScaleKey)
        UserDefaults.standard.set(-900.0, forKey: ScreenshotPreferences.watermarkRotationKey)
        UserDefaults.standard.set(9.0, forKey: ScreenshotPreferences.watermarkOpacityKey)

        XCTAssertEqual(ScreenshotPreferences.watermarkScale, 0.06, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, -90, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, 1, accuracy: 0.0001)
    }

    func testNonNumberValuesFallBackToDefaults() {
        for key in [
            ScreenshotPreferences.watermarkScaleKey,
            ScreenshotPreferences.watermarkRotationKey,
            ScreenshotPreferences.watermarkOpacityKey,
        ] {
            UserDefaults.standard.set("wide", forKey: key)
        }

        XCTAssertEqual(ScreenshotPreferences.watermarkScale, ScreenshotPreferences.defaultWatermarkScale)
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, ScreenshotPreferences.defaultWatermarkRotation)
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, ScreenshotPreferences.defaultWatermarkOpacity)
    }

    func testInvalidPlacementFallsBackToTheDefault() {
        UserDefaults.standard.set("sideways", forKey: ScreenshotPreferences.watermarkPlacementKey)
        XCTAssertEqual(ScreenshotPreferences.watermarkPlacement, ScreenshotPreferences.defaultWatermarkPlacement)
    }

    func testInvalidColorFallsBackToTheDefault() {
        for value in ["", "red", "#FFF", "#GGGGGG"] {
            UserDefaults.standard.set(value, forKey: ScreenshotPreferences.watermarkColorKey)
            XCTAssertEqual(ScreenshotPreferences.watermarkColor, ScreenshotPreferences.defaultWatermarkColor, value)
        }
    }
}

final class WatermarkCaptureDefaultsTests: XCTestCase {
    private let keys = [
        ScreenshotPreferences.watermarkPlacementKey,
        ScreenshotPreferences.watermarkScaleKey,
        ScreenshotPreferences.watermarkRotationKey,
        ScreenshotPreferences.watermarkOpacityKey,
        ScreenshotPreferences.watermarkColorKey,
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
    func testPrepareForCaptureAppliesTheStoredAppearance() {
        ScreenshotPreferences.watermarkPlacement = .center
        ScreenshotPreferences.watermarkScale = 0.04
        ScreenshotPreferences.watermarkRotation = -30
        ScreenshotPreferences.watermarkOpacity = 0.8
        ScreenshotPreferences.watermarkColor = "#32ADE6"

        let session = CaptureSession()
        session.prepareForCapture()

        XCTAssertEqual(session.watermarkPlacement, .center)
        XCTAssertEqual(session.watermarkScale, 0.04, accuracy: 0.0001)
        XCTAssertEqual(session.watermarkRotation, -30, accuracy: 0.0001)
        XCTAssertEqual(session.watermarkOpacity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(AnnotationPalette.hex(for: session.watermarkColor), "#32ADE6")
    }

    @MainActor
    func testEditorChangesStayInTheSession() {
        ScreenshotPreferences.watermarkPlacement = .topLeft
        ScreenshotPreferences.watermarkScale = 0.03
        ScreenshotPreferences.watermarkRotation = 15
        ScreenshotPreferences.watermarkOpacity = 0.7
        ScreenshotPreferences.watermarkColor = "#34C759"

        let session = CaptureSession()
        session.prepareForCapture()

        session.watermarkPlacement = .tiled
        session.watermarkScale = 0.05
        session.watermarkRotation = -45
        session.watermarkOpacity = 0.3
        session.watermarkColor = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)

        XCTAssertEqual(ScreenshotPreferences.watermarkPlacement, .topLeft)
        XCTAssertEqual(ScreenshotPreferences.watermarkScale, 0.03, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkRotation, 15, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkOpacity, 0.7, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotPreferences.watermarkColor, "#34C759")
    }
}
