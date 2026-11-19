import AppKit
import XCTest
@testable import PanelumiCore

/// A capture that cannot work must say so before it draws anything: the
/// overlay is the wrong place to discover a missing grant.
final class CapturePermissionTests: XCTestCase {
    @MainActor
    func testCaptureDoesNotOpenWithoutTheScreenRecordingGrant() {
        let coordinator = ScreenshotCoordinator()
        var permissionRequests = 0
        coordinator.screenRecordingGranted = { false }
        coordinator.onPermissionFailure = { permissionRequests += 1 }

        coordinator.begin()

        XCTAssertFalse(coordinator.isSelectionActive)
        XCTAssertEqual(permissionRequests, 1)
    }

    @MainActor
    func testTextRecognitionDoesNotOpenWithoutTheScreenRecordingGrant() {
        let coordinator = ScreenshotCoordinator()
        var permissionRequests = 0
        coordinator.screenRecordingGranted = { false }
        coordinator.onPermissionFailure = { permissionRequests += 1 }

        coordinator.beginTextRecognition()

        XCTAssertFalse(coordinator.isSelectionActive)
        XCTAssertEqual(permissionRequests, 1)
    }

    @MainActor
    func testCaptureOpensWhenTheGrantIsPresent() async throws {
        let coordinator = ScreenshotCoordinator()
        coordinator.screenRecordingGranted = { true }
        // The freeze and the overlay's colour sample would otherwise reach
        // ScreenCaptureKit: a test process must never trigger a TCC request.
        coordinator.displayCaptureHook = { _ in nil }
        coordinator.regionCaptureHook = { _, _ in nil }
        coordinator.onPermissionFailure = { XCTFail("The grant is present, so nothing may ask for it") }

        coordinator.begin()
        defer { cancelOverlay() }
        for _ in 0..<1_000 {
            if coordinator.isSelectionActive { break }
            await Task.yield()
        }

        XCTAssertTrue(coordinator.isSelectionActive)
    }

    /// A nil region capture with the grant gone is a permission failure, not an
    /// empty selection; only the first one has an answer in the checklist.
    @MainActor
    func testRegionFailureNamesThePermissionWhenTheGrantIsGone() {
        guard case .permission = ScreenshotCoordinator.regionCaptureFailure(permissionGranted: false) else {
            return XCTFail("A missing grant must surface as .permission")
        }
        guard case .captureFailed = ScreenshotCoordinator.regionCaptureFailure(permissionGranted: true) else {
            return XCTFail("With the grant, a nil capture is the selection's fault")
        }
    }

    @MainActor
    func testAbortClosesTheOverlayWithoutDelivering() {
        let controller = SelectionController()
        var captured = false
        var cancelled = false
        controller.begin(
            onCapture: { _, _ in captured = true },
            onCancel: { cancelled = true },
            captureBase: { _, _ in nil },
            captureWindows: { _, _, _ in nil }
        )

        controller.abort()

        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(captured)
    }

    /// Closes whatever overlay `begin` opened, so a failure cannot leave one up.
    @MainActor
    private func cancelOverlay() {
        for window in NSApp.windows {
            guard let view = window.contentView as? SelectionView else { continue }
            view.onCancel?()
        }
    }
}
