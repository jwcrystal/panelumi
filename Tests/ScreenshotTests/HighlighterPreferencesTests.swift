import XCTest
@testable import PanelumiCore

/// Runs against the test process's own defaults domain, restored afterwards.
final class HighlighterPreferencesTests: XCTestCase {
    private let keys = [
        ScreenshotPreferences.highlighterWidthKey,
        ScreenshotPreferences.highlighterStraightKey,
        ScreenshotPreferences.annotationLineWidthKey,
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

    func testDefaultSitsInsideTheBandRange() {
        XCTAssertEqual(ScreenshotPreferences.highlighterWidth, ScreenshotPreferences.defaultHighlighterWidth)
        XCTAssertTrue(ScreenshotPreferences.highlighterWidthRange.contains(ScreenshotPreferences.defaultHighlighterWidth))
    }

    func testStoredWidthIsClampedToTheRange() {
        ScreenshotPreferences.highlighterWidth = 0.5
        XCTAssertEqual(ScreenshotPreferences.highlighterWidth,
                       ScreenshotPreferences.highlighterWidthRange.upperBound, accuracy: 1e-9)

        ScreenshotPreferences.highlighterWidth = 0
        XCTAssertEqual(ScreenshotPreferences.highlighterWidth,
                       ScreenshotPreferences.highlighterWidthRange.lowerBound, accuracy: 1e-9)
    }

    func testUnreadableStoredWidthFallsBackToTheDefault() {
        UserDefaults.standard.set("wide", forKey: ScreenshotPreferences.highlighterWidthKey)
        XCTAssertEqual(ScreenshotPreferences.highlighterWidth, ScreenshotPreferences.defaultHighlighterWidth)
    }

    @MainActor
    func testSessionKeepsTheBandWidthApartFromThePenWidth() {
        ScreenshotPreferences.annotationLineWidth = 0.009
        ScreenshotPreferences.highlighterWidth = 0.012
        let session = CaptureSession()
        session.prepareForCapture()
        XCTAssertEqual(session.defaultStyle.lineWidth, 0.009, accuracy: 1e-9)
        XCTAssertEqual(session.defaultStyle.highlighterWidth, 0.012, accuracy: 1e-9)

        session.defaultStyle.highlighterWidth = 0.017
        XCTAssertEqual(ScreenshotPreferences.highlighterWidth, 0.017, accuracy: 1e-9)
        XCTAssertEqual(ScreenshotPreferences.annotationLineWidth, 0.009, accuracy: 1e-9,
                       "moving the band leaves the pen width alone")

        session.defaultStyle.lineWidth = 0.015
        XCTAssertEqual(ScreenshotPreferences.highlighterWidth, 0.017, accuracy: 1e-9,
                       "moving the pen leaves the band width alone")
    }

    func testWidthLevelsCoverOneToTen() {
        let range = ScreenshotPreferences.highlighterWidthRange
        XCTAssertEqual(CaptureToolbarView.highlighterWidthLevel(for: range.lowerBound), 1)
        XCTAssertEqual(CaptureToolbarView.highlighterWidthLevel(for: range.upperBound), 10)
        XCTAssertEqual(CaptureToolbarView.highlighterWidthLevel(for: 0), 1)
        XCTAssertEqual(CaptureToolbarView.highlighterWidthLevel(for: 1), 10)
    }

    @MainActor
    func testStraightModeIsRememberedBetweenCaptures() {
        let session = CaptureSession()
        session.prepareForCapture()
        XCTAssertTrue(session.highlighterStraight, "the straight band is the default")

        session.highlighterStraight = false
        XCTAssertFalse(ScreenshotPreferences.highlighterStraight)

        let next = CaptureSession()
        next.prepareForCapture()
        XCTAssertFalse(next.highlighterStraight, "the mode survives the next capture")
    }
}
