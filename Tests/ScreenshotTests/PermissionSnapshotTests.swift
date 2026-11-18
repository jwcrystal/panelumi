import AVFoundation
import XCTest
@testable import PanelumiCore

/// The checklist rules with no TCC behind them: what counts as missing, and when
/// a Screen Recording grant still needs a relaunch.
final class PermissionSnapshotTests: XCTestCase {
    private func snapshot(
        accessibility: Bool = true,
        screenRecording: Bool = true,
        screenRecordingAtLaunch: Bool = true,
        microphone: AVAuthorizationStatus = .authorized,
        systemEvents: PermissionCenter.AutomationState = .granted,
        finder: PermissionCenter.AutomationState = .granted
    ) -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: accessibility,
            screenRecording: screenRecording,
            screenRecordingAtLaunch: screenRecordingAtLaunch,
            microphone: microphone,
            systemEvents: systemEvents,
            finder: finder
        )
    }

    func testEverythingGrantedCountsNothingMissing() {
        let snapshot = snapshot()
        XCTAssertTrue(snapshot.allGranted)
        XCTAssertEqual(snapshot.missingCount, 0)
    }

    func testScreenRecordingIsPartOfSetup() {
        XCTAssertEqual(snapshot(screenRecording: false).missing, [.screenRecording])
    }

    func testEveryShippedFeatureIsRepresented() {
        let missing = PermissionSnapshot(
            accessibility: false,
            screenRecording: false,
            microphone: .denied,
            systemEvents: .denied,
            finder: .denied
        ).missing
        XCTAssertEqual(missing, [.accessibility, .screenRecording, .microphone, .systemEvents, .finder])
    }

    func testAnUnansweredAutomationQueryIsNotCountedAsMissing() {
        // `unknown` means the target app is not running, not that the grant was
        // refused, so the menu must not advertise it as something to fix.
        XCTAssertTrue(snapshot(systemEvents: .unknown, finder: .unknown).allGranted)
    }

    func testGrantArrivingAfterLaunchNeedsARelaunch() {
        XCTAssertTrue(snapshot(screenRecordingAtLaunch: false).screenRecordingRelaunchNeeded)
    }

    func testGrantPresentAtLaunchNeedsNoRelaunch() {
        XCTAssertFalse(snapshot().screenRecordingRelaunchNeeded)
    }

    func testMissingGrantNeedsNoRelaunchYet() {
        XCTAssertFalse(snapshot(screenRecording: false, screenRecordingAtLaunch: false).screenRecordingRelaunchNeeded)
    }
}
