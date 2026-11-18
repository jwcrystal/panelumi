import XCTest
@testable import PanelumiCore

/// The keyboard belongs to the capture overlay for as long as the session is
/// live and nothing else has a claim on it.
final class CaptureFocusPolicyTests: XCTestCase {
    func testTheOverlayClaimsTheKeyboardOnlyDuringALiveSessionInAnActiveApp() {
        XCTAssertTrue(policy(session: true, app: true, takeover: false).claimsKeyboard)
        XCTAssertFalse(policy(session: true, app: false, takeover: false).claimsKeyboard)
        XCTAssertFalse(policy(session: false, app: true, takeover: false).claimsKeyboard)
        XCTAssertFalse(policy(session: false, app: false, takeover: false).claimsKeyboard)
    }

    func testATakeoverKeepsTheKeyboardItHandedToItsExtension() {
        XCTAssertFalse(policy(session: true, app: true, takeover: true).claimsKeyboard)
        XCTAssertFalse(policy(session: true, app: false, takeover: true).claimsKeyboard)
        XCTAssertFalse(policy(session: false, app: true, takeover: true).claimsKeyboard)
        XCTAssertFalse(policy(session: false, app: false, takeover: true).claimsKeyboard)
    }

    func testCaptureKeysAreOwnedWhetherOrNotTheOverlayIsKey() {
        XCTAssertTrue(policy(session: true, takeover: false).ownsKeyEvent(overlayIsKey: true))
        XCTAssertTrue(policy(session: true, takeover: false).ownsKeyEvent(overlayIsKey: false))
    }

    func testATakeoverLeavesKeysWithAnAttachedKeyWindow() {
        XCTAssertTrue(policy(session: true, takeover: true).ownsKeyEvent(overlayIsKey: true))
        XCTAssertFalse(policy(session: true, takeover: true).ownsKeyEvent(overlayIsKey: false))
    }

    func testNoKeyBelongsToTheCaptureOnceTheSessionEnds() {
        for takeover in [false, true] {
            for overlayIsKey in [false, true] {
                XCTAssertFalse(
                    policy(session: false, takeover: takeover).ownsKeyEvent(overlayIsKey: overlayIsKey),
                    "session ended, takeover \(takeover), overlay key \(overlayIsKey)"
                )
            }
        }
    }

    private func policy(
        session: Bool,
        app: Bool = true,
        takeover: Bool = false
    ) -> CaptureFocusPolicy {
        CaptureFocusPolicy(sessionActive: session, appActive: app, takeoverActive: takeover)
    }
}
